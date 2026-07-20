#!/usr/bin/env python3
"""行为测试：离线 signed-driver-package 只能安全恢复缺失发布 INF。"""

from __future__ import annotations

import importlib.util
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import textwrap
from pathlib import Path


TEST_DIR = Path(__file__).resolve().parent
REPO_ROOT = TEST_DIR.parents[2]
HELPER = REPO_ROOT / 'deploy/scripts/lib/signed-driver-package.py'
STOCK_DIR = REPO_ROOT / 'deploy/scripts/stock-viogpudo'
CATROOT_GUID = '{F750E6C3-38EE-11D1-85E5-00C04FC295EE}'


def fail(message: str) -> None:
    raise AssertionError(message)


def require(condition: bool, message: str) -> None:
    if not condition:
        fail(message)


def write_fake_hivex(module_dir: Path) -> None:
    """提供 helper 实际访问的最小 SYSTEM hive 契约。"""

    module_dir.mkdir(parents=True, exist_ok=True)
    (module_dir / 'hivex.py').write_text(
        textwrap.dedent(
            '''\
            VALUES = {
                (('Select',), 'Current'): 1,
                (('ControlSet001', 'Enum', 'PCI',
                  'VEN_1AF4&DEV_1050', 'INSTANCE'), 'Service'): 'VioGpuDod',
                (('ControlSet001', 'Enum', 'PCI',
                  'VEN_1AF4&DEV_1050', 'INSTANCE'), 'Driver'):
                    '{4d36e968-e325-11ce-bfc1-08002be10318}\\\\0000',
                (('ControlSet001', 'Control', 'Class',
                  '{4d36e968-e325-11ce-bfc1-08002be10318}', '0000'),
                 'InfPath'): 'oem42.inf',
                (('ControlSet001', 'Control', 'Class',
                  '{4d36e968-e325-11ce-bfc1-08002be10318}', '0000'),
                 'InfSection'): 'VioGpuDod_Inst',
                (('ControlSet001', 'Control', 'Class',
                  '{4d36e968-e325-11ce-bfc1-08002be10318}', '0000'),
                 'DriverVersion'): '100.101.104.28500',
            }

            NODES = {
                (): ('Select', 'ControlSet001'),
                ('Select',): (),
                ('ControlSet001',): ('Enum', 'Control'),
                ('ControlSet001', 'Enum'): ('PCI',),
                ('ControlSet001', 'Enum', 'PCI'): ('VEN_1AF4&DEV_1050',),
                ('ControlSet001', 'Enum', 'PCI', 'VEN_1AF4&DEV_1050'):
                    ('INSTANCE',),
                ('ControlSet001', 'Enum', 'PCI',
                 'VEN_1AF4&DEV_1050', 'INSTANCE'): (),
                ('ControlSet001', 'Control'): ('Class',),
                ('ControlSet001', 'Control', 'Class'):
                    ('{4d36e968-e325-11ce-bfc1-08002be10318}',),
                ('ControlSet001', 'Control', 'Class',
                 '{4d36e968-e325-11ce-bfc1-08002be10318}'): ('0000',),
                ('ControlSet001', 'Control', 'Class',
                 '{4d36e968-e325-11ce-bfc1-08002be10318}', '0000'): (),
            }

            class Hivex:
                def __init__(self, _path):
                    pass

                def root(self):
                    return ()

                def node_get_child(self, node, name):
                    candidate = node + (name,)
                    return candidate if candidate in NODES else None

                def node_get_value(self, node, name):
                    key = (node, name)
                    return key if key in VALUES else None

                def value_string(self, value):
                    return VALUES[value]

                def value_dword(self, value):
                    return VALUES[value]

                def node_children(self, node):
                    return [node + (name,) for name in NODES[node]]

                def node_name(self, node):
                    return node[-1]
            '''
        ),
        encoding='utf-8',
    )


