#!/usr/bin/env bash
# Resolve the managed G-11 Python runtime without changing global Python.

G11_PYTHON_RUNTIME_BIN=${G11_PYTHON_RUNTIME_BIN:-/opt/g11/python/bin/python3}
G11_PYTHON_RUNTIME_INSTALLER=${G11_PYTHON_RUNTIME_INSTALLER:-}

g11_python_has_module() {
    local python_bin=$1 module=$2
    [[ -x "$python_bin" ]] || return 1
    "$python_bin" -c "import ${module}" >/dev/null 2>&1
}

g11_python_resolve() {
    local module=${1:-pypsrp} fallback

    if g11_python_has_module "$G11_PYTHON_RUNTIME_BIN" "$module"; then
        printf '%s\n' "$G11_PYTHON_RUNTIME_BIN"
        return 0
    fi
    fallback=$(command -v python3 2>/dev/null || true)
    if [[ -n "$fallback" ]] && g11_python_has_module "$fallback" "$module"; then
        printf '%s\n' "$fallback"
        return 0
    fi
    if [[ -n "$G11_PYTHON_RUNTIME_INSTALLER" ]]; then
        printf '缺少 G-11 Python/%s 运行环境；请执行：sudo %q\n' \
            "$module" "$G11_PYTHON_RUNTIME_INSTALLER" >&2
    else
        printf '缺少 G-11 Python/%s 运行环境；请执行 deploy/host/install-g11-python-runtime.sh\n' \
            "$module" >&2
    fi
    return 1
}
