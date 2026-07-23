#!/usr/bin/env python3
"""为严格 CPU 启动提供不可复用的进程组锚点与 pidfd 信号入口。"""

from __future__ import annotations

import argparse
import ctypes
import os
import pathlib
import signal
import subprocess
import sys
import time
from collections.abc import Sequence


PR_SET_PDEATHSIG = 1
TERMINATION_SIGNALS = {
    "HUP": signal.SIGHUP,
    "INT": signal.SIGINT,
    "QUIT": signal.SIGQUIT,
    "TERM": signal.SIGTERM,
    "KILL": signal.SIGKILL,
    "USR1": signal.SIGUSR1,
}


def process_identity(pid: int) -> tuple[str, str, int] | None:
    """返回 state/starttime/pgid；comm 中的括号不会干扰尾字段解析。"""

    try:
        raw = pathlib.Path(f"/proc/{pid}/stat").read_text(encoding="ascii")
    except OSError:
        return None
    _prefix, separator, suffix = raw.rpartition(")")
    fields = suffix.split() if separator else []
    try:
        return (fields[0], fields[19], int(fields[2])) if len(fields) > 19 else None
    except (ValueError, IndexError):
        return None


def generation_is_live(pid: int, starttime: str) -> bool:
    identity = process_identity(pid)
    return identity is not None and identity[0] not in {"X", "x", "Z", "z"} \
        and identity[1] == starttime


def send_bound_signal(pid: int, starttime: str, signum: signal.Signals) -> bool:
    """用 pidfd 绑定进程对象，复核 starttime 后发送信号。"""

    if not hasattr(os, "pidfd_open") or not hasattr(signal, "pidfd_send_signal"):
        return False
    try:
        pidfd = os.pidfd_open(pid, 0)
    except ProcessLookupError:
        return False
    except OSError:
        return False
    try:
        if not generation_is_live(pid, starttime):
            return False
        signal.pidfd_send_signal(pidfd, signum)
        return True
    except (OSError, PermissionError, ProcessLookupError):
        return False
    finally:
        os.close(pidfd)


def runtime_pidfd_supported() -> bool:
    """实际验证当前内核与 seccomp 允许 pidfd 信号通道。"""

    if not hasattr(os, "pidfd_open") \
            or not hasattr(signal, "pidfd_send_signal") \
            or not hasattr(os, "setsid"):
        return False
    self_pid = os.getpid()
    identity = process_identity(self_pid)
    if identity is None or identity[0] in {"X", "x", "Z", "z"}:
        return False
    try:
        pidfd = os.pidfd_open(self_pid, 0)
    except (OSError, PermissionError, ProcessLookupError):
        return False
    try:
        # 不能只依赖 Python 编译时的 API 存在性；信号 0 不改变进程状态，
        # 却会真正穿过当前内核和运行时 seccomp 规则。
        if not generation_is_live(self_pid, identity[1]):
            return False
        signal.pidfd_send_signal(pidfd, 0)
        return True
    except (OSError, PermissionError, ProcessLookupError):
        return False
    finally:
        os.close(pidfd)


def set_parent_death_signal() -> bool:
    """让内核在原监督父代消失时向锚点发送 SIGUSR2。"""

    try:
        libc = ctypes.CDLL(None, use_errno=True)
        result = libc.prctl(PR_SET_PDEATHSIG, int(signal.SIGUSR2), 0, 0, 0)
    except (AttributeError, OSError):
        return False
    return result == 0


def normalize_returncode(returncode: int | None, fallback: int = 1) -> int:
    if returncode is None:
        return fallback
    if returncode < 0:
        return min(255, 128 + abs(returncode))
    return min(255, returncode)


