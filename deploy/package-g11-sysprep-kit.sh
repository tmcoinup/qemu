#!/usr/bin/env bash
# Package the public, credential-free files copied into the Windows
# template before Sysprep. No licensed EXE or DLS token enters this kit.
set -euo pipefail
umask 077

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/vm-storage.sh
source "$here/lib/vm-storage.sh"
vm_storage_init

usage() { echo "usage: $0 [OUTPUT_DIRECTORY] [--replace]" >&2; }
OUTPUT=""
REPLACE=0
while (($#)); do
    case "$1" in
        --replace) REPLACE=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *)
            [[ -z "$OUTPUT" ]] || { usage; exit 2; }
            OUTPUT=$1
            shift
            ;;
    esac
done
OUTPUT=${OUTPUT:-"$STAGE_DIR/G11SysprepKit"}
[[ "$OUTPUT" == /* && "$OUTPUT" != / ]] || {
    echo "[g11-sysprep-kit] OUTPUT_DIRECTORY must be a non-root absolute path" >&2
    exit 2
}
OUTPUT_PARENT=$(dirname -- "$OUTPUT")
OUTPUT_LEAF=$(basename -- "$OUTPUT")
[[ -d "$OUTPUT_PARENT" && ! -L "$OUTPUT_PARENT" ]] || {
    echo "[g11-sysprep-kit] output parent must be a plain directory: $OUTPUT_PARENT" >&2
    exit 1
}
if [[ -e "$OUTPUT" || -L "$OUTPUT" ]]; then
    ((REPLACE)) || {
        echo "[g11-sysprep-kit] output already exists: $OUTPUT" >&2
        echo "[g11-sysprep-kit] use --replace only for this generated three-file kit" >&2
        exit 1
    }
    [[ -d "$OUTPUT" && ! -L "$OUTPUT" ]] || {
        echo "[g11-sysprep-kit] existing output is not a plain directory: $OUTPUT" >&2
        exit 1
    }
    mapfile -t existing_entries < <(
        find "$OUTPUT" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort
    )
    [[ "${existing_entries[*]}" == \
        'G11-Sysprep-README.txt Seal-G11-Template.cmd g11-sysprep-clone.xml' ]] || {
        echo "[g11-sysprep-kit] existing output contains unknown/missing entries; refusing replacement" >&2
        exit 1
    }
    for existing in "${existing_entries[@]}"; do
        [[ -f "$OUTPUT/$existing" && ! -L "$OUTPUT/$existing" ]] || {
            echo "[g11-sysprep-kit] existing entry is not a regular file: $existing" >&2
            exit 1
        }
    done
fi

STAGE=$(mktemp -d "$OUTPUT_PARENT/.${OUTPUT_LEAF}.new.XXXXXXXX")
BACKUP=""
cleanup() {
    [[ -z "$STAGE" ]] || rm -rf -- "$STAGE"
    if [[ -n "$BACKUP" && -d "$BACKUP" && ! -e "$OUTPUT" ]]; then
        mv -T -- "$BACKUP" "$OUTPUT" || true
    fi
}
trap cleanup EXIT
chmod 0700 "$STAGE"
cp -- "$here/guest/Seal-G11-Template.cmd" "$STAGE/"
cp -- "$here/guest/G11-Sysprep-README.txt" "$STAGE/"
cp -- "$here/autounattend/g11-sysprep-clone.xml" \
    "$STAGE/g11-sysprep-clone.xml"
chmod 0600 "$STAGE"/*

if [[ -e "$OUTPUT" ]]; then
    BACKUP="$OUTPUT_PARENT/.${OUTPUT_LEAF}.old.$$.$RANDOM"
    mv -T -- "$OUTPUT" "$BACKUP"
fi
mv -T -- "$STAGE" "$OUTPUT"
STAGE=""
if [[ -n "$BACKUP" ]]; then
    rm -rf -- "$BACKUP"
    BACKUP=""
fi
trap - EXIT
echo "[g11-sysprep-kit] PASS: $OUTPUT"
echo "把整个目录复制进模板 Windows，然后以管理员身份运行 Seal-G11-Template.cmd。"
