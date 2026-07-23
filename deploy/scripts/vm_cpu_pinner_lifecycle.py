#!/usr/bin/env python3
"""QMP 启动闸门与 CPU 隔离分区的生命周期管理。

该模块只负责有状态的 QMP/进程操作；NUMA 放置算法位于 ``vm_cpu_placement.py``，
避免并发、超时和清理分支污染可纯函数测试的拓扑代码。
"""

from __future__ import annotations

import json
import os
import pathlib
import select
import signal
import socket
import subprocess
import sys
import time
from types import TracebackType
from typing import Any


class QmpError(RuntimeError):
    """QMP 帧、响应或进程代际不符合严格启动契约。"""


def log(message: str) -> None:
    try:
        print(f">> CPU 隔离:   {message}", file=sys.stderr, flush=True)
    except (BrokenPipeError, OSError):
        # 启动终端断开不能杀死已经接管 exact child 的清理者。
        try:
            sys.stderr = open(os.devnull, "w", encoding="utf-8")
        except OSError:
            pass


class _QmpSession:
    """每次连接独立协商 capabilities，并按 id 跳过异步 event。"""

    def __init__(self, path: str, timeout: float = 2.0) -> None:
        self.path = path
        self.timeout = timeout
        self.client: socket.socket | None = None
        self.stream: Any = None
        self.sequence = 0

    def __enter__(self) -> _QmpSession:
        try:
            self.client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            self.client.settimeout(self.timeout)
            self.client.connect(self.path)
            self.stream = self.client.makefile("rw", encoding="utf-8")
            greeting = self._read_json()
            if "QMP" not in greeting:
                raise QmpError("缺少 QMP greeting")
            self.execute("qmp_capabilities")
            return self
        except BaseException:
            self._close()
            raise

    def __exit__(
        self,
        _kind: type[BaseException] | None,
        _value: BaseException | None,
        _traceback: TracebackType | None,
    ) -> None:
        self._close()

    def _close(self) -> None:
        if self.stream is not None:
            try:
                self.stream.close()
            except OSError:
                pass
            self.stream = None
        if self.client is not None:
            self.client.close()
            self.client = None

    def _read_json(self) -> dict[str, Any]:
        line = self.stream.readline()
        if not line:
            raise QmpError("QMP 连接提前关闭")
        value = json.loads(line)
        if not isinstance(value, dict):
            raise QmpError("QMP 响应不是对象")
        return value

    def execute(self, command: str) -> Any:
        self.sequence += 1
        ident = f"vmate-pin-{self.sequence}"
        request = {"execute": command, "id": ident}
        if self.client is not None:
            self.client.settimeout(self.timeout)
        self.stream.write(json.dumps(request) + "\n")
        self.stream.flush()
        deadline = time.monotonic() + self.timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError(f"QMP {command} 响应超时")
            if self.client is not None:
                self.client.settimeout(remaining)
            response = self._read_json()
            if response.get("id") != ident:
                continue
            if "error" in response:
                raise QmpError(f"QMP {command} 失败: {response['error']}")
            if "return" not in response:
                raise QmpError(f"QMP {command} 缺少 return")
            return response["return"]


def tgid_of(tid: int) -> int | None:
    try:
        lines = pathlib.Path(f"/proc/{tid}/status").read_text().splitlines()
    except OSError:
        return None
    for line in lines:
        if line.startswith("Tgid:"):
            fields = line.split()
            return int(fields[1]) if len(fields) > 1 else None
    return None


def _process_state_and_starttime(pid: int) -> tuple[str, str] | None:
    try:
        raw = pathlib.Path(f"/proc/{pid}/stat").read_text(encoding="ascii")
    except OSError:
        return None
    _prefix, separator, suffix = raw.rpartition(")")
    fields = suffix.split() if separator else []
    return (fields[0], fields[19]) if len(fields) > 19 else None


def process_starttime(pid: int) -> str | None:
    """读取 /proc stat 的启动 tick；和 PID 一起抵御退出后的 PID 复用。"""

    identity = _process_state_and_starttime(pid)
    return identity[1] if identity is not None else None


def process_pgid(pid: int) -> int | None:
    """读取 /proc stat 的进程组；和 supervisor 传入值共同绑定启动链。"""

    try:
        raw = pathlib.Path(f"/proc/{pid}/stat").read_text(encoding="ascii")
    except OSError:
        return None
    _prefix, separator, suffix = raw.rpartition(")")
    fields = suffix.split() if separator else []
    try:
        return int(fields[2]) if len(fields) > 2 else None
    except ValueError:
        return None


