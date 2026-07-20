#!/usr/bin/env bash
# 仅供“不测试 KVM”的目录/profile 单元测试使用。
#
# 生产选择器现在要求调用方必须提供物理位宽与真实 vCPU realize 两个门禁。目录、
# 序号、内存等测试不应访问 CI 宿主的 /dev/kvm，但也不能依赖“函数不存在即跳过”
# 的旧漏洞，因此显式加载这个受控替身，只核对候选已经形成完整 CPU 拓扑。

sv_validate_cpu_phys_bits() {
    [[ "${CPU_PHYS_BITS:-}" =~ ^[0-9]+$ ]] &&
        (( CPU_PHYS_BITS >= 32 && CPU_PHYS_BITS <= 52 ))
}

sv_validate_cpu_realize() {
    [[ "${CPU_CORES:-}" =~ ^[0-9]+$ &&
       "${CPU_THREADS:-}" =~ ^[0-9]+$ &&
       "${CPUS:-}" =~ ^[0-9]+$ &&
       -n "${CPU_QEMU_ARG:-}" ]] &&
        (( CPU_CORES > 0 && CPU_THREADS == CPUS &&
           CPU_THREADS % CPU_CORES == 0 ))
}
