/*
 * VMate 消费级 NVMe 身份画像与严格格式校验。
 *
 * 画像中的 PCI 身份来自实际设备枚举，型号/容量系列和链路来自厂商资料，固件与
 * 序列号语法来自同型号设备样本。生成值始终是合成序列号，绝不复制真实设备值。
 */
#include "qemu/osdep.h"
#include "qapi/error.h"

#include "vmate-identity.h"

typedef enum VmateNvmeSerialKind {
    VMATE_NVME_SERIAL_SAMSUNG_970_PRO,
    VMATE_NVME_SERIAL_INTEL_760P,
    VMATE_NVME_SERIAL_ALNUM12,
} VmateNvmeSerialKind;

typedef struct VmateNvmeIdentityEntry {
    VmateNvmeIdentity public;
    VmateNvmeSerialKind serial_kind;
} VmateNvmeIdentityEntry;

/*
 * IEEE OUI 在 NVMe Identify Controller 中按低字节在前存放，因此表内字节顺序
 * 与 smartctl 显示顺序相反，例如 00:25:38 保存为 38 25 00。
 */
static const VmateNvmeIdentityEntry vmate_nvme_identities[] = {
    {
        .public = {
            .id = "samsung-970-pro-512gb",
            .manufacturer = "Samsung",
            .model = "Samsung SSD 970 PRO 512GB",
            .firmware = "1B2QEXP7",
            .pci_vendor = 0x144d,
            .pci_device = 0xa808,
            .subsystem_vendor = 0x144d,
            .subsystem_device = 0xa801,
            .ieee_oui = { 0x38, 0x25, 0x00 },
            .pcie_generation = 3,
            .lanes = 4,
        },
        .serial_kind = VMATE_NVME_SERIAL_SAMSUNG_970_PRO,
    },
    {
        .public = {
            .id = "intel-760p-512gb",
            .manufacturer = "Intel",
            .model = "INTEL SSDPEKKW512G8",
            .firmware = "001C",
            .pci_vendor = 0x8086,
            .pci_device = 0xf1a6,
            .subsystem_vendor = 0x8086,
            .subsystem_device = 0x390b,
            .ieee_oui = { 0xe4, 0xd2, 0x5c },
            .pcie_generation = 3,
            .lanes = 4,
        },
        .serial_kind = VMATE_NVME_SERIAL_INTEL_760P,
    },
    {
        .public = {
            .id = "wd-pc-sn730-512gb",
            .manufacturer = "Western Digital",
            .model = "WDC PC SN730 SDBPNTY-512G-1027",
            .firmware = "11110000",
            .pci_vendor = 0x15b7,
            .pci_device = 0x5006,
            .subsystem_vendor = 0x15b7,
            .subsystem_device = 0x5006,
            .ieee_oui = { 0x44, 0x1b, 0x00 },
            .pcie_generation = 3,
            .lanes = 4,
        },
        .serial_kind = VMATE_NVME_SERIAL_ALNUM12,
    },
    {
        .public = {
            .id = "kioxia-xg6-512gb",
            .manufacturer = "KIOXIA",
            .model = "KXG60ZNV512G KIOXIA",
            .firmware = "AGHA4101",
            .pci_vendor = 0x1179,
            .pci_device = 0x011a,
            .subsystem_vendor = 0x1179,
            .subsystem_device = 0x0001,
            .ieee_oui = { 0x8e, 0xe3, 0x8c },
            .pcie_generation = 3,
            .lanes = 4,
        },
        .serial_kind = VMATE_NVME_SERIAL_ALNUM12,
    },
};

static const VmateNvmeIdentityEntry *
vmate_nvme_identity_entry(const VmateNvmeIdentity *identity)
{
    size_t i;

    for (i = 0; i < ARRAY_SIZE(vmate_nvme_identities); i++) {
        if (&vmate_nvme_identities[i].public == identity) {
            return &vmate_nvme_identities[i];
        }
    }
    return NULL;
}

const VmateNvmeIdentity *vmate_nvme_identity_lookup(const char *id)
{
    size_t i;

    if (!id || !id[0]) {
        return NULL;
    }
    for (i = 0; i < ARRAY_SIZE(vmate_nvme_identities); i++) {
        if (!strcmp(vmate_nvme_identities[i].public.id, id)) {
            return &vmate_nvme_identities[i].public;
        }
    }
    return NULL;
}

/*
 * 只检查厂商格式中的可变负载。Samsung 的 index 4 是固定字母 N，不应参与
 * 占位判断；其它画像传 SIZE_MAX，表示负载内没有固定位置。全 0、全 F 和
 * 全 N 都是常见的未写入/未知占位值，三类统一拒绝。
 */
