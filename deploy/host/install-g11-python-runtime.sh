#!/usr/bin/env bash
# Install/check the root-owned Python runtime used by G-11 WinRM automation.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
requirements=${G11_PYTHON_REQUIREMENTS:-$here/requirements/g11-winrm.txt}
install_root=${G11_PYTHON_INSTALL_ROOT:-/opt/g11}
runtime_dir=$install_root/python
state_dir=${G11_PYTHON_STATE_DIR:-/etc/qemu}
state_file=$state_dir/g11-python-runtime.state
mode=install
wheelhouse=${G11_PYTHON_WHEELHOUSE:-}
temporary=
backup=
transaction=0

usage() {
    cat <<'EOF'
用法：install-g11-python-runtime.sh [--check] [--wheelhouse DIR]

默认安装/修复 /opt/g11/python；--check 只读复检。
离线新主机可先在联网机下载 requirements 中的两个通用 wheel，再用
--wheelhouse 指向该目录。脚本不接收、保存或打印任何宿主/来宾凭据。
EOF
}

while (($#)); do
    case "$1" in
        --check) mode=check; shift ;;
        --wheelhouse)
            (($# >= 2)) || { usage >&2; exit 2; }
            wheelhouse=$2
            shift 2
            ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done

[[ "$install_root" == /* && "$install_root" != / && "$runtime_dir" == "$install_root/python" ]] || {
    echo "不安全的 G11_PYTHON_INSTALL_ROOT: $install_root" >&2
    exit 2
}
[[ -f "$requirements" && ! -L "$requirements" ]] || {
    echo "requirements 缺失或是符号链接: $requirements" >&2
    exit 1
}
if [[ -n "$wheelhouse" ]]; then
    wheelhouse=$(realpath -e -- "$wheelhouse") || exit
    [[ -d "$wheelhouse" && ! -L "$wheelhouse" ]] || {
        echo "wheelhouse 不是安全目录: $wheelhouse" >&2
        exit 1
    }
fi

verify_runtime() {
    local python_bin=$1
    [[ -x "$python_bin" ]] || return 1
    "$python_bin" - <<'PY'
from importlib.metadata import version
from pypsrp.client import Client
import cryptography
import requests
import spnego

assert version("pypsrp") == "0.9.1"
assert version("pyspnego") == "0.12.2"
assert tuple(int(value) for value in requests.__version__.split(".")[:2]) >= (2, 27)
assert tuple(int(value) for value in cryptography.__version__.split(".")[:2]) >= (3, 1)
assert Client is not None and spnego is not None
PY
}

requirements_sha=$(sha256sum -- "$requirements" | awk '{print $1}')
if [[ "$mode" == check ]]; then
    verify_runtime "$runtime_dir/bin/python3" || {
        echo "G-11 Python runtime 缺失或版本不匹配: $runtime_dir" >&2
        exit 1
    }
    grep -Fxq 'schema=1' "$state_file" 2>/dev/null \
        && grep -Fxq "requirements_sha256=$requirements_sha" "$state_file" 2>/dev/null || {
        echo "G-11 Python runtime 状态文件缺失或摘要不匹配: $state_file" >&2
        exit 1
    }
    echo "[g11-python] PASS: pypsrp=0.9.1 pyspnego=0.12.2 runtime=$runtime_dir"
    exit 0
fi

((EUID == 0)) || {
    echo "安装模式必须使用 root；请运行：sudo $0${wheelhouse:+ --wheelhouse $wheelhouse}" >&2
    exit 1
}

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends --no-upgrade \
    python3 python3-venv python3-pip python3-requests python3-cryptography ca-certificates

install -d -o root -g root -m 0755 "$install_root" "$state_dir"
temporary=$(mktemp -d "$install_root/.python.XXXXXXXX")
cleanup() {
    local status=$?
    trap - EXIT
    if [[ -n "$temporary" && "$temporary" == "$install_root"/.python.* && -d "$temporary" ]]; then
        rm -rf -- "$temporary"
    fi
    if ((status != 0 && transaction == 1)) && [[ -n "$backup" && -d "$backup" ]]; then
        [[ ! -e "$runtime_dir" ]] || rm -rf -- "$runtime_dir"
        mv -- "$backup" "$runtime_dir" || true
    fi
    exit "$status"
}
trap cleanup EXIT

python3 -m venv --system-site-packages "$temporary"
pip_args=(
    --disable-pip-version-check
    --no-deps
    --only-binary=:all:
    --require-hashes
    --requirement "$requirements"
)
if [[ -n "$wheelhouse" ]]; then
    pip_args=( --no-index --find-links "$wheelhouse" "${pip_args[@]}" )
fi
"$temporary/bin/python3" -m pip install "${pip_args[@]}"
verify_runtime "$temporary/bin/python3"

if [[ -e "$runtime_dir" || -L "$runtime_dir" ]]; then
    [[ -d "$runtime_dir" && ! -L "$runtime_dir" ]] || {
        echo "拒绝覆盖非普通目录: $runtime_dir" >&2
        exit 1
    }
    backup="$install_root/python.backup.$(date -u +%Y%m%dT%H%M%SZ).$$"
    mv -- "$runtime_dir" "$backup"
    transaction=1
fi
mv -- "$temporary" "$runtime_dir"
temporary=
chown -R root:root "$runtime_dir"
chmod 0755 "$runtime_dir"
chmod -R go-w "$runtime_dir"
verify_runtime "$runtime_dir/bin/python3"

state_tmp=$(mktemp "$state_dir/.g11-python-runtime.XXXXXXXX")
{
    echo 'schema=1'
    echo 'pypsrp=0.9.1'
    echo 'pyspnego=0.12.2'
    printf 'requirements_sha256=%s\n' "$requirements_sha"
    printf 'python=%s\n' "$runtime_dir/bin/python3"
} >"$state_tmp"
install -o root -g root -m 0644 "$state_tmp" "$state_file"
rm -f -- "$state_tmp"
transaction=0
if [[ -n "$backup" ]]; then
    echo "[g11-python] 旧环境备份: $backup"
fi
echo "[g11-python] PASS: pypsrp=0.9.1 pyspnego=0.12.2 runtime=$runtime_dir"
