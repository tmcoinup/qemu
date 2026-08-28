#!/usr/bin/env python3
"""Locked NVIDIA GRID mode policy used by the G-11 FHD monitor flow.

The production-signed GRID 538.33 INF publishes a broad ``NV_Modes`` list in
the display adapter's PnP software key.  G-11 restricts that source list to the
page-safe modes advertised by its reviewed 1920x1080 EDID.  Registry callers
may replace only a reviewed GRID/legacy value or the current policy; an unknown
value is deliberately rejected.

R535's local-console presentation path rounds its message buffer up to 4 KiB,
but validates it against the unrounded scanout length.  A mode whose
128-byte-aligned pitch times height is not 4-KiB aligned is therefore rejected
by ``nvidia-vgpu-mgr`` and reaches QEMU as an all-zero REGION.  The policy below
deliberately omits those modes even when they are otherwise ordinary PC modes.
"""

from __future__ import annotations

import re
from collections.abc import Iterable, Sequence


DISPLAY_ADAPTER_CLASS_GUID = "{4d36e968-e325-11ce-bfc1-08002be10318}"
NVIDIA_DISPLAY_SERVICE = "nvlddmkm"
GRID_53833_DRIVER_VERSION = "31.0.15.3833"
GRID_53833_INF_SHA256 = (
    "67a240e1d464cf97dabfec1a7cecf000eaa9ddfd702f32ba2c8771f17905dc2b"
)
GRID_53833_CATALOG_SHA256 = (
    "56b07bd93280bbda761cb5c9a3a13262c3605320d7286953989e2a5b16d5ec6f"
)

# Exact REG_MULTI_SZ emitted by the production-signed GRID 538.33 nvgridsw.inf
# used by G-11.  REG_SZ_APPEND makes the second INF line a second element.
GRID_53833_NV_MODES = (
    "{*}SHV 1280x720x8,16,32,64 1680x1050x8,16,32,64 "
    "1920x1080x8,16,32,64 2048x1536x8,16,32,64=1; "
    "1920x1440x8,16,32,64=1F; 640x480x8,16,32,64 "
    "800x600x8,16,32,64 1024x768x8,16,32,64=1FFF; "
    "1920x1200x8,16,32,64=3F; 1600x900x8,16,32,64=3FF; "
    "2560x1440x8,16,32,64 2560x1600x8,16,32,64=7B; "
    "1600x1024x8,16,32,64 1600x1200x8,16,32,64=7F; "
    "1280x768x8,16,32,64 1280x800x8,16,32,64 "
    "1280x960x8,16,32,64 1280x1024x8,16,32,64 "
    "1360x768x8,16,32,64 1366x768x8,16,32,64=7FF;",
    " 1152x864x8,16,32,64 1440x1080x8,16,32,64=FFF;"
    "S 720x480x8,16,32,64=1; 720x576x8,16,32,64=8032;",
)

# Previous reviewed policy.  Keep this exact value only as a migration source
# for VMs that already received the original 15-mode G-11 policy; never write
# it as the destination policy.
LEGACY_FHD_NV_MODES_POLICY = (
    "{*}SHV 1280x720x8,16,32,64 1920x1080x8,16,32,64=1; "
    "640x480x8,16,32,64 800x600x8,16,32,64 "
    "1024x768x8,16,32,64=1FFF; 1600x900x8,16,32,64=3FF; "
    "1600x1024x8,16,32,64 1600x1200x8,16,32,64=7F; "
    "1280x768x8,16,32,64 1280x960x8,16,32,64 "
    "1280x1024x8,16,32,64 1360x768x8,16,32,64 "
    "1366x768x8,16,32,64=7FF;",
    " 1152x864x8,16,32,64 1440x1080x8,16,32,64=FFF;",
)

# Previous reviewed 10-mode policy.  It is accepted only as a migration source:
# 1600x900 and 800x600 both produce non-page-aligned R535 console frames.
PAGE_UNSAFE_FHD_NV_MODES_POLICY = (
    "{*}SHV 1280x720x8,16,32,64 1920x1080x8,16,32,64=1; "
    "640x480x8,16,32,64 800x600x8,16,32,64 "
    "1024x768x8,16,32,64=1FFF; 1600x900x8,16,32,64=3FF; "
    "1280x768x8,16,32,64 1280x960x8,16,32,64 "
    "1280x1024x8,16,32,64 1360x768x8,16,32,64=7FF;",
)

# Exact page-safe source-mode set advertised by the reviewed G-11 FHD EDID.
# Windows Settings normally hides 640x480, so its picker normally shows seven
# of these eight modes.
FHD_NV_MODES_POLICY = (
    "{*}SHV 1280x720x8,16,32,64 1920x1080x8,16,32,64=1; "
    "640x480x8,16,32,64 1024x768x8,16,32,64=1FFF; "
    "1280x768x8,16,32,64 1280x960x8,16,32,64 "
    "1280x1024x8,16,32,64 1360x768x8,16,32,64=7FF;",
)

FHD_VISIBLE_MODES = frozenset(
    {
        (1920, 1080),
        (1360, 768),
        (1280, 1024),
        (1280, 960),
        (1280, 768),
        (1280, 720),
        (1024, 768),
        (640, 480),
    }
)

R535_CONSOLE_PITCH_ALIGNMENT = 128
R535_PRESENTATION_ALIGNMENT = 4096

_MODE_TOKEN = re.compile(
    r"(?<!\d)(?P<width>\d{3,4})x(?P<height>\d{3,4})"
    r"x\d+(?:,\d+)*(?![\d,])",
    re.IGNORECASE,
)


