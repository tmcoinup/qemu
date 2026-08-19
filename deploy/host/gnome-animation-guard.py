#!/usr/bin/env python3
"""Run one or more G-11 SDL processes with GNOME animations disabled.

GNOME Shell's size-change effect paints an old-window clone together with the
new window.  That is subtle for ordinary applications, but looks like two
desktops for a VM scanout.  This helper changes only the current user's
``enable-animations`` setting, restores the exact previous value when the last
guarded process exits, and keeps a small runtime journal for crash recovery.
"""

from __future__ import annotations

import fcntl
import json
import os
from pathlib import Path
import signal
import stat
import subprocess
import sys
import tempfile
from typing import Any


SCHEMA = "org.gnome.desktop.interface"
KEY = "enable-animations"
STATE_VERSION = 1


def _runtime_dir() -> Path:
    override = os.environ.get("QEMU_GNOME_ANIMATION_STATE_DIR")
    if override:
        return Path(override)
    runtime = os.environ.get("XDG_RUNTIME_DIR")
    if runtime:
        return Path(runtime)
    return Path("/tmp") / f"qemu-g11-{os.getuid()}"


def _ensure_private_directory(path: Path) -> None:
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = path.lstat()
    if info.st_uid != os.getuid() or not stat.S_ISDIR(info.st_mode):
        raise RuntimeError(f"unsafe animation state directory: {path}")
    os.chmod(path, 0o700)


def _state_path() -> Path:
    return _runtime_dir() / f"qemu-g11-sdl-{os.getuid()}.gnome-animation.json"


def _lock_path() -> Path:
    return _runtime_dir() / f"qemu-g11-sdl-{os.getuid()}.gnome-animation.lock"


def _proc_root() -> Path:
    return Path(os.environ.get("QEMU_GNOME_ANIMATION_PROC_ROOT", "/proc"))


def _gsettings_command() -> str:
    return os.environ.get("QEMU_GNOME_ANIMATION_GSETTINGS", "gsettings")


def _gsettings(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [_gsettings_command(), *args],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
    )


def _get_animation_setting() -> str | None:
    result = _gsettings("get", SCHEMA, KEY)
    value = result.stdout.strip().lower()
    if result.returncode != 0 or value not in {"true", "false"}:
        return None
    return value


def _set_animation_setting(value: str) -> bool:
    if value not in {"true", "false"}:
        return False
    writable = _gsettings("writable", SCHEMA, KEY)
    if writable.returncode != 0 or writable.stdout.strip().lower() != "true":
        return False
    return _gsettings("set", SCHEMA, KEY, value).returncode == 0


def _process_start_time(pid: int) -> str | None:
    try:
        stat = (_proc_root() / str(pid) / "stat").read_text(encoding="utf-8")
        # Field 2 is parenthesized and may itself contain spaces or ')'.
        fields = stat.rsplit(")", 1)[1].split()
        return fields[19]  # proc(5) field 22: process start time.
    except (IndexError, OSError):
        return None


def _owner(pid: int) -> dict[str, Any] | None:
    start_time = _process_start_time(pid)
    if start_time is None:
        return None
    return {"pid": pid, "start_time": start_time}


def _owner_is_live(owner: object) -> bool:
    if not isinstance(owner, dict):
        return False
    pid = owner.get("pid")
    start_time = owner.get("start_time")
    return (
        isinstance(pid, int)
        and pid > 0
        and isinstance(start_time, str)
        and _process_start_time(pid) == start_time
    )


def _load_state(path: Path) -> dict[str, Any] | None:
    try:
        state = json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return None
    if not isinstance(state, dict) or state.get("version") != STATE_VERSION:
        return None
    if state.get("original") not in {"true", "false"}:
        return None
    if not isinstance(state.get("owners"), list):
        return None
    return state


def _write_state(path: Path, state: dict[str, Any]) -> None:
    _ensure_private_directory(path.parent)
    old_umask = os.umask(0o077)
    tmp_name = ""
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            prefix=path.name + ".tmp.",
            dir=path.parent,
            delete=False,
        ) as tmp:
            tmp_name = tmp.name
            json.dump(state, tmp, sort_keys=True)
            tmp.write("\n")
            tmp.flush()
            os.fsync(tmp.fileno())
        os.replace(tmp_name, path)
    finally:
        os.umask(old_umask)
        if tmp_name:
            try:
                os.unlink(tmp_name)
            except FileNotFoundError:
                pass


def _remove_state(path: Path) -> None:
    try:
        path.unlink()
    except FileNotFoundError:
        pass


