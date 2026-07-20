# shellcheck shell=bash
# ---------------------------------------------------------------------------
# 为每台 VM 生成私有 swtpm local CA 配置。
#
# 系统 `/var/lib/swtpm-localca` 可能由 root/tss 管理，绝不能为了普通用户启动 VM
# 而递归 chown。每实例独立 CA 同时避免不同用户互相签发/篡改 TPM 证书状态。
# ---------------------------------------------------------------------------

_sv_tpm_safe_label() {
    local value="${1:-unknown}"
    value="${value//[^A-Za-z0-9._-]/_}"
    value="${value:0:64}"
    printf '%s\n' "${value:-unknown}"
}

sv_tpm_prepare_private_ca() (
    local vm_dir="$1"
    local config_dir="$vm_dir/tpm-config"
    local ca_dir="$vm_dir/tpm-ca"
    local setup_config="$config_dir/swtpm_setup.conf"
    local localca_config="$config_dir/swtpm-localca.conf"
    local localca_options="$config_dir/swtpm-localca.options"
    local localca_tool manufacturer version model pcr_banks

    # 配置格式按行解析，拒绝换行路径；也拒绝预置符号链接，防止把权限收紧或 CA
    # 文件写到实例目录以外。NUL 无法存在于 shell 变量，无需单独检查。
    if [[ -z "$vm_dir" || "$vm_dir" == *$'\n'* || "$vm_dir" == *$'\r'* ]]; then
        echo "ERROR: VM_DIR 不能包含换行，无法安全生成 TPM 配置" >&2
        return 1
    fi
    for path in "$config_dir" "$ca_dir"; do
        if [[ -L "$path" ]]; then
            echo "ERROR: TPM 私有目录不能是符号链接: $path" >&2
            return 1
        fi
    done

    localca_tool="$(command -v swtpm_localca 2>/dev/null || true)"
    if [[ -z "$localca_tool" || ! -x "$localca_tool" ]]; then
        echo "ERROR: 缺少 swtpm_localca，无法创建隔离的 EK/Platform certificate" >&2
        return 1
    fi

    manufacturer="$(_sv_tpm_safe_label "${BOARD_MFR:-ASUSTeK}")"
    version="$(_sv_tpm_safe_label "${BOARD_VERSION:-1}")"
    model="$(_sv_tpm_safe_label "${BOARD_PRODUCT:-Desktop}")"
    pcr_banks="${TPM_PCR_BANKS:-sha256}"
    case "$pcr_banks" in
        sha1|sha256|sha1,sha256|sha256,sha1) ;;
        *)
            echo "ERROR: TPM_PCR_BANKS 仅接受 sha1/sha256 的无重复逗号列表" >&2
            return 1
            ;;
    esac

    # 子 shell 的 umask 不会污染后续 QEMU 启动；生成工具后续创建的 CA 私钥也会
    # 继承私有目录边界。显式 chmod 覆盖已有目录的宽松历史权限。
    umask 077
    mkdir -p "$config_dir" "$ca_dir"
    chmod 0700 "$config_dir" "$ca_dir"

    {
        printf 'create_certs_tool = %s\n' "$localca_tool"
        printf 'create_certs_tool_config = %s\n' "$localca_config"
        printf 'create_certs_tool_options = %s\n' "$localca_options"
        printf 'active_pcr_banks = %s\n' "$pcr_banks"
    } >"$setup_config"
    {
        printf 'statedir = %s\n' "$ca_dir"
        printf 'signingkey = %s/signkey.pem\n' "$ca_dir"
        printf 'issuercert = %s/issuercert.pem\n' "$ca_dir"
        printf 'certserial = %s/certserial\n' "$ca_dir"
    } >"$localca_config"
    {
        printf '%s\n' "--platform-manufacturer $manufacturer"
        printf '%s\n' "--platform-version $version"
        printf '%s\n' "--platform-model $model"
    } >"$localca_options"
    chmod 0600 "$setup_config" "$localca_config" "$localca_options"
)
