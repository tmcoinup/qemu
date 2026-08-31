#!/usr/bin/env python3
"""Apply the audited Linux 6.8 compatibility delta to GRID host R535.161.05."""

from __future__ import annotations

import argparse
import hashlib
import os
import stat
import sys
import tempfile
from pathlib import Path


PRISTINE_SHA256 = {
    "conftest.sh": "4e1d7009462d800339801c6e4029e225a531409124d0574f88423856c8024682",
    "nvidia/nv-pci.c": "7e17739d773b7fce1af2cca8babb67c2ee1b8357e7b31dc0d7e5901298e93863",
    "nvidia/nvidia.Kbuild": "b56c73c1dcda951440e8e3258ae949e427b57987ec457e601e5311d997e16bc2",
    "nvidia-vgpu-vfio/nvidia-vgpu-vfio.Kbuild": "615ec37048bac0ac8fe45dbbf6160a80915795d8119889c48ac716bb5a08b019",
    "nvidia-vgpu-vfio/nvidia-vgpu-vfio.c": "0ffd4d05e966973b4bdf0367d158e78395b520c448e12bf8c46eee3ebcf83b6f",
    "nvidia-vgpu-vfio/vgpu-vfio-mdev.c": "0a50099cf62b6f058b473d27f5cb8ac041896eee2ec4889f6e1a37758dce83ec",
    "nvidia-vgpu-vfio/vgpu-vfio-pci-core.c": "25870c023777baaef1a24004bae9d6112baf483a5d57fa70d8fa438b4e2bc18a",
}

# Filled with hashes produced from the exact vGPU 16.4 DEB after every audited
# replacement below.  Keeping both maps makes the operation idempotent while
# rejecting a partly patched or locally modified proprietary source tree.
PATCHED_SHA256 = {
    "conftest.sh": "55d12131fbe924873548a49e452241c1dff77c2f4fb488ddce471483f465c6d5",
    "nvidia/nv-pci.c": "98b2d287f987b66ec37917f0ba58c3486e52a53a00acd90b7da7259f463d797d",
    "nvidia/nvidia.Kbuild": "513b373e37617a0af04c2a0ea3b1c948af3ae3d277a26d4172e364f0b4e831ba",
    "nvidia-vgpu-vfio/nvidia-vgpu-vfio.Kbuild": "6b86d471b5488fdf363cc48e293e0b37d381d88ff330cc569606bf1093abe2a3",
    "nvidia-vgpu-vfio/nvidia-vgpu-vfio.c": "71766a933af2a3a834aadf53efeeaba6a87909c731053fda35f248c5d24936f1",
    "nvidia-vgpu-vfio/vgpu-vfio-mdev.c": "0875569c60e433b6d8e542c574a6ff72f262f99d0294d81bc3196e03a9d9ab1a",
    "nvidia-vgpu-vfio/vgpu-vfio-pci-core.c": "5ede0ce9a8d53d71143896abf44dbec46f18a10fc769de867460f5c11973936f",
}


DETACH_IOAS_CONFTEST = r'''
        vfio_device_ops_has_detach_ioas)
            #
            # Determine if 'vfio_device_ops' struct has 'detach_ioas' field.
            #
            # Added by commit 9048c7341c4d ("vfio-iommufd: Add detach_ioas
            # support for physical VFIO devices") in v6.8.
            #
            CODE="
            #include <linux/pci.h>
            #include <linux/vfio.h>
            int conftest_vfio_device_ops_has_detach_ioas(void) {
                return offsetof(struct vfio_device_ops, detach_ioas);
            }"

            compile_check_conftest "$CODE" "NV_VFIO_DEVICE_OPS_HAS_DETACH_IOAS" "" "types"
        ;;
'''

LINUX68_CONFTESTS = r'''
        bus_type_has_iommu_ops)
            #
            # Determine if 'bus_type' still has the removed 'iommu_ops' field.
            #
            CODE="
            #include <linux/device.h>
            int conftest_bus_type_has_iommu_ops(void) {
                return offsetof(struct bus_type, iommu_ops);
            }"

            compile_check_conftest "$CODE" "NV_BUS_TYPE_HAS_IOMMU_OPS" "" "types"
        ;;

        eventfd_signal_has_counter_arg)
            #
            # Linux 6.8 removed the eventfd_signal() counter argument.
            #
            CODE="
            #include <linux/eventfd.h>
            void conftest_eventfd_signal_has_counter_arg(void) {
                struct eventfd_ctx *ctx;
                eventfd_signal(ctx, 1);
            }"

            compile_check_conftest "$CODE" "NV_EVENTFD_SIGNAL_HAS_COUNTER_ARG" "" "types"
        ;;
'''


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise ValueError(f"{label}: expected one source anchor, found {count}")
    return text.replace(old, new, 1)


