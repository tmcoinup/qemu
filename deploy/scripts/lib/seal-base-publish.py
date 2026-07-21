#!/usr/bin/env python3
"""以稳定源文件描述符把已验证 base 发布成独立的 root-owned inode。"""

from __future__ import annotations

import errno
import fcntl
import os
import re
import signal
import stat
import sys
from collections.abc import Sequence


FINGERPRINT_FIELDS = 9
PROC_FD_PATTERN = re.compile(r"^/proc/[1-9][0-9]*/fd/[0-9]+$")
COPY_CHUNK_BYTES = 4 * 1024 * 1024
FICLONE = 0x40049409


class PublishError(RuntimeError):
    """可向入口层直接报告的受控发布失败。"""


def invoking_user_uid() -> int:
    """解析 sudo/pkexec 的原始普通用户，拒绝无法归属到真实用户的 root 调用。"""

    for variable_name in ("SUDO_UID", "PKEXEC_UID"):
        raw_uid = os.environ.get(variable_name, "")
        if raw_uid.isdecimal() and int(raw_uid) != 0:
            return int(raw_uid)
    raise PublishError("无法确认调用方的普通用户 UID")


def file_fingerprint(file_stat: os.stat_result) -> str:
    """编码足以绑定 inode、内容版本、owner、mode 与 link count 的字段。"""

    values = (
        file_stat.st_dev,
        file_stat.st_ino,
        file_stat.st_size,
        file_stat.st_mtime_ns,
        file_stat.st_ctime_ns,
        file_stat.st_uid,
        file_stat.st_gid,
        stat.S_IMODE(file_stat.st_mode),
        file_stat.st_nlink,
    )
    return ":".join(str(value) for value in values)


def parse_fingerprint(raw_fingerprint: str) -> tuple[int, ...]:
    """严格解析调用方在 qcow2 校验前后记录的源 inode 快照。"""

    fields = raw_fingerprint.split(":")
    if len(fields) != FINGERPRINT_FIELDS:
        raise PublishError("源 base fingerprint 字段数量非法")
    try:
        values = tuple(int(field, 10) for field in fields)
    except ValueError as error:
        raise PublishError("源 base fingerprint 不是十进制整数") from error
    if any(value < 0 for value in values):
        raise PublishError("源 base fingerprint 包含负数")
    return values


def stat_tuple(file_stat: os.stat_result) -> tuple[int, ...]:
    """返回与 file_fingerprint 完全相同顺序的数值元组。"""

    return tuple(int(field) for field in file_fingerprint(file_stat).split(":"))


def open_fingerprint_target(path: str) -> int:
    """普通路径拒绝 symlink；仅允许内核生成的 /proc/PID/fd/N 稳定引用跟随。"""

    flags = os.O_RDONLY | os.O_CLOEXEC
    if not PROC_FD_PATTERN.fullmatch(path):
        flags |= os.O_NOFOLLOW
    return os.open(path, flags)


def write_all_at(destination_fd: int, data: bytes, offset: int) -> None:
    """处理 pwrite 短写，确保一个数据 extent 完整复制。"""

    written = 0
    while written < len(data):
        count = os.pwrite(destination_fd, data[written:], offset + written)
        if count <= 0:
            raise PublishError("复制 base 时发生零长度写入")
        written += count


def copy_range(
    source_fd: int,
    destination_fd: int,
    start: int,
    end: int,
) -> None:
    """复制一个实际数据 extent；洞区由目标 ftruncate 保持稀疏。"""

    offset = start
    while offset < end:
        chunk = os.pread(
            source_fd,
            min(COPY_CHUNK_BYTES, end - offset),
            offset,
        )
        if not chunk:
            raise PublishError("复制 base 时源文件提前结束")
        write_all_at(destination_fd, chunk, offset)
        offset += len(chunk)


def copy_sparse_fallback(
    source_fd: int,
    destination_fd: int,
    size: int,
) -> None:
    """无 SEEK_DATA/SEEK_HOLE 时按块复制，并跳过全零块以保留稀疏性。"""

    offset = 0
    while offset < size:
        chunk = os.pread(
            source_fd,
            min(COPY_CHUNK_BYTES, size - offset),
            offset,
        )
        if not chunk:
            raise PublishError("复制 base 时源文件提前结束")
        if any(chunk):
            write_all_at(destination_fd, chunk, offset)
        offset += len(chunk)


