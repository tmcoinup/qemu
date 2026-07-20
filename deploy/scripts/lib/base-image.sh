#!/usr/bin/env bash
# base 镜像元数据校验与同文件系统原子发布。
#
# 这里把 seal/clone 共同依赖的 qcow2 契约集中起来：
#   - 元数据必须能被 qemu-img 与 Python JSON 解析；
#   - 可克隆的 base 必须是无 backing/data file 的独立 qcow2；
#   - seal 的 root helper 通过 O_EXCL 发布独立 inode；普通事务 helper 使用
#     hard-link no-replace，二者都绝不覆盖已有目录项。

if [[ "${_BASE_IMAGE_LOADED:-0}" == "1" ]]; then
    # shellcheck disable=SC2317 # source guard 同时兼容直接执行语法检查。
    return 0 2>/dev/null || exit 0
fi
_BASE_IMAGE_LOADED=1

# 读取 qemu-img JSON，并把调用方需要的稳定字段写入 BASE_IMAGE_* 全局变量。
base_image_load_metadata() {
    local qemu_img="${1:-}" image="${2:-}"
    local metadata parsed

    [[ -n "$qemu_img" && -f "$image" &&
       ( ! -L "$image" || "$image" =~ ^/proc/[1-9][0-9]*/fd/[0-9]+$ ) ]] || {
        echo "ERROR: base 镜像路径不是普通文件: ${image:-empty}" >&2
        return 1
    }
    if ! metadata="$("$qemu_img" info --output=json "$image")"; then
        echo "ERROR: qemu-img 无法读取镜像元数据: $image" >&2
        return 1
    fi
    if ! parsed="$(
        python3 -c '
import json
import sys

info = json.load(sys.stdin)
image_format = info.get("format")
virtual_size = info.get("virtual-size")
has_backing = bool(
    info.get("backing-filename") or info.get("full-backing-filename")
)
format_data = info.get("format-specific", {}).get("data", {})
has_external_data = bool(format_data.get("data-file"))
if not isinstance(image_format, str):
    raise ValueError("missing image format")
if not isinstance(virtual_size, int) or virtual_size <= 0:
    raise ValueError("invalid virtual size")
print(
    f"{image_format}\t{virtual_size}\t"
    f"{int(has_backing)}\t{int(has_external_data)}"
)
' <<<"$metadata"
    )"; then
        echo "ERROR: qemu-img JSON 缺少有效的 format/virtual-size: $image" >&2
        return 1
    fi

    # shellcheck disable=SC2034 # BASE_IMAGE_* 字段由 source 本库的入口脚本读取。
    IFS=$'\t' read -r \
        BASE_IMAGE_FORMAT BASE_IMAGE_VIRTUAL_SIZE BASE_IMAGE_HAS_BACKING \
        BASE_IMAGE_HAS_EXTERNAL_DATA \
        <<<"$parsed"
    [[ "$BASE_IMAGE_HAS_BACKING" == 0 || "$BASE_IMAGE_HAS_BACKING" == 1 ]] || {
        echo "ERROR: base 镜像 backing 元数据非法: $image" >&2
        return 1
    }
    [[ "$BASE_IMAGE_HAS_EXTERNAL_DATA" == 0 ||
       "$BASE_IMAGE_HAS_EXTERNAL_DATA" == 1 ]] || {
        echo "ERROR: base 镜像 external data 元数据非法: $image" >&2
        return 1
    }
}

# clone 的 base 必须能独立长期保存；链式 base 会把上游镜像变成隐式生命周期依赖。
base_image_require_standalone_qcow2() {
    local qemu_img="${1:-}" image="${2:-}"

    base_image_load_metadata "$qemu_img" "$image" || return 1
    if [[ "$BASE_IMAGE_FORMAT" != qcow2 ]]; then
        echo "ERROR: base 必须是 qcow2，实际格式为 $BASE_IMAGE_FORMAT: $image" >&2
        return 1
    fi
    if [[ "$BASE_IMAGE_HAS_BACKING" != 0 ]]; then
        echo "ERROR: base 仍依赖 backing file，不是独立密封镜像: $image" >&2
        return 1
    fi
    if [[ "$BASE_IMAGE_HAS_EXTERNAL_DATA" != 0 ]]; then
        echo "ERROR: base 仍依赖 external data file，不是独立密封镜像: $image" >&2
        return 1
    fi
    if ! "$qemu_img" check -q "$image"; then
        echo "ERROR: base 未通过 qemu-img check: $image" >&2
        return 1
    fi
}