def patch_conftest(text: str) -> str:
    text = replace_once(
        text,
        "\n        pci_irq_vector_helpers)\n",
        f"\n{DETACH_IOAS_CONFTEST}\n        pci_irq_vector_helpers)\n",
        "vfio detach_ioas conftest",
    )
    text = replace_once(
        text,
        "\n        drm_available)\n",
        f"\n{LINUX68_CONFTESTS}\n        drm_available)\n",
        "Linux 6.8 conftests",
    )
    old_vmap = r'''            # Determine if drm_gem_object_funcs::vmap takes 'map'
            # argument of 'struct dma_buf_map' type.
            #
            # The commit 49a3f51dfeee ("drm/gem: Use struct dma_buf_map in GEM
            # vmap ops and convert GEM backends") update
            # drm_gem_object_funcs::vmap to take 'map' argument.
            #
            CODE="
            #include <drm/drm_gem.h>
            int conftest_drm_gem_object_vmap_has_map_arg(
                    struct drm_gem_object *obj, struct dma_buf_map *map) {
                return obj->funcs->vmap(obj, map);
            }"
'''
    new_vmap = r'''            # Determine whether drm_gem_object_funcs::vmap takes a map argument.
            # The map type changed from dma_buf_map to iosys_map in Linux 5.18;
            # passing NULL avoids binding this compile probe to either spelling.
            #
            CODE="
            #include <drm/drm_gem.h>
            int conftest_drm_gem_object_vmap_has_map_arg(
                    struct drm_gem_object *obj) {
                return obj->funcs->vmap(obj, NULL);
            }"
'''
    text = replace_once(text, old_vmap, new_vmap, "DRM GEM vmap conftest")
    text = replace_once(
        text,
        """            if (test_configuration_option ${iommu} || test_configuration_option ${iommu}_MODULE); then
                VFIO_IOMMU_PRESENT=1
            fi

            if (test_configuration_option ${mdev} || test_configuration_option ${mdev}_MODULE); then
""",
        """            if (test_configuration_option ${iommu} || test_configuration_option ${iommu}_MODULE); then
                VFIO_IOMMU_PRESENT=1
            fi
            if [ "$ARCH" = "x86" ]; then
                ARCH="x86_64"
            fi

            if (test_configuration_option ${mdev} || test_configuration_option ${mdev}_MODULE); then
""",
        "x86_64 vGPU sanity check",
    )
    return text


def patch_nvidia_kbuild(text: str) -> str:
    return replace_once(
        text,
        "NV_CONFTEST_TYPE_COMPILE_TESTS += memory_failure_has_trapno_arg\n",
        "NV_CONFTEST_TYPE_COMPILE_TESTS += memory_failure_has_trapno_arg\n"
        "NV_CONFTEST_TYPE_COMPILE_TESTS += bus_type_has_iommu_ops\n",
        "nvidia bus_type conftest list",
    )


def patch_nv_pci(text: str) -> str:
    text = replace_once(
        text,
        """#if defined(NV_SEQ_READ_ITER_PRESENT)
#include <linux/seq_file.h>
#include <linux/kernfs.h>
#endif

static void
""",
        """#if defined(NV_SEQ_READ_ITER_PRESENT)
#include <linux/seq_file.h>
#include <linux/kernfs.h>
#endif

#if !defined(NV_BUS_TYPE_HAS_IOMMU_OPS)
#include <linux/iommu.h>
#endif

static void
""",
        "Linux 6.8 IOMMU include",
    )
    return replace_once(
        text,
        "        if (pci_dev->dev.bus->iommu_ops == NULL) \n"
        "        {\n",
        """#if defined(NV_BUS_TYPE_HAS_IOMMU_OPS)
        if (pci_dev->dev.bus->iommu_ops == NULL)
#else
        if ((pci_dev->dev.iommu != NULL) && (pci_dev->dev.iommu->iommu_dev != NULL) &&
            (pci_dev->dev.iommu->iommu_dev->ops == NULL))
#endif
        {
""",
        "Linux 6.8 IOMMU operation lookup",
    )


def patch_vgpu_kbuild(text: str) -> str:
    text = replace_once(
        text,
        "NV_CONFTEST_TYPE_COMPILE_TESTS     += vfio_device_ops_has_bind_iommufd\n",
        "NV_CONFTEST_TYPE_COMPILE_TESTS     += vfio_device_ops_has_bind_iommufd\n"
        "NV_CONFTEST_TYPE_COMPILE_TESTS     += vfio_device_ops_has_detach_ioas\n",
        "vGPU detach_ioas conftest list",
    )
    return replace_once(
        text,
        "NV_CONFTEST_TYPE_COMPILE_TESTS     += vfio_precopy_info\n",
        "NV_CONFTEST_TYPE_COMPILE_TESTS     += vfio_precopy_info\n"
        "NV_CONFTEST_TYPE_COMPILE_TESTS     += eventfd_signal_has_counter_arg\n",
        "vGPU eventfd conftest list",
    )


def patch_mdev_ops(text: str) -> str:
    anchor = """#if defined(NV_VFIO_DEVICE_OPS_HAS_BIND_IOMMUFD)
    .bind_iommufd   = vfio_iommufd_emulated_bind,
    .unbind_iommufd = vfio_iommufd_emulated_unbind,
    .attach_ioas    = vfio_iommufd_emulated_attach_ioas,
#endif
};
"""
    replacement = anchor.replace(
        "#endif\n};",
        "#endif\n#if defined(NV_VFIO_DEVICE_OPS_HAS_DETACH_IOAS)\n"
        "    .detach_ioas    = vfio_iommufd_emulated_detach_ioas,\n#endif\n};",
    )
    return replace_once(text, anchor, replacement, "mdev detach_ioas operation")


