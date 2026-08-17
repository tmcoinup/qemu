#!/usr/bin/env bash
# shellcheck shell=bash
#
# Read-only uniqueness checks for identities persisted in G-11 vm.conf files.
#
# This library is deliberately independent and side-effect free at source
# time.  Its scan functions never source or eval a configuration file, never
# follow an instance/configuration symlink, and never write below VM_ROOT.
# The side-effect-free hardware serial helper is loaded only so legacy
# MEM_SN+MEM_SLOTS bundles and new MEM_SERIAL_LIST bundles use exactly the same
# per-slot derivation as start-vm.
#
# Public API:
#
#   g11_identity_candidate_is_unique KEY VALUE [IGNORE_VM_ID [ROOT]]
#   g11_identity_uniqueness_check KEY VALUE [IGNORE_VM_ID [ROOT]]
#
#       Return 0 when VALUE is unused, 1 when it conflicts, and 2 when an
#       argument, root, or vm.conf is malformed.  ROOT defaults to VM_ROOT,
#       then /home/ubuntu/images/vms.  IGNORE_VM_ID skips that numeric bundle
#       before opening vm.conf, which permits an atomic --force replacement.
#
#   g11_identity_candidates_are_unique IGNORE_VM_ID ROOT KEY VALUE [...]
#
#       Scan once for several candidate pairs.  This also rejects duplicate
#       candidate values in the shared SYS_SN/MB_SN/CHASSIS_SN namespace.
#
# Supported keys are VM_UUID, VM_MAC, SYS_SN, MB_SN, CHASSIS_SN, MEM_SN,
# MEM_SERIAL_LIST, SSD_SN, and MONITOR_SERIAL.  MEM_SN and every comma-delimited
# MEM_SERIAL_LIST member share one MEMORY_SERIAL namespace.  UUID and MAC
# comparisons are ASCII case-insensitive.  Other serials are byte-for-byte.
#
# After each call, the following non-exported diagnostics are available:
#
#   G11_IDENTITY_UNIQUENESS_RESULT       unique | conflict | invalid
#   G11_IDENTITY_UNIQUENESS_MESSAGE
#   G11_IDENTITY_CONFLICT_VM_ID
#   G11_IDENTITY_CONFLICT_CANDIDATE_FIELD
#   G11_IDENTITY_CONFLICT_EXISTING_FIELD
#   G11_IDENTITY_CONFLICT_CONFIG

if ! declare -F g11_hardware_serial_memory_list_generate >/dev/null 2>&1; then
    _g11_identity_uniqueness_lib_dir=$(
        cd "$(dirname "${BASH_SOURCE[0]}")" && pwd
    )
    # shellcheck source=hardware-serials.sh
    source "$_g11_identity_uniqueness_lib_dir/hardware-serials.sh"
    unset _g11_identity_uniqueness_lib_dir
fi

_g11_identity_uniqueness_set_result() {
    G11_IDENTITY_UNIQUENESS_RESULT=${1:-invalid}
    G11_IDENTITY_UNIQUENESS_MESSAGE=${2:-}
    G11_IDENTITY_CONFLICT_VM_ID=${3:-}
    G11_IDENTITY_CONFLICT_CANDIDATE_FIELD=${4:-}
    G11_IDENTITY_CONFLICT_EXISTING_FIELD=${5:-}
    G11_IDENTITY_CONFLICT_CONFIG=${6:-}
}

_g11_identity_uniqueness_key_supported() {
    case ${1:-} in
        VM_UUID|VM_MAC|SYS_SN|MB_SN|CHASSIS_SN|MEM_SN|MEM_SERIAL_LIST|SSD_SN|MONITOR_SERIAL)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

_g11_identity_uniqueness_namespace() {
    case ${1:-} in
        SYS_SN|MB_SN|CHASSIS_SN)
            printf '%s\n' SYSTEM_SERIAL
            ;;
        MEM_SN|MEM_SERIAL_LIST)
            printf '%s\n' MEMORY_SERIAL
            ;;
        VM_UUID|VM_MAC|SSD_SN|MONITOR_SERIAL)
            printf '%s\n' "$1"
            ;;
        *)
            return 2
            ;;
    esac
}

