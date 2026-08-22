#!/usr/bin/env bash
# Exercise the reversible Mutter workaround without touching /etc/environment
# or the live GNOME session.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../../.." && pwd)"
helper="$repo_root/deploy/host/g11-mutter-kms-thread.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

[[ -x "$helper" ]] || fail "Mutter workaround helper is missing or not executable"
bash -n "$helper" || fail "Mutter workaround helper has invalid shell syntax"

tmp_dir=$(mktemp -d /tmp/g11-mutter-kms-test.XXXXXX)
trap 'rm -rf -- "$tmp_dir"' EXIT
env_file="$tmp_dir/environment"
original_file="$tmp_dir/environment.original"
fake_proc="$tmp_dir/proc"

run_helper() {
    env G11_MUTTER_TEST_MODE=1 \
        G11_MUTTER_ENV_FILE="$env_file" \
        G11_MUTTER_PROC_ROOT="$fake_proc" \
        "$helper" "$@"
}

assert_json_fields() {
    local payload=$1
    shift
    if ! python3 -c '
import json
import sys

data = json.load(sys.stdin)
expected_keys = {
    "schema", "config", "session_type", "session_mode", "kms_thread",
    "recommendation", "managed", "relogin_required",
}
assert set(data) == expected_keys, (set(data), expected_keys)
assert data["schema"] == 1
assert data["config"] in {"absent", "managed-user", "unmanaged", "invalid"}
assert data["session_type"] in {"wayland", "x11", "unknown", "absent"}
assert data["session_mode"] in {
    "user", "kernel", "unset", "other", "absent", "unknown",
}
assert data["kms_thread"] in {"realtime", "normal", "absent", "unknown"}
assert data["recommendation"] in {
    "ready", "enable", "relogin", "not-applicable", "conflict", "unknown",
}
assert isinstance(data["managed"], bool)
assert isinstance(data["relogin_required"], bool)
for item in sys.argv[1:]:
    key, expected = item.split("=", 1)
    if expected == "true":
        expected = True
    elif expected == "false":
        expected = False
    elif expected == "null":
        expected = None
    elif expected.isdecimal():
        expected = int(expected)
    assert data[key] == expected, (key, data[key], expected)
' "$@" <<<"$payload"; then
        fail "machine-readable status did not match: $*"
    fi
}

write_fake_task_stat() {
    local path=$1 policy=$2 rt_priority=$3 field
    local -a fields=()

    # /proc/PID/task/TID/stat fields after the closing comm parenthesis start
    # at field 3.  Fields 40/41 carry rt_priority/policy.
    for ((field = 3; field <= 41; field++)); do
        fields+=(0)
    done
    fields[0]=S
    fields[37]=$rt_priority
    fields[38]=$policy
    printf '4243 (KMS thread) %s\n' "${fields[*]}" >"$path"
}

printf 'LANG=en_US.UTF-8\nSAFE_SETTING=kept\n' >"$env_file"
cp -- "$env_file" "$original_file"
chmod 0640 "$env_file"
before_owner=$(stat -c '%u:%g' "$env_file")

run_helper enable >/dev/null || fail "non-root test-mode enable failed"
[[ "$(grep -Fxc '# BEGIN G11 MANAGED MUTTER KMS THREAD' "$env_file")" == 1 ]] ||
    fail "managed BEGIN marker was not written exactly once"
[[ "$(grep -Fxc 'MUTTER_DEBUG_KMS_THREAD_TYPE=user' "$env_file")" == 1 ]] ||
    fail "official user KMS setting was not written exactly once"
[[ "$(grep -Fxc '# END G11 MANAGED MUTTER KMS THREAD' "$env_file")" == 1 ]] ||
    fail "managed END marker was not written exactly once"
[[ "$(stat -c '%a' "$env_file")" == 640 ]] ||
    fail "atomic enable did not preserve file mode"
[[ "$(stat -c '%u:%g' "$env_file")" == "$before_owner" ]] ||
    fail "atomic enable did not preserve owner/group"

# Enable is idempotent and must not append a second block.
run_helper enable >/dev/null || fail "idempotent enable failed"
[[ "$(grep -Fxc '# BEGIN G11 MANAGED MUTTER KMS THREAD' "$env_file")" == 1 ]] ||
    fail "idempotent enable duplicated the managed block"
