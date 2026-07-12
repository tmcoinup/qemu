#!/usr/bin/env bash
# 运行真实 QEMU，验证 fb-shm 流式控制协议、每客户端唤醒与共享头防篡改。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
QEMU="${QEMU:-$REPO_ROOT/build/qemu-system-x86_64}"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

[[ -x "$QEMU" ]] || fail "缺少可执行 QEMU: $QEMU"

TMP_DIR="$(mktemp -d)"
FB_SOCK="$TMP_DIR/fb.sock"
QMP_SOCK="$TMP_DIR/qmp.sock"
QEMU_LOG="$TMP_DIR/qemu.log"
qemu_pid=""

cleanup() {
    if [[ -n "$qemu_pid" ]] && kill -0 "$qemu_pid" 2>/dev/null; then
        kill "$qemu_pid" 2>/dev/null || true
        wait "$qemu_pid" 2>/dev/null || true
    fi
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

"$QEMU" \
    -machine q35,accel=tcg \
    -nodefaults \
    -device VGA \
    -display none \
    -object fb-shm,id=runtime-test,path="$FB_SOCK",rate=1 \
    -qmp unix:"$QMP_SOCK",server=on,wait=off \
    > /dev/null 2> "$QEMU_LOG" &
qemu_pid=$!

for _ in $(seq 1 100); do
    [[ -S "$FB_SOCK" && -S "$QMP_SOCK" ]] && break
    if ! kill -0 "$qemu_pid" 2>/dev/null; then
        sed -n '1,120p' "$QEMU_LOG" >&2
        fail "QEMU 在 fb-shm socket 就绪前退出"
    fi
    sleep 0.05
done
[[ -S "$FB_SOCK" ]] || fail "fb-shm socket 未创建"

python3 - "$FB_SOCK" "$QMP_SOCK" "$qemu_pid" <<'PY'
import array
import json
import mmap
import os
import socket
import struct
import sys
import time


FB_SOCK, QMP_SOCK, QEMU_PID = sys.argv[1], sys.argv[2], int(sys.argv[3])
MAGIC = 0x46425348
HELLO = 1
SET_ROI = 2
OK = 0
EBUSY = 2
REQ = struct.Struct("=IIiiIIII")
ACK = struct.Struct("=IIIIIIII")


def process_alive():
    """不回收子进程，只探测 QEMU 是否仍存在。"""
    try:
        os.kill(QEMU_PID, 0)
        return True
    except ProcessLookupError:
        return False


def recv_ack_with_fds(client):
    """累计 stream 短读，同时保留第一段携带的 SCM_RIGHTS。"""
    payload = bytearray()
    received_fds = []
    while len(payload) < ACK.size:
        data, ancillary, _flags, _addr = client.recvmsg(
            ACK.size - len(payload), socket.CMSG_SPACE(2 * array.array("i").itemsize)
        )
        if not data:
            raise AssertionError("fb-shm 在 ACK 完整前断开")
        payload.extend(data)
        for level, kind, cmsg_data in ancillary:
            if level == socket.SOL_SOCKET and kind == socket.SCM_RIGHTS:
                fds = array.array("i")
                usable = len(cmsg_data) - len(cmsg_data) % fds.itemsize
                fds.frombytes(cmsg_data[:usable])
                received_fds.extend(fds.tolist())
    return ACK.unpack(payload), received_fds


def connect_split_hello():
    """逐字节发送 HELLO，覆盖任意 stream 拆包。"""
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.settimeout(3.0)
    client.connect(FB_SOCK)
    request = REQ.pack(MAGIC, HELLO, 0, 0, 0, 0, 1, 0)
    for byte in request:
        client.sendall(bytes((byte,)))
    ack, fds = recv_ack_with_fds(client)
    return client, ack, fds


clients = []
handles = []
try:
    # mapping 由 DCL 首次 refresh 异步创建；EBUSY 时换新连接重试，避免把
    # 同一 HELLO client 留在半初始化状态影响待测协议。
    for _ in range(60):
        client, ack, fds = connect_split_hello()
        if ack[2] == OK:
            clients.append(client)
            handles.append(fds)
            break
        client.close()
        for fd in fds:
            os.close(fd)
        assert ack[2] == EBUSY, ack
        time.sleep(0.05)
    else:
        raise AssertionError("fb-shm mapping 未在期限内就绪")

    client2, ack2, fds2 = connect_split_hello()
    assert ack2[2] == OK, ack2
    clients.append(client2)
    handles.append(fds2)

    assert all(len(fds) == 2 for fds in handles), handles
    event_ids = []
    for _memfd, eventfd in handles:
        with open(f"/proc/self/fdinfo/{eventfd}", encoding="ascii") as info:
            fields = dict(
                line.strip().split(":", 1)
                for line in info
                if ":" in line
            )
        event_ids.append(fields.get("eventfd-id", "").strip())
    assert all(event_ids), event_ids
    assert event_ids[0] != event_ids[1], event_ids

    # consumer 拥有可写 memfd，因此主动破坏 buf_offset[0]，再用拆包 ROI 请求
    # 触发 geometry 更新。QEMU 必须按私有容量恢复 offset=HEADER_SIZE，而不能
    # 将恶意值当宿主写指针；进程存活也覆盖旧实现的越界写崩溃。
    memfd = handles[0][0]
    mapping = mmap.mmap(memfd, ack[3], access=mmap.ACCESS_WRITE)
    mapping[24:32] = struct.pack("=Q", (1 << 64) - 4096)
    roi = REQ.pack(MAGIC, SET_ROI, 0, 0, 320, 200, 0, 0)
    clients[0].sendall(roi[:7])
    clients[0].sendall(roi[7:19])
    clients[0].sendall(roi[19:])
    roi_ack = b""
    while len(roi_ack) < ACK.size:
        chunk = clients[0].recv(ACK.size - len(roi_ack))
        if not chunk:
            raise AssertionError("SET_ROI ACK 前断开")
        roi_ack += chunk
    assert ACK.unpack(roi_ack)[2] == OK

    for _ in range(60):
        if struct.unpack("=Q", mapping[24:32])[0] == 256:
            break
        if not process_alive():
            raise AssertionError("header 篡改后 QEMU 崩溃")
        time.sleep(0.05)
    else:
        raise AssertionError("producer 未恢复被篡改的 buf_offset[0]")
    mapping.close()

    # 用 QMP 正常退出，确保控制连接清理和 object finalize 也被执行。
    qmp = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    qmp.connect(QMP_SOCK)
    stream = qmp.makefile("rwb", buffering=0)
    assert "QMP" in json.loads(stream.readline())
    stream.write(b'{"execute":"qmp_capabilities","id":"caps"}\n')
    assert json.loads(stream.readline()).get("id") == "caps"
    stream.write(b'{"execute":"quit","id":"quit"}\n')
    while json.loads(stream.readline()).get("id") != "quit":
        pass
    stream.close()
    qmp.close()
finally:
    for client in clients:
        client.close()
    for fd_pair in handles:
        for fd in fd_pair:
            try:
                os.close(fd)
            except OSError:
                pass
PY

wait "$qemu_pid"
qemu_pid=""

echo "OK: fb-shm runtime control and isolation checks passed"