_g11_identity_uniqueness_normalize() {
    local LC_ALL=C
    local key=${1:-} value=${2-}

    case $key in
        VM_UUID|VM_MAC)
            printf '%s\n' "${value^^}"
            ;;
        *)
            printf '%s\n' "$value"
            ;;
    esac
}

_g11_identity_uniqueness_file_has_nul() {
    local file=$1

    # Bash variables cannot represent NUL.  Detect it before read strips it,
    # otherwise `KEY=AB\0CD` could be mistaken for the printable value ABCD.
    LC_ALL=C od -An -v -t x1 -- "$file" 2>/dev/null |
        grep -Eq '(^|[[:space:]])00([[:space:]]|$)'
}

_g11_identity_uniqueness_parse_config() {
    local file=$1 output_name=$2
    local line line_no=0 key raw value
    local -n output=$output_name

    output=()
    if _g11_identity_uniqueness_file_has_nul "$file"; then
        _g11_identity_uniqueness_set_result invalid \
            "configuration contains a NUL byte" '' '' '' "$file"
        return 2
    fi

    while IFS= read -r line || [[ -n $line ]]; do
        ((line_no += 1))
        if [[ $line == *$'\r'* ]]; then
            _g11_identity_uniqueness_set_result invalid \
                "malformed configuration line $line_no: CR is not allowed" \
                '' '' '' "$file"
            return 2
        fi
        [[ $line =~ ^[[:space:]]*$ || $line =~ ^[[:space:]]*# ]] && continue

        if [[ ! $line =~ ^([A-Z][A-Z0-9_]*)=(.*)$ ]]; then
            _g11_identity_uniqueness_set_result invalid \
                "malformed configuration assignment at line $line_no" \
                '' '' '' "$file"
            return 2
        fi
        key=${BASH_REMATCH[1]}
        raw=${BASH_REMATCH[2]}

        if [[ -v "output[$key]" ]]; then
            _g11_identity_uniqueness_set_result invalid \
                "duplicate configuration key $key at line $line_no" \
                '' '' "$key" "$file"
            return 2
        fi

        if [[ ${raw:0:1} == '"' ]]; then
            if (( ${#raw} < 2 )) || [[ ${raw: -1} != '"' ]]; then
                _g11_identity_uniqueness_set_result invalid \
                    "unterminated quoted value for $key at line $line_no" \
                    '' '' "$key" "$file"
                return 2
            fi
            value=${raw:1:${#raw}-2}
            if [[ $value == *'"'* || $value == *$'\t'* ]]; then
                _g11_identity_uniqueness_set_result invalid \
                    "quoted value for $key has an unsupported quote or tab at line $line_no" \
                    '' '' "$key" "$file"
                return 2
            fi
        else
            if [[ $raw == *'"'* || $raw == *"'"* ||
                  $raw == *[[:space:]]* || $raw == *'#'* ]]; then
                _g11_identity_uniqueness_set_result invalid \
                    "unquoted value for $key is malformed at line $line_no" \
                    '' '' "$key" "$file"
                return 2
            fi
            value=$raw
        fi
        output["$key"]=$value
    done < "$file"
}

_g11_identity_uniqueness_validate_scope() {
    local ignore_vm_id=${1-} root=${2-}

    if [[ -n $ignore_vm_id &&
          ! $ignore_vm_id =~ ^[1-9][0-9]{0,9}$ ]]; then
        _g11_identity_uniqueness_set_result invalid \
            "IGNORE_VM_ID must be empty or a positive numeric VM id"
        return 2
    fi
    if [[ -z $root || $root != /* || $root == / || ! -d $root || -L $root ]]; then
        _g11_identity_uniqueness_set_result invalid \
            "VM_ROOT must be an existing absolute non-symlink directory"
        return 2
    fi
}

_g11_identity_memory_serial_list_split() {
    local serial_list=${1-} output_name=${2-}
    local serial rebuilt='' seen='|'
    local -n output=$output_name

    output=()
    [[ -n "$serial_list" && "$serial_list" != *$'\n'* &&
       "$serial_list" != *$'\r'* ]] || return 2
    IFS=',' read -r -a output <<<"$serial_list"
    ((${#output[@]} > 0)) || return 2
    for serial in "${output[@]}"; do
        g11_hardware_serial_memory_validate "$serial" || return 2
        [[ "$seen" != *"|$serial|"* ]] || return 2
        [[ -z "$rebuilt" ]] || rebuilt+=,
        rebuilt+=$serial
        seen+="$serial|"
    done
    [[ "$rebuilt" == "$serial_list" ]] || return 2
}

_g11_identity_memory_serials_from_config() {
    local parsed_name=$1 values_name=$2 labels_name=$3
    local config=$4 instance_id=$5
    local -n parsed_config=$parsed_name
    local -n output_values=$values_name
    local -n output_labels=$labels_name
    local base slot_count serial_list slot
    local -a members=()

    output_values=()
    output_labels=()
    if [[ -v 'parsed_config[MEM_SERIAL_LIST]' ]]; then
        serial_list=${parsed_config[MEM_SERIAL_LIST]}
        if ! _g11_identity_memory_serial_list_split "$serial_list" members; then
            _g11_identity_uniqueness_set_result invalid \
                "MEM_SERIAL_LIST is not a strict unique JEDEC serial list" \
                "$instance_id" '' MEM_SERIAL_LIST "$config"
            return 2
        fi
        if [[ ! -v 'parsed_config[MEM_SN]' ||
              ! -v 'parsed_config[MEM_SLOTS]' ]]; then
            _g11_identity_uniqueness_set_result invalid \
                "MEM_SERIAL_LIST requires MEM_SN and MEM_SLOTS" \
                "$instance_id" '' MEM_SERIAL_LIST "$config"
            return 2
        fi
        base=${parsed_config[MEM_SN]}
        slot_count=${parsed_config[MEM_SLOTS]}
        if ! g11_hardware_serial_memory_list_validate \
                "$base" "$slot_count" "$serial_list"; then
            _g11_identity_uniqueness_set_result invalid \
                "MEM_SERIAL_LIST does not match MEM_SN+MEM_SLOTS derivation" \
                "$instance_id" '' MEM_SERIAL_LIST "$config"
            return 2
        fi
        output_values=("${members[@]}")
        for ((slot = 1; slot <= ${#members[@]}; slot += 1)); do
            output_labels+=("MEM_SERIAL_LIST[$slot]")
        done
        return 0
    fi

    [[ -v 'parsed_config[MEM_SN]' ]] || return 0
    base=${parsed_config[MEM_SN]}
    [[ -n "$base" ]] || return 0
    if [[ ! -v 'parsed_config[MEM_SLOTS]' ]]; then
        output_values=("$base")
        output_labels=(MEM_SN)
        return 0
    fi
    # start-vm canonicalizes a legacy scalar before deciding whether it is a
    # valid JEDEC base or a seed that needs stable normalization.
    base=${base^^}
    slot_count=${parsed_config[MEM_SLOTS]}
    if [[ ! "$slot_count" =~ ^[1-9][0-9]*$ ]]; then
        _g11_identity_uniqueness_set_result invalid \
            "MEM_SLOTS is invalid for legacy per-slot serial derivation" \
            "$instance_id" '' MEM_SLOTS "$config"
        return 2
    fi
    if ! g11_hardware_serial_memory_validate "$base"; then
        base=$(g11_hardware_serial_memory_stable_from_seed "$base") || {
            _g11_identity_uniqueness_set_result invalid \
                "legacy MEM_SN cannot be normalized for per-slot derivation" \
                "$instance_id" '' MEM_SN "$config"
            return 2
        }
    fi
    serial_list=$(g11_hardware_serial_memory_list_generate \
        "$base" "$slot_count") || {
        _g11_identity_uniqueness_set_result invalid \
            "legacy MEM_SN+MEM_SLOTS per-slot derivation failed" \
            "$instance_id" '' MEM_SN "$config"
        return 2
    }
    _g11_identity_memory_serial_list_split "$serial_list" members || return 2
    output_values=("${members[@]}")
    for ((slot = 1; slot <= ${#members[@]}; slot += 1)); do
        output_labels+=("MEM_SN[$slot]")
    done
}

g11_identity_candidates_are_unique() {
    local ignore_vm_id=${1-} root=${2-}
    shift 2 || {
        _g11_identity_uniqueness_set_result invalid \
            "expected IGNORE_VM_ID ROOT and at least one KEY VALUE pair"
        return 2
    }
    local -a candidate_keys=() candidate_labels=() candidate_values=()
    local -a candidate_namespaces=() existing_fields=()
    local -a pending_values=() pending_labels=()
    local -a existing_memory_values=() existing_memory_labels=()
    local -A parsed=() seen_candidate_keys=()
    local key value namespace normalized previous_normalized
    local config instance_dir instance_id existing_field existing_value
    local index previous_index pending_index existing_index

    _g11_identity_uniqueness_set_result invalid ''
    _g11_identity_uniqueness_validate_scope "$ignore_vm_id" "$root" || return
    if (( $# == 0 || $# % 2 != 0 )); then
        _g11_identity_uniqueness_set_result invalid \
            "candidate arguments must be one or more KEY VALUE pairs"
        return 2
    fi

    while (( $# )); do
        key=$1
        value=$2
        shift 2
        if ! _g11_identity_uniqueness_key_supported "$key"; then
            _g11_identity_uniqueness_set_result invalid \
                "unsupported identity key: ${key:-<empty>}"
            return 2
        fi
        if [[ -v "seen_candidate_keys[$key]" ]]; then
            _g11_identity_uniqueness_set_result invalid \
                "duplicate candidate key: $key"
            return 2
        fi
        if [[ -z $value || $value == *$'\n'* || $value == *$'\r'* ]]; then
            _g11_identity_uniqueness_set_result invalid \
                "candidate $key must be a non-empty single-line value"
            return 2
        fi
        seen_candidate_keys["$key"]=1
        namespace=$(_g11_identity_uniqueness_namespace "$key") || return
        pending_values=("$value")
        pending_labels=("$key")
        if [[ "$key" == MEM_SERIAL_LIST ]]; then
            if ! _g11_identity_memory_serial_list_split \
                    "$value" pending_values; then
                _g11_identity_uniqueness_set_result invalid \
                    "candidate MEM_SERIAL_LIST must contain unique strict JEDEC serials"
                return 2
            fi
            pending_labels=()
            for ((pending_index = 1;
                  pending_index <= ${#pending_values[@]};
                  pending_index += 1)); do
                pending_labels+=("MEM_SERIAL_LIST[$pending_index]")
            done
        fi

        for ((pending_index = 0;
              pending_index < ${#pending_values[@]};
              pending_index += 1)); do
            value=${pending_values[$pending_index]}
            normalized=$(_g11_identity_uniqueness_normalize \
                "$key" "$value") || return
            for ((previous_index = 0;
                  previous_index < ${#candidate_keys[@]};
                  previous_index += 1)); do
                [[ ${candidate_namespaces[$previous_index]} == "$namespace" ]] \
                    || continue
                previous_normalized=$(_g11_identity_uniqueness_normalize \
                    "${candidate_keys[$previous_index]}" \
                    "${candidate_values[$previous_index]}") || return
                if [[ $normalized == "$previous_normalized" ]]; then
                    _g11_identity_uniqueness_set_result conflict \
                        "candidate ${pending_labels[$pending_index]} duplicates ${candidate_labels[$previous_index]}" \
                        "$ignore_vm_id" "${pending_labels[$pending_index]}" \
                        "${candidate_labels[$previous_index]}" ''
                    return 1
                fi
            done
            candidate_keys+=("$key")
            candidate_labels+=("${pending_labels[$pending_index]}")
            candidate_values+=("$value")
            candidate_namespaces+=("$namespace")
        done
    done

    for config in "$root"/*/vm.conf; do
        [[ -e $config || -L $config ]] || continue
        instance_dir=${config%/vm.conf}
        instance_id=${instance_dir##*/}
        if [[ ! $instance_id =~ ^[1-9][0-9]{0,9}$ ]]; then
            _g11_identity_uniqueness_set_result invalid \
                "vm.conf is below a non-numeric instance directory" \
                "$instance_id" '' '' "$config"
            return 2
        fi
        [[ $instance_id == "$ignore_vm_id" ]] && continue
        if [[ ! -d $instance_dir || -L $instance_dir ||
              ! -f $config || -L $config || ! -r $config ]]; then
            _g11_identity_uniqueness_set_result invalid \
                "instance or vm.conf is not a readable regular non-symlink" \
                "$instance_id" '' '' "$config"
            return 2
        fi
        _g11_identity_uniqueness_parse_config "$config" parsed || return
        if [[ -v 'parsed[VM_ID]' && ${parsed[VM_ID]} != "$instance_id" ]]; then
            _g11_identity_uniqueness_set_result invalid \
                "VM_ID does not match its instance directory" \
                "$instance_id" '' VM_ID "$config"
            return 2
        fi
        _g11_identity_memory_serials_from_config parsed \
            existing_memory_values existing_memory_labels \
            "$config" "$instance_id" || return

        for ((index = 0; index < ${#candidate_keys[@]}; index += 1)); do
            key=${candidate_keys[$index]}
            value=${candidate_values[$index]}
            namespace=${candidate_namespaces[$index]}
            case $namespace in
                SYSTEM_SERIAL)
                    existing_fields=(SYS_SN MB_SN CHASSIS_SN)
                    ;;
                MEMORY_SERIAL)
                    normalized=$(_g11_identity_uniqueness_normalize \
                        "$key" "$value") || return
                    for ((existing_index = 0;
                          existing_index < ${#existing_memory_values[@]};
                          existing_index += 1)); do
                        existing_value=$(_g11_identity_uniqueness_normalize \
                            MEM_SN \
                            "${existing_memory_values[$existing_index]}") \
                            || return
                        if [[ $normalized == "$existing_value" ]]; then
                            _g11_identity_uniqueness_set_result conflict \
                                "${candidate_labels[$index]} is already used by VM $instance_id field ${existing_memory_labels[$existing_index]}" \
                                "$instance_id" "${candidate_labels[$index]}" \
                                "${existing_memory_labels[$existing_index]}" \
                                "$config"
                            return 1
                        fi
                    done
                    continue
                    ;;
                *)
                    existing_fields=("$key")
                    ;;
            esac
            normalized=$(_g11_identity_uniqueness_normalize "$key" "$value") || return
            for existing_field in "${existing_fields[@]}"; do
                [[ -v "parsed[$existing_field]" ]] || continue
                existing_value=${parsed[$existing_field]}
                [[ -n $existing_value ]] || continue
                existing_value=$(_g11_identity_uniqueness_normalize \
                    "$existing_field" "$existing_value") || return
                if [[ $normalized == "$existing_value" ]]; then
                    _g11_identity_uniqueness_set_result conflict \
                        "$key is already used by VM $instance_id field $existing_field" \
                        "$instance_id" "${candidate_labels[$index]}" \
                        "$existing_field" "$config"
                    return 1
                fi
            done
        done
    done

    _g11_identity_uniqueness_set_result unique "candidate identities are unused"
    return 0
}

g11_identity_candidate_is_unique() {
    local key=${1-} value=${2-} ignore_vm_id=${3-}
    local root=${4:-${VM_ROOT:-/home/ubuntu/images/vms}}

    if (( $# < 2 || $# > 4 )); then
        _g11_identity_uniqueness_set_result invalid \
            "expected KEY VALUE [IGNORE_VM_ID [ROOT]]"
        return 2
    fi
    g11_identity_candidates_are_unique \
        "$ignore_vm_id" "$root" "$key" "$value"
}

# Short compatibility spelling for callers that treat this as a predicate.
g11_identity_uniqueness_check() {
    g11_identity_candidate_is_unique "$@"
}
