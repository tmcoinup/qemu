#!/usr/bin/env python3
"""Build a lab-only VM-bound loader from an operator-supplied template.

The template binary is not part of VMate and must be supplied explicitly.
This diagnostic rewrites the equal-length VM identifier in the two encrypted
configuration records observed on the authorized lab machine.  For isolation
testing it can also apply a same-length SMBIOS-only probe, or neutralize every
non-display source mapping while retaining the original array shape and byte
length.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import struct


PC02_TEMPLATE_SHA256 = (
    "094f69e37a8723c166ff5cc762775897008f967cddba02effb75025ed271eb0b"
)
OUTER_CONFIG_LENGTH_OFFSET = 0x1075F0
OUTER_CONFIG_OFFSET = 0x1075F4
OUTER_PAYLOAD_LENGTH_OFFSET = 0x133B0
OUTER_PAYLOAD_OFFSET = 0x133B4
INNER_CONFIG_LENGTH_OFFSET = 0xE1970
INNER_CONFIG_OFFSET = 0xE1974
CONFIG_KEY = b"1" * 16


def rc4(data: bytes, key: bytes) -> bytes:
    state = list(range(256))
    j = 0
    for i in range(256):
        j = (j + state[i] + key[i % len(key)]) & 0xFF
        state[i], state[j] = state[j], state[i]
    output = bytearray(len(data))
    i = 0
    j = 0
    for offset, value in enumerate(data):
        i = (i + 1) & 0xFF
        j = (j + state[i]) & 0xFF
        state[i], state[j] = state[j], state[i]
        output[offset] = value ^ state[(state[i] + state[j]) & 0xFF]
    return bytes(output)


def parse_guid_ascii(value: str, label: str) -> bytes:
    encoded = value.lower().encode("ascii")
    if len(encoded) != 36:
        raise ValueError(f"{label} must contain a 36-character GUID")
    parts = value.split("-")
    if [len(part) for part in parts] != [8, 4, 4, 4, 12]:
        raise ValueError(f"{label} is not a canonical GUID")
    int("".join(parts), 16)
    return encoded


def replace_identifier(record: bytes, old_id: bytes, new_id: bytes,
                       label: str) -> bytes:
    if record.count(old_id) != 1:
        raise ValueError(f"{label} does not contain exactly one old VMId")
    rewritten = record.replace(old_id, new_id)
    if len(rewritten) != len(record) or old_id in rewritten:
        raise ValueError(f"{label} VMId rewrite changed the record shape")
    decoded = json.loads(rewritten.decode("utf-8"))
    if not isinstance(decoded, list) or len(decoded) < 2:
        raise ValueError(f"{label} is not the expected configuration array")
    if str(decoded[1]).lower().encode("ascii") != new_id:
        raise ValueError(f"{label} VMId verification failed")
    return rewritten


def read_u32(image: bytes | bytearray, offset: int, label: str) -> int:
    if offset < 0 or offset + 4 > len(image):
        raise ValueError(f"{label} length field is outside the image")
    return struct.unpack_from("<I", image, offset)[0]


def get_pe_raw_section_end(image: bytes | bytearray, offset: int) -> int:
    """Return the raw end of the PE section containing a file offset."""
    if len(image) < 0x40 or bytes(image[:2]) != b"MZ":
        raise ValueError("inner payload has no DOS header")
    pe_offset = read_u32(image, 0x3C, "PE header")
    if pe_offset + 24 > len(image) or \
            bytes(image[pe_offset:pe_offset + 4]) != b"PE\0\0":
        raise ValueError("inner payload has no PE header")
    section_count = struct.unpack_from("<H", image, pe_offset + 6)[0]
    optional_size = struct.unpack_from("<H", image, pe_offset + 20)[0]
    section_table = pe_offset + 24 + optional_size
    if section_count <= 0 or section_table + section_count * 40 > len(image):
        raise ValueError("inner payload section table is invalid")
    for index in range(section_count):
        header = section_table + index * 40
        raw_size = read_u32(image, header + 16, "section raw size")
        raw_offset = read_u32(image, header + 20, "section raw offset")
        if raw_offset <= offset < raw_offset + raw_size:
            return raw_offset + raw_size
    raise ValueError("inner configuration is outside every PE section")


def calculate_loader_checksum(record: bytes | bytearray) -> int:
    """Match the outer loader's folded byte-sum integrity contract."""
    checksum = 0
    for value in record:
        checksum += value
        if checksum > 0xFFFF:
            checksum = (checksum & 0xFFFF) + (checksum >> 16)
    return (~checksum) & 0xFFFF


