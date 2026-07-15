#!/usr/bin/env bash
# gpu-mode — RTX 2080 在 vGPU host driver 与消费版 driver 之间快速切换
#
# 设计要点见 deploy/host/gpu-mode.README.md
set -euo pipefail
shopt -s nullglob

ROOT=/opt/nvidia-modes
LOCK=$ROOT/state/current
KVER=$(uname -r)

VGPU_DRV_VERSION="535.161.05"
# vGPU host driver 是 NVIDIA 官方 deb (nvidia-vgpu-ubuntu-535) 装的。原 deb 路径用于
# init-consumer 之后复原 vGPU dpkg 状态 + 文件层。
VGPU_DEB_PATH="/home/ubuntu/Downloads/vGPU16.4/Host_Drivers/nvidia-vgpu-ubuntu-535_535.161.05_amd64.deb"

# 消费版主版本号（apt 包后缀）。从 nvidia-driver-535 升到 580 = 改这里 + 跑 init-consumer。
# 升级前必读：CUDA 13 需要 driver ≥ 580，所以装了 PyTorch cu130 / 后续 cu13x 必须 580+；
# 而 vGPU host driver 仍然钉死 535（vGPU 16.x 系列），两条线版本独立。
CONSUMER_DRV_MAJOR="580"
# 消费版从 Ubuntu noble-security 仓库装 (apt nvidia-driver-${MAJOR})。
# 不用 .run installer：vGPU deb 共存时 .run 检测到 "alternate install" 会跳过 .ko 安装。
CONSUMER_APT_PKGS=(
  "nvidia-driver-${CONSUMER_DRV_MAJOR}"
  "nvidia-utils-${CONSUMER_DRV_MAJOR}"
  "libnvidia-encode-${CONSUMER_DRV_MAJOR}"
  "libnvidia-decode-${CONSUMER_DRV_MAJOR}"
)

# NVIDIA 安装树触及的所有路径（glob 形式）。两种模式取并集，切换时按并集 rm 再解压目标快照。
# 任何 NVIDIA 文件落点漏在外面 = 切换后串味，所以宁多勿少。
# 注意：每一项必须**整个**用双引号包住，否则 array 赋值时 bash 会立刻 glob 展开
# (e.g. "abc"*.ko 中 *.ko 在引号外 → 赋值时就被展开成已存在的字面路径，运行时再 expand 没意义)
declare -a MANAGED_GLOBS=(
  "/lib/modules/${KVER}/updates/dkms/nvidia*.ko*"
  "/usr/lib/x86_64-linux-gnu/libnvidia*.so*"
  "/usr/lib/x86_64-linux-gnu/libcuda*.so*"
  "/usr/lib/x86_64-linux-gnu/libnvcuvid*.so*"
  "/usr/lib/x86_64-linux-gnu/libnvidia-egl-*.so*"
  "/usr/lib/x86_64-linux-gnu/libGLX_nvidia*.so*"
  "/usr/lib/x86_64-linux-gnu/libGLESv1_CM_nvidia*.so*"
  "/usr/lib/x86_64-linux-gnu/libGLESv2_nvidia*.so*"
  "/usr/lib/x86_64-linux-gnu/libEGL_nvidia*.so*"
  "/usr/lib/x86_64-linux-gnu/libnvoptix*.so*"
  "/usr/lib/x86_64-linux-gnu/libOpenCL.so*"
  "/usr/lib/x86_64-linux-gnu/vdpau/libvdpau_nvidia*.so*"
  "/usr/lib/x86_64-linux-gnu/gbm/nvidia-drm_gbm.so"
  "/usr/lib/firmware/nvidia"
  "/lib/firmware/nvidia"
  "/usr/bin/nvidia-smi"
  "/usr/bin/nvidia-vgpud"
  "/usr/bin/nvidia-vgpu-mgr"
  "/usr/bin/nvidia-modprobe"
  "/usr/bin/nvidia-debugdump"
  "/usr/bin/nvidia-cuda-mps-control"
  "/usr/bin/nvidia-cuda-mps-server"
  "/usr/bin/nvidia-persistenced"
  "/usr/bin/nvidia-settings"
  "/usr/bin/nvidia-xconfig"
  "/usr/bin/nvidia-bug-report.sh"
  "/usr/share/nvidia"
  "/etc/vulkan/icd.d/nvidia_icd.json"
  "/etc/vulkan/icd.d/nvidia_layers.json"
  "/etc/vulkan/implicit_layer.d/nvidia_layers.json"
  "/etc/OpenCL/vendors/nvidia.icd"
  "/usr/share/glvnd/egl_vendor.d/10_nvidia.json"
  "/usr/share/egl/egl_external_platform.d/10_nvidia_wayland.json"
  "/usr/share/egl/egl_external_platform.d/15_nvidia_gbm.json"
  # systemd unit 文件 — vGPU deb 和 .run 都会写到这里，必须按模式切换
  "/usr/lib/systemd/system/nvidia-*.service"
  "/usr/lib/systemd/system/nvidia-*.target"
  "/lib/systemd/system/nvidia-*.service"
  "/lib/systemd/system/nvidia-*.target"
  # modprobe 配置 — installer 会写
  "/etc/modprobe.d/nvidia*.conf"
  "/usr/lib/modprobe.d/nvidia*.conf"
  # dkms 源码树（重编内核模块时要；切换时不重编也无害）
  "/usr/src/nvidia-*"
)

