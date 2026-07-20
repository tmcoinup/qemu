#!/usr/bin/env python3
"""验证 DDR4 EE1004 SPD 的迁移状态和 256B/512B 配置边界。"""

from __future__ import annotations

import json
import os
import pathlib
import socket
import subprocess
import tempfile
import time


REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]
QEMU = REPO_ROOT / "build" / "qemu-system-x86_64"


class LineSocket:
    """为 QMP/qtest 提供带启动超时的逐行 Unix socket。"""

    def __init__(self, path: pathlib.Path, process: subprocess.Popen[str]):
        deadline = time.monotonic() + 5
        while not path.exists():
            if process.poll() is not None:
                stderr = process.stderr.read() if process.stderr else ""
                raise RuntimeError(f"QEMU 提前退出：{stderr}")
            if time.monotonic() > deadline:
                raise TimeoutError(f"等待 socket 超时：{path}")
            time.sleep(0.01)
        self.socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.socket.connect(str(path))
        self.stream = self.socket.makefile("rwb", buffering=0)

    def close(self) -> None:
        self.stream.close()
        self.socket.close()


class TestVM:
    """最小 Q35 测试机，暴露 QMP、qtest 和 ICH9 SMBus 事务。"""

    def __init__(
        self,
        root: pathlib.Path,
        name: str,
        ee1004: bool,
        incoming: str | None = None,
    ):
        qmp_path = root / f"{name}.qmp"
        qtest_path = root / f"{name}.qtest"
        smbios = (
            "type=17,memory-type=0x1a,rank=1,device-width=16,"
            "voltage=1200,speed=2400,configured-speed=2133,"
            "manufacturer=Samsung,serial=00112233,"
            "part=M378A5644EB0-CRC"
        )
        if ee1004:
            smbios += ",spd-ee1004=on"
        command = [
            str(QEMU),
            "-machine",
            "q35",
            "-accel",
            "tcg",
            "-display",
            "none",
            "-nodefaults",
            "-S",
            "-m",
            "2G",
            "-smbios",
            smbios,
            "-qmp",
            f"unix:{qmp_path},server=on,wait=off",
            "-qtest",
            f"unix:{qtest_path},server=on,wait=off",
        ]
        if incoming:
            command.extend(("-incoming", incoming))
        self.process = subprocess.Popen(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        self.qmp = LineSocket(qmp_path, self.process)
        json.loads(self.qmp.stream.readline())
        self.qmp_command("qmp_capabilities")
        self.qtest = LineSocket(qtest_path, self.process)
        self._configure_smbus()

    def qmp_command(
        self,
        command: str,
        arguments: dict[str, object] | None = None,
    ) -> dict[str, object]:
        payload: dict[str, object] = {"execute": command}
        if arguments is not None:
            payload["arguments"] = arguments
        self.qmp.stream.write((json.dumps(payload) + "\n").encode())
        while True:
            raw_reply = self.qmp.stream.readline()
            if not raw_reply:
                raise ConnectionError(f"QMP 在 {command} 期间关闭")
            reply = json.loads(raw_reply)
            if "return" in reply or "error" in reply:
                return reply

    def qtest_command(self, command: str) -> str:
        self.qtest.stream.write((command + "\n").encode())
        reply = self.qtest.stream.readline().decode().strip()
        if not reply.startswith("OK"):
            raise RuntimeError(f"qtest 命令失败：{command!r}: {reply!r}")
        return reply

    def _outb(self, port: int, value: int) -> None:
        self.qtest_command(f"outb 0x{port:x} 0x{value:x}")

    def _inb(self, port: int) -> int:
        reply = self.qtest_command(f"inb 0x{port:x}")
        return int(reply.split()[1], 0)

    def _configure_smbus(self) -> None:
        # 给 00:1f.3 分配 I/O BAR，并启用 ICH9 SMBus host controller。
        self.qtest_command("outl 0xcf8 0x8000fb20")
        self.qtest_command("outl 0xcfc 0x0000b101")
        self.qtest_command("outl 0xcf8 0x8000fb04")
        self.qtest_command("outw 0xcfc 0x0001")
        self.qtest_command("outl 0xcf8 0x8000fb40")
        self.qtest_command("outb 0xcfc 0x01")
        self.smbus_base = 0xB100

    def smbus_transaction(
        self,
        address: int,
        read: bool,
        protocol: int,
        command_byte: int | None = None,
    ) -> tuple[int, int]:
        self._outb(self.smbus_base, 0xFF)
        self._outb(self.smbus_base + 4, (address << 1) | int(read))
        if command_byte is not None:
            self._outb(self.smbus_base + 3, command_byte)
        self._outb(self.smbus_base + 2, 0x40 | (protocol << 2))
        # QEMU 第一次读 status 时执行延迟的 SMBus transaction。
        self._inb(self.smbus_base)
        status = self._inb(self.smbus_base)
        value = self._inb(self.smbus_base + 5)
        return status, value

    def stop(self) -> None:
        try:
            self.qmp_command("quit")
        except (BrokenPipeError, ConnectionError, OSError):
            pass
        try:
            self.process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()
        self.qtest.close()
        self.qmp.close()


def wait_for_migration(vm: TestVM) -> str:
    """等待源端迁移进入终态，避免依赖固定 sleep。"""

    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        reply = vm.qmp_command("query-migrate")
        if "error" in reply:
            return "qmp-error"
        result = reply.get("return")
        if not isinstance(result, dict):
            raise RuntimeError(f"query-migrate 返回格式异常：{reply!r}")
        status = result.get("status")
        if status in {"completed", "failed", "cancelled"}:
            return str(status)
        time.sleep(0.02)
    return "timeout"


def wait_for_target_rejection(vm: TestVM) -> bool:
    """目标端加载错误不一定通过无 return-path 的源端状态回传。"""

    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        returncode = vm.process.poll()
        if returncode is not None:
            return returncode != 0
        try:
            reply = vm.qmp_command("query-migrate")
        except (BrokenPipeError, ConnectionError, OSError):
            time.sleep(0.02)
            continue
        result = reply.get("return")
        if isinstance(result, dict) and result.get("status") == "failed":
            return True
        time.sleep(0.02)
    return False


def start_pair(
    root: pathlib.Path,
    name: str,
    source_ee1004: bool,
    target_ee1004: bool,
) -> tuple[TestVM, TestVM, pathlib.Path]:
    migration_path = root / f"{name}.migration"
    target = TestVM(
        root,
        f"{name}-target",
        target_ee1004,
        f"unix:{migration_path}",
    )
    source = TestVM(root, f"{name}-source", source_ee1004)
    return source, target, migration_path


def migrate(source: TestVM, migration_path: pathlib.Path) -> str:
    reply = source.qmp_command("migrate", {"uri": f"unix:{migration_path}"})
    if "return" not in reply:
        raise RuntimeError(f"migrate 命令被拒绝：{reply!r}")
    return wait_for_migration(source)


def test_matching_ee1004(root: pathlib.Path) -> None:
    source, target, migration_path = start_pair(root, "matching", True, True)
    try:
        # 读 byte320 后 offset=65，且 page=1；目标应继续读到 byte321。
        status, _ = source.smbus_transaction(0x50, True, 2, 63)
        assert status == 0x02
        status, _ = source.smbus_transaction(0x37, False, 0)
        assert status == 0x02
        assert source.smbus_transaction(0x50, True, 1) == (0x02, 0x80)
        assert migrate(source, migration_path) == "completed"
        assert target.smbus_transaction(0x50, True, 1) == (0x02, 0xCE)
    finally:
        source.stop()
        target.stop()


def test_accessed_mismatched_eeprom_sizes(root: pathlib.Path) -> None:
    for name, source_size, target_size in (
        ("legacy-to-ee1004", False, True),
        ("ee1004-to-legacy", True, False),
    ):
        source, target, migration_path = start_pair(
            root, name, source_size, target_size
        )
        try:
            if source_size:
                assert source.smbus_transaction(0x37, False, 0)[0] == 0x02
            else:
                assert source.smbus_transaction(0x50, True, 2, 0)[0] == 0x02
            source_status = migrate(source, migration_path)
            assert source_status in {"completed", "failed"}
            assert wait_for_target_rejection(target), (
                f"{name} 的目标端未拒绝跨 256B/512B 配置迁移"
            )
        finally:
            source.stop()
            target.stop()


def main() -> int:
    if not QEMU.is_file():
        raise FileNotFoundError(f"缺少已构建 QEMU：{QEMU}")
    with tempfile.TemporaryDirectory() as directory:
        root = pathlib.Path(directory)
        test_matching_ee1004(root)
        test_accessed_mismatched_eeprom_sizes(root)
    print("PASS: EE1004 migration state and accessed size boundaries")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
