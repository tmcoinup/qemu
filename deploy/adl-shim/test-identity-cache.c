#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "adl_identity_cache.h"

struct fake_snapshot_source {
    enum adl_identity_state state;
    struct adl_gpu_identity identity;
    unsigned int calls;
};

static int g_failures;

static void expect(int condition, const char *message)
{
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message);
        ++g_failures;
    }
}

static enum adl_identity_state fake_loader(
    void *context, struct adl_gpu_identity *identity)
{
    struct fake_snapshot_source *source = context;

    ++source->calls;
    memset(identity, 0, sizeof(*identity));
    if (source->state == ADL_IDENTITY_PRESENT) {
        *identity = source->identity;
    }
    return source->state;
}

static void set_present(struct fake_snapshot_source *source,
                        const char *name, unsigned int device_id)
{
    memset(source, 0, sizeof(*source));
    source->state = ADL_IDENTITY_PRESENT;
    (void)snprintf(source->identity.name, sizeof(source->identity.name),
                   "%s", name);
    source->identity.pci_vendor_id = UINT32_C(0x1002);
    source->identity.pci_device_id = device_id;
    (void)snprintf(source->identity.carrier.instance_id,
                   sizeof(source->identity.carrier.instance_id),
                   "PCI\\VEN_1AF4&DEV_1050\\FAKE_%04X", device_id);
}

static void test_same_process_refresh(void)
{
    struct adl_identity_cache cache = ADL_IDENTITY_CACHE_INITIALIZER;
    struct fake_snapshot_source source;
    struct adl_gpu_identity identity;

    set_present(&source, "AMD Radeon RX 560", UINT32_C(0x67ff));
    expect(adl_identity_cache_initialize(&cache, fake_loader, &source) ==
               ADL_IDENTITY_PRESENT,
           "初始 AMD snapshot");
    expect(adl_identity_cache_copy(&cache, &identity) == ADL_IDENTITY_PRESENT &&
               strcmp(identity.name, "AMD Radeon RX 560") == 0,
           "初始 copy 必须可见");

    set_present(&source, "AMD Radeon RX 550", UINT32_C(0x699f));
    expect(adl_identity_cache_refresh(&cache, fake_loader, &source) ==
               ADL_IDENTITY_PRESENT,
           "同进程 pointer 切换后 Refresh 必须成功");
    expect(adl_identity_cache_copy(&cache, &identity) == ADL_IDENTITY_PRESENT &&
               identity.pci_device_id == UINT32_C(0x699f) &&
               strcmp(identity.name, "AMD Radeon RX 550") == 0,
           "Refresh 必须发布新 snapshot 而非 InitOnce 旧值");

    source.state = ADL_IDENTITY_INVALID;
    expect(adl_identity_cache_refresh(&cache, fake_loader, &source) ==
               ADL_IDENTITY_INVALID,
           "撕裂 snapshot 的 Refresh 必须失败");
    expect(adl_identity_cache_copy(&cache, &identity) == ADL_IDENTITY_PRESENT &&
               identity.pci_device_id == UINT32_C(0x699f),
           "失败 Refresh 不得丢失上一个已验证 snapshot");
}

static void test_initial_retry(void)
{
    struct adl_identity_cache cache = ADL_IDENTITY_CACHE_INITIALIZER;
    struct fake_snapshot_source source;
    struct adl_gpu_identity identity;
    unsigned int initial_calls;

    memset(&source, 0, sizeof(source));
    source.state = ADL_IDENTITY_INVALID;
    expect(adl_identity_cache_initialize(&cache, fake_loader, &source) ==
               ADL_IDENTITY_INVALID,
           "初始撕裂不得缓存为永久失败");
    initial_calls = source.calls;
    set_present(&source, "AMD Radeon RX 560", UINT32_C(0x67ff));
    source.calls = initial_calls;
    expect(adl_identity_cache_initialize(&cache, fake_loader, &source) ==
               ADL_IDENTITY_PRESENT,
           "初始失败后必须可重试");
    expect(source.calls == 2u &&
               adl_identity_cache_copy(&cache, &identity) ==
                   ADL_IDENTITY_PRESENT,
           "retry 必须读取并发布 snapshot");
}

int main(void)
{
    test_same_process_refresh();
    test_initial_retry();
    if (g_failures != 0) {
        fprintf(stderr, "FAIL: %d 个 identity cache 断言失败\n", g_failures);
        return EXIT_FAILURE;
    }
    puts("PASS: ADL identity refresh cache");
    return EXIT_SUCCESS;
}