# 快速验证运行期 backing：seal 后的 base inode 必须归 root 且严格为 0444，
# 普通 VM 用户只能读取，不能通过任一 hard-link 改写内容。这里只读取 stat 与
# qcow2 header，不执行全盘 hash/check，适合每次 start 调用。
base_image_require_trusted_backing_qcow2_fast() {
    local qemu_img="${1:-}" image="${2:-}" expected_size="${3:-}"
    local allow_legacy="${4:-0}" owner mode

    [[ -n "$qemu_img" && -f "$image" && ! -L "$image" &&
       "$expected_size" =~ ^[0-9]+$ &&
       ( "$allow_legacy" == 0 || "$allow_legacy" == 1 ) ]] || {
        echo "ERROR: backing 路径或容量参数非法: ${image:-empty}" >&2
        return 1
    }
    owner="$(stat -c '%u' -- "$image")"
    mode="$(stat -c '%a' -- "$image")"
    if [[ "$owner" == 0 && "$mode" == 444 ]]; then
        :
    elif [[ "$allow_legacy" == 1 ]] &&
         (( (8#$mode & 8#222) == 0 )) && [[ ! -w "$image" ]]; then
        echo "WARN: 使用普通用户所有的 legacy 只读 backing: $image" >&2
        echo "      新 clone 会自动使用 root-owned 实例 pin；旧实例可继续启动。" >&2
    else
        echo "ERROR: backing 必须是 root-owned 0444 密封镜像: $image" >&2
        echo "       actual owner=$owner mode=$mode；请重新运行 seal-base.sh。" >&2
        return 1
    fi
    [[ -r "$image" ]] || {
        echo "ERROR: 当前 VM 用户无法读取 backing: $image" >&2
        return 1
    }
    [[ ! -w "$image" ]] || {
        echo "ERROR: 当前 VM 用户仍可写 backing（含 ACL 授权）: $image" >&2
        return 1
    }

    base_image_load_metadata "$qemu_img" "$image" || return 1
    if [[ "$BASE_IMAGE_FORMAT" != qcow2 ||
          "$BASE_IMAGE_HAS_BACKING" != 0 ||
          "$BASE_IMAGE_HAS_EXTERNAL_DATA" != 0 ||
          "$BASE_IMAGE_VIRTUAL_SIZE" != "$expected_size" ]]; then
        echo "ERROR: backing 不是同容量的独立 qcow2: $image" >&2
        return 1
    fi
}

# 验证 clone overlay 的格式、容量和 backing 解析结果。调用方传入 canonical base，
# 这里允许 overlay 记录相对路径，但解析后的完整路径必须仍是同一个 base。
base_image_require_overlay_qcow2() {
    local qemu_img="${1:-}" image="${2:-}"
    local expected_base="${3:-}" expected_size="${4:-}"
    local metadata

    [[ -n "$qemu_img" && -f "$image" && ! -L "$image" &&
       -f "$expected_base" && ! -L "$expected_base" &&
       "$expected_size" =~ ^[0-9]+$ ]] || {
        echo "ERROR: clone overlay 校验参数非法" >&2
        return 1
    }
    if ! metadata="$("$qemu_img" info --output=json "$image")"; then
        echo "ERROR: qemu-img 无法读取 clone overlay: $image" >&2
        return 1
    fi
    if ! python3 -c '
import json
import os
import sys

image, expected_base, expected_size_raw = sys.argv[1:]
info = json.load(sys.stdin)
expected_size = int(expected_size_raw)
format_data = info.get("format-specific", {}).get("data", {})
backing = info.get("full-backing-filename") or info.get("backing-filename")
backing_format = info.get("backing-filename-format")
if info.get("format") != "qcow2":
    raise ValueError("overlay format is not qcow2")
if info.get("virtual-size") != expected_size:
    raise ValueError("overlay virtual size does not match base")
if not isinstance(backing, str) or not backing:
    raise ValueError("overlay does not have a backing file")
if backing_format != "qcow2":
    raise ValueError("overlay backing format is not qcow2")
if format_data.get("data-file"):
    raise ValueError("overlay unexpectedly uses an external data file")
if not os.path.isabs(backing):
    backing = os.path.join(os.path.dirname(image), backing)
if os.path.realpath(backing) != os.path.realpath(expected_base):
    raise ValueError("overlay backing file does not resolve to expected base")
    ' "$image" "$expected_base" "$expected_size" <<<"$metadata"
    then
        echo "ERROR: clone overlay 格式、容量或 backing 契约不匹配: $image" >&2
        return 1
    fi
    if ! "$qemu_img" check -q "$image"; then
        echo "ERROR: clone overlay 未通过 qemu-img check: $image" >&2
        return 1
    fi
}

# 临时文件与目标必须位于同一文件系统。link(2) 自带 no-replace 语义，目标为普通
# 文件或 dangling symlink 时都会失败；成功后两条目录项指向同一完整 inode。
base_image_publish_no_replace() {
    local temporary="${1:-}" target="${2:-}"

    [[ -f "$temporary" && ! -L "$temporary" ]] || {
        echo "ERROR: 待发布 base 临时文件非法: ${temporary:-empty}" >&2
        return 1
    }
    if [[ -e "$target" || -L "$target" ]]; then
        echo "ERROR: base 目标已存在，拒绝覆盖: $target" >&2
        return 1
    fi
    if ! ln -T -- "$temporary" "$target"; then
        echo "ERROR: 无法原子发布 base（目标可能被并发创建）: $target" >&2
        return 1
    fi
    [[ "$temporary" -ef "$target" ]] || {
        echo "ERROR: base 发布后的 inode 校验失败: $target" >&2
        base_image_remove_published_file "$temporary" "$target"
        return 1
    }
}

# 仅当目标仍指向本次 staging inode 时回滚，避免删除并发替换后的未知文件。
base_image_remove_published_file() {
    local temporary="${1:-}" target="${2:-}"

    if [[ -n "$temporary" && -n "$target" &&
          -f "$temporary" && ! -L "$temporary" &&
          -f "$target" && ! -L "$target" &&
          "$temporary" -ef "$target" ]]; then
        rm -- "$target"
    fi
}

# 按发布 helper 返回的完整 fingerprint 删除失败事务目标。目标路径若被并发替换，
# fingerprint 必然不同，因此不会误删未知目录项。
base_image_remove_published_fingerprint() {
    local fingerprint_tool="${1:-}" expected="${2:-}" target="${3:-}"
    local actual

    [[ -n "$fingerprint_tool" && -n "$expected" && -n "$target" ]] || return 0
    if actual="$(python3 "$fingerprint_tool" fingerprint "$target" 2>/dev/null)" &&
       [[ "$actual" == "$expected" ]]; then
        rm -- "$target"
    fi
}