def rewrite_outer_checksum(record: bytes, checksum: int) -> bytes:
    decoded = json.loads(record.decode("utf-8"))
    if not isinstance(decoded, list) or len(decoded) < 7 or \
            not isinstance(decoded[5], int) or \
            not isinstance(decoded[6], int):
        raise ValueError("outer configuration has no checksum contract")
    decoded[5] = checksum
    compact = json.dumps(
        decoded, ensure_ascii=False, separators=(",", ":")
    ).replace("/", "\\/").encode("utf-8")
    if len(compact) > len(record):
        raise ValueError("outer checksum rewrite grew the configuration")
    # JSON permits trailing whitespace.  Keep the encrypted record and its
    # following section layout unchanged if a checksum has fewer digits.
    return compact + (b" " * (len(record) - len(compact)))


def rewrite_inner_config(record: bytes, old_id: bytes, new_id: bytes,
                         device_map_mode: str,
                         vrd_instance_id: str | None = None,
                         source_instance_map: dict[str, str] | None = None
                         ) -> bytes:
    if device_map_mode == "all":
        return replace_identifier(record, old_id, new_id,
                                  "inner configuration")

    decoded = json.loads(record.decode("utf-8"))
    if not isinstance(decoded, list) or len(decoded) < 10:
        raise ValueError("inner configuration is not the expected array")
    if str(decoded[1]).lower().encode("ascii") != old_id:
        raise ValueError("inner configuration VMId does not match old VMId")
    if device_map_mode == "identity-probe":
        identity = decoded[3]
        if not isinstance(identity, list) or len(identity) < 2 or \
                identity[1] != "A.40":
            raise ValueError(
                "identity-probe requires the expected A.40 BIOS version"
            )
        # This same-length SMBIOS string does not affect device matching.  It
        # distinguishes an inner-record integrity/binding failure from a
        # failure caused by neutralized PnP source identifiers.
        identity[1] = "A.41"
    else:
        device_map = decoded[9]
        if not isinstance(device_map, list):
            raise ValueError("inner configuration device map is not an array")
        selected_names = []
        selected_entries = []
        normalized_source_map = {
            str(key).lower(): str(value)
            for key, value in (source_instance_map or {}).items()
        }
        used_source_keys = set()
        for entry in device_map:
            if not isinstance(entry, list) or len(entry) < 8:
                raise ValueError("device mapping is not the expected array")
            name = str(entry[0]).lower()
            source_id = str(entry[2])
            source_key = source_id.lower()
            if source_key in normalized_source_map:
                replacement = normalized_source_map[source_key]
                if not replacement or "\\" in replacement:
                    raise ValueError(
                        "source instance overrides must be non-empty tails"
                    )
                entry[3] = replacement
                used_source_keys.add(source_key)
            if name in {"vrd.inf", "wvmbusvideo.inf"}:
                if name == "vrd.inf" and vrd_instance_id is not None:
                    if not vrd_instance_id or "\\" in vrd_instance_id:
                        raise ValueError(
                            "vrd instance ID must be a non-empty instance tail"
                        )
                    entry[3] = vrd_instance_id
                selected_names.append(name)
                selected_entries.append(entry)
                if device_map_mode == "all-rebound":
                    continue
                continue
            if device_map_mode == "all-rebound":
                continue
            if device_map_mode == "display-only-compact":
                continue
            if not source_id:
                raise ValueError(
                    "device mapping has an empty source identifier"
                )
            # Preserve every field length and the parser's expected map count,
            # but make this source PnP identifier impossible to match.
            entry[2] = "X" + source_id[1:]
        if device_map_mode == "all-rebound":
            missing_source_keys = set(normalized_source_map) - \
                used_source_keys
            if missing_source_keys:
                raise ValueError(
                    "source instance map contains unknown source IDs: " +
                    ", ".join(sorted(missing_source_keys))
                )
            if not used_source_keys and vrd_instance_id is None:
                raise ValueError("all-rebound requires a source override")
        else:
            if selected_names.count("vrd.inf") != 1 or \
                    selected_names.count("wvmbusvideo.inf") != 1:
                raise ValueError(
                    "display-only mode requires one vrd.inf and one "
                    "wvmbusvideo.inf mapping"
                )
            if device_map_mode == "display-only-compact":
                decoded[9] = selected_entries
    decoded[1] = new_id.decode("ascii")
    compact = json.dumps(
        decoded, ensure_ascii=False, separators=(",", ":")
    ).replace("/", "\\/").encode("utf-8")
    if device_map_mode not in {"display-only-compact", "all-rebound"} and \
            len(compact) != len(record):
        raise ValueError(
            "display-only rewrite changed the inner configuration length"
        )
    return compact