status_out=$(run_helper status)
grep -Fq 'G11 workaround 已写入' <<<"$status_out" ||
    fail "status did not report the managed file state"

run_helper disable >/dev/null || fail "managed disable failed"
cmp -s "$original_file" "$env_file" ||
    fail "disable did not restore the original file content"
[[ "$(stat -c '%a' "$env_file")" == 640 ]] ||
    fail "atomic disable did not preserve file mode"
run_helper disable >/dev/null || fail "idempotent disable failed"

# An assignment without G11 markers belongs to the administrator.  Neither
# action may overwrite or delete it.
printf 'MUTTER_DEBUG_KMS_THREAD_TYPE=kernel\nSAFE_SETTING=kept\n' >"$env_file"
cp -- "$env_file" "$original_file"
if run_helper enable >/dev/null 2>&1; then
    fail "enable overwrote an unmanaged MUTTER_DEBUG_KMS_THREAD_TYPE"
fi
cmp -s "$original_file" "$env_file" ||
    fail "failed enable changed an unmanaged configuration"
if run_helper disable >/dev/null 2>&1; then
    fail "disable claimed ownership of an unmanaged assignment"
fi
cmp -s "$original_file" "$env_file" ||
    fail "failed disable changed an unmanaged configuration"

# A malformed or expanded marker block is never rewritten automatically.
printf '%s\n' \
    '# BEGIN G11 MANAGED MUTTER KMS THREAD' \
    'MUTTER_DEBUG_KMS_THREAD_TYPE=user' \
    'UNEXPECTED=value' \
    '# END G11 MANAGED MUTTER KMS THREAD' >"$env_file"
cp -- "$env_file" "$original_file"
if run_helper disable >/dev/null 2>&1; then
    fail "disable accepted an altered managed block"
fi
cmp -s "$original_file" "$env_file" ||
    fail "malformed block rejection changed the file"

# Test mode must never be usable against the production target, and a target
# symlink must be rejected before any write.
if env G11_MUTTER_TEST_MODE=1 G11_MUTTER_ENV_FILE=/etc/environment \
        "$helper" status >/dev/null 2>&1; then
    fail "test mode accepted /etc/environment"
fi
real_target="$tmp_dir/real-environment"
printf 'SAFE_SETTING=kept\n' >"$real_target"
rm -f -- "$env_file"
ln -s "$real_target" "$env_file"
if run_helper enable >/dev/null 2>&1; then
    fail "helper accepted a symlink target"
fi
[[ "$(<"$real_target")" == 'SAFE_SETTING=kept' ]] ||
    fail "symlink rejection changed the real target"
rm -f -- "$env_file"

# Status checks the running shell environment, not just /etc/environment.
# A fake proc tree keeps this deterministic and does not inspect/change the
# real desktop session.
printf '%s\n%s\n%s\n' \
    '# BEGIN G11 MANAGED MUTTER KMS THREAD' \
    'MUTTER_DEBUG_KMS_THREAD_TYPE=user' \
    '# END G11 MANAGED MUTTER KMS THREAD' >"$env_file"
mkdir -p "$fake_proc/4242/task/4242"
printf 'gnome-shell\n' >"$fake_proc/4242/comm"
printf 'gnome-shell\n' >"$fake_proc/4242/task/4242/comm"
printf 'XDG_SESSION_TYPE=wayland\0MUTTER_DEBUG_KMS_THREAD_TYPE=user\0' \
    >"$fake_proc/4242/environ"
status_out=$(env G11_MUTTER_TEST_MODE=1 \
    G11_MUTTER_ENV_FILE="$env_file" \
    G11_MUTTER_PROC_ROOT="$fake_proc" \
    G11_MUTTER_TEST_SHELL_PID=4242 \
    "$helper" status)
grep -Fq '环境=user（workaround 已在本会话生效）' <<<"$status_out" ||
    fail "status did not verify the live gnome-shell environment"
grep -Fq '当前未发现独立 KMS thread' <<<"$status_out" ||
    fail "status did not recognize the user-thread topology"
grep -Fq '不会自动注销' <<<"$status_out" ||
    fail "status omitted the no-auto-logout guarantee"