def patch_pci_ops(text: str) -> str:
    anchor = """#if defined(NV_VFIO_DEVICE_OPS_HAS_BIND_IOMMUFD)
    .bind_iommufd = vfio_iommufd_physical_bind,
    .unbind_iommufd = vfio_iommufd_physical_unbind,
    .attach_ioas = vfio_iommufd_physical_attach_ioas,
#endif
};
"""
    replacement = anchor.replace(
        "#endif\n};",
        "#endif\n#if defined(NV_VFIO_DEVICE_OPS_HAS_DETACH_IOAS)\n"
        "    .detach_ioas = vfio_iommufd_physical_detach_ioas,\n#endif\n};",
    )
    return replace_once(text, anchor, replacement, "physical detach_ioas operation")


def patch_vgpu_source(text: str) -> str:
    eventfd = """#if defined(NV_EVENTFD_SIGNAL_HAS_COUNTER_ARG)
        eventfd_signal(trigger, 1);
#else
        eventfd_signal(trigger);
#endif"""
    text = replace_once(
        text,
        "        eventfd_signal(trigger, 1);",
        eventfd,
        "MSI-X eventfd signature",
    )
    status_anchor = """    NV_SPIN_UNLOCK_IRQRESTORE(&vgpu_dev->intr_info_lock, eflags);

    eventfd_signal(trigger, 1);

    return status;
"""
    status_replacement = status_anchor.replace(
        "    eventfd_signal(trigger, 1);",
        eventfd.replace("        ", "    ", 1),
    )
    text = replace_once(
        text,
        status_anchor,
        status_replacement,
        "MSI/INTx eventfd signature",
    )
    return replace_once(
        text,
        'MODULE_VERSION(NV_VERSION_STRING);\n#if defined(NV_VGPU_KVM_BUILD)',
        'MODULE_VERSION(NV_VERSION_STRING);\n\n'
        '#if defined(MODULE_IMPORT_NS)\nMODULE_IMPORT_NS(IOMMUFD);\n#endif\n\n'
        '#if defined(NV_VGPU_KVM_BUILD)',
        "IOMMUFD namespace import",
    )


PATCHERS = {
    "conftest.sh": patch_conftest,
    "nvidia/nv-pci.c": patch_nv_pci,
    "nvidia/nvidia.Kbuild": patch_nvidia_kbuild,
    "nvidia-vgpu-vfio/nvidia-vgpu-vfio.Kbuild": patch_vgpu_kbuild,
    "nvidia-vgpu-vfio/nvidia-vgpu-vfio.c": patch_vgpu_source,
    "nvidia-vgpu-vfio/vgpu-vfio-mdev.c": patch_mdev_ops,
    "nvidia-vgpu-vfio/vgpu-vfio-pci-core.c": patch_pci_ops,
}


def atomic_write(path: Path, content: str) -> None:
    mode = stat.S_IMODE(path.stat().st_mode)
    fd, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary_name, mode)
        os.replace(temporary_name, path)
    finally:
        try:
            os.unlink(temporary_name)
        except FileNotFoundError:
            pass


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("source_root", type=Path)
    args = parser.parse_args()
    root = args.source_root
    if not root.is_absolute() or root.is_symlink() or not root.is_dir():
        parser.error("source_root must be an absolute, non-symlink directory")

    paths = {relative: root / relative for relative in PRISTINE_SHA256}
    for relative, path in paths.items():
        if path.is_symlink() or not path.is_file():
            raise SystemExit(f"unsafe or missing R535 source file: {relative}")
    actual = {relative: sha256(path) for relative, path in paths.items()}
    if actual == PATCHED_SHA256:
        print("R535 Linux 6.8 compatibility patch already applied")
        return 0
    if actual != PRISTINE_SHA256:
        for relative in sorted(actual):
            if actual[relative] != PRISTINE_SHA256[relative]:
                print(
                    f"unexpected pristine hash {relative}: {actual[relative]}",
                    file=sys.stderr,
                )
        return 1

    rendered: dict[str, str] = {}
    try:
        for relative, patcher in PATCHERS.items():
            rendered[relative] = patcher(paths[relative].read_text(encoding="utf-8"))
    except ValueError as error:
        print(f"R535 Linux 6.8 compatibility patch refused: {error}", file=sys.stderr)
        return 1
    for relative, content in rendered.items():
        atomic_write(paths[relative], content)

    final = {relative: sha256(path) for relative, path in paths.items()}
    for relative in sorted(final):
        print(f"{final[relative]}  {relative}")
    if final != PATCHED_SHA256:
        print("patched hashes do not match the audited contract", file=sys.stderr)
        return 1
    print("R535 Linux 6.8 compatibility patch applied and verified")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
