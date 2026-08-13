#!/usr/bin/env bash
# setup-host-helpers 的 QEMU 多信任记录读写层；调用者负责安装锁与目录安全。

# shellcheck source=../qemu-trust-manifest.sh
source "$HERE/qemu-trust-manifest.sh"

check_qemu_trust_manifest() {
    local manifest="${1:-$QEMU_TRUST_DEST}" expected="${2:-}" canonical

    qemu_trust_manifest_load_checked "$manifest" "$OWNER_UID" "$OWNER_GID" 644 \
        || { echo "ERROR: $QEMU_TRUST_ERROR" >&2; return 1; }
    qemu_trust_manifest_has_live_record || {
        echo "ERROR: QEMU 信任清单没有仍有效的可执行文件" >&2
        return 1
    }
    [[ -n "$expected" ]] || return 0
    canonical="$(realpath -e -- "$expected" 2>/dev/null)" || {
        echo "ERROR: 无法规范化待检查 QEMU: $expected" >&2
        return 1
    }
    qemu_trust_manifest_find_path "$canonical" &&
        qemu_trust_manifest_record_is_live "$QEMU_TRUST_MATCH_INDEX" || {
        echo "ERROR: 指定 QEMU 未以当前 device/inode/SHA-256 登记: $canonical" >&2
        return 1
    }
}

stage_qemu_trust_manifest() {
    local destination="$1"

    qemu_trust_manifest_prepare_upsert "$QEMU_TRUST_DEST" \
        "$OWNER_UID" "$OWNER_GID" "$QEMU_SOURCE" "$QEMU_SHA256" \
        "$QEMU_DEVICE" "$QEMU_INODE" || {
        echo "ERROR: 无法合并 QEMU 信任清单: $QEMU_TRUST_ERROR" >&2
        return 1
    }
    qemu_trust_manifest_render > "$destination"
    chown "$OWNER_UID:$OWNER_GID" "$destination" 2>/dev/null || true
    chmod 0644 "$destination"
}

unregister_qemu_trust_path() {
    local requested="$1" remaining

    qemu_trust_path_is_canonical "$requested" || {
        echo "ERROR: unregister 的 --qemu 必须是词法 canonical 绝对路径" >&2
        return 2
    }
    acquire_cpu_runtime_lock
    if ! refuse_active_legacy_cpu_isolation || ! refuse_inflight_cpu_helpers; then
        echo "ERROR: CPU 隔离仍活动，安全延后 QEMU 信任注销" >&2
        return "$HOST_HELPER_UPGRADE_DEFERRED"
    fi
    # 只在取得 CPU 锁后读取，避免注销器与 apply 各自沿用锁外旧快照。
    qemu_trust_manifest_load_checked "$QEMU_TRUST_DEST" \
        "$OWNER_UID" "$OWNER_GID" 644 || {
        echo "ERROR: 无法重新验证 QEMU 信任清单: $QEMU_TRUST_ERROR" >&2
        return 1
    }
    qemu_trust_manifest_remove_path "$requested"
    qemu_trust_manifest_write_atomic "$QEMU_TRUST_DEST" \
        "$OWNER_UID" "$OWNER_GID" 0644 || {
        echo "ERROR: 无法原子更新 QEMU 信任清单: $QEMU_TRUST_ERROR" >&2
        return 1
    }
    remaining="$(qemu_trust_manifest_count)"
    printf 'removed=%s remaining=%s\n' "$QEMU_TRUST_REMOVED" "$remaining"
}
