/*
 * fb-shm user-creatable QOM sidecar。
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 *
 * -object fb-shm 与窗口显示后端并存。对象只注册一次性 notifier，
 * 待 machine 初始化完成、图形 console 存在后再创建真实 DCL。
 */

#include "qemu/osdep.h"
#include "qemu/error-report.h"
#include "qemu/module.h"
#include "qom/object.h"
#include "qom/object_interfaces.h"
#include "system/system.h"
#include "fb-shm-internal.h"

/* ------------------------------------------------------------------ */
/* user-creatable QOM object  (-object fb-shm,id=...,...)              */
/*                                                                     */
/* Coexists with any -display backend (sdl/gtk/none/vnc).  Whereas the */
/* DisplayType path consumes the -display slot, this path is purely    */
/* additive: it registers a second DCL on the same primary console, so */
/* SDL can render to a window AND fb-shm exports raw frames.           */
/* ------------------------------------------------------------------ */

#define TYPE_FB_SHM_EXPORT "fb-shm"
OBJECT_DECLARE_SIMPLE_TYPE(FbShmExport, FB_SHM_EXPORT)

struct FbShmExport {
    Object parent;
    /* properties (set before complete()) */
    char *path;
    uint32_t x, y, width, height;
    uint32_t rate;
    bool cursor;
    /* runtime */
    Notifier machine_done_notifier;
    bool notifier_registered;
    bool deferred_pending;
    FbShmDisplay *display;
};

static void fb_shm_export_get_path(Object *obj, Visitor *v,
                                   const char *name, void *opaque,
                                   Error **errp)
{
    FbShmExport *o = FB_SHM_EXPORT(obj);
    visit_type_str(v, name, &o->path, errp);
}

static void fb_shm_export_set_path(Object *obj, Visitor *v,
                                   const char *name, void *opaque,
                                   Error **errp)
{
    FbShmExport *o = FB_SHM_EXPORT(obj);
    char *s = NULL;
    if (!visit_type_str(v, name, &s, errp)) return;
    g_free(o->path);
    o->path = s;
}

static void fb_shm_export_machine_done(Notifier *n, void *unused)
{
    FbShmExport *o = container_of(n, FbShmExport, machine_done_notifier);
    if (!o->deferred_pending) {
        return;
    }
    /*
     * 中文注释：machine-init notifier 是一次性延迟器。回调可能由 notifier
     * 遍历触发，也可能在 machine 已 ready 时由 add() 同步触发；两种情况都
     * 必须先从全局链表摘除，避免 object-del 后链表残留悬空节点。
     */
    if (o->notifier_registered) {
        qemu_remove_machine_init_done_notifier(&o->machine_done_notifier);
        o->notifier_registered = false;
    }
    o->deferred_pending = false;
    const char *id = object_get_canonical_path_component(OBJECT(o));
    FbShmConfig cfg = {
        .id          = id,
        .sock_path   = o->path,
        .x           = o->x,
        .y           = o->y,
        .w           = o->width,
        .h           = o->height,
        .rate        = o->rate,
        .blend_cursor = o->cursor,
    };
    Error *err = NULL;
    o->display = fb_shm_create(&cfg, &err);
    if (err) {
        /* machine_init_done notifiers can't propagate errors back to the
         * user, so warn loudly and let QEMU keep running. */
        warn_report_err(err);
    }
}

static void fb_shm_export_complete(UserCreatable *uc, Error **errp)
{
    /* Defer real registration until the machine has finished initialising,
     * because -object is parsed before VGA / virtio-gpu create their
     * consoles. */
    FbShmExport *o = FB_SHM_EXPORT(uc);
    if (o->deferred_pending || o->display) {
        error_setg(errp, "fb-shm: already realised");
        return;
    }
    o->machine_done_notifier.notify = fb_shm_export_machine_done;
    o->deferred_pending = true;
    o->notifier_registered = true;
    qemu_add_machine_init_done_notifier(&o->machine_done_notifier);
}

static bool fb_shm_export_can_be_deleted(UserCreatable *uc)
{
#if defined(_WIN32) && defined(CONFIG_OPENGL)
    FbShmExport *o = FB_SHM_EXPORT(uc);

    if (o->display &&
        (o->display->d3d_handoff_scheduled ||
         o->display->d3d_retiring || o->display->d3d_gl_blocked ||
         fb_shm_gpu_pending_active(&o->display->d3d_pending, NULL))) {
        /*
         * object-del 可稍后重试。
         * mutex 未安全收回时销毁 timer/backend，
         * 会留下回调或造成跨进程并发访问。
         */
        return false;
    }
#else
    (void)uc;
#endif
    return true;
}