def copy_sparse(source_fd: int, destination_fd: int, size: int) -> None:
    """优先按文件系统 extent 复制，不把 qcow2 稀疏洞展开成真实占用。"""

    os.ftruncate(destination_fd, size)
    if size == 0:
        return

    position = 0
    try:
        while position < size:
            try:
                data_start = os.lseek(source_fd, position, os.SEEK_DATA)
            except OSError as error:
                if error.errno == errno.ENXIO:
                    break
                raise
            if data_start >= size:
                break
            data_end = min(
                os.lseek(source_fd, data_start, os.SEEK_HOLE),
                size,
            )
            if data_end <= data_start:
                raise PublishError("文件系统返回了非法 data/hole extent")
            copy_range(source_fd, destination_fd, data_start, data_end)
            position = data_end
    except OSError as error:
        if error.errno not in (errno.EINVAL, errno.ENOTSUP, errno.ENOSYS):
            raise
        os.ftruncate(destination_fd, 0)
        os.ftruncate(destination_fd, size)
        copy_sparse_fallback(source_fd, destination_fd, size)


def clone_or_copy(source_fd: int, destination_fd: int, size: int) -> None:
    """支持 reflink 时零拷贝克隆，否则退回保留稀疏洞的普通复制。"""

    try:
        fcntl.ioctl(destination_fd, FICLONE, source_fd)
        return
    except OSError as error:
        if error.errno not in (
            errno.EBADF,
            errno.EINVAL,
            errno.EOPNOTSUPP,
            errno.EXDEV,
            errno.ENOTTY,
        ):
            raise
    os.ftruncate(destination_fd, 0)
    copy_sparse(source_fd, destination_fd, size)


def entry_matches_fd(
    directory_fd: int,
    target_name: str,
    target_fd: int,
) -> bool:
    """确认可见目录项仍指向本进程以 O_EXCL 创建的目标 inode。"""

    try:
        entry_stat = os.stat(
            target_name,
            dir_fd=directory_fd,
            follow_symlinks=False,
        )
    except FileNotFoundError:
        return False
    target_stat = os.fstat(target_fd)
    return (
        stat.S_ISREG(entry_stat.st_mode)
        and entry_stat.st_dev == target_stat.st_dev
        and entry_stat.st_ino == target_stat.st_ino
    )


def publish(
    source_path: str,
    target_path: str,
    expected_fingerprint: str,
) -> str:
    """复制、复核并以 mode 0444 作为最终可见提交标志。"""

    if os.geteuid() != 0:
        raise PublishError("seal base 发布 helper 必须由 sudo 以 root 运行")
    if not PROC_FD_PATTERN.fullmatch(source_path):
        raise PublishError("源 base 必须使用 /proc/PID/fd/N 稳定引用")

    sudo_uid = invoking_user_uid()
    expected = parse_fingerprint(expected_fingerprint)

    target_path = os.path.abspath(target_path)
    target_directory = os.path.dirname(target_path)
    target_name = os.path.basename(target_path)
    if not target_name or target_name in (".", ".."):
        raise PublishError("最终 base 文件名非法")

    source_fd = -1
    directory_fd = -1
    target_fd = -1
    committed = False
    try:
        source_fd = open_fingerprint_target(source_path)
        source_stat = os.fstat(source_fd)
        if not stat.S_ISREG(source_stat.st_mode):
            raise PublishError("源 base FD 不是普通文件")
        if stat_tuple(source_stat) != expected:
            raise PublishError("源 base 在 qcow2 校验后发生变化")
        if (
            source_stat.st_uid != sudo_uid
            or stat.S_IMODE(source_stat.st_mode) != 0o444
            or source_stat.st_nlink != 1
        ):
            raise PublishError("源 base 必须是调用用户拥有的 0444 单链接 staging")

        directory_fd = os.open(
            target_directory,
            os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
        )
        target_fd = os.open(
            target_name,
            os.O_WRONLY
            | os.O_CREAT
            | os.O_EXCL
            | os.O_NOFOLLOW
            | os.O_CLOEXEC,
            0,
            dir_fd=directory_fd,
        )
        clone_or_copy(source_fd, target_fd, source_stat.st_size)
        if stat_tuple(os.fstat(source_fd)) != expected:
            raise PublishError("源 base 在 root 复制期间发生变化")

        os.fsync(target_fd)
        os.fchown(target_fd, 0, 0)
        os.fchmod(target_fd, 0o444)
        os.fsync(target_fd)
        if not entry_matches_fd(directory_fd, target_name, target_fd):
            raise PublishError("最终 base 目录项在发布期间被替换")
        os.fsync(directory_fd)
        committed = True
        return file_fingerprint(os.fstat(target_fd))
    finally:
        if not committed and directory_fd >= 0 and target_fd >= 0:
            if entry_matches_fd(directory_fd, target_name, target_fd):
                os.unlink(target_name, dir_fd=directory_fd)
                os.fsync(directory_fd)
        for file_descriptor in (target_fd, directory_fd, source_fd):
            if file_descriptor >= 0:
                os.close(file_descriptor)