class _LockedState:
    def __enter__(self) -> Path:
        lock_path = _lock_path()
        _ensure_private_directory(lock_path.parent)
        flags = os.O_RDWR | os.O_CREAT
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        fd = os.open(lock_path, flags, 0o600)
        self._file = os.fdopen(fd, "a+", encoding="utf-8")
        fcntl.flock(self._file.fileno(), fcntl.LOCK_EX)
        return _state_path()

    def __exit__(self, *_args: object) -> None:
        fcntl.flock(self._file.fileno(), fcntl.LOCK_UN)
        self._file.close()


def _prune_owners(state: dict[str, Any]) -> list[dict[str, Any]]:
    return [owner for owner in state["owners"] if _owner_is_live(owner)]


def acquire(pid: int) -> bool:
    owner = _owner(pid)
    if owner is None:
        print(f"gnome-animation-guard: owner pid is not live: {pid}", file=sys.stderr)
        return False

    with _LockedState() as path:
        state = _load_state(path)
        if state is not None:
            state["owners"] = _prune_owners(state)
            if not state["owners"]:
                _set_animation_setting(state["original"])
                _remove_state(path)
                state = None

        if state is None:
            original = _get_animation_setting()
            if original is None:
                return False
            state = {
                "version": STATE_VERSION,
                "original": original,
                "owners": [],
            }

        if owner not in state["owners"]:
            state["owners"].append(owner)
        # Journal first: a killed helper can be repaired by the next acquire or
        # by the explicit recover command without guessing the old value.
        _write_state(path, state)
        if _set_animation_setting("false"):
            return True

        state["owners"] = [entry for entry in state["owners"] if entry != owner]
        if state["owners"]:
            _write_state(path, state)
        else:
            _set_animation_setting(state["original"])
            _remove_state(path)
        return False


def release(pid: int) -> bool:
    with _LockedState() as path:
        state = _load_state(path)
        if state is None:
            return True
        owners = _prune_owners(state)
        owners = [owner for owner in owners if owner.get("pid") != pid]
        state["owners"] = owners
        if owners:
            _write_state(path, state)
            return _set_animation_setting("false")
        restored = _set_animation_setting(state["original"])
        if restored:
            _remove_state(path)
        return restored


def recover() -> bool:
    with _LockedState() as path:
        state = _load_state(path)
        if state is None:
            return True
        state["owners"] = _prune_owners(state)
        if state["owners"]:
            _write_state(path, state)
            return _set_animation_setting("false")
        restored = _set_animation_setting(state["original"])
        if restored:
            _remove_state(path)
        return restored


def status() -> int:
    with _LockedState() as path:
        state = _load_state(path)
        current = _get_animation_setting()
        if state is None:
            print(f"inactive current={current or 'unavailable'}")
            return 0
        owners = _prune_owners(state)
        owner_pids = ",".join(str(owner["pid"]) for owner in owners) or "none"
        print(
            f"active owners={owner_pids} original={state['original']} "
            f"current={current or 'unavailable'}"
        )
        return 0


def run_guarded(command: list[str]) -> int:
    if not command:
        print("gnome-animation-guard: missing command after --", file=sys.stderr)
        return 2

    owner_pid = os.getpid()
    guarded = acquire(owner_pid)
    if not guarded:
        print(
            "gnome-animation-guard: GNOME animation setting unavailable; "
            "starting command unchanged",
            file=sys.stderr,
        )

    child: subprocess.Popen[bytes] | None = None

    def forward(signum: int, _frame: object) -> None:
        if child is not None and child.poll() is None:
            child.send_signal(signum)

    old_handlers: dict[int, Any] = {}
    for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        old_handlers[signum] = signal.signal(signum, forward)

    try:
        child = subprocess.Popen(command)
        return child.wait()
    except FileNotFoundError as exc:
        print(f"gnome-animation-guard: {exc}", file=sys.stderr)
        return 127
    finally:
        for signum, handler in old_handlers.items():
            signal.signal(signum, handler)
        if guarded and not release(owner_pid):
            print(
                "gnome-animation-guard: failed to restore GNOME animations; "
                "run this helper with 'recover'",
                file=sys.stderr,
            )


def usage(program: str) -> None:
    print(
        f"usage: {program} run -- COMMAND [ARG ...]\n"
        f"       {program} acquire PID\n"
        f"       {program} release PID\n"
        f"       {program} recover\n"
        f"       {program} status",
        file=sys.stderr,
    )


def main(argv: list[str]) -> int:
    if len(argv) >= 3 and argv[1] == "run" and argv[2] == "--":
        return run_guarded(argv[3:])
    if len(argv) == 3 and argv[1] in {"acquire", "release"}:
        try:
            pid = int(argv[2], 10)
        except ValueError:
            usage(argv[0])
            return 2
        ok = acquire(pid) if argv[1] == "acquire" else release(pid)
        return 0 if ok else 1
    if len(argv) == 2 and argv[1] == "recover":
        return 0 if recover() else 1
    if len(argv) == 2 and argv[1] == "status":
        return status()
    usage(argv[0])
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