def emit_supervisor_status(status_fd: int | None, message: str) -> bool:
    """向仅由严格启动父 shell 持有读端的管道写入一条状态记录。"""

    if status_fd is None:
        return True
    payload = f"{message}\n".encode("ascii", errors="strict")
    try:
        while payload:
            written = os.write(status_fd, payload)
            if written <= 0:
                return False
            payload = payload[written:]
        return True
    except (BrokenPipeError, OSError):
        return False


def process_matches(pid: int | None, starttime: str | None) -> bool:
    if pid is None or starttime is None:
        return False
    identity = _process_state_and_starttime(pid)
    return identity is not None and identity[0] not in {"X", "x", "Z", "z"} \
        and identity[1] == starttime


def query_vcpus(sock_path: str, expected_count: int,
                 timeout: float = 90.0, launcher_pid: int | None = None,
                 launcher_starttime: str | None = None,
                 orphan_grace: float = 2.5) -> list[tuple[int, int]]:
    """等待固定数量、连续 cpu-index 的 vCPU TID 集合。"""

    deadline = time.monotonic() + timeout
    orphan_deadline: float | None = None
    while time.monotonic() < deadline:
        if launcher_pid is not None and launcher_starttime is not None \
                and not process_matches(launcher_pid, launcher_starttime):
            if orphan_deadline is None:
                orphan_deadline = time.monotonic() + max(0.0, orphan_grace)
                deadline = min(deadline, orphan_deadline)
                log("⚠ 启动器已退出，短暂守候可能仍存活的 QEMU 子进程")
        try:
            with _QmpSession(sock_path) as session:
                entries = session.execute("query-cpus-fast")
            result = sorted(
                (int(entry["cpu-index"]), int(entry["thread-id"]))
                for entry in entries
                if "thread-id" in entry
            )
            if len(result) == expected_count \
                    and [index for index, _tid in result] == list(range(expected_count)):
                return result
        except (OSError, TimeoutError, ValueError, TypeError, KeyError,
                json.JSONDecodeError, QmpError):
            pass
        time.sleep(0.25)
    return []


def _session_matches_process(
    session: _QmpSession, pid: int, starttime: str,
) -> bool:
    if not process_matches(pid, starttime):
        return False
    entries = session.execute("query-cpus-fast")
    tids = [int(entry["thread-id"]) for entry in entries if "thread-id" in entry]
    return bool(tids) and all(tgid_of(tid) == pid for tid in tids)


def request_qmp_command(
    sock_path: str,
    command: str,
    pid: int | None = None,
    starttime: str | None = None,
    timeout: float = 10.0,
) -> bool:
    """幂等执行 ``cont``/``quit``，并在已知时核对 QMP 对应的进程代际。"""

    if command not in {"cont", "quit"}:
        return False
    deadline = time.monotonic() + timeout
    last_error = "QMP socket 未就绪"
    while time.monotonic() < deadline:
        if pid is not None and starttime is not None \
                and not process_matches(pid, starttime):
            return command == "quit"
        try:
            with _QmpSession(sock_path) as session:
                if pid is not None and starttime is not None \
                        and not _session_matches_process(session, pid, starttime):
                    raise QmpError("QMP socket 不属于已绑定的 QEMU 代际")
                if command == "cont":
                    status = session.execute("query-status")
                    if isinstance(status, dict) and status.get("status") == "running":
                        log("CPU 隔离完成，QEMU 已处于 running")
                        return True
                session.execute(command)
            if command == "cont":
                log("CPU 隔离完成，已 QMP cont")
                return True
            if pid is None or starttime is None \
                    or _wait_until_gone(pid, starttime, 1.0):
                log("严格绑核失败，QEMU 已退出")
                return True
        except (OSError, TimeoutError, ValueError, TypeError, KeyError,
                json.JSONDecodeError, QmpError) as exc:
            last_error = str(exc)
            # cont 可能已经执行，只是响应在传输中丢失；下一轮先 query-status，
            # 看到 running 就成功，绝不能把已经正确隔离的来宾误判为失败。
            if command == "quit" and pid is not None and starttime is not None \
                    and not process_matches(pid, starttime):
                log("严格绑核失败，QEMU 已退出")
                return True
        time.sleep(0.2)
    log(f"⚠ 无法执行 QMP {command}: {last_error}")
    return False