def rewrite(template: bytes, old_id: bytes, new_id: bytes,
            device_map_mode: str = "all",
            vrd_instance_id: str | None = None,
            source_instance_map: dict[str, str] | None = None) -> bytes:
    image = bytearray(template)
    outer_config_length = read_u32(
        image, OUTER_CONFIG_LENGTH_OFFSET, "outer configuration"
    )
    outer_config_end = OUTER_CONFIG_OFFSET + outer_config_length
    if outer_config_length < 64 or outer_config_end > len(image):
        raise ValueError("outer configuration length is invalid")
    outer_plain = rc4(bytes(image[OUTER_CONFIG_OFFSET:outer_config_end]),
                      CONFIG_KEY)
    outer_plain = replace_identifier(
        outer_plain, old_id, new_id, "outer configuration"
    )
    outer_decoded = json.loads(outer_plain.decode("utf-8"))
    if not isinstance(outer_decoded, list) or len(outer_decoded) < 7 or \
            not isinstance(outer_decoded[6], int):
        raise ValueError("outer configuration checksum boundary is missing")
    checksum_boundary = outer_decoded[6]
    if checksum_boundary <= 0 or checksum_boundary > len(image) or \
            checksum_boundary > OUTER_CONFIG_LENGTH_OFFSET:
        raise ValueError("outer configuration checksum boundary is invalid")

    payload_length = read_u32(
        image, OUTER_PAYLOAD_LENGTH_OFFSET, "outer payload"
    )
    payload_end = OUTER_PAYLOAD_OFFSET + payload_length
    if payload_length < INNER_CONFIG_OFFSET or payload_end > len(image):
        raise ValueError("outer payload length is invalid")
    payload = bytearray(rc4(
        bytes(image[OUTER_PAYLOAD_OFFSET:payload_end]), CONFIG_KEY
    ))
    if payload[:2] != b"MZ":
        raise ValueError("decrypted outer payload is not a PE image")
    inner_length = read_u32(
        payload, INNER_CONFIG_LENGTH_OFFSET, "inner configuration"
    )
    old_inner_end = INNER_CONFIG_OFFSET + inner_length
    if inner_length < 256 or old_inner_end > len(payload):
        raise ValueError("inner configuration length is invalid")
    inner_plain = rc4(
        bytes(payload[INNER_CONFIG_OFFSET:old_inner_end]), CONFIG_KEY
    )
    inner_plain = rewrite_inner_config(
        inner_plain, old_id, new_id, device_map_mode, vrd_instance_id,
        source_instance_map,
    )
    inner_length = len(inner_plain)
    inner_end = INNER_CONFIG_OFFSET + inner_length
    inner_capacity_end = get_pe_raw_section_end(payload, INNER_CONFIG_OFFSET)
    if inner_length < 256 or inner_end > inner_capacity_end:
        raise ValueError("rewritten inner configuration exceeds its section")
    clear_end = max(old_inner_end, inner_end)
    payload[INNER_CONFIG_OFFSET:clear_end] = b"\0" * (
        clear_end - INNER_CONFIG_OFFSET
    )
    struct.pack_into(
        "<I", payload, INNER_CONFIG_LENGTH_OFFSET, inner_length
    )
    payload[INNER_CONFIG_OFFSET:inner_end] = rc4(inner_plain, CONFIG_KEY)
    image[OUTER_PAYLOAD_OFFSET:payload_end] = rc4(bytes(payload), CONFIG_KEY)

    loader_checksum = calculate_loader_checksum(image[:checksum_boundary])
    outer_plain = rewrite_outer_checksum(outer_plain, loader_checksum)
    image[OUTER_CONFIG_OFFSET:outer_config_end] = rc4(
        outer_plain, CONFIG_KEY
    )

    verify_outer = rc4(
        bytes(image[OUTER_CONFIG_OFFSET:outer_config_end]), CONFIG_KEY
    )
    verify_payload = rc4(
        bytes(image[OUTER_PAYLOAD_OFFSET:payload_end]), CONFIG_KEY
    )
    verify_inner_length = read_u32(
        verify_payload, INNER_CONFIG_LENGTH_OFFSET,
        "verified inner configuration",
    )
    verify_inner_end = INNER_CONFIG_OFFSET + verify_inner_length
    if verify_inner_length != inner_length or \
            verify_inner_end > inner_capacity_end:
        raise ValueError("inner configuration length verification failed")
    verify_inner = rc4(
        verify_payload[INNER_CONFIG_OFFSET:verify_inner_end], CONFIG_KEY
    )
    for label, record in (
        ("outer configuration", verify_outer),
        ("inner configuration", verify_inner),
    ):
        if record.count(new_id) != 1 or old_id in record:
            raise ValueError(f"{label} post-write verification failed")
        json.loads(record.decode("utf-8"))
    final_outer = json.loads(verify_outer.decode("utf-8"))
    if final_outer[5] != calculate_loader_checksum(
            image[:checksum_boundary]):
        raise ValueError("outer checksum post-write verification failed")
    if device_map_mode in {"display-only", "display-only-compact"}:
        final_inner = json.loads(verify_inner.decode("utf-8"))
        names = [
            str(entry[0]).lower() for entry in final_inner[9]
            if not str(entry[2]).startswith("X")
        ]
        if names != ["vrd.inf", "wvmbusvideo.inf"]:
            raise ValueError("display-only post-write verification failed")
    return bytes(image)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--template", required=True, type=pathlib.Path)
    parser.add_argument("--output", required=True, type=pathlib.Path)
    parser.add_argument("--old-vm-id", required=True)
    parser.add_argument("--new-vm-id", required=True)
    parser.add_argument(
        "--expected-template-sha256", default=PC02_TEMPLATE_SHA256
    )
    parser.add_argument(
        "--device-map-mode",
        choices=(
            "all", "all-rebound", "identity-probe", "display-only",
            "display-only-compact",
        ),
        default="all",
        help=("retain every template mapping, rebind source instances, apply "
              "a same-length SMBIOS-only probe, neutralize every non-display "
              "source mapping, or retain only the two display mappings"),
    )
    parser.add_argument(
        "--vrd-instance-id",
        help=("override the vrd.inf source instance tail, for example "
              "5&2da4ebed&0&0"),
    )
    parser.add_argument(
        "--source-instance-map", type=pathlib.Path,
        help=("JSON object mapping source PnP IDs to target-VM instance "
              "tails; used by all-rebound"),
    )
    args = parser.parse_args()

    template = args.template.read_bytes()
    template_hash = hashlib.sha256(template).hexdigest()
    if template_hash != args.expected_template_sha256.lower():
        raise ValueError(
            "template SHA-256 mismatch: "
            f"expected {args.expected_template_sha256}, observed {template_hash}"
        )
    old_id = parse_guid_ascii(args.old_vm_id, "old VMId")
    new_id = parse_guid_ascii(args.new_vm_id, "new VMId")
    source_instance_map = None
    if args.source_instance_map is not None:
        source_instance_map = json.loads(
            args.source_instance_map.read_text(encoding="utf-8-sig")
        )
        if not isinstance(source_instance_map, dict) or not all(
                isinstance(key, str) and isinstance(value, str)
                for key, value in source_instance_map.items()):
            raise ValueError("source instance map must be a string JSON object")
    output = rewrite(
        template, old_id, new_id, args.device_map_mode,
        args.vrd_instance_id, source_instance_map,
    )
    if args.output.exists():
        raise FileExistsError(f"refusing to overwrite {args.output}")
    args.output.write_bytes(output)
    print(json.dumps({
        "template_sha256": template_hash,
        "output_sha256": hashlib.sha256(output).hexdigest(),
        "old_vm_id": old_id.decode("ascii"),
        "new_vm_id": new_id.decode("ascii"),
        "device_map_mode": args.device_map_mode,
        "vrd_instance_id": args.vrd_instance_id,
        "source_instance_override_count": len(source_instance_map or {}),
        "size": len(output),
    }, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
