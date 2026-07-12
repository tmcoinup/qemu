#!/usr/bin/env bash
# build-ovmf.sh —— 一键重 build stealth OVMF。
#
# 流程：
#   1. 检查 edk2 源码就绪（默认 ~/src/edk2，可用 EDK2 env 覆盖）
#   2. 应用 deploy/firmware/edk2-patches/*.patch（NVIDIA GOP 白名单等 stealth
#      改动）—— 已经应用过的跳过
#   3. source edksetup.sh + build BaseTools（首次需要）
#   4. build OvmfPkg/OvmfPkgX64.dsc -t GCC5 -b RELEASE 加：
#        -D TPM2_ENABLE=TRUE            ← 让 guest 看到 TPM 2.0
#        -D TPM_ENABLE=TRUE             ← TPM 1.2 同时启用，兼容老 guest
#        -D FD_SIZE_4MB=TRUE            ← 4MB 大小，跟 Ubuntu 默认对齐
#        -D NETWORK_TLS_ENABLE=TRUE     ← UEFI HTTPS boot 链
#   5. 备份当前 deploy/firmware/OVMF_CODE_4M_stealth.fd → .bak.<ts>
#   6. 拷贝 Build/OvmfX64/RELEASE_GCC5/FV/OVMF_CODE.fd → 新 stealth fd
#   7. 探测 build 产物里是否含 Tcg2 模块 → 自检
#
# 用法：
#   ./deploy/tools/build-ovmf.sh                    # 默认 build + 自动 verify
#   ./deploy/tools/build-ovmf.sh --no-patch         # 不应用 stealth patches（裸 OVMF）
#   ./deploy/tools/build-ovmf.sh --target DEBUG     # 切 DEBUG 模式（更大但有符号）
#   EDK2=/path/to/edk2 ./deploy/tools/build-ovmf.sh # 指定其它 edk2 源码
#
# 依赖 (apt): nasm iasl python3 gcc make uuid-runtime build-essential
#
# 单次 build 大约 1 分钟（增量），首次 + BaseTools 编译约 3 分钟。
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DEPLOY="$(cd "$HERE/.." && pwd)"
FIRMWARE_DIR="$DEPLOY/firmware"
PATCHES_DIR="$FIRMWARE_DIR/edk2-patches"

: "${EDK2:=$HOME/src/edk2}"
: "${TARGET:=RELEASE}"      # RELEASE / DEBUG
: "${TOOLCHAIN:=GCC5}"
: "${JOBS:=$(nproc)}"

APPLY_PATCHES=1
for arg in "$@"; do
    case "$arg" in
        --no-patch)   APPLY_PATCHES=0 ;;
        --target)     shift; TARGET="$1" ;;
        --target=*)   TARGET="${arg#*=}" ;;
        --jobs)       shift; JOBS="$1" ;;
        --jobs=*)     JOBS="${arg#*=}" ;;
        -h|--help)    sed -n '2,30p' "$0"; exit 0 ;;
        *) ;;
    esac
done