def adopt(source_path: str, expected_fingerprint: str) -> str:
    """把传输落地的单链接 base inode 原地密封为 root:root 0444。"""

    if os.geteuid() != 0:
        raise PublishError("base 导入 helper 必须由 sudo 以 root 运行")
    if not PROC_FD_PATTERN.fullmatch(source_path):
        raise PublishError("待导入 base 必须使用 /proc/PID/fd/N 稳定引用")

    invoking_uid = invoking_user_uid()
    expected = parse_fingerprint(expected_fingerprint)
    source_fd = -1
    try:
        source_fd = open_fingerprint_target(source_path)
        source_stat = os.fstat(source_fd)
        if not stat.S_ISREG(source_stat.st_mode):
            raise PublishError("待导入 base FD 不是普通文件")
        if stat_tuple(source_stat) != expected:
            raise PublishError("待导入 base 在 qcow2 校验后发生变化")
        if source_stat.st_uid != invoking_uid:
            raise PublishError("待导入 base 不属于调用 sudo 的普通用户")
        if source_stat.st_nlink != 1:
            raise PublishError("待导入 base 必须是单链接文件，避免影响其它目录项")

        stable_content = (
            source_stat.st_dev,
            source_stat.st_ino,
            source_stat.st_size,
            source_stat.st_mtime_ns,
            source_stat.st_nlink,
        )
        # 先去掉全部写位，再移交给 root；最后重复 chmod，覆盖部分文件系统在
        # chown 时重算 mode 的差异。全程操作稳定 FD，不重新解析用户可替换路径。
        os.fchmod(source_fd, 0o444)
        os.fsync(source_fd)
        os.fchown(source_fd, 0, 0)
        os.fchmod(source_fd, 0o444)
        os.fsync(source_fd)

        sealed_stat = os.fstat(source_fd)
        sealed_content = (
            sealed_stat.st_dev,
            sealed_stat.st_ino,
            sealed_stat.st_size,
            sealed_stat.st_mtime_ns,
            sealed_stat.st_nlink,
        )
        if sealed_content != stable_content:
            raise PublishError("base 密封时 inode、大小或内容时间戳发生变化")
        if (
            sealed_stat.st_uid != 0
            or sealed_stat.st_gid != 0
            or stat.S_IMODE(sealed_stat.st_mode) != 0o444
        ):
            raise PublishError("目标文件系统无法落实 root:root 0444 密封属性")
        return file_fingerprint(sealed_stat)
    finally:
        if source_fd >= 0:
            os.close(source_fd)


def fingerprint(path: str) -> str:
    """从稳定 FD 读取 fingerprint，供非特权 seal 绑定 qcow2 校验结果。"""

    file_descriptor = open_fingerprint_target(path)
    try:
        file_stat = os.fstat(file_descriptor)
        if not stat.S_ISREG(file_stat.st_mode):
            raise PublishError("fingerprint 目标不是普通文件")
        return file_fingerprint(file_stat)
    finally:
        os.close(file_descriptor)


def install_signal_guards() -> None:
    """把终止信号转换为异常，确保 finally 删除 mode 000 的半发布目标。"""

    def interrupt(signum: int, _frame: object) -> None:
        raise PublishError(f"base 发布被信号 {signum} 中断")

    for signal_number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(signal_number, interrupt)


def main(arguments: Sequence[str]) -> int:
    """解析两个窄入口：普通 fingerprint 与 root publish。"""

    try:
        if len(arguments) == 2 and arguments[0] == "fingerprint":
            print(fingerprint(arguments[1]))
            return 0
        if len(arguments) == 4 and arguments[0] == "publish":
            install_signal_guards()
            print(publish(arguments[1], arguments[2], arguments[3]))
            return 0
        if len(arguments) == 3 and arguments[0] == "adopt":
            install_signal_guards()
            print(adopt(arguments[1], arguments[2]))
            return 0
        raise PublishError(
            "usage: seal-base-publish.py fingerprint PATH | "
            "publish /proc/PID/fd/N TARGET EXPECTED_FINGERPRINT | "
            "adopt /proc/PID/fd/N EXPECTED_FINGERPRINT"
        )
    except (OSError, PublishError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
