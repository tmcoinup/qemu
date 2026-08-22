#!/usr/bin/env bash
# Foolproof operator wrapper for G-11 host performance policy.
set -euo pipefail

deploy_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
here=$deploy_root
# shellcheck source=lib/host-performance.sh
source "$deploy_root/lib/host-performance.sh"

usage() {
    cat >&2 <<'EOF'
用法:
  ./deploy/scripts/g11-performance.sh audit    # 只读检查
  ./deploy/scripts/g11-performance.sh apply    # 安装/更新并应用（推荐）
  ./deploy/scripts/g11-performance.sh restore  # 恢复首次 apply 前状态
EOF
    exit "${1:-2}"
}

command_name=${1:-audit}
[[ $# -le 1 ]] || usage
case "$command_name" in
    audit|status)
        "$G11_HOST_PERFORMANCE_SOURCE_HELPER" audit
        ;;
    apply)
        G11_HOST_PERFORMANCE=required
        g11_host_performance_apply
        ;;
    restore)
        G11_HOST_PERFORMANCE=required
        if ! g11_host_performance_helper_ready; then
            echo "[g11-performance] 已安装 helper 不存在或版本不匹配；先执行 apply" >&2
            exit 1
        fi
        g11_host_performance_restore
        ;;
    *) usage ;;
esac
