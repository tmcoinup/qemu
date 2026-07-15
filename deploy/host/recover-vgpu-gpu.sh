#!/usr/bin/env bash
# Recover this host's single NVIDIA vGPU physical function without rebooting.
#
# Safety policy:
#   * serialize with gpu-mode.sh and mdev create/remove via persistent mode state;
#   * require exactly one NVIDIA display-class PCI function on the host;
#   * require no mdev, NVIDIA device user, or VFIO device user;
#   * never force-unload a module;
#   * restrict the raw sysfs reset to FLR, with exact readback;
#   * never reboot the host automatically.
set -Eeuo pipefail

GPU_BDF="0000:04:00.0"
MDEV_TYPE="nvidia-257"
CHECK_ONLY=0
RESUME_INACTIVE_MANAGER=0
LOCK_FILE="/opt/nvidia-modes/state/current"
MANAGER_SERVICE="nvidia-vgpu-mgr.service"
VGPUD_SERVICE="nvidia-vgpud.service"

usage() {
  cat <<'EOF'
Usage:
  sudo ./deploy/host/recover-vgpu-gpu.sh [--check] [--resume]
      [--gpu 0000:04:00.0] [--mdev-type nvidia-257]

Options:
  --check                 Strictly read-only health/preflight report.
  --resume                Resume after this script previously left the vGPU
                          manager inactive/failed; all other gates still apply.
  --gpu BDF               NVIDIA physical function (default: 0000:04:00.0).
  --mdev-type TYPE        Required mdev type (default: nvidia-257).
  -h, --help              Show this help.

The recovery order is NVIDIA's default FLR, a clean module reload, then a
sysfs reset explicitly restricted to FLR. The script never requests bus reset,
force-removes a module, or reboots the host.
EOF
}

log()  { printf '[recover-vgpu] %s\n' "$*" >&2; }
warn() { printf '[recover-vgpu] WARNING: %s\n' "$*" >&2; }
die()  { printf '[recover-vgpu] ERROR: %s\n' "$*" >&2; exit 1; }

