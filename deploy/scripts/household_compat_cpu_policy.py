#!/usr/bin/env python3
"""锁定家用 SKU 相对 QEMU 基型必须显式覆盖的 CPU 属性。"""

from __future__ import annotations

import hashlib
import json
from typing import Any


# 这些字段只描述 CPUID 身份，不属于“从基型继承或关闭”的指令能力。
IDENTITY_PROPERTIES = {"family", "model", "stepping", "model-id"}

# QEMU 的代际基型通常代表该代较完整的 Core/Ryzen 能力，而低端 SKU
# 会熔断部分指令集。这里按候选 ID 精确列出差异，既避免多报能力，也防止
# 后续维护时为了“能启动”而随意少报一个本来具备能力的 SKU。
EXPECTED_FEATURE_OVERRIDES: dict[str, dict[str, str]] = {
    "compat-sandy-g630-p8h61": {"aes": "off", "avx": "off"},
    "compat-sandy-i3-2120-p8h61": {"aes": "off"},
    "compat-sandy-i5-2400-p8h61": {},
    "compat-ivy-g2020-p8b75": {
        "aes": "off",
        "avx": "off",
        "f16c": "off",
        "rdrand": "off",
    },
    "compat-ivy-i3-3220-p8b75": {"aes": "off", "rdrand": "off"},
    "compat-ivy-i5-3470-p8b75": {},
    "compat-haswell-g3220-h81": {
        "aes": "off",
        "avx": "off",
        "avx2": "off",
        "bmi1": "off",
        "bmi2": "off",
        "f16c": "off",
        "fma": "off",
    },
    "compat-haswell-i3-4130-h81": {},
    "compat-haswell-i5-4570-h81": {},
    # Family 10h 原生拥有 3DNow!/3DNow!Ext，不能在目录中永久关闭；若现代
    # 宿主缺少相应 KVM 位，QEMU 参数构造器会按实际宿主动态追加 mask。
    "compat-k10-athlon-ii-x2-250-m5a78l": {},
    "compat-k10-phenom-ii-x4-955-m5a78l": {},
    "compat-zen-athlon-200ge-b350": {},
    "compat-zen-ryzen3-1200-b350": {},
    "normal-ryzen7-5800-ryzen3-1200-b350": {},
}

# 每个摘要覆盖完整 cpu 对象，包括 SKU 名称/部件号、QEMU CPUID、核心线程、
# 频率、物理位宽、核显策略和 SMBIOS Type 4 字段。通用范围校验负责解释
# 单字段错误，本表负责防止多个“各自合法”的字段被成套交换后悄悄漂移。
EXPECTED_CPU_FACT_DIGESTS = {
    "compat-sandy-g630-p8h61": "07f1992939d5b2a0f18bd8477d7ba0afc75c38479100ba52089689acc126166f",
    "compat-sandy-i3-2120-p8h61": "b18057cf1142bf0f4c480a7244757a4fd7f8ee9ec0c1e94b0d55f577ce6736d1",
    "compat-sandy-i5-2400-p8h61": "a62060e866720a648d617e3e95dacfabdc000d5de6bccb938e1e27210af0fb3b",
    "compat-ivy-g2020-p8b75": "8361c8e1ecfc70a96467777a6fc33ad360db5612397a8ad38dc3fc6345a19a9c",
    "compat-ivy-i3-3220-p8b75": "2d209646daab0b43164227fca241af3e716f2cb9e759ccf2303eba4299348e6c",
    "compat-ivy-i5-3470-p8b75": "2f63f1715eec16d6a2ca71efb4d4aea56e3fbeae72b53a7ae7ab2c5b2ef5c33e",
    "compat-haswell-g3220-h81": "176e8edec0081c0cee6aa69242c1023eb6d468ee5df715e25ee30b18dc8f6629",
    "compat-haswell-i3-4130-h81": "47efb77f5f620f639d9a399514955e7017e7d90a7035cacf9610695616c9193e",
    "compat-haswell-i5-4570-h81": "0df623041e97fb0bc85b1b9bc3de446421432dd7d852bc996b93d8444b70815c",
    "compat-k10-athlon-ii-x2-250-m5a78l": "836bc80aa80b94d86e0632743318e4814e551fe9f22d4a103cca49c3bc6237fc",
    "compat-k10-phenom-ii-x4-955-m5a78l": "d2cc3bd0264cffcd7a6f1edd5a06058c2ad82fa9c8454707cc3469075d7b57b1",
    "compat-zen-athlon-200ge-b350": "ad175651d8c593dab604c834e134b4aacae1dfdafe797c805197aaa8bbd18365",
    "compat-zen-ryzen3-1200-b350": "a79d5480571e90a31bbcdb46912f35d5381e774c44c0db712744e771c5478af9",
    "normal-ryzen7-5800-ryzen3-1200-b350": "a79d5480571e90a31bbcdb46912f35d5381e774c44c0db712744e771c5478af9",
}


def validate_cpu_facts(
    candidate_id: str,
    cpu: dict[str, Any],
    where: str,
) -> None:
    """把候选 ID 与整套已审计 CPU 事实做不可交换绑定。"""
    expected = EXPECTED_CPU_FACT_DIGESTS.get(candidate_id)
    if expected is None:
        raise ValueError(f"{where}.id 没有经审核的 CPU 事实摘要")
    canonical = json.dumps(
        cpu,
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")
    actual = hashlib.sha256(canonical).hexdigest()
    if actual != expected:
        raise ValueError(
            f"{where}.cpu 偏离已审计 SKU 事实："
            f"actual_digest={actual} expected_digest={expected}"
        )


def validate_feature_overrides(
    candidate_id: str,
    properties: dict[str, str],
    where: str,
) -> None:
    """要求每个 SKU 的显式能力覆盖与已核对策略完全相同。"""
    if candidate_id not in EXPECTED_FEATURE_OVERRIDES:
        raise ValueError(f"{where}.id 没有经审核的 CPU 指令能力策略")
    actual = {
        key: value
        for key, value in properties.items()
        if key not in IDENTITY_PROPERTIES
    }
    expected = EXPECTED_FEATURE_OVERRIDES[candidate_id]
    if actual != expected:
        raise ValueError(
            f"{where}.cpu.qemu_arg 指令覆盖错误："
            f"actual={actual!r} expected={expected!r}"
        )
