#!/usr/bin/env python3
"""验证统一 EXE 的生成头、释放表与 launcher 入口形成封闭映射。"""

from __future__ import annotations

import pathlib
import re


ROOT = pathlib.Path(__file__).resolve().parents[3]
LAUNCHER = ROOT / "deploy/guest-stealth/launcher/respawn-stealth-launcher.c"
PAYLOADS = ROOT / "deploy/guest-stealth/launcher/respawn-stealth-payloads.h"
BUILD = ROOT / "deploy/guest-stealth/build-exe.sh"


def fail(message: str) -> None:
    raise SystemExit("FAIL: " + message)


launcher_text = LAUNCHER.read_text(encoding="utf-8")
payload_text = PAYLOADS.read_text(encoding="utf-8")
build_text = BUILD.read_text(encoding="utf-8")

if '#include "respawn-stealth-payloads.h"' not in launcher_text:
    fail("launcher 主流程没有接入独立 payload 表")
if re.search(r'^#include "payload_|^static const EmbeddedPayload embedded_payloads',
             launcher_text, re.MULTILINE):
    fail("launcher 主流程重新内联了生成 payload 或释放表")

include_symbols = set(re.findall(r'^#include "payload_([a-z0-9_]+)\.h"$',
                                 payload_text, re.MULTILINE))
rows = re.findall(
    r'\{\s*L"([^"]+)",\s*payload_([a-z0-9_]+),'
    r'\s*\(DWORD\)sizeof\(payload_([a-z0-9_]+)\)\s*\}',
    payload_text,
)
if not include_symbols or not rows:
    fail("payload 生成头或释放表为空")
files = [name for name, _, _ in rows]
row_symbols = {symbol for _, symbol, size_symbol in rows
               if symbol == size_symbol}
if len(row_symbols) != len({symbol for _, symbol, _ in rows}):
    fail("payload 表数据指针与 sizeof 符号不一致")
if include_symbols != row_symbols:
    fail(f"生成头与释放表不闭合: include-only={include_symbols - row_symbols}, "
         f"row-only={row_symbols - include_symbols}")
if len(files) != len(set(files)):
    fail("payload 表存在重复目标文件名")

for symbol in include_symbols:
    if f'"$BUILD_DIR/payload_{symbol}.h"' not in build_text:
        fail("构建脚本没有生成 payload 头: " + symbol)

required = {
    "project-monitor-identity.ps1",
    "monitor-identities.json",
    "monitor-friendly-name-projector.exe",
    "CougarPointSystem.inf",
    "PantherPointSystem.inf",
    "LynxPointSystem.inf",
}
missing = required - set(files)
if missing:
    fail("全池关键 payload 未进入释放表: " + ", ".join(sorted(missing)))

for source in (LAUNCHER, PAYLOADS, BUILD):
    if sum(1 for _ in source.open(encoding="utf-8")) > 500:
        fail("文件超过 500 行: " + str(source))

print("OK: guest-stealth payload table checks passed")
