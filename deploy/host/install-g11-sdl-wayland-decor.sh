#!/usr/bin/env bash
# Install the userspace Cairo libdecor plugin used by G-11 SDL/Wayland titles.
# This does not install a kernel driver or change guest/host boot policy.
set -euo pipefail

package_name=libdecor-0-plugin-1-cairo

usage() {
    cat <<'EOF'
用法：
  ./deploy/host/install-g11-sdl-wayland-decor.sh
  ./deploy/host/install-g11-sdl-wayland-decor.sh --check
  ./deploy/host/install-g11-sdl-wayland-decor.sh --print

默认动作仅安装 Ubuntu/Debian 的 userspace Cairo libdecor 插件。脚本不会改 BCD、
不会开启 testsigning/nointegritychecks，也不会安装任何内核驱动。
EOF
}

find_cairo_plugin() {
    local candidate multiarch=""

    if command -v dpkg-architecture >/dev/null 2>&1; then
        multiarch=$(dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null || true)
    fi
    for candidate in \
            "${multiarch:+/usr/lib/$multiarch/libdecor/plugins-1/libdecor-cairo.so}" \
            /usr/lib/libdecor/plugins-1/libdecor-cairo.so \
            /usr/lib64/libdecor/plugins-1/libdecor-cairo.so; do
        [[ -n "$candidate" && -f "$candidate" ]] || continue
        printf '%s\n' "$candidate"
        return 0
    done
    while IFS= read -r candidate; do
        [[ -f "$candidate" ]] || continue
        printf '%s\n' "$candidate"
        return 0
    done < <(find /usr/lib /usr/lib64 -maxdepth 6 -type f \
        -path '*/libdecor/plugins-1/libdecor-cairo.so' -print 2>/dev/null)
    return 1
}

run_root() {
    if ((EUID == 0)); then
        "$@"
    else
        command -v sudo >/dev/null 2>&1 || {
            echo "安装需要 root，且系统没有 sudo" >&2
            return 1
        }
        sudo "$@"
    fi
}

case "${1:-}" in
    '') ;;
    --check)
        if plugin=$(find_cairo_plugin); then
            echo "G-11 SDL Wayland Cairo libdecor: ready ($plugin)"
            exit 0
        fi
        echo "G-11 SDL Wayland Cairo libdecor: missing" >&2
        exit 1
        ;;
    --print)
        echo "package=$package_name"
        echo "effect=userspace SDL/Wayland window decoration only"
        exit 0
        ;;
    -h|--help)
        usage
        exit 0
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac
[[ $# -le 1 ]] || {
    usage >&2
    exit 2
}

if plugin=$(find_cairo_plugin); then
    echo "G-11 SDL Wayland Cairo libdecor 已就绪: $plugin"
    exit 0
fi

command -v apt-get >/dev/null 2>&1 || {
    echo "当前封装仅支持 Ubuntu/Debian apt；请安装提供 libdecor-cairo.so 的 userspace 包" >&2
    exit 1
}

echo "安装 userspace 包 $package_name（不安装内核驱动）..."
if ! run_root env DEBIAN_FRONTEND=noninteractive \
        apt-get install -y "$package_name"; then
    echo "本地 apt 索引无法直接安装，刷新索引后重试..." >&2
    run_root apt-get update
    run_root env DEBIAN_FRONTEND=noninteractive \
        apt-get install -y "$package_name"
fi

plugin=$(find_cairo_plugin 2>/dev/null || true)
[[ -n "$plugin" ]] || {
    echo "$package_name 安装后仍未找到 libdecor-cairo.so" >&2
    exit 1
}
echo "安装完成: $plugin"
echo "以后用 start-vm.sh/g11-sdl-performance.sh 启动 SDL；封装会仅为该 QEMU 进程选择 Cairo 插件。"
