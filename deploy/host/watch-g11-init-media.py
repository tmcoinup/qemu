#!/usr/bin/env python3
"""Remove the private G-11 initialization optical stack after guest eject.

The guest first copies and verifies its VM-bound payload, then issues the
standard SCSI media-eject request.  This watcher treats the resulting open tray
as the only authorization to hot-remove the reviewed scsi-cd + usb-bot stack.
It never controls a normal/manual optical device and never writes guest data.
"""

from __future__ import annotations

import json
import os
import signal
import socket
import stat
import sys
import time
from typing import Any


DEVICE_ID = "g11-init-odd"
USB_DEVICE_ID = "g11-init-odd-usb"
BACKEND_ID = "g11-init-odd-media"
CONNECT_TIMEOUT_SECONDS = 180
EJECT_TIMEOUT_SECONDS = 20 * 60


class WatchError(RuntimeError):
    pass


class QmpClosed(WatchError):
    pass


class Qmp:
    def __init__(self, path: str) -> None:
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(5)
        self.sock.connect(path)
        self.stream = self.sock.makefile("rwb", buffering=0)
        self.sequence = 0
        while True:
            line = self.stream.readline()
            if not line:
                raise QmpClosed("QMP closed before greeting")
            message = json.loads(line)
            if "QMP" in message:
                break

    def close(self) -> None:
        try:
            self.stream.close()
        finally:
            self.sock.close()

    def command(self, name: str, arguments: dict[str, Any] | None = None) -> Any:
        self.sequence += 1
        ident = f"g11-init-media-{self.sequence}"
        request: dict[str, Any] = {"execute": name, "id": ident}
        if arguments is not None:
            request["arguments"] = arguments
        self.stream.write((json.dumps(request) + "\r\n").encode("utf-8"))
        while True:
            line = self.stream.readline()
            if not line:
                raise QmpClosed(f"QMP closed before {name} response")
            response = json.loads(line)
            if response.get("id") != ident:
                continue
            if "error" in response:
                detail = response["error"].get("desc", "QMP error")
                raise WatchError(f"{name}: {detail}")
            return response.get("return")


def wait_for_socket(path: str) -> None:
    deadline = time.monotonic() + CONNECT_TIMEOUT_SECONDS
    while time.monotonic() < deadline:
        try:
            metadata = os.lstat(path)
        except FileNotFoundError:
            time.sleep(0.1)
            continue
        if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISSOCK(metadata.st_mode):
            raise WatchError(f"QMP path is not a real socket: {path}")
        return
    raise WatchError(f"QMP socket did not appear within {CONNECT_TIMEOUT_SECONDS}s")


def peripheral_types(qmp: Qmp) -> dict[str, str]:
    return {
        item.get("name", ""): item.get("type", "")
        for item in (qmp.command("qom-list", {"path": "/machine/peripheral"}) or [])
        if item.get("name") != "type"
    }


def qom_get(qmp: Qmp, device_id: str, prop: str) -> Any:
    return qmp.command(
        "qom-get",
        {"path": f"/machine/peripheral/{device_id}", "property": prop},
    )


def optical_entry(qmp: Qmp) -> dict[str, Any] | None:
    matches = []
    for entry in qmp.command("query-block") or []:
        inserted = entry.get("inserted") or {}
        qdev = entry.get("qdev", "")
        if (
            entry.get("device") == BACKEND_ID
            or qdev == DEVICE_ID
            or qdev.endswith("/" + DEVICE_ID)
            or inserted.get("node-name") == BACKEND_ID
        ):
            matches.append(entry)
    if len(matches) > 1:
        raise WatchError("multiple initialization optical backends found")
    return matches[0] if matches else None


def inserted_filename(entry: dict[str, Any]) -> str | None:
    inserted = entry.get("inserted") or {}
    return inserted.get("file") or (inserted.get("image") or {}).get("filename")


def validate_stack(
    qmp: Qmp,
    expected_media: str,
    vendor: str,
    product: str,
    firmware: str,
) -> None:
    devices = peripheral_types(qmp)
    if devices.get(DEVICE_ID) != "child<scsi-cd>":
        raise WatchError(f"unexpected {DEVICE_ID} type: {devices.get(DEVICE_ID)!r}")
    if devices.get(USB_DEVICE_ID) != "child<usb-bot>":
        raise WatchError(
            f"unexpected {USB_DEVICE_ID} type: {devices.get(USB_DEVICE_ID)!r}"
        )
    actual = {
        key: qom_get(qmp, DEVICE_ID, key)
        for key in ("vendor", "product", "ver", "serial", "hotpluggable")
    }
    expected = {
        "vendor": vendor,
        "product": product,
        "ver": firmware,
        "serial": "",
        "hotpluggable": True,
    }
    if actual != expected:
        raise WatchError(
            "initialization optical identity mismatch: "
            + json.dumps(actual, ensure_ascii=False, sort_keys=True)
        )
    if not bool(qom_get(qmp, USB_DEVICE_ID, "attached")):
        raise WatchError("initialization usb-bot is not attached")
    if not bool(qom_get(qmp, USB_DEVICE_ID, "x-no-serial")):
        raise WatchError("initialization usb-bot exposes an invented serial")
    entry = optical_entry(qmp)
    if entry is None:
        raise WatchError("initialization optical backend is missing")
    filename = inserted_filename(entry)
    if not filename or os.path.realpath(filename) != expected_media:
        raise WatchError(f"initialization media mismatch: {filename!r}")
    if not bool((entry.get("inserted") or {}).get("ro")):
        raise WatchError("initialization media is not read-only")