def sentinel_main(parent_pid: int, parent_start: str, pgid: int) -> int:
    """guard 被不可捕获地终止时，仍保持 PGID 并独立清理整个命令组。"""

    state = {"disarmed": False, "parent_dead": False}

    def handle_usr1(_signum: int, _frame: object) -> None:
        state["disarmed"] = True

    def handle_usr2(_signum: int, _frame: object) -> None:
        state["parent_dead"] = True

    signal.signal(signal.SIGUSR1, handle_usr1)
    signal.signal(signal.SIGUSR2, handle_usr2)
    for signum in (signal.SIGHUP, signal.SIGINT, signal.SIGQUIT, signal.SIGTERM):
        signal.signal(signum, signal.SIG_IGN)
    if not set_parent_death_signal() or os.getppid() != parent_pid \
            or not generation_is_live(parent_pid, parent_start):
        state["parent_dead"] = True
    while not state["disarmed"] and not state["parent_dead"]:
        if not generation_is_live(parent_pid, parent_start):
            state["parent_dead"] = True
            break
        time.sleep(0.02)
    if state["disarmed"]:
        return 0
    try:
        os.killpg(pgid, signal.SIGTERM)
    except ProcessLookupError:
        return 0
    time.sleep(0.5)
    try:
        os.killpg(pgid, signal.SIGKILL)
    except ProcessLookupError:
        return 0
    return 1


