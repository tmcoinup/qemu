#!/usr/bin/env bash
# 静态验证 QEMU 11.0.2 构建工具契约，不执行 configure、编译或补丁写入。
# shellcheck disable=SC2016 # 本文件刻意匹配生产脚本中的 shell 变量字面量。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
BUILD_SCRIPT="$REPO_ROOT/deploy/tools/build.sh"
PATCH_SCRIPT="$REPO_ROOT/deploy/tools/apply-patches.sh"
OVMF_BUILD_SCRIPT="$REPO_ROOT/deploy/tools/build-ovmf.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

require_text() {
    local needle="$1"
    local file="$2"

    grep -F -- "$needle" "$file" >/dev/null \
        || fail "缺少 '$needle': $file"
}

reject_text() {
    local needle="$1"
    local file="$2"

    if grep -F -- "$needle" "$file" >/dev/null; then
        fail "不应再出现 '$needle': $file"
    fi
}

test_shell_syntax() {
    bash -n "$BUILD_SCRIPT"
    bash -n "$PATCH_SCRIPT"
    bash -n "$OVMF_BUILD_SCRIPT"
}

test_qemu_11_baseline_and_werror() {
    require_text 'EXPECTED_QEMU_VERSION="11.0.2"' "$BUILD_SCRIPT"
    require_text '--enable-werror' "$BUILD_SCRIPT"
    reject_text '--disable-werror' "$BUILD_SCRIPT"
    reject_text 'QEMU 9.2.0' "$BUILD_SCRIPT"
    reject_text 'qemu-9.2.0' "$BUILD_SCRIPT"
}

test_python_preflight_contract() {
    # 中文注释：只检查预检代码存在，不在静态测试中创建 pyvenv 或联网下载。
    require_text 'find_spec("venv")' "$BUILD_SCRIPT"
    require_text 'find_spec("ensurepip")' "$BUILD_SCRIPT"
    require_text '"setuptools": (44, 1, 1)' "$BUILD_SCRIPT"
    require_text '"wheel": (0, 34, 2)' "$BUILD_SCRIPT"
    require_text 'python3-setuptools python3-wheel' "$BUILD_SCRIPT"
}

test_required_native_dependencies_are_preflighted() {
    require_text 'for tool in bzip2 ninja pkg-config python3' "$BUILD_SCRIPT"
    require_text 'for pkg in glib-2.0 pixman-1 zlib' "$BUILD_SCRIPT"
    require_text 'build-essential bzip2 ninja-build' "$BUILD_SCRIPT"
    require_text 'zlib1g-dev' "$BUILD_SCRIPT"
}

test_runtime_version_provenance() {
    require_text "git describe --match 'v*' --always --abbrev=10 HEAD" "$BUILD_SCRIPT"
    require_text 'git status --porcelain --untracked-files=all --' "$BUILD_SCRIPT"
    require_text ". ':(exclude)deploy'" "$BUILD_SCRIPT"
    require_text 'QEMU_RUNTIME_PKGVERSION="${QEMU_RUNTIME_PKGVERSION}-dirty"' \
        "$BUILD_SCRIPT"
    require_text 'CFG_FLAGS+=(--with-pkgversion="$QEMU_RUNTIME_PKGVERSION")' \
        "$BUILD_SCRIPT"
    require_text '"$MESON" configure . "-Dpkgversion=$QEMU_RUNTIME_PKGVERSION"' \
        "$BUILD_SCRIPT"
}

test_ovmf_basetools_preflight() {
    require_text 'BaseTools/Source/C/bin/VfrCompile' "$OVMF_BUILD_SCRIPT"
    require_text 'make -C "$EDK2/BaseTools"' "$OVMF_BUILD_SCRIPT"
    require_text 'BASETOOLS_CC="${CC:-gcc} -std=gnu17"' "$OVMF_BUILD_SCRIPT"
    reject_text 'BaseTools/BinWrappers/PosixLike/build' "$OVMF_BUILD_SCRIPT"
}

