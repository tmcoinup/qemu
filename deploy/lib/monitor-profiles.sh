#!/usr/bin/env bash
# shellcheck shell=bash

# Source this file, then use monitor_profile_load or
# monitor_profile_pick_random.  Functions accept an optional catalog path as
# their final argument; MONITOR_PROFILE_CATALOG overrides the default.

_monitor_profile_lib_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
MONITOR_PROFILE_CATALOG=${MONITOR_PROFILE_CATALOG:-"${_monitor_profile_lib_dir}/../config/monitor-profiles.tsv"}
MONITOR_CREATE_PROFILE_POOL=${MONITOR_CREATE_PROFILE_POOL:-"${_monitor_profile_lib_dir}/../config/monitor-create-cn-fhd.txt"}
MONITOR_REQUIRED_PREFERRED_X=1920
MONITOR_REQUIRED_PREFERRED_Y=1080
MONITOR_REQUIRED_PREFERRED_REFRESH_HZ=60

_monitor_profile_error() {
    printf 'monitor-profiles: %s\n' "$*" >&2
}

_monitor_profile_is_uint() {
    [[ $1 =~ ^(0|[1-9][0-9]*)$ ]]
}

# Serial formats are keyed by the real monitor identity rather than inferred
# from a coincidentally similar prefix.  Keep the catalog schema stable for
# the shell and PowerShell consumers; every loaded profile still exposes its
# explicit policy through MONITOR_SERIAL_POLICY.
monitor_profile_serial_policy_for_key() {
    case ${1:-} in
        samsung-s24f350) printf '%s\n' samsung-h4zmc-decimal5 ;;
        redmi-rmmnt238nf) printf '%s\n' redmi-29200-decimal8 ;;
        *) printf '%s\n' generic-prefix-hash ;;
    esac
}

# Source EDID captures document the serial format, but their exact observed
# values must never be copied into a synthetic VM identity.
monitor_profile_serial_is_reserved() {
    local serial=${1-}
    local policy=${2:-${MONITOR_SERIAL_POLICY:-generic-prefix-hash}}

    case $policy in
        samsung-h4zmc-decimal5)
            [[ $serial == H4ZMC01676 || $serial == H4ZMC01889 ]]
            ;;
        redmi-29200-decimal8)
            [[ $serial == 2920000167575 || $serial == 2920000116680 ]]
            ;;
        *) return 1 ;;
    esac
}