class StrictGroupGuard:
    """保持 PGID leader 存活，直到命令组清空或严格启动被撤销。"""

    def __init__(self, parent_pid: int, parent_start: str,
                 command: Sequence[str]) -> None:
        self.parent_pid = parent_pid
        self.parent_start = parent_start
        self.command = list(command)
        self.self_pid = os.getpid()
        self.adopted = False
        self.termination: signal.Signals | None = None
        self.child: subprocess.Popen[bytes] | None = None
        self.sentinel_pid: int | None = None
        self.sentinel_start: str | None = None

    def _handle_signal(self, signum: int, _frame: object) -> None:
        received = signal.Signals(signum)
        if received == signal.SIGUSR1:
            self.adopted = True
        elif received == signal.SIGUSR2:
            if not self.adopted:
                self.termination = signal.SIGTERM
        elif received in {signal.SIGHUP, signal.SIGINT, signal.SIGQUIT,
                          signal.SIGTERM}:
            self.termination = received

    def _install_handlers(self) -> None:
        for signum in (signal.SIGHUP, signal.SIGINT, signal.SIGQUIT,
                       signal.SIGTERM, signal.SIGUSR1, signal.SIGUSR2):
            signal.signal(signum, self._handle_signal)

    def _other_group_members(self) -> list[int]:
        members: list[int] = []
        for stat_path in pathlib.Path("/proc").glob("[0-9]*/stat"):
            try:
                pid = int(stat_path.parent.name)
            except ValueError:
                continue
            if pid == self.self_pid or pid == self.sentinel_pid:
                continue
            identity = process_identity(pid)
            if identity is not None and identity[0] not in {"X", "x", "Z", "z"} \
                    and identity[2] == self.self_pid:
                members.append(pid)
        return members

    def _spawn_sentinel(self) -> bool:
        identity = process_identity(self.self_pid)
        if identity is None:
            return False
        child_pid = os.fork()
        if child_pid == 0:
            status = sentinel_main(self.self_pid, identity[1], self.self_pid)
            os._exit(status)
        self.sentinel_pid = child_pid
        for _attempt in range(50):
            sentinel_identity = process_identity(child_pid)
            if sentinel_identity is not None \
                    and sentinel_identity[0] not in {"X", "x", "Z", "z"}:
                self.sentinel_start = sentinel_identity[1]
                return True
            time.sleep(0.01)
        return False

    def _disarm_sentinel(self) -> bool:
        if self.sentinel_pid is None or self.sentinel_start is None:
            return False
        if not send_bound_signal(
            self.sentinel_pid, self.sentinel_start, signal.SIGUSR1
        ):
            return False
        deadline = time.monotonic() + 1.0
        while time.monotonic() < deadline:
            waited, _status = os.waitpid(self.sentinel_pid, os.WNOHANG)
            if waited == self.sentinel_pid:
                self.sentinel_pid = None
                self.sentinel_start = None
                return True
            time.sleep(0.01)
        return False

    def _terminate_group(self, requested: signal.Signals) -> int:
        """锚点捕获首个信号并保持 PGID，宽限后再对同一组升级 KILL。"""

        try:
            os.killpg(self.self_pid, requested)
        except ProcessLookupError:
            pass
        deadline = time.monotonic() + 0.5
        while self._other_group_members() and time.monotonic() < deadline:
            time.sleep(0.02)
        if self._other_group_members():
            os.killpg(self.self_pid, signal.SIGKILL)
        self._disarm_sentinel()
        return 128 + int(requested)

    def run(self) -> int:
        self._install_handlers()
        if not set_parent_death_signal():
            print("ERROR: 无法设置严格启动父代死亡信号", file=sys.stderr)
            return 1
        if os.getppid() != self.parent_pid \
                or not generation_is_live(self.parent_pid, self.parent_start):
            return 1
        try:
            os.setsid()
        except OSError as exc:
            print(f"ERROR: 无法建立严格启动 session: {exc}", file=sys.stderr)
            return 1
        if self.termination is not None:
            return self._terminate_group(self.termination)
        if not self._spawn_sentinel():
            print("ERROR: 无法建立严格启动 PGID sentinel", file=sys.stderr)
            return 1
        try:
            # 与原 setsid+exec 路径一致保留实例锁 FD8 和调用方明确留下的描述符。
            self.child = subprocess.Popen(self.command, close_fds=False)
        except OSError as exc:
            print(f"ERROR: 无法启动严格 QEMU 命令: {exc}", file=sys.stderr)
            return 1

        child_return: int | None = None
        while True:
            if self.termination is not None:
                return self._terminate_group(self.termination)
            if child_return is None:
                child_return = self.child.poll()
                if child_return is None:
                    # 正常 VM 运行期只做 O(1) 的直接子进程检查。对每台 VM
                    # 每 20ms 扫描全部 /proc 会在多 VM 宿主上常驻占用 CPU。
                    time.sleep(0.02)
                    continue
            if not self.adopted:
                # paused/握手阶段即便包装命令先退出，也只等待父代明确 adopt 或撤销；
                # sentinel 仍负责父代突然死亡，期间无需扫描同组后代。
                time.sleep(0.02)
                continue
            # 只有直接命令已退出时，才检查是否仍有同 PGID 后代。
            # 这覆盖包装器组长早退的情况，又不影响长时间运行的 QEMU。
            members = self._other_group_members()
            if child_return is not None and self.adopted and not members:
                if not self._disarm_sentinel():
                    return self._terminate_group(signal.SIGTERM)
                return normalize_returncode(child_return)
            # 包装器组长已退出但 QEMU 后代仍长时间运行时，也把
            # 全表检查限制为每 0.5 秒一次；最终退出延迟上界可接受。
            time.sleep(0.5)


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="VMate strict process group guard")
    subparsers = parser.add_subparsers(dest="action", required=True)
    subparsers.add_parser("check")
    identity_parser = subparsers.add_parser("identity")
    identity_parser.add_argument("pid", type=int)
    run_parser = subparsers.add_parser("run")
    run_parser.add_argument("parent_pid", type=int)
    run_parser.add_argument("parent_start")
    run_parser.add_argument("command", nargs=argparse.REMAINDER)
    signal_parser = subparsers.add_parser("signal")
    signal_parser.add_argument("pid", type=int)
    signal_parser.add_argument("starttime")
    signal_parser.add_argument("signal", choices=tuple(TERMINATION_SIGNALS))
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    if args.action == "check":
        return 0 if runtime_pidfd_supported() else 1
    if args.action == "identity":
        identity = process_identity(args.pid)
        if identity is None:
            return 1
        print(identity[0], identity[1], identity[2])
        return 0
    if args.action == "signal":
        return 0 if send_bound_signal(
            args.pid, args.starttime, TERMINATION_SIGNALS[args.signal]
        ) else 1
    command = list(args.command)
    if command[:1] == ["--"]:
        command = command[1:]
    if not args.parent_start.isdigit() or not command:
        return 2
    return StrictGroupGuard(args.parent_pid, args.parent_start, command).run()


if __name__ == "__main__":
    raise SystemExit(main())
