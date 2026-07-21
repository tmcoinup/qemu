#!/usr/bin/env bash
# 生成只包含 dnf-fix-deps.exe 的正式发布目录。
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
DIST="$HERE/dist"
CONTROLLED_BUILD_DIR="$REPO_ROOT/build/guest-dnf-deps-exe"
LOCK_PATH="$REPO_ROOT/build/.guest-dnf-deps-package.lock"
STAGE_DIR=""
BACKUP_DIR=""

command -v flock >/dev/null 2>&1 || {
    echo "ERROR: 缺少打包锁工具: flock" >&2
    exit 1
}
mkdir -p "$REPO_ROOT/build"
exec 9>"$LOCK_PATH"
flock -w 30 9 || {
    echo "ERROR: 等待其它 dnf-fix-deps 打包进程超时" >&2
    exit 1
}

cleanup() {
    if [[ -n "$STAGE_DIR" && -d "$STAGE_DIR" && ! -L "$STAGE_DIR" ]]; then
        rm -rf -- "$STAGE_DIR"
    fi
    if [[ -n "$BACKUP_DIR" && -d "$BACKUP_DIR" &&
          ! -L "$BACKUP_DIR" && ! -e "$DIST" ]]; then
        mv -- "$BACKUP_DIR" "$DIST"
        BACKUP_DIR=""
    fi
}
trap cleanup EXIT

if [[ -L "$DIST" || ( -e "$DIST" && ! -d "$DIST" ) ]]; then
    echo "ERROR: 正式 dist 必须是普通目录或不存在" >&2
    exit 1
fi
STAGE_DIR="$(mktemp -d "$HERE/.dnf-fix-deps-dist.XXXXXXXX")"

# 正式发布忽略调用环境中的路径覆盖，并先在同一文件系统完成全部验证。
OUT_DIR="$STAGE_DIR" \
BUILD_DIR="$CONTROLLED_BUILD_DIR" \
    "$HERE/build-exe.sh"

mapfile -d '' -t entries < <(
    find "$STAGE_DIR" -mindepth 1 -maxdepth 1 -print0
)
if [[ "${#entries[@]}" -ne 1 ||
      "${entries[0]}" != "$STAGE_DIR/dnf-fix-deps.exe" ||
      ! -f "$STAGE_DIR/dnf-fix-deps.exe" ||
      -L "$STAGE_DIR/dnf-fix-deps.exe" ||
      ! -s "$STAGE_DIR/dnf-fix-deps.exe" ]]; then
    echo "ERROR: staging 必须且只能包含一个非空 dnf-fix-deps.exe" >&2
    find "$STAGE_DIR" -mindepth 1 -maxdepth 1 -printf '  %f\n' >&2 || true
    exit 1
fi

chmod 0755 "$STAGE_DIR" "$STAGE_DIR/dnf-fix-deps.exe"
if [[ -d "$DIST" ]]; then
    BACKUP_DIR="$(mktemp -d "$HERE/.dnf-fix-deps-old.XXXXXXXX")"
    rmdir "$BACKUP_DIR"
    mv -- "$DIST" "$BACKUP_DIR"
fi
if ! mv -- "$STAGE_DIR" "$DIST"; then
    echo "ERROR: 无法发布已验证的 dist" >&2
    exit 1
fi
STAGE_DIR=""
if [[ -n "$BACKUP_DIR" ]]; then
    rm -rf -- "$BACKUP_DIR"
    BACKUP_DIR=""
fi

echo ">> 正式发布物: $DIST/dnf-fix-deps.exe"
sha256sum "$DIST/dnf-fix-deps.exe"