test_ovmf_nasm_version_preflight() {
    require_text 'check_nasm_version' "$OVMF_BUILD_SCRIPT"
    require_text '(major == 2 && minor < 15)' "$OVMF_BUILD_SCRIPT"
    require_text '(major == 3 && minor < 2)' "$OVMF_BUILD_SCRIPT"
    require_text '若使用 3.x 则需要 3.02+' "$OVMF_BUILD_SCRIPT"
}

test_cli_compatibility() {
    local help_output

    help_output="$("$BUILD_SCRIPT" --help)"
    for option in --clean --reconfig --debug --jobs --verify \
            --install-host-helpers --no-install-host-helpers; do
        grep -F -- "$option" <<<"$help_output" >/dev/null \
            || fail "--help 丢失既有选项 $option"
    done
}

test_host_helper_orchestration_contract() {
    # 中文注释：行为与失败顺序由独立隔离测试执行；这里保留关键安全字面门禁，
    # 防止后续重构重新依赖可由调用环境注入的测试安装根或隐式 QEMU 路径。
    require_text 'INSTALL_HOST_HELPERS="${INSTALL_HOST_HELPERS:-auto}"' "$BUILD_SCRIPT"
    require_text '"$setup" install "--qemu=$BIN"' "$BUILD_SCRIPT"
    require_text '"--expect-device=$QEMU_TRUST_DEVICE"' "$BUILD_SCRIPT"
    require_text '"--expect-inode=$QEMU_TRUST_INODE"' "$BUILD_SCRIPT"
    require_text '"--expect-sha256=$QEMU_TRUST_SHA256"' "$BUILD_SCRIPT"
    require_text '"$setup" check' "$BUILD_SCRIPT"
    require_text 'sudo -n -- "$@"' "$BUILD_SCRIPT"
    require_text 'host_helper_terminal_foreground' "$BUILD_SCRIPT"
    require_text 'host_helper_container_detected' "$BUILD_SCRIPT"
    reject_text 'sudo -n -- env ' "$BUILD_SCRIPT"
}

test_patch_script_validates_integrated_qemu11_features() {
    require_text 'shopt -s nullglob' "$PATCH_SCRIPT"
    require_text '[0-9][0-9][0-9][0-9]-*.patch' "$PATCH_SCRIPT"
    require_text 'check_integrated_feature "Samsung NVMe"' "$PATCH_SCRIPT"
    require_text 'check_integrated_feature "USB HID 身份属性"' "$PATCH_SCRIPT"
    # 中文注释：这里按字面检查 shell 变量，单引号是刻意的，不应展开。
    # shellcheck disable=SC2016
    require_text 'exec "$HERE/build.sh" "$@"' "$PATCH_SCRIPT"
    reject_text 'git apply "$p"' "$PATCH_SCRIPT"
    reject_text 'git checkout v9.2.0' "$PATCH_SCRIPT"
    # 中文注释：补丁文件本身仍是可审计的 QEMU 9.2.0 历史清单，因此脚本
    # 可以说明来源；测试禁止的是 checkout/git apply 等旧基线执行路径。
    require_text '以 QEMU 9.2.0 上下文保存，仅用于' "$PATCH_SCRIPT"
}