json_out=$(env G11_MUTTER_TEST_MODE=1 \
    G11_MUTTER_ENV_FILE="$env_file" \
    G11_MUTTER_PROC_ROOT="$fake_proc" \
    G11_MUTTER_TEST_SHELL_PID=4242 \
    "$helper" status --json)
assert_json_fields "$json_out" \
    config=managed-user session_type=wayland \
    session_mode=user kms_thread=absent recommendation=ready managed=true \
    relogin_required=false

# Immediately after a managed disable, the old Shell still carries user mode.
# The machine interface must ask for a new login instead of claiming that the
# rollback has already reached the running compositor.
printf 'SAFE_SETTING=kept\n' >"$env_file"
json_out=$(env G11_MUTTER_TEST_MODE=1 \
    G11_MUTTER_ENV_FILE="$env_file" \
    G11_MUTTER_PROC_ROOT="$fake_proc" \
    G11_MUTTER_TEST_SHELL_PID=4242 \
    "$helper" status --json)
assert_json_fields "$json_out" \
    config=absent session_mode=user kms_thread=absent \
    recommendation=relogin managed=false relogin_required=true
printf '%s\n%s\n%s\n' \
    '# BEGIN G11 MANAGED MUTTER KMS THREAD' \
    'MUTTER_DEBUG_KMS_THREAD_TYPE=user' \
    '# END G11 MANAGED MUTTER KMS THREAD' >"$env_file"

# The default/kernel fixture exposes the independent realtime KMS thread.
mkdir -p "$fake_proc/4242/task/4243"
printf 'KMS thread\n' >"$fake_proc/4242/task/4243/comm"
printf 'policy : 2\nrt_priority : 20\n' >"$fake_proc/4242/task/4243/sched"
printf 'XDG_SESSION_TYPE=wayland\0' >"$fake_proc/4242/environ"
status_out=$(env G11_MUTTER_TEST_MODE=1 \
    G11_MUTTER_ENV_FILE="$env_file" \
    G11_MUTTER_PROC_ROOT="$fake_proc" \
    G11_MUTTER_TEST_SHELL_PID=4242 \
    "$helper" status)
grep -Fq '环境未设置（默认 kernel 模式）' <<<"$status_out" ||
    fail "status did not recognize the default shell environment"
grep -Fq 'TID=4243' <<<"$status_out" ||
    fail "status did not report the independent KMS thread"
grep -Fq '当前会话尚未生效' <<<"$status_out" ||
    fail "status did not explain that a new login is required"

# Machine status reports only closed enums/booleans/numbers.  It must not leak
# arbitrary values from /etc/environment or the running Shell environment.
printf 'XDG_SESSION_TYPE=wayland\0TOP_SECRET=never-print-this\0' \
    >"$fake_proc/4242/environ"
printf 'SAFE_SETTING=never-print-this-either\n%s\n%s\n%s\n' \
    '# BEGIN G11 MANAGED MUTTER KMS THREAD' \
    'MUTTER_DEBUG_KMS_THREAD_TYPE=user' \
    '# END G11 MANAGED MUTTER KMS THREAD' >"$env_file"
json_out=$(env G11_MUTTER_TEST_MODE=1 \
    G11_MUTTER_ENV_FILE="$env_file" \
    G11_MUTTER_PROC_ROOT="$fake_proc" \
    G11_MUTTER_TEST_SHELL_PID=4242 \
    "$helper" status --json)
[[ "$json_out" != *never-print-this* ]] ||
    fail "JSON status leaked an environment value"
assert_json_fields "$json_out" \
    config=managed-user session_type=wayland \
    session_mode=unset kms_thread=realtime recommendation=relogin managed=true \
    relogin_required=true

# With no managed assignment, the same GNOME Wayland + realtime RR topology
# recommends enable.  There is deliberately no mouse fixture: polling rate is
# an amplifier, not a hard applicability gate.
printf 'SAFE_SETTING=kept\n' >"$env_file"
json_out=$(env G11_MUTTER_TEST_MODE=1 \
    G11_MUTTER_ENV_FILE="$env_file" \
    G11_MUTTER_PROC_ROOT="$fake_proc" \
    G11_MUTTER_TEST_SHELL_PID=4242 \
    "$helper" status --json)