class NvidiaModePolicyError(ValueError):
    """The registry value is malformed or is not a reviewed policy source."""


def _canonical(values: Sequence[str]) -> tuple[str, ...]:
    return tuple(" ".join(value.split()) for value in values)


def mode_set(values: Iterable[str]) -> frozenset[tuple[int, int]]:
    """Return every compressed resolution token in an NV_Modes value."""

    modes: set[tuple[int, int]] = set()
    for value in values:
        if not isinstance(value, str):
            raise NvidiaModePolicyError("NV_Modes contains a non-string element")
        modes.update(
            (int(match.group("width")), int(match.group("height")))
            for match in _MODE_TOKEN.finditer(value)
        )
    return frozenset(modes)


def is_16_10(mode: tuple[int, int]) -> bool:
    width, height = mode
    return width * 10 == height * 16


def r535_console_frame_bytes(mode: tuple[int, int]) -> int:
    """Return R535's 32-bpp, 128-byte-pitch-aligned scanout length."""

    width, height = mode
    if width <= 0 or height <= 0:
        raise NvidiaModePolicyError(f"invalid display mode: {mode}")
    row_bytes = width * 4
    pitch = (
        (row_bytes + R535_CONSOLE_PITCH_ALIGNMENT - 1)
        // R535_CONSOLE_PITCH_ALIGNMENT
        * R535_CONSOLE_PITCH_ALIGNMENT
    )
    return pitch * height


def is_r535_console_safe_mode(mode: tuple[int, int]) -> bool:
    """Return whether R535 can deliver this mode without page padding."""

    return r535_console_frame_bytes(mode) % R535_PRESENTATION_ALIGNMENT == 0


def validate_policy(values: Sequence[str]) -> None:
    """Fail unless *values* is the exact reviewed page-safe G-11 policy."""

    if _canonical(values) != _canonical(FHD_NV_MODES_POLICY):
        raise NvidiaModePolicyError("NV_Modes is not the exact G-11 FHD policy")
    modes = mode_set(values)
    if modes != FHD_VISIBLE_MODES:
        raise NvidiaModePolicyError(
            f"G-11 FHD policy modes differ: {sorted(modes)}"
        )
    forbidden = sorted(mode for mode in modes if is_16_10(mode))
    if forbidden:
        raise NvidiaModePolicyError(
            f"G-11 FHD policy contains 16:10 modes: {forbidden}"
        )
    unsafe = sorted(mode for mode in modes if not is_r535_console_safe_mode(mode))
    if unsafe:
        details = ", ".join(
            f"{width}x{height}=0x{r535_console_frame_bytes((width, height)):x}"
            for width, height in unsafe
        )
        raise NvidiaModePolicyError(
            f"G-11 FHD policy contains R535 page-unsafe modes: {details}"
        )


def locked_policy_for(values: Sequence[str]) -> tuple[tuple[str, ...], bool]:
    """Return the reviewed policy and whether the registry needs a write.

    Only the locked GRID 538.33 source value, the previous reviewed 15-mode and
    10-mode policies, and the already-applied current policy are accepted.  This
    avoids silently overwriting a different driver release or a user's custom
    mode configuration while still allowing existing G-11 VMs to migrate.
    """

    canonical = _canonical(values)
    if canonical == _canonical(FHD_NV_MODES_POLICY):
        validate_policy(values)
        return FHD_NV_MODES_POLICY, False
    if canonical not in {
        _canonical(GRID_53833_NV_MODES),
        _canonical(LEGACY_FHD_NV_MODES_POLICY),
        _canonical(PAGE_UNSAFE_FHD_NV_MODES_POLICY),
    }:
        raise NvidiaModePolicyError(
            "NV_Modes differs from locked GRID 538.33, reviewed legacy, "
            "page-unsafe 10-mode, and current G-11 policies"
        )
    validate_policy(FHD_NV_MODES_POLICY)
    return FHD_NV_MODES_POLICY, True


def decode_reg_multi_sz(data: bytes) -> tuple[str, ...]:
    """Strictly decode a REG_MULTI_SZ payload, including its double NUL."""

    if len(data) % 2:
        raise NvidiaModePolicyError("REG_MULTI_SZ has an odd byte length")
    try:
        text = data.decode("utf-16le")
    except UnicodeDecodeError as exc:
        raise NvidiaModePolicyError("REG_MULTI_SZ is not valid UTF-16LE") from exc
    if not text.endswith("\x00\x00"):
        raise NvidiaModePolicyError("REG_MULTI_SZ lacks its double-NUL terminator")
    body = text[:-2]
    if not body:
        raise NvidiaModePolicyError("REG_MULTI_SZ is empty")
    values = tuple(body.split("\x00"))
    if any(not value for value in values):
        raise NvidiaModePolicyError("REG_MULTI_SZ contains an empty interior element")
    return values


def encode_reg_multi_sz(values: Sequence[str]) -> bytes:
    """Encode a non-empty string sequence as a strict REG_MULTI_SZ payload."""

    if not values or any(not isinstance(value, str) or not value for value in values):
        raise NvidiaModePolicyError("REG_MULTI_SZ requires non-empty strings")
    if any("\x00" in value for value in values):
        raise NvidiaModePolicyError("REG_MULTI_SZ element contains NUL")
    return ("\x00".join(values) + "\x00\x00").encode("utf-16le")


# Validate constants at import time so callers cannot write a broken policy.
validate_policy(FHD_NV_MODES_POLICY)