test_vmate_nsis_runtime_is_closed() {
    REPO_ROOT="$REPO_ROOT" python3 - <<'PY'
import importlib.util
import io
import os
import tempfile

root = os.environ["REPO_ROOT"]
spec = importlib.util.spec_from_file_location(
    "qemu_nsis", os.path.join(root, "scripts", "nsis.py")
)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

with tempfile.TemporaryDirectory() as staging:
    for name in module.VMATE_RUNTIME_BINARIES:
        open(os.path.join(staging, name), "wb").close()
    module.validate_vmate_runtime_binaries(staging)
    for missing in module.VMATE_RUNTIME_BINARIES:
        path = os.path.join(staging, missing)
        os.unlink(path)
        try:
            module.validate_vmate_runtime_binaries(staging)
        except RuntimeError as error:
            if missing not in str(error):
                raise SystemExit("missing binary was not named: " + missing)
        else:
            raise SystemExit("VMate staging accepted a missing binary: " + missing)
        open(path, "wb").close()

with tempfile.TemporaryDirectory() as staging:
    install_root = os.path.join(staging, "install")
    sysroot = os.path.join(staging, "sysroot")
    os.mkdir(install_root)
    os.mkdir(sysroot)
    fixture_paths = {
        "qemu-system-x86_64.exe": install_root,
        "libslirp-0.dll": install_root,
        "libglib-2.0-0.dll": sysroot,
        "broken.exe": install_root,
    }
    for name, directory in fixture_paths.items():
        open(os.path.join(directory, name), "wb").close()
    outputs = {
        "qemu-system-x86_64.exe": (
            "DLL Name: KERNEL32.dll\nDLL Name: libslirp-0.dll\n"
        ),
        "libslirp-0.dll": "DLL Name: libglib-2.0-0.dll\n",
        "libglib-2.0-0.dll": "DLL Name: api-ms-win-core-path-l1-1-0.dll\n",
        "broken.exe": "DLL Name: missing-third-party.dll\n",
    }
    original_check_output = module.subprocess.check_output

    def fake_check_output(command, text):
        if command[:2] != ["objdump", "-p"] or not text:
            raise AssertionError("unexpected objdump invocation")
        return outputs[os.path.basename(command[-1])]

    module.subprocess.check_output = fake_check_output
    try:
        index = module.build_dependency_index((install_root, sysroot))
        _, dependencies = module.find_deps(
            os.path.join(install_root, "qemu-system-x86_64.exe"),
            index,
            set(),
            strict=True,
        )
        names = {os.path.basename(path).casefold() for path in dependencies}
        expected = {
            "qemu-system-x86_64.exe",
            "libslirp-0.dll",
            "libglib-2.0-0.dll",
        }
        if names != expected:
            raise SystemExit("staging-root DLL closure was not collected")
        try:
            module.find_deps(
                os.path.join(install_root, "broken.exe"),
                index,
                set(),
                strict=True,
            )
        except RuntimeError as error:
            if "missing-third-party.dll" not in str(error):
                raise SystemExit("unresolved DLL was not named")
        else:
            raise SystemExit("VMate dependency closure accepted a missing DLL")
    finally:
        module.subprocess.check_output = original_check_output

nsh = io.StringIO()
mui = io.StringIO()
module.write_system_emulation_sections(
    ["/tmp/qemu-system-x86_64w.exe", "/tmp/qemu-system-x86_64.exe"],
    nsh,
    mui,
    True,
)
generated = nsh.getvalue()
required = 'Section "x86_64" Section_x86_64\n                SectionIn RO'
if required not in generated:
    raise SystemExit("VMate x86_64 NSIS section is not read-only")
gui = generated.split('Section "x86_64w" Section_x86_64w', 1)[1]
if "SectionIn RO" in gui:
    raise SystemExit("optional GUI emulator unexpectedly became read-only")
plain_nsh = io.StringIO()
module.write_system_emulation_sections(
    ["/tmp/qemu-system-x86_64.exe"], plain_nsh, io.StringIO(), False
)
if "SectionIn RO" in plain_nsh.getvalue():
    raise SystemExit("upstream x86_64 emulator unexpectedly became read-only")

with open(os.path.join(root, "qemu.nsi"), encoding="utf-8") as source:
    installer = source.read()
dll_section = installer.split(
    'Section "Libraries (DLL)" SectionDll', 1
)[1].split("SectionEnd", 1)[0]
if not (
    "!ifdef CONFIG_VMATE_RUNTIME" in dll_section
    and "SectionIn RO" in dll_section
):
    raise SystemExit("VMate DLL section is not read-only")
PY
}

test_shell_syntax
test_qemu_11_baseline_and_werror
test_python_preflight_contract
test_required_native_dependencies_are_preflighted
test_runtime_version_provenance
test_ovmf_basetools_preflight
test_ovmf_nasm_version_preflight
test_cli_compatibility
test_host_helper_orchestration_contract
test_patch_script_validates_integrated_qemu11_features
test_vmate_nsis_runtime_is_closed

echo "OK: QEMU 11.0.2 build tooling static checks passed"