assert_json_fields "$json_out" \
    config=absent session_type=wayland session_mode=unset \
    kms_thread=realtime \
    recommendation=enable managed=false relogin_required=false

# The real /proc stat format takes precedence over the compact sched fallback.
# This directly covers the production path used on the live host.
write_fake_task_stat "$fake_proc/4242/task/4243/stat" 2 15
printf 'policy : 0\nrt_priority : 0\n' >"$fake_proc/4242/task/4243/sched"
json_out=$(env G11_MUTTER_TEST_MODE=1 \
    G11_MUTTER_ENV_FILE="$env_file" \
    G11_MUTTER_PROC_ROOT="$fake_proc" \
    G11_MUTTER_TEST_SHELL_PID=4242 \
    "$helper" status --json)
assert_json_fields "$json_out" \
    kms_thread=realtime recommendation=enable
rm -f -- "$fake_proc/4242/task/4243/stat"

# FIFO with positive realtime priority is also affected.
printf 'policy : 1\nrt_priority : 7\n' >"$fake_proc/4242/task/4243/sched"
json_out=$(env G11_MUTTER_TEST_MODE=1 \
    G11_MUTTER_ENV_FILE="$env_file" \
    G11_MUTTER_PROC_ROOT="$fake_proc" \
    G11_MUTTER_TEST_SHELL_PID=4242 \
    "$helper" status --json)
assert_json_fields "$json_out" \
    kms_thread=realtime recommendation=enable

# GNOME Xorg is not applicable even if a fake realtime KMS thread exists.
printf 'XDG_SESSION_TYPE=x11\0' >"$fake_proc/4242/environ"
json_out=$(env G11_MUTTER_TEST_MODE=1 \
    G11_MUTTER_ENV_FILE="$env_file" \
    G11_MUTTER_PROC_ROOT="$fake_proc" \
    G11_MUTTER_TEST_SHELL_PID=4242 \
    "$helper" status --json)
assert_json_fields "$json_out" \
    session_type=x11 kms_thread=realtime recommendation=not-applicable

# A separate but non-realtime KMS thread is outside this workaround's narrow
# scheduler diagnosis and must not produce an enable recommendation.
printf 'XDG_SESSION_TYPE=wayland\0' >"$fake_proc/4242/environ"
printf 'policy : 0\nrt_priority : 0\n' >"$fake_proc/4242/task/4243/sched"
json_out=$(env G11_MUTTER_TEST_MODE=1 \
    G11_MUTTER_ENV_FILE="$env_file" \
    G11_MUTTER_PROC_ROOT="$fake_proc" \
    G11_MUTTER_TEST_SHELL_PID=4242 \
    "$helper" status --json)
assert_json_fields "$json_out" \
    session_type=wayland kms_thread=normal recommendation=not-applicable

# Unexpected session/mode values map to the one strict unknown/other contract;
# raw values are never reflected into JSON.
printf 'XDG_SESSION_TYPE=future-display\0MUTTER_DEBUG_KMS_THREAD_TYPE=future-mode\0' \
    >"$fake_proc/4242/environ"
printf 'policy : 2\nrt_priority : 20\n' >"$fake_proc/4242/task/4243/sched"
json_out=$(env G11_MUTTER_TEST_MODE=1 \
    G11_MUTTER_ENV_FILE="$env_file" \
    G11_MUTTER_PROC_ROOT="$fake_proc" \
    G11_MUTTER_TEST_SHELL_PID=4242 \
    "$helper" status --json)
[[ "$json_out" != *future-display* && "$json_out" != *future-mode* ]] ||
    fail "JSON status reflected an unexpected raw session value"
assert_json_fields "$json_out" \
    session_type=unknown session_mode=other recommendation=unknown

# A present GNOME Shell candidate with unreadable/missing key data is unknown.
mv -- "$fake_proc/4242/environ" "$fake_proc/4242/environ.saved"
json_out=$(env G11_MUTTER_TEST_MODE=1 \
    G11_MUTTER_ENV_FILE="$env_file" \
    G11_MUTTER_PROC_ROOT="$fake_proc" \
    G11_MUTTER_TEST_SHELL_PID=4242 \
    "$helper" status --json)
assert_json_fields "$json_out" \
    session_type=unknown session_mode=unknown recommendation=unknown