def copy_stock_file(name: str, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(STOCK_DIR / name, destination)


def create_fixture(root: Path) -> tuple[dict[str, str], Path, bytes]:
    windows = root / 'Windows'
    inf_dir = windows / 'INF'
    inf_dir.mkdir(parents=True)
    copy_stock_file('viogpudo.cat', windows / 'System32/CatRoot' /
                    CATROOT_GUID / 'oem42.cat')
    copy_stock_file('viogpudo.sys', windows / 'System32/drivers/viogpudo.sys')
    repository = (
        windows / 'System32/DriverStore/FileRepository' /
        'viogpudo.inf_amd64_fixture'
    )
    for name in ('viogpudo.inf', 'viogpudo.cat', 'viogpudo.sys'):
        copy_stock_file(name, repository / name)

    module_dir = root / 'fake-hivex'
    write_fake_hivex(module_dir)
    env = os.environ.copy()
    env.update({
        'HIVE': str(root / 'SYSTEM'),
        'WINDOWS_ROOT': str(windows),
        'STOCK_INF': str(STOCK_DIR / 'viogpudo.inf'),
        'STOCK_CAT': str(STOCK_DIR / 'viogpudo.cat'),
        'STOCK_SYS': str(STOCK_DIR / 'viogpudo.sys'),
        'SUBSYS_RE': r'^VEN_1AF4&DEV_1050',
        'PYTHONPATH': str(module_dir) + os.pathsep + env.get('PYTHONPATH', ''),
    })
    return env, inf_dir / 'oem42.inf', (STOCK_DIR / 'viogpudo.inf').read_bytes()


def run_helper(env: dict[str, str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(HELPER)],
        cwd=REPO_ROOT,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )


def require_success(result: subprocess.CompletedProcess[str], label: str) -> None:
    require(result.returncode == 0, f'{label} failed:\n{result.stdout}')


def test_missing_inf_is_restored() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        env, published, stock_inf = create_fixture(root)
        result = run_helper(env)
        require_success(result, 'missing INF recovery')
        require(published.read_bytes() == stock_inf, 'recovered INF bytes differ')
        require(not published.is_symlink(), 'recovered INF must not be a link')
        source_mode = stat.S_IMODE((STOCK_DIR / 'viogpudo.inf').stat().st_mode)
        target_mode = stat.S_IMODE(published.stat().st_mode)
        require(target_mode == source_mode, 'recovered INF mode must match stock')


def test_existing_trusted_inf_is_not_replaced() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        env, published, stock_inf = create_fixture(root)
        published.write_bytes(stock_inf)
        os.utime(published, ns=(1_700_000_000_000_000_000,) * 2)
        original_mtime = published.stat().st_mtime_ns
        result = run_helper(env)
        require_success(result, 'trusted INF verification')
        require(published.read_bytes() == stock_inf, 'trusted INF was changed')
        require(published.stat().st_mtime_ns == original_mtime,
                'trusted INF mtime was changed')


def test_existing_bad_inf_is_unchanged() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        env, published, _ = create_fixture(root)
        bad_payload = b'not a signed INF\n'
        published.write_bytes(bad_payload)
        result = run_helper(env)
        require(result.returncode != 0, 'bad INF must fail closed')
        require(published.read_bytes() == bad_payload,
                'bad INF must not be overwritten')


def test_dry_run_never_creates_an_inf() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        env, published, _ = create_fixture(root)
        env['DRY_RUN'] = '1'
        result = run_helper(env)
        require_success(result, 'dry-run missing INF check')
        require(not published.exists(), 'dry-run created a published INF')


def test_link_or_directory_is_not_treated_as_missing() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        env, published, _ = create_fixture(root)
        published.symlink_to('absent.inf')
        result = run_helper(env)
        require(result.returncode != 0, 'dangling link must fail closed')
        require(published.is_symlink(), 'dangling link was overwritten')

    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        env, published, _ = create_fixture(root)
        published.mkdir()
        result = run_helper(env)
        require(result.returncode != 0, 'directory target must fail closed')
        require(published.is_dir(), 'directory target was replaced')


def test_parent_directory_link_is_not_followed() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        env, published, _ = create_fixture(root)
        inf_directory = published.parent
        redirected_directory = root / 'outside-windows-root'
        inf_directory.rmdir()
        redirected_directory.mkdir()
        inf_directory.symlink_to(redirected_directory, target_is_directory=True)
        result = run_helper(env)
        require(result.returncode != 0,
                'parent INF link must fail closed')
        require(inf_directory.is_symlink(), 'parent INF link was replaced')
        require(not (redirected_directory / published.name).exists(),
                'published INF escaped the Windows root through parent link')


def load_helper_for_publish_test(root: Path):
    env, _, _ = create_fixture(root)
    original = {name: os.environ.get(name) for name in env}
    os.environ.update(env)
    module_dir = Path(env['PYTHONPATH'].split(os.pathsep, 1)[0])
    sys.path.insert(0, str(module_dir))
    try:
        spec = importlib.util.spec_from_file_location(
            'signed_driver_package_publish_test', HELPER
        )
        require(spec is not None and spec.loader is not None,
                'cannot load signed-driver-package helper')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module, original
    finally:
        sys.path.pop(0)


def restore_environment(original: dict[str, str | None]) -> None:
    for name, value in original.items():
        if value is None:
            os.environ.pop(name, None)
        else:
            os.environ[name] = value


def test_publish_does_not_replace_a_racing_target() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        module, original = load_helper_for_publish_test(root)
        try:
            target = root / 'race.inf'
            original_payload = b'pre-existing target\n'
            target.write_bytes(original_payload)
            try:
                module.publish_missing_inf(target, b'new payload\n', 0o644)
            except RuntimeError as exc:
                require('appeared while restoring' in str(exc),
                        f'unexpected no-replace failure: {exc}')
            else:
                fail('publish must not replace a target created by another writer')
            require(target.read_bytes() == original_payload,
                    'no-replace publish overwrote an existing target')
        finally:
            restore_environment(original)


def main() -> int:
    test_missing_inf_is_restored()
    test_existing_trusted_inf_is_not_replaced()
    test_existing_bad_inf_is_unchanged()
    test_dry_run_never_creates_an_inf()
    test_link_or_directory_is_not_treated_as_missing()
    test_parent_directory_link_is_not_followed()
    test_publish_does_not_replace_a_racing_target()
    print('OK: signed-driver package recovery is fail-closed and no-replace')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