static void fb_shm_export_instance_finalize(Object *obj)
{
    FbShmExport *o = FB_SHM_EXPORT(obj);
    if (o->notifier_registered) {
        qemu_remove_machine_init_done_notifier(&o->machine_done_notifier);
        o->notifier_registered = false;
    }
    o->deferred_pending = false;
    fb_shm_destroy(o->display);
    o->display = NULL;
    g_free(o->path);
}

/*
 * 中文注释：fb-shm 的 QOM 属性需要逐字段调用 uint32 visitor。这里用宏生成
 * 对称的 getter/setter，避免复制五组完全相同的访问逻辑；该做法与具体
 * QEMU 版本无关，也不会绕过 QEMU 11 的 visitor 类型检查。
 */

#define FB_SHM_UINT32_PROP(NAME, FIELD)                                       \
static void fb_shm_export_get_##FIELD(Object *obj, Visitor *v,                \
                                      const char *name, void *opaque,        \
                                      Error **errp) {                         \
    FbShmExport *o = FB_SHM_EXPORT(obj);                                       \
    visit_type_uint32(v, name, &o->FIELD, errp);                               \
}                                                                              \
static void fb_shm_export_set_##FIELD(Object *obj, Visitor *v,                \
                                      const char *name, void *opaque,        \
                                      Error **errp) {                         \
    FbShmExport *o = FB_SHM_EXPORT(obj);                                       \
    visit_type_uint32(v, name, &o->FIELD, errp);                               \
}

FB_SHM_UINT32_PROP("x",      x)
FB_SHM_UINT32_PROP("y",      y)
FB_SHM_UINT32_PROP("width",  width)
FB_SHM_UINT32_PROP("height", height)
FB_SHM_UINT32_PROP("rate",   rate)

static void fb_shm_export_get_cursor(Object *obj, Visitor *v,
                                     const char *name, void *opaque,
                                     Error **errp)
{
    FbShmExport *o = FB_SHM_EXPORT(obj);
    visit_type_bool(v, name, &o->cursor, errp);
}
static void fb_shm_export_set_cursor(Object *obj, Visitor *v,
                                     const char *name, void *opaque,
                                     Error **errp)
{
    FbShmExport *o = FB_SHM_EXPORT(obj);
    visit_type_bool(v, name, &o->cursor, errp);
}

static void fb_shm_export_class_init(ObjectClass *oc, const void *data)
{
    UserCreatableClass *ucc = USER_CREATABLE_CLASS(oc);
    ucc->complete = fb_shm_export_complete;
    ucc->can_be_deleted = fb_shm_export_can_be_deleted;

    object_class_property_add(oc, "path", "string",
                              fb_shm_export_get_path,
                              fb_shm_export_set_path, NULL, NULL);
    object_class_property_add(oc, "x", "uint32",
                              fb_shm_export_get_x,
                              fb_shm_export_set_x, NULL, NULL);
    object_class_property_add(oc, "y", "uint32",
                              fb_shm_export_get_y,
                              fb_shm_export_set_y, NULL, NULL);
    object_class_property_add(oc, "width", "uint32",
                              fb_shm_export_get_width,
                              fb_shm_export_set_width, NULL, NULL);
    object_class_property_add(oc, "height", "uint32",
                              fb_shm_export_get_height,
                              fb_shm_export_set_height, NULL, NULL);
    object_class_property_add(oc, "rate", "uint32",
                              fb_shm_export_get_rate,
                              fb_shm_export_set_rate, NULL, NULL);
    object_class_property_add(oc, "cursor", "bool",
                              fb_shm_export_get_cursor,
                              fb_shm_export_set_cursor, NULL, NULL);
}

static const TypeInfo fb_shm_export_info = {
    .name = TYPE_FB_SHM_EXPORT,
    .parent = TYPE_OBJECT,
    .class_init = fb_shm_export_class_init,
    .instance_size = sizeof(FbShmExport),
    .instance_finalize = fb_shm_export_instance_finalize,
    .interfaces = (InterfaceInfo[]) {
        { TYPE_USER_CREATABLE },
        { }
    }
};

static void fb_shm_export_register_types(void)
{
    type_register_static(&fb_shm_export_info);
}

type_init(fb_shm_export_register_types)
