#!/usr/bin/env bash
# Exercise the production NBD preflight with temporary sysfs/device fixtures.
# No root, real module load, NBD connection, or guest image is used.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
installer="$root/deploy/install-vgpu-portable-to-base.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

python3 - "$installer" "$tmp/prepare.sh" "$tmp" <<'PY'
from pathlib import Path
import re
import sys

source = Path(sys.argv[1]).read_text()
body = re.search(r'(?ms)^prepare_nbd_device\(\) \{\n.*?^\}', source)
assert body, 'production NBD preflight function is missing'
body = body[0].replace('/sys/', sys.argv[3] + '/fixture/sys/')
assert '[[ -b "$candidate" ]]' in body
body = body.replace('[[ -b "$candidate" ]]', '[[ -f "$candidate" ]]')
body = body.replace('candidate="/dev/$sys_name"',
                    'candidate="' + sys.argv[3] + '/fixture/dev/$sys_name"')
Path(sys.argv[2]).write_text(body + '\n')
assert source.index('\nprepare_nbd_device\n') < source.index(
    '\ncp --reflink=auto -- "$BASE" "$BASE_TMP"'), 'NBD must be checked before copying'
assert source.index('\nsource "$here/lib/nbd-lock.sh"\n') < source.index(
    '\nprepare_nbd_device\n'), 'selection must hold the shared NBD lock'
PY
source "$tmp/prepare.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
die() { echo "$*" >&2; exit 1; }
log() { :; }
fixture="$tmp/fixture"
reset_fixture() {
    rm -rf -- "$fixture"
    mkdir -p "$fixture/dev" "$fixture/sys/block"
    NBD=""
    load_failure=0
    settle_failure=0
}
module_ready() {
    mkdir -p "$fixture/sys/module/nbd/parameters"
    printf '%s\n' "${1:-32}" >"$fixture/sys/module/nbd/parameters/max_part"
}
device() {
    mkdir -p "$fixture/sys/block/$1"
    touch "$fixture/dev/$1"
    printf '%s\n' "${2:-0}" >"$fixture/sys/block/$1/size"
}
modprobe() {
    printf '%s\n' "$*" >>"$fixture/modprobe.calls"
    ((load_failure == 0)) || return 1
    module_ready
    device nbd0
}
udevadm() { ((settle_failure == 0)); }
findmnt() { [[ -e "${!#}.mounted" ]]; }
lsblk() {
    [[ ! -e "${!#}.unreadable" ]] || return 1
    if [[ -e "${!#}.child-mounted" ]]; then printf '/mnt/other-task\n'; fi
    return 0
}
expect_failure() {
    if (prepare_nbd_device) >"$tmp/result" 2>&1; then
        fail "unexpected success: $1"
    fi
    rg -Fq -- "$1" "$tmp/result" || fail "missing diagnosis: $1"
}

reset_fixture
prepare_nbd_device
[[ "$NBD" == "$fixture/dev/nbd0" ]] || fail 'fresh module was not usable'
[[ "$(cat "$fixture/modprobe.calls")" == 'nbd max_part=32 nbds_max=32' ]] ||
    fail 'module was not loaded once with partition support'

reset_fixture
module_ready
device nbd0
printf '1234\n' >"$fixture/sys/block/nbd0/pid"
device nbd1 2048
device nbd2
touch "$fixture/dev/nbd2.mounted"
device nbd3
touch "$fixture/dev/nbd3.child-mounted"
device nbd4
rm "$fixture/sys/block/nbd4/size"
device nbd5
touch "$fixture/dev/nbd5.unreadable"
device nbd42
prepare_nbd_device
[[ "$NBD" == "$fixture/dev/nbd42" ]] ||
    fail 'selection missed a free device above index 31 or reused a busy/unknown device'
[[ ! -e "$fixture/modprobe.calls" ]] || fail 'an already loaded module was changed'
rm -rf -- "$fixture/sys/block/nbd42" "$fixture/dev/nbd42"
expect_failure 'busy or cannot be inspected'

reset_fixture
load_failure=1
expect_failure 'could not load the host NBD module'

reset_fixture
module_ready 0
device nbd0
expect_failure 'already loaded without partition support'
[[ ! -e "$fixture/modprobe.calls" ]] || fail 'partition failure tried to reload the module'

reset_fixture
module_ready
expect_failure 'no /dev/nbdN block devices are visible'

reset_fixture
module_ready
device nbd0
settle_failure=1
expect_failure 'udev did not settle'

if rg -n 'qemu-nbd|rmmod|modprobe[[:space:]]+(-r|--remove)' "$tmp/prepare.sh" |
        rg -v '^[0-9]+:[[:space:]]*#'; then
    fail 'preflight can disconnect a device or unload a module'
fi
echo 'PASS: base NBD preflight loads missing modules and preserves busy/unknown devices'