mv -- "$fake_proc/4242/environ.saved" "$fake_proc/4242/environ"

# A Shell candidate whose task directory cannot be inspected is unknown, not
# falsely "absent"/not-applicable.  This keeps restricted or racing /proc
# observations fail-closed.
mv -- "$fake_proc/4242/task" "$fake_proc/4242/task.saved"
json_out=$(env G11_MUTTER_TEST_MODE=1 \
    G11_MUTTER_ENV_FILE="$env_file" \
    G11_MUTTER_PROC_ROOT="$fake_proc" \
    G11_MUTTER_TEST_SHELL_PID=4242 \
    "$helper" status --json)
assert_json_fields "$json_out" \
    kms_thread=unknown recommendation=unknown
mv -- "$fake_proc/4242/task.saved" "$fake_proc/4242/task"

# Unknown scheduling fails closed, while a completely absent GNOME Shell is
# positively not applicable rather than unknown.
printf 'XDG_SESSION_TYPE=wayland\0' >"$fake_proc/4242/environ"
: >"$fake_proc/4242/task/4243/sched"
json_out=$(env G11_MUTTER_TEST_MODE=1 \
    G11_MUTTER_ENV_FILE="$env_file" \
    G11_MUTTER_PROC_ROOT="$fake_proc" \
    G11_MUTTER_TEST_SHELL_PID=4242 \
    "$helper" status --json)
assert_json_fields "$json_out" \
    kms_thread=unknown recommendation=unknown
json_out=$(env G11_MUTTER_TEST_MODE=1 \
    G11_MUTTER_ENV_FILE="$env_file" \
    G11_MUTTER_PROC_ROOT="$fake_proc" \
    G11_MUTTER_TEST_SHELL_PID=9999 \
    "$helper" status --json)
assert_json_fields "$json_out" \
    session_type=absent session_mode=absent \
    kms_thread=absent recommendation=not-applicable

# Unmanaged assignments and malformed managed blocks are explicit conflicts;
# the JSON probe remains successful so callers can consume the diagnosis.
printf 'MUTTER_DEBUG_KMS_THREAD_TYPE=kernel\n' >"$env_file"
json_out=$(env G11_MUTTER_TEST_MODE=1 \
    G11_MUTTER_ENV_FILE="$env_file" \
    G11_MUTTER_PROC_ROOT="$fake_proc" \
    G11_MUTTER_TEST_SHELL_PID=4242 \
    "$helper" status --json)
assert_json_fields "$json_out" \
    config=unmanaged managed=false recommendation=conflict
json_out=$(env G11_MUTTER_TEST_MODE=1 \
    G11_MUTTER_ENV_FILE="$env_file" \
    G11_MUTTER_PROC_ROOT="$fake_proc" \
    G11_MUTTER_TEST_SHELL_PID=9999 \
    "$helper" status --json)
assert_json_fields "$json_out" \
    config=unmanaged session_type=absent session_mode=absent \
    kms_thread=absent recommendation=conflict
printf '%s\n%s\n%s\n%s\n' \
    '# BEGIN G11 MANAGED MUTTER KMS THREAD' \
    'MUTTER_DEBUG_KMS_THREAD_TYPE=user' \
    'UNEXPECTED=value' \
    '# END G11 MANAGED MUTTER KMS THREAD' >"$env_file"
json_out=$(env G11_MUTTER_TEST_MODE=1 \
    G11_MUTTER_ENV_FILE="$env_file" \
    G11_MUTTER_PROC_ROOT="$fake_proc" \
    G11_MUTTER_TEST_SHELL_PID=4242 \
    "$helper" status --json)
assert_json_fields "$json_out" \
    config=invalid managed=false recommendation=conflict

# --json belongs only to status and extra arguments must be rejected before
# either mutating action can run.
cp -- "$env_file" "$original_file"
if run_helper enable --json >/dev/null 2>&1; then
    fail "enable accepted the status-only --json option"
fi
cmp -s "$original_file" "$env_file" ||
    fail "rejected enable --json changed the environment fixture"
if run_helper status --json extra >/dev/null 2>&1; then
    fail "status accepted extra machine-interface arguments"
fi

echo "OK: G-11 Mutter KMS thread workaround checks passed"