static bool vmate_nvme_payload_is_placeholder(const char *serial,
                                              size_t begin, size_t end,
                                              size_t fixed_index)
{
    static const char placeholders[] = { '0', 'F', 'N' };
    size_t placeholder_index;

    for (placeholder_index = 0;
         placeholder_index < ARRAY_SIZE(placeholders);
         placeholder_index++) {
        size_t i;
        bool all_same = true;
        bool saw_payload = false;

        for (i = begin; i < end; i++) {
            if (i == fixed_index) {
                continue;
            }
            saw_payload = true;
            if (serial[i] != placeholders[placeholder_index]) {
                all_same = false;
                break;
            }
        }
        if (saw_payload && all_same) {
            return true;
        }
    }
    return false;
}

static bool vmate_nvme_serial_samsung(const char *serial)
{
    size_t i;

    if (strlen(serial) != 15 || serial[0] != 'S' || serial[4] != 'N') {
        return false;
    }
    for (i = 1; i < 15; i++) {
        if (i != 4 && !g_ascii_isupper(serial[i]) &&
            !g_ascii_isdigit(serial[i])) {
            return false;
        }
    }
    return !vmate_nvme_payload_is_placeholder(serial, 1, 15, 4);
}

static bool vmate_nvme_serial_intel(const char *serial)
{
    size_t i;

    /*
     * 多个公开的 760p 512GB 实机样本均为 BTHH、八位大写字母数字和容量
     * 后缀 512D；公开的 256GB 样本则以 256B 结尾。该规则只是实机样本
     * 外形，不声称是 Intel 官方序列分配语法。
     */
    if (strlen(serial) != 16 || strncmp(serial, "BTHH", 4) ||
        strcmp(serial + 12, "512D")) {
        return false;
    }
    for (i = 4; i < 12; i++) {
        if (!g_ascii_isupper(serial[i]) && !g_ascii_isdigit(serial[i])) {
            return false;
        }
    }
    return !vmate_nvme_payload_is_placeholder(serial, 4, 12, SIZE_MAX);
}

static bool vmate_nvme_serial_alnum12(const char *serial)
{
    size_t i;

    /*
     * WD PC SN730 与 KIOXIA XG6 的公开样本都能确认十二位大写字母数字形态，
     * 但 WD 手册同时允许厂商可变 ASCII，因此这里只验证共同的保守子集。
     */
    if (strlen(serial) != 12) {
        return false;
    }
    for (i = 0; i < 12; i++) {
        if (!g_ascii_isupper(serial[i]) && !g_ascii_isdigit(serial[i])) {
            return false;
        }
    }
    return !vmate_nvme_payload_is_placeholder(serial, 0, 12, SIZE_MAX);
}

static bool vmate_nvme_serial_valid(const VmateNvmeIdentityEntry *entry,
                                    const char *serial)
{
    if (!serial) {
        return false;
    }
    switch (entry->serial_kind) {
    case VMATE_NVME_SERIAL_SAMSUNG_970_PRO:
        return vmate_nvme_serial_samsung(serial);
    case VMATE_NVME_SERIAL_INTEL_760P:
        return vmate_nvme_serial_intel(serial);
    case VMATE_NVME_SERIAL_ALNUM12:
        return vmate_nvme_serial_alnum12(serial);
    default:
        return false;
    }
}

bool vmate_nvme_identity_validate(const VmateNvmeIdentity *identity,
                                  const char *model,
                                  const char *firmware,
                                  const char *serial,
                                  uint16_t subsystem_vendor,
                                  uint16_t subsystem_device,
                                  Error **errp)
{
    const VmateNvmeIdentityEntry *entry =
        vmate_nvme_identity_entry(identity);

    if (!entry) {
        error_setg(errp, "unknown VMate NVMe identity profile");
        return false;
    }
    if (!model || strcmp(model, identity->model)) {
        error_setg(errp, "model-number does not match NVMe identity '%s' "
                         "(expected '%s')", identity->id, identity->model);
        return false;
    }
    if (!firmware || strcmp(firmware, identity->firmware)) {
        error_setg(errp, "firmware-rev does not match NVMe identity '%s' "
                         "(expected '%s')", identity->id, identity->firmware);
        return false;
    }
    if (!vmate_nvme_serial_valid(entry, serial)) {
        error_setg(errp, "serial does not match vendor format for NVMe "
                         "identity '%s'", identity->id);
        return false;
    }
    if (subsystem_vendor &&
        subsystem_vendor != identity->subsystem_vendor) {
        error_setg(errp, "subsys-vendor-id must be 0x%04x for NVMe identity "
                         "'%s'", identity->subsystem_vendor, identity->id);
        return false;
    }
    if (subsystem_device && subsystem_device != identity->subsystem_device) {
        error_setg(errp, "subsys-id must be 0x%04x for NVMe identity '%s'",
                   identity->subsystem_device, identity->id);
        return false;
    }
    return true;
}