# 危险路径白名单：任何展开结果落到这些路径上就 abort，防 glob 翻车删根。
SAFETY_DENY=( "/" "/usr" "/usr/lib" "/usr/lib/x86_64-linux-gnu" "/usr/bin" "/lib" "/lib/modules" "/etc" "/usr/share" "/lib/firmware" "/usr/lib/firmware" )

c_blue='\033[1;36m'; c_red='\033[1;31m'; c_yel='\033[1;33m'; c_off='\033[0m'
log()  { printf "${c_blue}[gpu-mode]${c_off} %s\n" "$*" >&2; }
warn() { printf "${c_yel}[gpu-mode]${c_off} %s\n" "$*" >&2; }
die()  { printf "${c_red}[gpu-mode] %s${c_off}\n" "$*" >&2; exit 1; }

require_root() { [[ $EUID -eq 0 ]] || die "需要 root: sudo $0 $*"; }

current_mode() {
  [[ -f $ROOT/state/current ]] && cat "$ROOT/state/current" || echo unknown
}

# 把 MANAGED_GLOBS 在当前文件树展开成实际存在的路径列表（绝对路径，去重）
# 字面路径不存在时跳过；含 wildcard 的靠 nullglob。
expand_managed() {
  local p
  {
    for p in "${MANAGED_GLOBS[@]}"; do
      eval "for x in $p; do
        if [[ -e \"\$x\" || -L \"\$x\" ]]; then printf '%s\n' \"\$x\"; fi
      done" 2>/dev/null || true
    done
  } | sort -u
}

# 返回所有快照 manifest 中记录过的路径并集（用于切换时的清空步骤）
union_manifests() {
  cat "$ROOT/manifests/"*.list 2>/dev/null | sort -u
}

assert_path_safe() {
  local p
  for p in "$@"; do
    local d
    for d in "${SAFETY_DENY[@]}"; do
      [[ "$p" == "$d" ]] && die "安全检查失败：拒绝处理保护路径 $p"
    done
    [[ "$p" == /* ]] || die "安全检查失败：非绝对路径 $p"
  done
}

assert_no_gpu_users() {
  if pgrep -fa 'qemu-system' >/dev/null 2>&1; then
    pgrep -fa 'qemu-system' >&2
    die "有 qemu-system 进程在跑，先 stop-vm 全部 VM"
  fi
  if compgen -G "/sys/bus/mdev/devices/*" >/dev/null; then
    die "存在 mdev 设备，先释放：ls /sys/bus/mdev/devices/"
  fi
  # /dev/nvidia* 仍被持有时只警告，stop_stack 会再清一次
  if lsof -t /dev/nvidia* /dev/nvidiactl /dev/nvidia-uvm 2>/dev/null | grep -q .; then
    warn "/dev/nvidia* 仍被持有，stop_stack 会停 gdm 释放"
  fi
}

snapshot_mode() {
  local mode=$1
  case "$mode" in vgpu|consumer) ;; *) die "snapshot 模式必须是 vgpu/consumer" ;; esac
  mkdir -p "$ROOT/snapshots" "$ROOT/manifests" "$ROOT/state"
  local manifest=$ROOT/manifests/${mode}.list
  local snap=$ROOT/snapshots/${mode}.tar.zst

  expand_managed > "$manifest"
  [[ -s $manifest ]] || die "没找到任何 NVIDIA 文件可快照（驱动是不是没装？）"
  local n; n=$(wc -l < "$manifest")
  log "snapshot $mode: $n 个路径 → $snap"

  # tar 用相对路径（去掉前导 /），从根目录打包
  tar --zstd --xattrs --acls -C / -cpf "$snap" -T <(sed 's|^/||' "$manifest")
  log "snapshot 完成 ($(du -h "$snap" | cut -f1))"
}

stop_stack() {
  log "mask + stop nvidia-vgpu 服务 + 停 gdm"
  # mask 防止任何机制（udev / systemd 依赖 / Restart=）在 .run installer 跑时 auto-start
  systemctl mask --runtime nvidia-vgpu-mgr.service nvidia-vgpud.service 2>&1 | grep -v '^Created' || true
  systemctl stop nvidia-vgpu-mgr.service 2>/dev/null || true
  systemctl stop nvidia-vgpud.service 2>/dev/null || true
  systemctl stop nvidia-persistenced.service 2>/dev/null || true
  systemctl stop gdm.service gdm3.service 2>/dev/null || true
  sleep 1
  # 验证 mask 真的生效（is-enabled 对 masked 返回非零，要 || true 才不触发 set -e）
  local m; m=$(systemctl is-enabled nvidia-vgpu-mgr.service 2>&1 || true)
  log "  nvidia-vgpu-mgr now: $m"
}

unload_modules() {
  log "卸载 nvidia 内核模块"
  local mods=(nvidia_vgpu_vfio nvidia_drm nvidia_modeset nvidia_uvm nvidia)
  local m
  for m in "${mods[@]}"; do
    if lsmod | awk '{print $1}' | grep -qx "$m"; then
      log "  rmmod $m"
      if ! rmmod "$m" 2>/tmp/gpu-mode-rmmod.err; then
        cat /tmp/gpu-mode-rmmod.err >&2
        # 列一下持有者帮排查
        lsof /dev/nvidia* /dev/nvidiactl 2>/dev/null | head -20 >&2 || true
        die "rmmod $m 失败 — 还有进程持有 GPU"
      fi
    fi
  done
}

apply_snapshot() {
  local mode=$1
  local snap=$ROOT/snapshots/${mode}.tar.zst
  [[ -f $snap ]] || die "没找到 snapshot：$snap（先跑 init-${mode}）"

  # 清理目标：所有 manifest 已知路径 ∪ 当前文件树里 MANAGED_GLOBS 能展开到的路径
  # 后者用来扫掉 installer 中途失败留下的孤儿文件（不在任何 manifest 里）
  log "清理 NVIDIA 文件路径（manifests ∪ 当前文件树扫描）"
  local p removed=0
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    assert_path_safe "$p"
    if [[ -e "$p" || -L "$p" ]]; then
      rm -rf -- "$p" && removed=$((removed+1))
    fi
  done < <({ union_manifests; expand_managed; } | sort -u)
  log "  清理 $removed 个路径"

  log "解压 $mode 快照"
  tar --zstd --xattrs --acls -xpf "$snap" -C /
}

reload_modules() {
  local mode=$1
  log "depmod -a $KVER"
  depmod -a "$KVER"
  log "modprobe nvidia"
  modprobe nvidia
  if [[ $mode == vgpu ]]; then
    log "modprobe nvidia_vgpu_vfio"
    modprobe nvidia_vgpu_vfio
  else
    # consumer 模式：显式 modprobe nvidia_uvm + nvidia_modeset。
    # 不靠"udev 按需"，因为 PyTorch 等首次 cudaInit 会失败：
    #   RuntimeError: CUDA unknown error - this may be due to an incorrectly set up environment
    # 实测必须 uvm 加载完成再 cudaInit 才稳。
    log "modprobe nvidia_uvm + nvidia_modeset (consumer)"
    modprobe nvidia_uvm 2>&1 | tail -1 || warn "modprobe nvidia_uvm 失败"
    modprobe nvidia_modeset 2>&1 | tail -1 || warn "modprobe nvidia_modeset 失败"
  fi
}

start_stack() {
  local mode=$1
  if [[ $mode == vgpu ]]; then
    log "unmask + 拉起 nvidia-vgpu-mgr"
    systemctl unmask --runtime nvidia-vgpu-mgr.service nvidia-vgpud.service 2>/dev/null || true
    systemctl daemon-reload
    systemctl start nvidia-vgpu-mgr.service
    # nvidia-vgpud 是 socket-on-demand，不主动 start
  else
    # consumer 模式：保持 vgpu 服务 masked，避免 udev 误拉
    :
  fi
  log "拉起显示管理器"
  systemctl start gdm3.service 2>/dev/null || systemctl start gdm.service 2>/dev/null || true
}

cmd_status() {
  echo "current mode : $(current_mode)"
  echo "kernel       : $KVER"
  echo "snapshots    :"
  ls -lh "$ROOT/snapshots/" 2>/dev/null | awk 'NR>1{printf "  %s  %s\n",$5,$NF}' || echo "  (none)"
  echo "loaded mods  :"
  lsmod | awk '/^nvidia/ {printf "  %-22s used=%s\n",$1,$3}'
  echo "driver ver   :"
  if [[ -r /proc/driver/nvidia/version ]]; then
    awk '/NVRM/{print "  " $0}' /proc/driver/nvidia/version
  else
    echo "  (no nvidia loaded)"
  fi
  echo "services     :"
  for s in nvidia-vgpu-mgr nvidia-vgpud nvidia-persistenced; do
    printf "  %-22s %s\n" "$s" "$(systemctl is-active "$s" 2>/dev/null || true)"
  done
}

cmd_switch() {
  local target=$1
  case "$target" in vgpu|consumer) ;; *) die "目标必须是 vgpu/consumer" ;; esac
  local cur; cur=$(current_mode)
  if [[ "$target" == "$cur" ]]; then
    log "已经是 $target 模式，无需切换"
    return 0
  fi

  require_root
  [[ -f $LOCK && ! -L $LOCK ]] || die "持久 mode state/lock 不安全或不存在：$LOCK"
  exec 9<"$LOCK"
  flock -n 9 || die "另一个 gpu-mode 在运行（lock=$LOCK）"

  [[ -f "$ROOT/snapshots/${target}.tar.zst" ]] || die "$target 快照不存在 — 先跑 init-${target}"

  assert_no_gpu_users
  log "切换 $cur → $target"
  local t0=$SECONDS

  stop_stack
  unload_modules
  apply_snapshot "$target"
  reload_modules "$target"
  start_stack "$target"

  echo "$target" > "$ROOT/state/current"
  log "✓ 切到 $target，用时 $((SECONDS-t0))s"
  cmd_status
}

cmd_init_vgpu() {
  require_root
  mkdir -p "$ROOT"/{snapshots,manifests,state,cache}

  if [[ ! -r /proc/driver/nvidia/version ]]; then
    die "当前没有 nvidia 模块加载，无法捕获 vGPU 状态。请先确认 vGPU host driver 正常。"
  fi
  local nvrm; nvrm=$(awk '/NVRM/{print $8}' /proc/driver/nvidia/version)
  log "检测到 NVRM $nvrm（期望 $VGPU_DRV_VERSION）"

  snapshot_mode vgpu
  echo vgpu > "$ROOT/state/current"
  log "✓ vGPU 快照就绪"
  log "下一步：sudo $0 init-consumer    # 自动下载并安装消费版"
}

cmd_init_consumer() {
  require_root
  mkdir -p "$ROOT"/{snapshots,manifests,state,cache}

  [[ -f "$ROOT/snapshots/vgpu.tar.zst" ]] || die "先跑 init-vgpu 备份当前 vGPU"
  [[ -f "$VGPU_DEB_PATH" ]] || die "找不到 vGPU 原 deb：$VGPU_DEB_PATH（用来复原 dpkg 状态）"

  [[ -f $LOCK && ! -L $LOCK ]] || die "持久 mode state/lock 不安全或不存在：$LOCK"
  exec 9<"$LOCK"
  flock -n 9 || die "另一个 gpu-mode 在运行"

  assert_no_gpu_users
  log "停 vGPU 栈，准备装消费版"
  stop_stack
  unload_modules

  # 失败时自动恢复 vGPU（apt purge 后 vGPU deb 状态需要 dpkg -i 复原）
  trap '{ rc=$?; if (( rc != 0 )); then
    warn "init-consumer 失败 (exit $rc)，尝试自动恢复 vGPU"
    apply_snapshot vgpu 2>/dev/null || true
    if ! dpkg -l nvidia-vgpu-ubuntu-535 2>/dev/null | grep -q "^ii"; then
      warn "  dpkg -i 复原 vGPU deb"
      dpkg -i "'"$VGPU_DEB_PATH"'" 2>/dev/null || true
    fi
    reload_modules vgpu 2>/dev/null || true
    start_stack vgpu 2>/dev/null || true
  fi; }' EXIT

  # 清旧 dkms 残留
  log "清 dkms 里 consumer 旧版残留"
  for ver_dir in /var/lib/dkms/nvidia/*; do
    [[ -d "$ver_dir" ]] || continue
    local v=$(basename "$ver_dir")
    [[ "$v" == "$VGPU_DRV_VERSION" ]] && continue
    log "  dkms remove nvidia/$v"
    dkms remove nvidia/"$v" --all 2>/dev/null || true
    rm -rf "$ver_dir" "/usr/src/nvidia-$v"
  done

  log "apt-get update（noble-security 镜像可达）"
  DEBIAN_FRONTEND=noninteractive apt-get update -qq 2>&1 | grep -v '^W:' || true

  # us.archive.ubuntu.com 走本地 198.18.x 透明代理时偶尔挂（main 仓库的小包），
  # 用阿里云 mirror 预下 libnvidia-egl-wayland1 dpkg -i 满足依赖
  if [[ -f "$ROOT/cache/libnvidia-egl-wayland1_1.1.13-1build1_amd64.deb" ]]; then
    log "dpkg -i 预装 libnvidia-egl-wayland1（绕本地代理对 main 仓库的偶发屏蔽）"
    dpkg -i "$ROOT/cache/libnvidia-egl-wayland1_1.1.13-1build1_amd64.deb" 2>&1 | tail -3 || true
  fi

  # 跨主版本（535 → 580 等）apt 不会自动解 vGPU 冲突，必须先显式 purge。
  # 同主版本（535 → 535）历史上 apt 能自动 dpkg purge，但这里统一处理免分支。
  # vGPU dpkg 状态会在本函数尾部 dpkg -i 时复原；trap 失败路径也复原。
  log "purge vGPU deb 让出 dpkg 名字空间（cross-major 必需）"
  apt-mark unhold nvidia-vgpu-ubuntu-535 2>&1 | tail -1 || true
  DEBIAN_FRONTEND=noninteractive apt-get purge -y nvidia-vgpu-ubuntu-535 2>&1 | tail -3 \
    || warn "apt purge vGPU deb 有非致命警告，继续"

  log "apt install 消费版"
  log "  packages: ${CONSUMER_APT_PKGS[*]}"
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    "${CONSUMER_APT_PKGS[@]}" \
    || die "apt install 失败 — 看 /var/log/dpkg.log /var/lib/dkms/*/build/make.log"

  # 装完可能 auto-modprobe；再卸一遍保证 snapshot/apply 干净
  log "卸载 consumer 模块（如有）"
  unload_modules

  log "捕获 consumer 状态"
  snapshot_mode consumer

  log "apt purge consumer deb 包（让 dpkg 状态空出来给 vGPU deb）"
  # consumer 的 nvidia-dkms-${MAJOR} 跟 vGPU 的 nvidia-dkms-kernel 冲突，必须先卸
  local M="${CONSUMER_DRV_MAJOR}"
  DEBIAN_FRONTEND=noninteractive apt-get purge -y \
    "nvidia-driver-${M}" "nvidia-utils-${M}" "nvidia-dkms-${M}" "nvidia-kernel-source-${M}" \
    "nvidia-kernel-common-${M}" "nvidia-compute-utils-${M}" \
    "libnvidia-*-${M}" "nvidia-firmware-${M}*" "xserver-xorg-video-nvidia-${M}" \
    2>&1 | tail -5 || warn "apt purge 有非致命警告，继续"

  log "dpkg -i 重装 vGPU deb（复原 dpkg 状态 + 文件 + dkms）"
  dpkg -i "$VGPU_DEB_PATH" 2>&1 | tail -10 \
    || die "dpkg -i vGPU deb 失败 — 看 /var/log/dpkg.log"

  log "apt-mark hold nvidia-vgpu-ubuntu-535 防 apt upgrade"
  apt-mark hold nvidia-vgpu-ubuntu-535 2>&1 | tail -1 || true

  # dpkg -i vGPU 会 trigger 模块加载；卸了再 apply 保证文件层干净
  unload_modules

  log "apply_snapshot vgpu 把 vGPU 文件层稳定化"
  apply_snapshot vgpu
  reload_modules vgpu
  start_stack vgpu
  echo vgpu > "$ROOT/state/current"

  trap - EXIT
  log "✓ 初始化完成 — vGPU dpkg 状态完整，consumer 快照 ready"
  log "切换：sudo $0 consumer    /    sudo $0 vgpu"
}

cmd_doctor() {
  echo "=== gpu-mode doctor ==="
  echo "ROOT          : $ROOT"
  echo "current mode  : $(current_mode)"
  echo "kernel        : $KVER"
  echo
  echo "--- snapshots ---"
  ls -la "$ROOT/snapshots/" 2>/dev/null || echo "(missing)"
  echo
  echo "--- manifests (line count) ---"
  for f in "$ROOT/manifests/"*.list; do
    [[ -f $f ]] && printf "  %-30s %s lines\n" "$(basename "$f")" "$(wc -l < "$f")"
  done
  echo
  echo "--- loaded modules ---"
  lsmod | awk '/^nvidia/'
  echo
  echo "--- /dev/nvidia holders ---"
  lsof /dev/nvidia* /dev/nvidiactl /dev/nvidia-uvm 2>/dev/null | head -20 || true
  echo
  echo "--- mdev devices ---"
  ls -la /sys/bus/mdev/devices/ 2>/dev/null || true
  echo
  echo "--- running qemu ---"
  pgrep -fa qemu-system || echo "(none)"
}

usage() {
  cat <<'EOF'
gpu-mode — RTX 2080 在 vGPU host driver 与消费版 driver 间切换

用法:
  sudo gpu-mode.sh status                    显示当前模式 / 已加载模块 / 快照
  sudo gpu-mode.sh init-vgpu                 把当前 vGPU 安装树打成 vgpu 快照
  sudo gpu-mode.sh init-consumer [run-path]  下载/运行消费版 .run 并打 consumer 快照
  sudo gpu-mode.sh vgpu                      切到 vGPU 模式（VM 拆分用）
  sudo gpu-mode.sh consumer                  切到消费版模式（宿主用）
  sudo gpu-mode.sh snapshot <vgpu|consumer>  重打指定模式快照（内核升级后必跑）
  sudo gpu-mode.sh doctor                    一站式状态打印，排错用

切换前必须：
  - 所有 qemu-system VM 已停（stop-vm.sh）
  - 没有 mdev 设备占用
EOF
}

main() {
  local sub=${1:-status}
  shift || true
  case "$sub" in
    status)              cmd_status ;;
    vgpu|consumer)       cmd_switch "$sub" ;;
    snapshot)            require_root; snapshot_mode "${1:-$(current_mode)}" ;;
    init-vgpu)           cmd_init_vgpu ;;
    init-consumer)       cmd_init_consumer "${1:-}" ;;
    doctor)              cmd_doctor ;;
    -h|--help|help|"")   usage ;;
    *)                   usage; die "未知子命令: $sub" ;;
  esac
}

main "$@"