def wait_device_absent(qmp: Qmp, device_id: str) -> None:
    deadline = time.monotonic() + 8
    while device_id in peripheral_types(qmp):
        if time.monotonic() >= deadline:
            raise WatchError(f"timed out removing {device_id}")
        time.sleep(0.05)


def remove_stack(qmp: Qmp) -> None:
    devices = peripheral_types(qmp)
    if DEVICE_ID in devices:
        qmp.command("device_del", {"id": DEVICE_ID})
        wait_device_absent(qmp, DEVICE_ID)
    devices = peripheral_types(qmp)
    if USB_DEVICE_ID in devices:
        qmp.command("device_del", {"id": USB_DEVICE_ID})
        wait_device_absent(qmp, USB_DEVICE_ID)
    try:
        qmp.command("blockdev-del", {"node-name": BACKEND_ID})
    except WatchError as exc:
        # A legacy -drive backend can remain host-internal until QEMU exits;
        # with both frontends gone it cannot be enumerated by Windows.
        print(f"[g11-init-media] backend retained (guest-invisible): {exc}")
    devices = peripheral_types(qmp)
    if DEVICE_ID in devices or USB_DEVICE_ID in devices:
        raise WatchError("initialization optical frontend survived hot-remove")


def run(arguments: list[str]) -> int:
    if len(arguments) != 6:
        raise WatchError(
            "usage: watch-g11-init-media.py QMP VM_NAME ISO VENDOR PRODUCT FIRMWARE"
        )
    qmp_path, expected_name, media, vendor, product, firmware = arguments
    if not os.path.isabs(qmp_path) or not os.path.isabs(media):
        raise WatchError("QMP and ISO paths must be absolute")
    expected_media = os.path.realpath(media)
    if not os.path.isfile(expected_media) or os.path.islink(media):
        raise WatchError(f"initialization ISO is not a safe file: {media}")
    wait_for_socket(qmp_path)
    qmp = Qmp(qmp_path)
    try:
        qmp.command("qmp_capabilities")
        actual_name = (qmp.command("query-name") or {}).get("name")
        if actual_name != expected_name:
            raise WatchError(
                f"QMP VM identity mismatch: {actual_name!r} != {expected_name!r}"
            )
        validate_stack(qmp, expected_media, vendor, product, firmware)
        print(
            f"[g11-init-media] armed for {expected_name}; "
            "waiting for authenticated guest eject",
            flush=True,
        )
        deadline = time.monotonic() + EJECT_TIMEOUT_SECONDS
        observed_inserted = True
        while time.monotonic() < deadline:
            entry = optical_entry(qmp)
            if entry is None:
                devices = peripheral_types(qmp)
                if DEVICE_ID not in devices and USB_DEVICE_ID not in devices:
                    print("[g11-init-media] PASS: optical stack already absent")
                    return 0
                raise WatchError("optical backend disappeared before its frontends")
            inserted = entry.get("inserted") or {}
            tray_open = entry.get("tray_open") is True
            if tray_open or (observed_inserted and not inserted):
                remove_stack(qmp)
                print(
                    "[g11-init-media] PASS: payload ejected; temporary "
                    "optical device and USB transport removed",
                    flush=True,
                )
                return 0
            observed_inserted = observed_inserted or bool(inserted)
            time.sleep(0.25)
        raise WatchError("guest did not eject initialization media within 20 minutes")
    except QmpClosed:
        # A full VM shutdown also removes the device.  The required marker
        # remains, so a later retry will attach a fresh verified stack.
        print("[g11-init-media] QEMU exited before live detach; no device remains")
        return 0
    finally:
        qmp.close()


def main() -> int:
    signal.signal(signal.SIGTERM, lambda _signum, _frame: sys.exit(0))
    try:
        return run(sys.argv[1:])
    except (OSError, ValueError, json.JSONDecodeError, WatchError) as exc:
        print(f"[g11-init-media] ERROR: {exc}", file=sys.stderr, flush=True)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
