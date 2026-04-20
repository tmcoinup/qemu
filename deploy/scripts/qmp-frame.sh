#!/bin/bash
# ---------------------------------------------------------------------------
# qmp-frame.sh
#
# Minimal QMP client for driving stealth VMs programmatically:
#   frame capture, input injection, snapshot/restore, power ops.
#
# Depends on socat (apt install socat) + jq.
#
# Usage:
#   ./qmp-frame.sh <INSTANCE> screenshot <outfile.png>
#   ./qmp-frame.sh <INSTANCE> info          # query status
#   ./qmp-frame.sh <INSTANCE> send-key <KEY>
#   ./qmp-frame.sh <INSTANCE> snapshot <name>
#   ./qmp-frame.sh <INSTANCE> loadvm <name>
#   ./qmp-frame.sh <INSTANCE> stop|cont|reset|shutdown|quit
# ---------------------------------------------------------------------------
set -euo pipefail

INSTANCE="${1:?usage: $0 <INSTANCE> <cmd> [args]}"
CMD="${2:?}"
shift 2 || true

SOCK="/tmp/qemu-stealth-${INSTANCE}.qmp"
[[ -S "$SOCK" ]] || { echo "no QMP socket for instance $INSTANCE" >&2; exit 1; }

qmp_send() {
    # sends a single JSON command, reads until we get an answer with "return"
    python3 - "$SOCK" "$1" <<'PY'
import json, socket, sys
sock_path, payload = sys.argv[1:]
s = socket.socket(socket.AF_UNIX)
s.connect(sock_path)
f = s.makefile('rwb', buffering=0)
# handshake
banner = f.readline()
f.write(b'{"execute":"qmp_capabilities"}\n')
f.readline()  # qmp_capabilities reply
f.write(payload.encode() + b'\n')
while True:
    line = f.readline()
    if not line:
        break
    obj = json.loads(line)
    if 'return' in obj or 'error' in obj:
        print(json.dumps(obj, indent=2))
        break
PY
}

case "$CMD" in
    screenshot)
        OUT="${1:?outfile.png required}"
        # screendump of default VGA head; PPM is default, convert to PNG.
        PPM="$(mktemp --suffix=.ppm)"
        qmp_send "$(printf '{"execute":"screendump","arguments":{"filename":"%s","format":"ppm"}}' "$PPM")" >/dev/null
        # Wait until file is finished writing
        sleep 0.2
        if command -v convert >/dev/null; then
            convert "$PPM" "$OUT" && rm -f "$PPM"
        else
            # ffmpeg fallback
            ffmpeg -y -loglevel error -i "$PPM" "$OUT" && rm -f "$PPM"
        fi
        echo "wrote $OUT"
        ;;
    info)     qmp_send '{"execute":"query-status"}' ;;
    send-key)
        KEY="${1:?}"
        qmp_send "$(printf '{"execute":"send-key","arguments":{"keys":[{"type":"qcode","data":"%s"}]}}' "$KEY")"
        ;;
    snapshot)
        NAME="${1:?name}"
        qmp_send "$(printf '{"execute":"human-monitor-command","arguments":{"command-line":"savevm %s"}}' "$NAME")"
        ;;
    loadvm)
        NAME="${1:?name}"
        qmp_send "$(printf '{"execute":"human-monitor-command","arguments":{"command-line":"loadvm %s"}}' "$NAME")"
        ;;
    stop)      qmp_send '{"execute":"stop"}' ;;
    cont)      qmp_send '{"execute":"cont"}' ;;
    reset)     qmp_send '{"execute":"system_reset"}' ;;
    shutdown)  qmp_send '{"execute":"system_powerdown"}' ;;
    quit)      qmp_send '{"execute":"quit"}' ;;
    raw)       qmp_send "$1" ;;
    *) echo "unknown cmd: $CMD" >&2; exit 2 ;;
esac
