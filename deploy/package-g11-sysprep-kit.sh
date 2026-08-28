#!/usr/bin/env bash
# Build one complete public, credential-free directory copied into the Windows
# template before Sysprep. No licensed VgpuPortable EXE or DLS token enters it.
set -euo pipefail
umask 077
export LC_ALL=C

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/vm-storage.sh
source "$here/lib/vm-storage.sh"
vm_storage_init

usage() {
    cat >&2 <<EOF
usage: $0 [OUTPUT_DIRECTORY] [--replace]

Build one G11SysprepKit directory containing the Sysprep entry point, read-only
template/Tamper-Protection gate, saved-state rollback helpers, failure
diagnostics, answer file, Finalize/Retry scripts, pinned Guest Lite clone
payload, and one compiled standalone G11GuestLite.exe. Licensed VgpuPortable.exe
and its token are never included; build-g11-private-base.sh injects that private
payload after shutdown.
EOF
}

arrays_equal() {
    local -n left=$1
    local -n right=$2
    local index

    ((${#left[@]} == ${#right[@]})) || return 1
    for index in "${!left[@]}"; do
        [[ "${left[$index]}" == "${right[$index]}" ]] || return 1
    done
}

legacy_entries=(
    G11-Sysprep-README.txt
    Seal-G11-Template.cmd
    g11-sysprep-clone.xml
)
previous_complete_entries=(
    G11-Sysprep-README.txt
    Payload
    Payload/Finalize-Clone.ps1
    Payload/GuestLite
    Payload/GuestLite/01-OneClick-Apply.cmd
    Payload/GuestLite/02-Audit.cmd
    Payload/GuestLite/03-Rollback.cmd
    Payload/GuestLite/G11-Guest-Lite.ps1
    Payload/GuestLite/README.txt
    Payload/GuestLite/clone-manifest.json
    Payload/Retry-Clone-Initialization.cmd
    Seal-G11-Template.cmd
    Standalone-GuestLite
    Standalone-GuestLite/G11GuestLite.exe
    g11-sysprep-clone.xml
)
diagnostic_complete_entries=(
    "${previous_complete_entries[@]}"
    Collect-Sysprep-Diagnostics.ps1
)
current_entries=(
    "${diagnostic_complete_entries[@]}"
    Assert-G11-Template-Ready.ps1
    Reset-G11-Template-State.ps1
    Template-Reset
    Template-Reset/GuestLite
    Template-Reset/GuestLite/G11-Guest-Lite.ps1
    Template-Reset/GuestPerformance
    Template-Reset/GuestPerformance/Optimize-Guest.ps1
)
mapfile -t legacy_entries < <(printf '%s\n' "${legacy_entries[@]}" | sort)
mapfile -t previous_complete_entries < <(
    printf '%s\n' "${previous_complete_entries[@]}" | sort
)
mapfile -t diagnostic_complete_entries < <(
    printf '%s\n' "${diagnostic_complete_entries[@]}" | sort
)
mapfile -t current_entries < <(printf '%s\n' "${current_entries[@]}" | sort)

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
        echo "[g11-sysprep-kit] use --replace only for a recognized generated kit" >&2
        exit 1
    }
    [[ -d "$OUTPUT" && ! -L "$OUTPUT" ]] || {
        echo "[g11-sysprep-kit] existing output is not a plain directory: $OUTPUT" >&2
        exit 1
    }
    mapfile -t existing_entries < <(
        find "$OUTPUT" -mindepth 1 -printf '%P\n' | sort
    )
    if ! arrays_equal existing_entries legacy_entries &&
            ! arrays_equal existing_entries previous_complete_entries &&
            ! arrays_equal existing_entries diagnostic_complete_entries &&
            ! arrays_equal existing_entries current_entries; then
        echo "[g11-sysprep-kit] existing output contains unknown/missing entries; refusing replacement" >&2
        exit 1
    fi
    for existing in "${existing_entries[@]}"; do
        [[ ! -L "$OUTPUT/$existing" &&
           ( -f "$OUTPUT/$existing" || -d "$OUTPUT/$existing" ) ]] || {
            echo "[g11-sysprep-kit] existing entry has an unsafe type: $existing" >&2
            exit 1
        }
    done
fi

for dependency in awk find install jq sha256sum stat \
        x86_64-w64-mingw32-gcc x86_64-w64-mingw32-windres; do
    command -v "$dependency" >/dev/null 2>&1 || {
        echo "[g11-sysprep-kit] missing build dependency: $dependency" >&2
        echo "[g11-sysprep-kit] install with: sudo apt install -y mingw-w64 jq" >&2
        exit 1
    }
done

GUEST_LITE_SOURCE="$here/guest/guest-lite"
GUEST_LITE_BUILDER="$GUEST_LITE_SOURCE/exe/build.sh"
GUEST_LITE_ASSETS=(
    G11-Guest-Lite.ps1
    01-OneClick-Apply.cmd
    02-Audit.cmd
    03-Rollback.cmd
    README.txt
)
PUBLIC_SOURCES=(
    "$here/guest/Seal-G11-Template.cmd"
    "$here/guest/Assert-G11-Template-Ready.ps1"
    "$here/guest/Reset-G11-Template-State.ps1"
    "$here/guest/Collect-Sysprep-Diagnostics.ps1"
    "$here/guest/G11-Sysprep-README.txt"
    "$here/autounattend/g11-sysprep-clone.xml"
    "$here/guest/finalize-g11-clone.ps1"
    "$here/guest/Retry-Clone-Initialization.cmd"
    "$GUEST_LITE_SOURCE/clone-manifest.json"
    "$here/guest/guest-performance/Optimize-Guest.ps1"
    "$GUEST_LITE_BUILDER"
)
for asset in "${GUEST_LITE_ASSETS[@]}"; do
    PUBLIC_SOURCES+=("$GUEST_LITE_SOURCE/$asset")
done
for source_path in "${PUBLIC_SOURCES[@]}"; do
    [[ -f "$source_path" && ! -L "$source_path" && -s "$source_path" ]] || {
        echo "[g11-sysprep-kit] missing or unsafe public source: $source_path" >&2
        exit 1
    }
done
[[ -x "$GUEST_LITE_BUILDER" ]] || {
    echo "[g11-sysprep-kit] Guest Lite builder is not executable: $GUEST_LITE_BUILDER" >&2
    exit 1
}

sha256_upper() {
    sha256sum -- "$1" | awk '{print toupper($1)}'
}

verify_guest_lite_payload() {
    local asset_dir=$1 name expected_sha expected_bytes asset_path

    jq -e '
        (keys | sort) == ["files", "profileVersion", "schemaVersion"] and
        .schemaVersion == 1 and .profileVersion == "2.6.4" and
        (.files | type) == "array" and (.files | length) == 5 and
        ([.files[].name] | sort) == [
            "01-OneClick-Apply.cmd", "02-Audit.cmd", "03-Rollback.cmd",
            "G11-Guest-Lite.ps1", "README.txt"
        ] and
        ([.files[].name] | unique | length) == 5 and
        all(.files[];
            (.name | type) == "string" and
            (.sha256 | test("^[0-9A-F]{64}$")) and
            (.bytes | type) == "number" and .bytes > 0 and
            (.bytes | floor) == .bytes)
    ' "$asset_dir/clone-manifest.json" >/dev/null || return 1
    while IFS=$'\t' read -r name expected_sha expected_bytes; do
        asset_path="$asset_dir/$name"
        [[ -f "$asset_path" && ! -L "$asset_path" &&
           "$(sha256_upper "$asset_path")" == "$expected_sha" &&
           "$(stat -c %s -- "$asset_path")" == "$expected_bytes" ]] ||
            return 1
    done < <(jq -r '.files[] | [.name, .sha256, (.bytes | tostring)] | @tsv' \
        "$asset_dir/clone-manifest.json")
}

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
PAYLOAD_STAGE="$STAGE/Payload"
GUEST_LITE_STAGE="$PAYLOAD_STAGE/GuestLite"
STANDALONE_STAGE="$STAGE/Standalone-GuestLite"
RESET_STAGE="$STAGE/Template-Reset"
RESET_GUEST_LITE_STAGE="$RESET_STAGE/GuestLite"
RESET_PERFORMANCE_STAGE="$RESET_STAGE/GuestPerformance"
install -d -m 0700 -- "$GUEST_LITE_STAGE" "$STANDALONE_STAGE" \
    "$RESET_GUEST_LITE_STAGE" "$RESET_PERFORMANCE_STAGE"
install -m 0600 -- "$here/guest/Seal-G11-Template.cmd" \
    "$STAGE/Seal-G11-Template.cmd"
install -m 0600 -- "$here/guest/Assert-G11-Template-Ready.ps1" \
    "$STAGE/Assert-G11-Template-Ready.ps1"
install -m 0600 -- "$here/guest/Reset-G11-Template-State.ps1" \
    "$STAGE/Reset-G11-Template-State.ps1"
install -m 0600 -- "$here/guest/Collect-Sysprep-Diagnostics.ps1" \
    "$STAGE/Collect-Sysprep-Diagnostics.ps1"
install -m 0600 -- "$here/guest/G11-Sysprep-README.txt" \
    "$STAGE/G11-Sysprep-README.txt"
install -m 0600 -- "$here/autounattend/g11-sysprep-clone.xml" \
    "$STAGE/g11-sysprep-clone.xml"
install -m 0600 -- "$here/guest/finalize-g11-clone.ps1" \
    "$PAYLOAD_STAGE/Finalize-Clone.ps1"
install -m 0600 -- "$here/guest/Retry-Clone-Initialization.cmd" \
    "$PAYLOAD_STAGE/Retry-Clone-Initialization.cmd"
for asset in "${GUEST_LITE_ASSETS[@]}"; do
    install -m 0600 -- "$GUEST_LITE_SOURCE/$asset" \
        "$GUEST_LITE_STAGE/$asset"
done
install -m 0600 -- "$GUEST_LITE_SOURCE/clone-manifest.json" \
    "$GUEST_LITE_STAGE/clone-manifest.json"
install -m 0600 -- "$GUEST_LITE_SOURCE/G11-Guest-Lite.ps1" \
    "$RESET_GUEST_LITE_STAGE/G11-Guest-Lite.ps1"
install -m 0600 -- "$here/guest/guest-performance/Optimize-Guest.ps1" \
    "$RESET_PERFORMANCE_STAGE/Optimize-Guest.ps1"

# Publish every CMD with Windows-safe CRLF while retaining LF-only reviewed
# sources in git. The pinned Guest Lite manifest describes these CRLF copies.
for launcher in "$STAGE/Seal-G11-Template.cmd" \
        "$PAYLOAD_STAGE/Retry-Clone-Initialization.cmd" \
        "$GUEST_LITE_STAGE"/*.cmd; do
    sed -i 's/$/\r/' "$launcher"
done
verify_guest_lite_payload "$GUEST_LITE_STAGE" || {
    echo '[g11-sysprep-kit] staged Guest Lite differs from its pinned manifest' >&2
    exit 1
}
"$GUEST_LITE_BUILDER" \
    --output "$STANDALONE_STAGE/G11GuestLite.exe" >/dev/null
[[ -f "$STANDALONE_STAGE/G11GuestLite.exe" &&
   ! -L "$STANDALONE_STAGE/G11GuestLite.exe" &&
   -s "$STANDALONE_STAGE/G11GuestLite.exe" ]] || {
    echo '[g11-sysprep-kit] standalone Guest Lite compilation failed' >&2
    exit 1
}

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
echo "[g11-sysprep-kit] readiness gate, rollback helpers, public payload, and Guest Lite EXE collected"
echo '把整个目录复制为 C:\G11SysprepKit（不要放进 ProgramData），然后只以管理员身份运行 Seal-G11-Template.cmd。'