monitor_profiles_validate() {
    # Bash bracket ranges follow LC_COLLATE.  Under locales such as
    # en_US.UTF-8/zh_CN.UTF-8, the ASCII range `[ -~]` below does not match
    # otherwise-valid names such as S24F350.  Keep validation byte-oriented
    # without changing the caller's locale.
    local LC_ALL=C
    local catalog=${1:-$MONITOR_PROFILE_CATALOG}
    local line line_no=0 row_count=0 pipe_chars
    local key vendor product_id edid_name display_name manufacturer
    local width_mm height_mm native_x native_y refresh_hz
    local min_v max_v min_h max_h max_clock_mhz video_input
    local year week serial_prefix mode_set
    local numeric value pair diagonal_sq serial_policy
    local key_re='^[a-z0-9][a-z0-9-]{0,47}$'
    local product_re='^0x[0-9A-F]{4}$'
    local video_input_re='^0x[0-9A-F]{2}$'
    local printable_12_re='^[ -~]{1,12}$'
    local printable_64_re='^[ -~]{1,64}$'
    local serial_re='^[A-Z0-9]{1,8}$'
    local -A seen_keys=()
    local -A seen_products=()

    [[ -r $catalog ]] || {
        _monitor_profile_error "catalog is not readable: $catalog"
        return 1
    }

    while IFS= read -r line || [[ -n $line ]]; do
        ((line_no += 1))

        [[ $line != *$'\r'* ]] || {
            _monitor_profile_error "$catalog:$line_no: CR characters are not allowed"
            return 1
        }
        [[ -z $line || $line == \#* ]] && continue

        pipe_chars=${line//[^|]/}
        [[ ${#pipe_chars} -eq 20 ]] || {
            _monitor_profile_error "$catalog:$line_no: expected 21 pipe-separated fields"
            return 1
        }

        IFS='|' read -r key vendor product_id edid_name display_name manufacturer \
            width_mm height_mm native_x native_y refresh_hz min_v max_v min_h \
            max_h max_clock_mhz video_input year week serial_prefix mode_set <<< "$line"

        [[ $key =~ $key_re ]] || {
            _monitor_profile_error "$catalog:$line_no: invalid key '$key'"
            return 1
        }
        [[ -z ${seen_keys[$key]+x} ]] || {
            _monitor_profile_error "$catalog:$line_no: duplicate key '$key'"
            return 1
        }
        seen_keys[$key]=1

        [[ $vendor =~ ^[A-Z]{3}$ ]] || {
            _monitor_profile_error "$catalog:$line_no: invalid PNP vendor '$vendor'"
            return 1
        }
        [[ $product_id =~ $product_re ]] || {
            _monitor_profile_error "$catalog:$line_no: invalid product id '$product_id'"
            return 1
        }
        pair=${vendor}:${product_id}
        [[ -z ${seen_products[$pair]+x} ]] || {
            _monitor_profile_error "$catalog:$line_no: duplicate PNP product '$pair'"
            return 1
        }
        seen_products[$pair]=1

        [[ $edid_name =~ $printable_12_re && $edid_name != ' '* && $edid_name != *' ' ]] || {
            _monitor_profile_error "$catalog:$line_no: EDID name must be 1-12 printable ASCII characters without edge spaces"
            return 1
        }
        [[ $display_name =~ $printable_64_re && $display_name != ' '* && $display_name != *' ' ]] || {
            _monitor_profile_error "$catalog:$line_no: invalid display name"
            return 1
        }
        [[ $manufacturer =~ $printable_64_re && $manufacturer != ' '* && $manufacturer != *' ' ]] || {
            _monitor_profile_error "$catalog:$line_no: invalid manufacturer"
            return 1
        }
        [[ $display_name == "$manufacturer "* ]] || {
            _monitor_profile_error "$catalog:$line_no: display name must start with manufacturer '$manufacturer'"
            return 1
        }
        for value in "$edid_name" "$display_name" "$manufacturer"; do
            [[ $value != *'"'* && $value != *'$'* && $value != *'`'* && $value != *'\'* ]] || {
                _monitor_profile_error "$catalog:$line_no: monitor names contain shell-unsafe characters"
                return 1
            }
        done

        numeric=("$width_mm" "$height_mm" "$native_x" "$native_y" "$refresh_hz" \
            "$min_v" "$max_v" "$min_h" "$max_h" "$max_clock_mhz" "$year" "$week")
        for value in "${numeric[@]}"; do
            _monitor_profile_is_uint "$value" || {
                _monitor_profile_error "$catalog:$line_no: numeric fields must be unsigned decimal integers"
                return 1
            }
        done

        # Reviewed creation profiles cover the common 21.5, 23.8/24 and
        # 27-inch FHD desktop classes.  Keep TVs, portable panels and larger
        # FHD panels out, while retaining exact DTD millimetres from the
        # source EDID instead of rounding every model to a nominal size.
        ((width_mm >= 450 && width_mm <= 610 && height_mm >= 250 && height_mm <= 345)) || {
            _monitor_profile_error "$catalog:$line_no: physical dimensions are outside the supported desktop-monitor range"
            return 1
        }
        diagonal_sq=$((width_mm * width_mm + height_mm * height_mm))
        ((diagonal_sq >= 540 * 540 && diagonal_sq <= 690 * 690)) || {
            _monitor_profile_error "$catalog:$line_no: physical diagonal is outside 21.3-27.2 inches"
            return 1
        }
        ((native_x == MONITOR_REQUIRED_PREFERRED_X &&
          native_y == MONITOR_REQUIRED_PREFERRED_Y &&
          refresh_hz == MONITOR_REQUIRED_PREFERRED_REFRESH_HZ)) || {
            _monitor_profile_error "$catalog:$line_no: every full-catalog preferred timing must be 1920x1080@60"
            return 1
        }
        ((refresh_hz >= 50 && refresh_hz <= 240 && min_v <= refresh_hz && refresh_hz <= max_v && max_v <= 240)) || {
            _monitor_profile_error "$catalog:$line_no: invalid vertical refresh range"
            return 1
        }
        ((min_h >= 10 && min_h <= 300 && min_h <= max_h && max_h <= 300)) || {
            _monitor_profile_error "$catalog:$line_no: invalid horizontal frequency range"
            return 1
        }
        ((max_clock_mhz >= 149 && max_clock_mhz <= 1000)) || {
            _monitor_profile_error "$catalog:$line_no: max clock cannot carry the native timing"
            return 1
        }

        [[ $video_input =~ $video_input_re ]] || {
            _monitor_profile_error "$catalog:$line_no: video input must be the raw EDID byte 20 (0xNN)"
            return 1
        }
        ((year >= 1990 && year <= 2100 && week >= 1 && week <= 53)) || {
            _monitor_profile_error "$catalog:$line_no: invalid manufacture date"
            return 1
        }
        [[ $serial_prefix =~ $serial_re ]] || {
            _monitor_profile_error "$catalog:$line_no: serial prefix must be 1-8 uppercase alphanumeric characters"
            return 1
        }
        serial_policy=$(monitor_profile_serial_policy_for_key "$key") || return
        case $serial_policy in
            samsung-h4zmc-decimal5)
                [[ $serial_prefix == H4ZMC ]] || {
                    _monitor_profile_error "$catalog:$line_no: samsung-s24f350 serial prefix must be H4ZMC"
                    return 1
                }
                ;;
            redmi-29200-decimal8)
                [[ $serial_prefix == 29200 ]] || {
                    _monitor_profile_error "$catalog:$line_no: redmi-rmmnt238nf serial prefix must be 29200"
                    return 1
                }
                ;;
            generic-prefix-hash)
                [[ $serial_prefix != H4ZMC && $serial_prefix != 29200 ]] || {
                    _monitor_profile_error "$catalog:$line_no: special serial prefix '$serial_prefix' is reserved for its matching profile"
                    return 1
                }
                ;;
            *)
                _monitor_profile_error "$catalog:$line_no: unsupported serial policy '$serial_policy'"
                return 1
                ;;
        esac
        [[ $mode_set == fhd-standard ]] || {
            _monitor_profile_error "$catalog:$line_no: unsupported mode set '$mode_set'"
            return 1
        }

        ((row_count += 1))
    done < "$catalog"

    ((row_count > 0)) || {
        _monitor_profile_error "$catalog: catalog contains no profiles"
        return 1
    }
}

monitor_profile_keys() {
    local catalog=${1:-$MONITOR_PROFILE_CATALOG}
    local line

    monitor_profiles_validate "$catalog" || return
    while IFS= read -r line || [[ -n $line ]]; do
        [[ -z $line || $line == \#* ]] && continue
        printf '%s\n' "${line%%|*}"
    done < "$catalog"
}

# Validate the profile-key pool used only for creation of new VMs.  The full
# catalog remains loadable so existing VM identities keep working, while this
# pool is deliberately constrained to mainland-China-common FHD ("1K")
# desktop monitors.
monitor_create_pool_validate() {
    # The catalog keys and all range expressions are deliberately ASCII.
    local LC_ALL=C
    local pool=${1:-$MONITOR_CREATE_PROFILE_POOL}
    local catalog=${2:-$MONITOR_PROFILE_CATALOG}
    local line line_no=0 row_count=0
    local p_key p_vendor p_product_id p_edid_name p_display_name p_manufacturer
    local p_width_mm p_height_mm p_native_x p_native_y p_refresh_hz
    local p_min_v p_max_v p_min_h p_max_h p_max_clock_mhz p_video_input
    local p_year p_week p_serial_prefix p_mode_set
    local key_re='^[a-z0-9][a-z0-9-]{0,47}$'
    local -A catalog_preferred=()
    local -A seen=()

    monitor_profiles_validate "$catalog" || return
    [[ -r $pool ]] || {
        _monitor_profile_error "creation pool is not readable: $pool"
        return 1
    }

    while IFS='|' read -r p_key p_vendor p_product_id p_edid_name p_display_name \
        p_manufacturer p_width_mm p_height_mm p_native_x p_native_y p_refresh_hz \
        p_min_v p_max_v p_min_h p_max_h p_max_clock_mhz p_video_input p_year \
        p_week p_serial_prefix p_mode_set; do
        [[ -z $p_key || $p_key == \#* ]] && continue
        catalog_preferred[$p_key]="${p_native_x}x${p_native_y}@${p_refresh_hz}|${p_mode_set}"
    done < "$catalog"

    while IFS= read -r line || [[ -n $line ]]; do
        ((line_no += 1))
        [[ $line != *$'\r'* ]] || {
            _monitor_profile_error "$pool:$line_no: CR characters are not allowed"
            return 1
        }
        [[ -z $line || $line == \#* ]] && continue
        [[ $line =~ $key_re ]] || {
            _monitor_profile_error "$pool:$line_no: invalid profile key '$line'"
            return 1
        }
        [[ -z ${seen[$line]+x} ]] || {
            _monitor_profile_error "$pool:$line_no: duplicate profile '$line'"
            return 1
        }
        seen[$line]=1
        [[ -n ${catalog_preferred[$line]+x} ]] || {
            _monitor_profile_error "$pool:$line_no: unknown catalog profile '$line'"
            return 1
        }
        [[ ${catalog_preferred[$line]} == \
           "${MONITOR_REQUIRED_PREFERRED_X}x${MONITOR_REQUIRED_PREFERRED_Y}@${MONITOR_REQUIRED_PREFERRED_REFRESH_HZ}|fhd-standard" ]] || {
            _monitor_profile_error "$pool:$line_no: creation profiles must have preferred timing 1920x1080@60"
            return 1
        }
        ((row_count += 1))
    done < "$pool"

    ((row_count > 0)) || {
        _monitor_profile_error "$pool: creation pool contains no profiles"
        return 1
    }
}

monitor_create_pool_keys() {
    local pool=${1:-$MONITOR_CREATE_PROFILE_POOL}
    local catalog=${2:-$MONITOR_PROFILE_CATALOG}
    local line

    monitor_create_pool_validate "$pool" "$catalog" || return
    while IFS= read -r line || [[ -n $line ]]; do
        [[ -z $line || $line == \#* ]] && continue
        printf '%s\n' "$line"
    done < "$pool"
}

monitor_create_pool_contains() {
    local requested=${1:-}
    local pool=${2:-$MONITOR_CREATE_PROFILE_POOL}
    local catalog=${3:-$MONITOR_PROFILE_CATALOG}
    local key

    [[ -n $requested ]] || return 1
    monitor_create_pool_validate "$pool" "$catalog" || return
    while IFS= read -r key || [[ -n $key ]]; do
        [[ -z $key || $key == \#* ]] && continue
        [[ $key == "$requested" ]] && return 0
    done < "$pool"
    return 1
}

monitor_create_pool_print_catalog() {
    local pool=${1:-$MONITOR_CREATE_PROFILE_POOL}
    local catalog=${2:-$MONITOR_PROFILE_CATALOG}
    local key

    monitor_create_pool_validate "$pool" "$catalog" || return
    printf '%-22s %-26s %-10s %-18s %s\n' \
        "KEY" "DISPLAY NAME" "PNP" "NATIVE" "SIZE"
    while IFS= read -r key || [[ -n $key ]]; do
        [[ -z $key || $key == \#* ]] && continue
        awk -F '|' -v wanted="$key" '
            !/^#/ && $1 == wanted {
                printf "%-22s %-26s %-10s %-18s %sx%smm\n", \
                    $1, $5, $2 ":" $3, $9 "x" $10 "@" $11 "Hz", $7, $8
                exit
            }
        ' "$catalog"
    done < "$pool"
}

monitor_profile_print_catalog() {
    local catalog=${1:-$MONITOR_PROFILE_CATALOG}

    monitor_profiles_validate "$catalog" || return
    awk -F '|' '
        BEGIN {
            printf "%-22s %-26s %-10s %-18s %s\n", "KEY", "DISPLAY NAME", "PNP", "NATIVE", "SIZE"
        }
        !/^#/ && NF {
            printf "%-22s %-26s %-10s %-18s %sx%smm\n", \
                $1, $5, $2 ":" $3, $9 "x" $10 "@" $11 "Hz", $7, $8
        }
    ' "$catalog"
}

monitor_profile_load() {
    local requested=${1:-}
    local catalog=${2:-$MONITOR_PROFILE_CATALOG}
    local p_key p_vendor p_product_id p_edid_name p_display_name p_manufacturer
    local p_width_mm p_height_mm p_native_x p_native_y p_refresh_hz
    local p_min_v p_max_v p_min_h p_max_h p_max_clock_mhz p_video_input
    local p_year p_week p_serial_prefix p_mode_set

    [[ -n $requested ]] || {
        _monitor_profile_error 'monitor_profile_load requires a profile key'
        return 2
    }
    monitor_profiles_validate "$catalog" || return

    while IFS='|' read -r p_key p_vendor p_product_id p_edid_name p_display_name \
        p_manufacturer p_width_mm p_height_mm p_native_x p_native_y p_refresh_hz \
        p_min_v p_max_v p_min_h p_max_h p_max_clock_mhz p_video_input p_year \
        p_week p_serial_prefix p_mode_set; do
        [[ -z $p_key || $p_key == \#* ]] && continue
        [[ $p_key == "$requested" ]] || continue

        MONITOR_PROFILE=$p_key
        MONITOR_VENDOR=$p_vendor
        MONITOR_PRODUCT_ID=$p_product_id
        MONITOR_EDID_NAME=$p_edid_name
        MONITOR_DISPLAY_NAME=$p_display_name
        MONITOR_MANUFACTURER=$p_manufacturer
        MONITOR_BRAND_NAME=$p_manufacturer
        MONITOR_MODEL_NAME=${p_display_name:$(( ${#p_manufacturer} + 1 ))}
        MONITOR_WIDTH_MM=$p_width_mm
        MONITOR_HEIGHT_MM=$p_height_mm
        MONITOR_NATIVE_X=$p_native_x
        MONITOR_NATIVE_Y=$p_native_y
        MONITOR_REFRESH_HZ=$p_refresh_hz
        MONITOR_MIN_V=$p_min_v
        MONITOR_MAX_V=$p_max_v
        MONITOR_MIN_H=$p_min_h
        MONITOR_MAX_H=$p_max_h
        MONITOR_MAX_CLOCK_MHZ=$p_max_clock_mhz
        MONITOR_VIDEO_INPUT=$p_video_input
        MONITOR_YEAR=$p_year
        MONITOR_WEEK=$p_week
        MONITOR_SERIAL_PREFIX=$p_serial_prefix
        MONITOR_SERIAL_POLICY=$(monitor_profile_serial_policy_for_key "$p_key") || return
        MONITOR_MODE_SET=$p_mode_set

        export MONITOR_PROFILE MONITOR_VENDOR MONITOR_PRODUCT_ID MONITOR_EDID_NAME
        export MONITOR_DISPLAY_NAME MONITOR_MANUFACTURER MONITOR_BRAND_NAME MONITOR_MODEL_NAME
        export MONITOR_WIDTH_MM MONITOR_HEIGHT_MM
        export MONITOR_NATIVE_X MONITOR_NATIVE_Y MONITOR_REFRESH_HZ MONITOR_MIN_V MONITOR_MAX_V
        export MONITOR_MIN_H MONITOR_MAX_H MONITOR_MAX_CLOCK_MHZ MONITOR_VIDEO_INPUT
        export MONITOR_YEAR MONITOR_WEEK MONITOR_SERIAL_PREFIX MONITOR_SERIAL_POLICY
        export MONITOR_MODE_SET
        return 0
    done < "$catalog"

    _monitor_profile_error "unknown profile '$requested'"
    return 1
}

_monitor_profile_random_index() {
    local count=${1:-0}
    local raw

    ((count > 0)) || {
        _monitor_profile_error 'random selection requires a non-empty list'
        return 2
    }
    if [[ -r /dev/urandom ]]; then
        raw=$(od -An -N4 -tu4 /dev/urandom 2>/dev/null) || raw=
        raw=${raw//[[:space:]]/}
    fi
    [[ ${raw:-} =~ ^[0-9]+$ ]] || raw=$(((RANDOM << 15) ^ RANDOM))
    printf '%s\n' "$((raw % count))"
}

monitor_profile_pick_random() {
    local catalog=${1:-$MONITOR_PROFILE_CATALOG}
    local index
    local -a keys=()

    monitor_profiles_validate "$catalog" || return
    mapfile -t keys < <(awk -F '|' '!/^#/ && NF { print $1 }' "$catalog")
    ((${#keys[@]} > 0)) || {
        _monitor_profile_error "$catalog: catalog contains no profiles"
        return 1
    }

    index=$(_monitor_profile_random_index "${#keys[@]}") || return
    monitor_profile_load "${keys[$index]}" "$catalog"
}

# Pick a brand uniformly, then pick one of that brand's allowed models
# uniformly.  This prevents brands with more catalog rows from dominating the
# identity chosen for a new VM.
monitor_profile_pick_create_random() {
    local pool=${1:-$MONITOR_CREATE_PROFILE_POOL}
    local catalog=${2:-$MONITOR_PROFILE_CATALOG}
    local brand index
    local -a brands=()
    local -a keys=()

    monitor_create_pool_validate "$pool" "$catalog" || return
    mapfile -t brands < <(awk -F '|' '
        FNR == NR {
            if ($0 !~ /^#/ && $0 != "") wanted[$1] = 1
            next
        }
        !/^#/ && NF && ($1 in wanted) && !seen[$6]++ { print $6 }
    ' "$pool" "$catalog")
    ((${#brands[@]} > 0)) || {
        _monitor_profile_error "$pool: creation pool contains no brands"
        return 1
    }

    index=$(_monitor_profile_random_index "${#brands[@]}") || return
    brand=${brands[$index]}
    mapfile -t keys < <(awk -F '|' -v brand="$brand" '
        FNR == NR {
            if ($0 !~ /^#/ && $0 != "") wanted[$1] = 1
            next
        }
        !/^#/ && NF && ($1 in wanted) && $6 == brand { print $1 }
    ' "$pool" "$catalog")
    ((${#keys[@]} > 0)) || {
        _monitor_profile_error "$pool: brand '$brand' contains no profiles"
        return 1
    }
    index=$(_monitor_profile_random_index "${#keys[@]}") || return
    monitor_profile_load "${keys[$index]}" "$catalog"
}

# Compatibility spelling for callers that treat random selection as a load.
monitor_profile_random() {
    monitor_profile_pick_random "$@"
}

monitor_profile_generate_serial() {
    local prefix=${1:-${MONITOR_SERIAL_PREFIX:-MON}}
    local seed=${2-}
    local policy=${3:-}
    local material remaining numeric_material candidate

    if [[ -z $policy ]]; then
        if [[ -n ${MONITOR_SERIAL_POLICY:-} &&
              ${MONITOR_SERIAL_PREFIX:-} == "$prefix" ]]; then
            policy=$MONITOR_SERIAL_POLICY
        else
            case $prefix in
                H4ZMC) policy=samsung-h4zmc-decimal5 ;;
                29200) policy=redmi-29200-decimal8 ;;
                *) policy=generic-prefix-hash ;;
            esac
        fi
    fi
    case $policy in
        samsung-h4zmc-decimal5)
            [[ $prefix == H4ZMC ]] || {
                _monitor_profile_error 'Samsung S24F350 serial prefix must be H4ZMC'
                return 2
            }
            ;;
        redmi-29200-decimal8)
            [[ $prefix == 29200 ]] || {
                _monitor_profile_error 'Redmi RMMNT238NF serial prefix must be 29200'
                return 2
            }
            ;;
        generic-prefix-hash)
            [[ $prefix =~ ^[A-Z0-9]{1,8}$ ]] || {
                _monitor_profile_error 'serial prefix must be 1-8 uppercase alphanumeric characters'
                return 2
            }
            ;;
        *)
            _monitor_profile_error "unsupported serial policy '$policy'"
            return 2
            ;;
    esac
    command -v sha256sum >/dev/null 2>&1 || {
        _monitor_profile_error 'sha256sum is required to generate monitor serials'
        return 1
    }

    if [[ -n $seed ]]; then
        material=$(printf '%s' "${prefix}|${seed}" | sha256sum) || return
    elif [[ -r /dev/urandom ]]; then
        material=$(od -An -N32 -tx1 /dev/urandom 2>/dev/null | tr -d '[:space:]') || return
    else
        material=$(printf '%s' "${prefix}|${RANDOM}|$$|${EPOCHREALTIME:-0}" | sha256sum) || return
    fi

    material=${material%% *}
    material=${material^^}
    material=${material//[^A-Z0-9]/}
    case $policy in
        samsung-h4zmc-decimal5)
            numeric_material=$((16#${material:0:15}))
            numeric_material=$((numeric_material % 100000))
            while :; do
                printf -v candidate 'H4ZMC%05d' "$numeric_material"
                if ! monitor_profile_serial_is_reserved "$candidate" "$policy"; then
                    printf '%s\n' "$candidate"
                    break
                fi
                numeric_material=$(((numeric_material + 1) % 100000))
            done
            ;;
        redmi-29200-decimal8)
            numeric_material=$((16#${material:0:15}))
            numeric_material=$((numeric_material % 100000000))
            while :; do
                printf -v candidate '29200%08d' "$numeric_material"
                if ! monitor_profile_serial_is_reserved "$candidate" "$policy"; then
                    printf '%s\n' "$candidate"
                    break
                fi
                numeric_material=$(((numeric_material + 1) % 100000000))
            done
            ;;
        generic-prefix-hash)
            remaining=$((12 - ${#prefix}))
            printf '%s%s\n' "$prefix" "${material:0:remaining}"
            ;;
    esac
}

# Validate the persisted/displayed serial against the currently loaded
# profile.  Optional prefix/policy arguments keep this useful to callers that
# do not use monitor_profile_load, while the one-argument form is the normal
# profile-aware API.
monitor_profile_serial_validate() {
    local LC_ALL=C
    local serial=${1-}
    local prefix=${2:-${MONITOR_SERIAL_PREFIX:-}}
    local policy=${3:-${MONITOR_SERIAL_POLICY:-generic-prefix-hash}}
    local suffix

    case $policy in
        samsung-h4zmc-decimal5)
            [[ $prefix == H4ZMC && $serial =~ ^H4ZMC[0-9]{5}$ ]] || return 1
            ! monitor_profile_serial_is_reserved "$serial" "$policy"
            ;;
        redmi-29200-decimal8)
            [[ $prefix == 29200 && $serial =~ ^29200[0-9]{8}$ ]] || return 1
            ! monitor_profile_serial_is_reserved "$serial" "$policy"
            ;;
        generic-prefix-hash)
            [[ $prefix =~ ^[A-Z0-9]{1,8}$ && ${#serial} -eq 12 ]] || return 1
            [[ ${serial:0:${#prefix}} == "$prefix" ]] || return 1
            suffix=${serial:${#prefix}}
            [[ $suffix =~ ^[0-9A-F]+$ ]]
            ;;
        *) return 1 ;;
    esac
}

monitor_profile_legacy_rows() {
    local catalog=${1:-$MONITOR_PROFILE_CATALOG}

    monitor_profiles_validate "$catalog" || return
    awk -F '|' '!/^#/ && NF { print $2 "|" $4 "|" $7 "|" $8 "|" $20 }' "$catalog"
}
