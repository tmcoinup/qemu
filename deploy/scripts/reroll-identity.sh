#!/bin/bash
# ---------------------------------------------------------------------------
# reroll-identity.sh [INSTANCE ...]
#
# Deletes the saved hardware-identity profile(s) so the next launch of
# start-vm.sh regenerates a random motherboard / serials / MAC
# / UUID for those instance(s).
#
# The VM qcow2 disk, OVMF NVRAM, and installed OS are untouched — only
# the SMBIOS-side identity is re-rolled. Windows will very likely treat
# this as a new PC and ask to re-activate, so only re-roll when you
# deliberately want a fresh fingerprint (e.g. a new DNF ban-wave).
#
#  Examples:
#     reroll-identity.sh 1          # re-roll just instance 1
#     reroll-identity.sh 1 2 3      # re-roll three instances
#     reroll-identity.sh --all      # re-roll every instance that has a profile
# ---------------------------------------------------------------------------
set -euo pipefail

VMS_DIR="${VMS_DIR:-/home/ubuntu/images/vms}"

usage() {
    sed -n '2,/^# --*$/p' "$0" | sed -e 's/^# *//' -e 's/^#$//' >&2
    exit "${1:-2}"
}

if (( $# == 0 )); then
    usage
fi

targets=()
if [[ "$1" == "--all" ]]; then
    shopt -s nullglob
    for f in "$VMS_DIR"/[0-9]*/profile; do
        n="${f%/profile}"; n="${n##*/}"
        targets+=("$n")
    done
    shopt -u nullglob
    if (( ${#targets[@]} == 0 )); then
        echo ">> no saved profiles found in $VMS_DIR/<N>/profile"
        exit 0
    fi
else
    for arg in "$@"; do
        if ! [[ "$arg" =~ ^[0-9]+$ ]]; then
            echo "ERROR: '$arg' is not a valid instance number" >&2
            exit 2
        fi
        targets+=("$arg")
    done
fi

for n in "${targets[@]}"; do
    f="$VMS_DIR/${n}/profile"
    if [[ -f "$f" ]]; then
        rm -f "$f"
        echo ">> removed $f (instance $n will re-roll on next launch)"
    else
        echo ">> instance $n had no saved profile ($f) — next launch will generate one"
    fi
done