while (($#)); do
  case "$1" in
    --check)
      CHECK_ONLY=1
      shift
      ;;
    --resume)
      RESUME_INACTIVE_MANAGER=1
      shift
      ;;
    --gpu)
      (($# >= 2)) || die "--gpu requires a value"
      GPU_BDF=$2
      shift 2
      ;;
    --mdev-type)
      (($# >= 2)) || die "--mdev-type requires a value"
      MDEV_TYPE=$2
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[[ $GPU_BDF =~ ^[[:xdigit:]]{4}:[[:xdigit:]]{2}:[[:xdigit:]]{2}\.[0-7]$ ]] ||
  die "invalid PCI BDF: $GPU_BDF"
[[ $MDEV_TYPE =~ ^nvidia-[0-9]+$ ]] || die "invalid mdev type: $MDEV_TYPE"
if [[ $EUID -ne 0 ]]; then
  ((CHECK_ONLY)) && die "run as root: sudo $0 --check"
  die "run as root: sudo $0"
fi

for command_name in flock lsof modprobe nvidia-smi rmmod systemctl; do
  command -v "$command_name" >/dev/null 2>&1 || die "missing command: $command_name"
done

GPU_DIR="/sys/bus/pci/devices/$GPU_BDF"
TYPE_DIR="$GPU_DIR/mdev_supported_types/$MDEV_TYPE"
AVAILABLE_FILE="$TYPE_DIR/available_instances"

module_loaded() {
  grep -q "^$1 " /proc/modules
}

capture_state() {
  manager_active=0
  systemctl is-active --quiet "$MANAGER_SERVICE" && manager_active=1
  vgpud_active=0
  systemctl is-active --quiet "$VGPUD_SERVICE" && vgpud_active=1
  nvidia_loaded=0
  module_loaded nvidia && nvidia_loaded=1
  vgpu_loaded=0
  module_loaded nvidia_vgpu_vfio && vgpu_loaded=1
}

validate_target() {
  local pci_vendor pci_class device_api available bound_driver display_dir
  local -a nvidia_display_functions=()

  [[ -d $GPU_DIR ]] || die "PCI device does not exist: $GPU_BDF"
  read -r pci_vendor < "$GPU_DIR/vendor"
  [[ $pci_vendor == 0x10de ]] || die "$GPU_BDF is not NVIDIA (vendor: $pci_vendor)"
  read -r pci_class < "$GPU_DIR/class"
  [[ $pci_class == 0x03* ]] || die "$GPU_BDF is not a display-class function (class: $pci_class)"

  for display_dir in /sys/bus/pci/devices/*; do
    [[ -r $display_dir/vendor && -r $display_dir/class ]] || continue
    [[ $(<"$display_dir/vendor") == 0x10de ]] || continue
    [[ $(<"$display_dir/class") == 0x03* ]] || continue
    nvidia_display_functions+=("${display_dir##*/}")
  done
  ((${#nvidia_display_functions[@]} == 1)) ||
    die "recovery requires exactly one NVIDIA display function; found: ${nvidia_display_functions[*]:-none}"
  [[ ${nvidia_display_functions[0]} == "$GPU_BDF" ]] ||
    die "the only NVIDIA display function is ${nvidia_display_functions[0]}, not $GPU_BDF"

  [[ -L $GPU_DIR/driver ]] || die "$GPU_BDF has no bound driver"
  bound_driver=$(basename "$(readlink -f "$GPU_DIR/driver")")
  [[ $bound_driver == nvidia ]] || die "$GPU_BDF is bound to $bound_driver, not nvidia"

  if [[ ! -d $TYPE_DIR ]]; then
    if ((RESUME_INACTIVE_MANAGER)) && [[ $MDEV_TYPE == nvidia-257 ]]; then
      warn "$MDEV_TYPE is temporarily absent from the failed driver; post-recovery health must restore it"
      return 0
    fi
    die "mdev type does not exist under $GPU_BDF: $MDEV_TYPE"
  fi
  read -r device_api < "$TYPE_DIR/device_api"
  [[ $device_api == vfio-pci ]] || die "$MDEV_TYPE has unexpected device_api: $device_api"
  [[ -w $TYPE_DIR/create ]] || die "$MDEV_TYPE create node is not writable as root"
  [[ -r $AVAILABLE_FILE ]] || die "$MDEV_TYPE available_instances is not readable"
  read -r available < "$AVAILABLE_FILE"
  [[ $available =~ ^[0-9]+$ ]] || die "$MDEV_TYPE available_instances is invalid: $available"
}

list_mdevs() {
  find /sys/bus/mdev/devices -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null
}

assert_no_mdevs() {
  local existing
  existing=$(list_mdevs)
  [[ -z $existing ]] || die "active mdev devices remain; stop their VMs first: $existing"
}

collect_device_nodes() {
  local pattern node
  for pattern in '/dev/nvidia*' '/dev/nvidia-caps/*' '/dev/vfio/*'; do
    while IFS= read -r node; do
      [[ -c $node ]] && printf '%s\n' "$node"
    done < <(compgen -G "$pattern" || true)
  done
}

assert_no_device_users() {
  local -a nodes=()
  local output rc

  mapfile -t nodes < <(collect_device_nodes | sort -u)
  ((${#nodes[@]})) || return 0

  set +e
  output=$(lsof -nP -t -- "${nodes[@]}" 2>&1)
  rc=$?
  set -e
  case $rc in
    0)
      lsof -nP -- "${nodes[@]}" >&2 || true
      die "NVIDIA/VFIO device nodes are still in use by PID(s): $(tr '\n' ' ' <<<"$output")"
      ;;
    1)
      [[ -z $output ]] || die "lsof could not prove device nodes idle: $output"
      ;;
    *)
      die "lsof failed while checking device users (exit $rc): $output"
      ;;
  esac
}

assert_headless_vgpu_modules() {
  local unexpected=() module_name
  for module_name in nvidia_drm nvidia_modeset nvidia_uvm; do
    module_loaded "$module_name" && unexpected+=("$module_name")
  done
  ((${#unexpected[@]} == 0)) ||
    die "extra NVIDIA display/compute modules are loaded: ${unexpected[*]}"
}

available_instances() {
  local value
  [[ -r $AVAILABLE_FILE ]] || return 1
  read -r value < "$AVAILABLE_FILE" || return 1
  [[ $value =~ ^[0-9]+$ ]] || return 1
  ((value > 0)) || return 1
  printf '%s\n' "$value"
}

target_gpu_queryable() {
  local reported target_suffix
  reported=$(nvidia-smi -i "$GPU_BDF" --query-gpu=pci.bus_id \
    --format=csv,noheader,nounits 2>/dev/null) || return 1
  reported=$(tr -d '[:space:]' <<<"$reported")
  target_suffix=${GPU_BDF#*:}
  [[ ${reported,,} == *:"${target_suffix,,}" ]]
}

gpu_healthy() {
  module_loaded nvidia &&
    module_loaded nvidia_vgpu_vfio &&
    systemctl is-active --quiet "$MANAGER_SERVICE" &&
    ! systemctl is-active --quiet "$VGPUD_SERVICE" &&
    ! module_loaded nvidia_drm &&
    ! module_loaded nvidia_modeset &&
    ! module_loaded nvidia_uvm &&
    target_gpu_queryable &&
    nvidia-smi vgpu >/dev/null 2>&1 &&
    available_instances >/dev/null
}

wait_for_health() {
  local attempt
  for attempt in {1..15}; do
    gpu_healthy && return 0
    sleep 1
  done
  return 1
}

show_health() {
  nvidia-smi -i "$GPU_BDF" --query-gpu=name,pci.bus_id,driver_version \
    --format=csv,noheader || return 1
  nvidia-smi vgpu || return 1
  printf '[recover-vgpu] %s available_instances=' "$MDEV_TYPE"
  cat "$AVAILABLE_FILE" || return 1
}

validate_target
capture_state
assert_no_mdevs
log "GPU=$GPU_BDF mdev_type=$MDEV_TYPE"
log "modules: nvidia=$nvidia_loaded nvidia_vgpu_vfio=$vgpu_loaded; manager_active=$manager_active vgpud_active=$vgpud_active"
assert_headless_vgpu_modules
((nvidia_loaded)) || die "nvidia is not loaded; refusing to report a partial stack as healthy"
((vgpu_loaded)) || die "nvidia_vgpu_vfio is not loaded; refusing to report a partial stack as healthy"
if ((!manager_active && !RESUME_INACTIVE_MANAGER)); then
  die "$MANAGER_SERVICE is not active; use --resume only after a recorded recovery failure"
fi
((!vgpud_active)) || die "$VGPUD_SERVICE is active; diagnose the unexpected daemon state first"

if gpu_healthy; then
  log "GPU/vGPU stack is already healthy; no recovery needed"
  show_health || die "health changed while reporting it"
  exit 0
fi

if ((CHECK_ONLY)); then
  nvidia-smi -i "$GPU_BDF" -L || true
  nvidia-smi vgpu || true
  die "GPU/vGPU health check failed; re-run without --check to recover"
fi

# This is the same lock used by gpu-mode.sh. deploy/lib/vgpu-mdev.sh also takes
# it around every mdev create/remove, closing both mode-switch and VM-start races.
[[ -f $LOCK_FILE && ! -L $LOCK_FILE && -r $LOCK_FILE ]] ||
  die "shared vGPU host lock is missing/unsafe: $LOCK_FILE"
exec 9<"$LOCK_FILE"
flock -n 9 || die "gpu-mode, mdev allocation, or another recovery is running (lock: $LOCK_FILE)"

# Everything above the lock is repeated because another process could have
# changed the host between the read-only report and acquisition of the lock.
validate_target
capture_state
assert_no_mdevs
assert_headless_vgpu_modules
((nvidia_loaded)) || die "nvidia is not loaded; refusing to guess a different host state"
((vgpu_loaded)) || die "nvidia_vgpu_vfio is not loaded; refusing to guess a different host state"
if ((!manager_active && !RESUME_INACTIVE_MANAGER)); then
  die "$MANAGER_SERVICE is not active; use --resume only after a recorded recovery failure"
fi
((!vgpud_active)) || die "$VGPUD_SERVICE is active; stop and diagnose it before GPU recovery"

if gpu_healthy; then
  log "GPU recovered before mutation; no action needed"
  show_health || die "health changed while reporting it"
  exit 0
fi

manager_stopped_by_us=$((manager_active ? 0 : 1))
manager_started_by_us=0
nvidia_removed_by_us=0
vgpu_removed_by_us=0
reset_methods_original=''
reset_methods_changed=0

restore_reset_methods() {
  local restored_methods
  ((reset_methods_changed)) || return 0
  if ! printf 'default\n' > "$GPU_DIR/reset_method"; then
    warn "could not restore the kernel default reset methods (previous: $reset_methods_original)"
    return 1
  fi
  read -r restored_methods < "$GPU_DIR/reset_method" || {
    warn "could not read reset_method after restoring kernel defaults"
    return 1
  }
  [[ -n $restored_methods ]] || {
    warn "kernel default reset method list is empty"
    return 1
  }
  log "reset_method restored to kernel defaults: $restored_methods"
  reset_methods_changed=0
}

restore_stack_best_effort() {
  local rc=$?
  trap - EXIT INT TERM

  restore_reset_methods || true
  if ((nvidia_removed_by_us)) && ! module_loaded nvidia; then
    warn "restoring nvidia after an interrupted/failed recovery"
    if modprobe nvidia; then nvidia_removed_by_us=0; else warn "could not restore nvidia"; fi
  fi
  if ((vgpu_removed_by_us)) && ! module_loaded nvidia_vgpu_vfio; then
    warn "restoring nvidia_vgpu_vfio after an interrupted/failed recovery"
    if modprobe nvidia_vgpu_vfio; then vgpu_removed_by_us=0; else warn "could not restore nvidia_vgpu_vfio"; fi
  fi
  if ((manager_started_by_us)) && ! systemctl is-active --quiet "$MANAGER_SERVICE"; then
    manager_stopped_by_us=1
  fi
  if ((manager_stopped_by_us)) && ! systemctl is-active --quiet "$MANAGER_SERVICE"; then
    if module_loaded nvidia && module_loaded nvidia_vgpu_vfio; then
      warn "restoring $MANAGER_SERVICE after an interrupted/failed recovery"
      if systemctl start "$MANAGER_SERVICE"; then manager_stopped_by_us=0; else warn "could not restore $MANAGER_SERVICE"; fi
    else
      warn "keeping $MANAGER_SERVICE stopped because one or more required modules could not be restored"
    fi
  fi
  exit "$rc"
}
trap restore_stack_best_effort EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

stop_manager() {
  if ((manager_stopped_by_us == 0)); then
    if ! systemctl is-active --quiet "$MANAGER_SERVICE"; then
      ((manager_started_by_us)) || die "$MANAGER_SERVICE stopped outside this recovery"
      warn "$MANAGER_SERVICE exited during this recovery; continuing toward FLR"
    fi
    systemctl is-active --quiet "$VGPUD_SERVICE" && die "$VGPUD_SERVICE became active; refusing to alter it"
    log "stopping $MANAGER_SERVICE"
    manager_stopped_by_us=1
    systemctl stop "$MANAGER_SERVICE"
    systemctl is-active --quiet "$MANAGER_SERVICE" && die "$MANAGER_SERVICE did not stop"
    manager_started_by_us=0
  fi
  assert_no_mdevs
  assert_no_device_users
}

start_manager() {
  ((manager_stopped_by_us)) || {
    systemctl is-active --quiet "$MANAGER_SERVICE" || return 1
    return 0
  }
  log "starting $MANAGER_SERVICE"
  if ! systemctl start "$MANAGER_SERVICE"; then
    warn "$MANAGER_SERVICE failed to start"
    return 1
  fi
  if ! systemctl is-active --quiet "$MANAGER_SERVICE"; then
    warn "$MANAGER_SERVICE did not become active"
    return 1
  fi
  manager_stopped_by_us=0
  manager_started_by_us=1
}

register_mdev_types() {
  local attempt available
  target_gpu_queryable || return 1
  systemctl is-active --quiet "$VGPUD_SERVICE" && {
    warn "$VGPUD_SERVICE is unexpectedly active"
    return 1
  }

  log "running one-shot $VGPUD_SERVICE to register mdev profiles"
  if ! systemctl start "$VGPUD_SERVICE"; then
    warn "$VGPUD_SERVICE failed"
    return 1
  fi
  for attempt in {1..15}; do
    if [[ -r $TYPE_DIR/device_api && -r $AVAILABLE_FILE ]] &&
        [[ $(<"$TYPE_DIR/device_api") == vfio-pci ]]; then
      read -r available < "$AVAILABLE_FILE" || true
      if [[ $available =~ ^[1-9][0-9]*$ ]]; then
        log "$MDEV_TYPE registered with available_instances=$available"
        return 0
      fi
    fi
    sleep 1
  done
  warn "$VGPUD_SERVICE did not restore $MDEV_TYPE"
  return 1
}

unload_modules() {
  log "unloading NVIDIA vGPU modules (never forced)"
  if module_loaded nvidia_vgpu_vfio; then
    vgpu_removed_by_us=1
    rmmod nvidia_vgpu_vfio || die "could not unload nvidia_vgpu_vfio; no forced unload was attempted"
  fi
  if module_loaded nvidia; then
    nvidia_removed_by_us=1
    rmmod nvidia || die "could not unload nvidia; no forced unload was attempted"
  fi
  [[ ! -e $GPU_DIR/driver ]] || die "$GPU_BDF is still bound after module unload"
}

load_modules() {
  log "loading NVIDIA vGPU modules"
  if ((nvidia_removed_by_us)); then
    modprobe nvidia
    nvidia_removed_by_us=0
  else
    module_loaded nvidia || die "nvidia disappeared outside this recovery"
  fi
  if ((vgpu_removed_by_us)); then
    modprobe nvidia_vgpu_vfio
    vgpu_removed_by_us=0
  else
    module_loaded nvidia_vgpu_vfio || die "nvidia_vgpu_vfio disappeared outside this recovery"
  fi
}

report_if_healthy() {
  wait_for_health || return 1
  show_health || return 1
  return 0
}

# A prior interrupted FLR may have left the safe, restricted method selected.
# The kernel ABI restores its dynamic default ordering by writing "default";
# writing the displayed list (for example "flr bus") is not a valid restore.
if ((RESUME_INACTIVE_MANAGER)) && [[ -r $GPU_DIR/reset_method ]]; then
  read -r selected_reset_method < "$GPU_DIR/reset_method"
  if [[ $selected_reset_method == flr ]]; then
    reset_methods_original=$selected_reset_method
    reset_methods_changed=1
    restore_reset_methods || die "could not restore reset_method defaults after the prior FLR"
  fi
fi

# If FLR already recovered NVML but the previous run exited before vgpud could
# republish profiles, repair registration without resetting the healthy GPU.
if target_gpu_queryable; then
  if register_mdev_types && report_if_healthy; then
    log "recovery succeeded by restoring mdev profile registration"
    exit 0
  fi
  warn "target is queryable but mdev registration is incomplete; continuing recovery"
fi

stop_manager

# NVIDIA documents plain --gpu-reset as FLR; bus reset requires a separate,
# explicit reset mode on versions that support it. This command requests no
# such mode. The final raw reset below is independently pinned to sysfs "flr".
log "stage 1/3: NVIDIA default FLR"
if nvidia-smi --gpu-reset -i "$GPU_BDF"; then
  if register_mdev_types && start_manager && report_if_healthy; then
    log "recovery succeeded via NVIDIA default FLR"
    exit 0
  fi
  warn "NVIDIA reset returned success, but the target-bound health gate failed"
  stop_manager
else
  warn "NVIDIA reset did not complete; continuing to a clean module reload"
fi

log "stage 2/3: clean module reload"
unload_modules
load_modules
if register_mdev_types && start_manager && report_if_healthy; then
  log "recovery succeeded via clean NVIDIA module reload"
  exit 0
fi
warn "module reload completed, but the target-bound health gate failed"

stop_manager
unload_modules

log "stage 3/3: sysfs function reset restricted to FLR"
[[ -r $GPU_DIR/reset_method && -w $GPU_DIR/reset_method ]] ||
  die "reset_method is not readable/writable for $GPU_BDF"
[[ -w $GPU_DIR/reset ]] || die "PCI reset is not writable for $GPU_BDF"
read -r reset_methods_original < "$GPU_DIR/reset_method"
case " $reset_methods_original " in
  *' flr '*) ;;
  *) die "FLR is not supported; refusing other methods: $reset_methods_original" ;;
esac

# Mark dirty before the write so signal-time cleanup also covers the smallest
# possible interruption window. Exact readback proves bus fallback is disabled.
reset_methods_changed=1
printf 'flr\n' > "$GPU_DIR/reset_method"
read -r selected_reset_method < "$GPU_DIR/reset_method"
[[ $selected_reset_method == flr ]] ||
  die "could not restrict reset_method to FLR (read back: $selected_reset_method)"
printf '1\n' > "$GPU_DIR/reset"
restore_reset_methods || die "FLR completed but reset_method restoration failed"

load_modules
register_mdev_types || die "$VGPUD_SERVICE could not restore $MDEV_TYPE after FLR"
start_manager || die "$MANAGER_SERVICE still cannot start after FLR-only reset"
if report_if_healthy; then
  log "recovery succeeded via FLR-only sysfs reset"
  exit 0
fi

die "FLR-only recovery failed. Do not use bus reset or forced rmmod; keep VM2 stopped and reboot the host manually when authorized."