log() { printf '[build-ovmf] %s\n' "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }

# -------- 预检 --------
[[ -d "$EDK2" ]]                                || die "EDK2 source not found: $EDK2 (set EDK2=...)"
[[ -f "$EDK2/edksetup.sh" ]]                    || die "$EDK2 looks invalid (no edksetup.sh)"
[[ -f "$EDK2/OvmfPkg/OvmfPkgX64.dsc" ]]         || die "$EDK2/OvmfPkg/OvmfPkgX64.dsc missing"
command -v nasm   >/dev/null 2>&1               || die "need apt: nasm"
command -v iasl   >/dev/null 2>&1               || die "need apt: iasl (acpica-tools)"
command -v uuidgen >/dev/null 2>&1              || die "need apt: uuid-runtime"
command -v gcc    >/dev/null 2>&1               || die "need apt: build-essential"

log "EDK2:        $EDK2"
log "TARGET:      $TARGET / $TOOLCHAIN  (jobs=$JOBS)"
log "FIRMWARE:    $FIRMWARE_DIR"

# -------- 1) Apply patches --------
if (( APPLY_PATCHES )) && [[ -d "$PATCHES_DIR" ]]; then
    for patch in "$PATCHES_DIR"/*.patch; do
        [[ -f "$patch" ]] || continue
        name="$(basename "$patch")"
        log "patch: $name"
        # 用 git apply --check 探测；已应用则跳过
        cd "$EDK2"
        if git apply --check --reverse "$patch" >/dev/null 2>&1; then
            log "  → 已应用，跳过"
        elif git apply --check "$patch" >/dev/null 2>&1; then
            git apply "$patch"
            log "  → 应用成功"
        else
            die "patch 既不能应用也不是已应用状态：$name"
        fi
    done
fi

# -------- 2) source edksetup.sh + build BaseTools --------
cd "$EDK2"
export PYTHON_COMMAND=python3
export WORKSPACE="$EDK2"
export EDK_TOOLS_PATH="$EDK2/BaseTools"
# edk2 的 BuildEnv 脚本里有大量 unset var 引用，临时关 set -u 兼容
set +u
source edksetup.sh BaseTools >/dev/null
set -u
if [[ ! -x "$EDK2/BaseTools/BinWrappers/PosixLike/build" ]]; then
    log "BaseTools 没编，先编（首次约 1 分钟）"
    make -C "$EDK2/BaseTools" -j "$JOBS"
fi

# -------- 3) build OVMF with TPM2 --------
log "build OVMF (TARGET=$TARGET, TPM2_ENABLE=TRUE)"
build -p OvmfPkg/OvmfPkgX64.dsc -a X64 -t "$TOOLCHAIN" -b "$TARGET" \
      -D TPM2_ENABLE=TRUE \
      -D TPM_ENABLE=TRUE \
      -D FD_SIZE_4MB=TRUE \
      -D NETWORK_TLS_ENABLE=TRUE \
      -n "$JOBS" 2>&1 | tail -10

# -------- 4) Locate output + install --------
SRC_FD="$EDK2/Build/OvmfX64/${TARGET}_${TOOLCHAIN}/FV/OVMF_CODE.fd"
[[ -f "$SRC_FD" ]] || die "build 没产出 OVMF_CODE.fd: $SRC_FD"
[[ $(stat -c%s "$SRC_FD") -ge 3000000 ]] || die "OVMF_CODE.fd 大小异常: $(stat -c%s "$SRC_FD") bytes"

DST_FD="$FIRMWARE_DIR/OVMF_CODE_4M_stealth.fd"
if [[ -f "$DST_FD" ]]; then
    BAK="${DST_FD}.bak.$(date +%s)"
    cp -p "$DST_FD" "$BAK"
    log "备份旧 fd → $BAK"
fi
cp -p "$SRC_FD" "$DST_FD"
log "拷贝 → $DST_FD ($(stat -c%s "$DST_FD") bytes)"

# -------- 5) 自检：Tcg2 模块在 build 产物里 --------
TCG_OUT="$EDK2/Build/OvmfX64/${TARGET}_${TOOLCHAIN}/X64"
log "Tcg2 build artifacts (copy-out 目录 $TCG_OUT/):"
missing=0
for m in Tcg2Dxe Tcg2Pei Tcg2ConfigDxe Tcg2PlatformDxe; do
    if [[ -f "$TCG_OUT/${m}.efi" ]]; then
        sz=$(stat -c%s "$TCG_OUT/${m}.efi")
        log "  ✓ $m.efi ($sz bytes)"
    else
        log "  ✗ $m.efi 缺失"
        missing=$((missing + 1))
    fi
done
(( missing == 0 )) || die "$missing 个 Tcg2 模块缺失 → TPM2_ENABLE 没真正生效"

log "done"
log ""
log "下一步：guest 关机 → host \`./deploy/scripts/start-vm.sh <N>\` 重启使用新 OVMF"
log "        guest 内 \`Get-Tpm\` 应返回 TpmPresent=True"