def request_qmp_quit(
    sock_path: str,
    pid: int | None = None,
    starttime: str | None = None,
    timeout: float = 10.0,
) -> bool:
    return request_qmp_command(sock_path, "quit", pid, starttime, timeout)


def _wait_until_gone(pid: int, starttime: str, timeout: float | None) -> bool:
    if hasattr(os, "pidfd_open"):
        try:
            pidfd = os.pidfd_open(pid, 0)
        except ProcessLookupError:
            return True
        except OSError:
            pidfd = -1
        if pidfd >= 0:
            try:
                if not process_matches(pid, starttime):
                    return True
                poller = select.poll()
                poller.register(pidfd, select.POLLIN)
                milliseconds = None if timeout is None else max(1, int(timeout * 1000))
                return bool(poller.poll(milliseconds))
            finally:
                os.close(pidfd)
    deadline = None if timeout is None else time.monotonic() + timeout
    while process_matches(pid, starttime):
        if deadline is not None and time.monotonic() >= deadline:
            return False
        time.sleep(0.2)
    return True


def _send_bound_signal(pid: int, starttime: str, signum: signal.Signals) -> bool:
    """通过 pidfd 绑定旧进程对象，复核代际后再发信号，消除 PID 复用窗口。"""

    if not hasattr(os, "pidfd_open") or not hasattr(signal, "pidfd_send_signal"):
        log("⚠ 当前 Python/内核缺少 pidfd signal，拒绝用存在 PID 复用竞态的 os.kill")
        return False
    try:
        pidfd = os.pidfd_open(pid, 0)
    except ProcessLookupError:
        return True
    except OSError:
        return False
    try:
        if not process_matches(pid, starttime):
            return True
        signal.pidfd_send_signal(pidfd, signum)
        return True
    except ProcessLookupError:
        return True
    except (OSError, PermissionError):
        return False
    finally:
        os.close(pidfd)


def ignore_lifecycle_signals() -> None:
    """让后台清理者不随终端广播信号消失；SIGKILL 仍可用于人工恢复。"""

    for signum in (signal.SIGHUP, signal.SIGINT, signal.SIGQUIT, signal.SIGTERM):
        signal.signal(signum, signal.SIG_IGN)


def stop_bound_qemu(sock_path: str, pid: int, starttime: str) -> bool:
    """只终止匹配 starttime 的 QEMU，绝不向复用后的 PID 发信号。"""

    request_qmp_quit(sock_path, pid, starttime, 5.0)
    if _wait_until_gone(pid, starttime, 2.0):
        return True
    for signum, wait_seconds in ((signal.SIGTERM, 3.0), (signal.SIGKILL, 2.0)):
        if not process_matches(pid, starttime):
            return True
        if not _send_bound_signal(pid, starttime, signum):
            return False
        if _wait_until_gone(pid, starttime, wait_seconds):
            return True
    return not process_matches(pid, starttime)


def release_instance(helper: str, instance: str, attempts: int = 3) -> bool:
    """在仍持有实例锁时重试 root helper release，避免空分区耗尽容量。"""

    last_error = "未执行"
    for _attempt in range(max(1, attempts)):
        try:
            result = subprocess.run(
                ["sudo", "-n", helper, "release", instance],
                capture_output=True, text=True, check=False,
            )
            if result.returncode == 0:
                log(f"实例 {instance} 的专属 CPU 已归还宿主")
                return True
            last_error = result.stderr.strip()[:240] or f"返回 {result.returncode}"
        except (OSError, subprocess.SubprocessError) as exc:
            last_error = str(exc)
        time.sleep(0.5)
    log(f"⚠ CPU 分区 release 失败，已保留状态供 stop-vm 重试: {last_error}")
    return False


def cleanup_applied_failure(
    sock_path: str, helper: str, instance: str, pid: int, starttime: str,
) -> bool:
    """严格启动后段失败时先确认旧 QEMU 退出，再释放它的 exact child。"""

    stopped = stop_bound_qemu(sock_path, pid, starttime)
    if not stopped:
        log("⚠ 已绑定 QEMU 无法停止；为避免错放仍在使用的 CPU，保留分区")
        return False
    return release_instance(helper, instance)


def watch_and_release(helper: str, instance: str, pid: int, starttime: str) -> bool:
    """守候正常退出/崩溃；调用者持续持 FD8，release 完成后才允许新代启动。"""

    ignore_lifecycle_signals()
    _wait_until_gone(pid, starttime, None)
    return release_instance(helper, instance)
