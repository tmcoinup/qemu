"""Validate the installed viogpudo WHQL package and repair a missing oemN.inf.

The helper is intentionally separate from the raw SYSTEM-hive writer:

* every pinned and installed INF/CAT/SYS file must match a fixed digest;
* an existing published INF mismatch fails closed;
* only a missing published INF is recreated, using atomic no-replace publish;
* CAT, SYS and DriverStore content are never modified.
"""

import hashlib
import os
import re
import stat
import tempfile

import hivex


HIVE = os.environ['HIVE']
WINDOWS_ROOT = os.environ['WINDOWS_ROOT']
STOCK_INF = os.environ['STOCK_INF']
STOCK_CAT = os.environ['STOCK_CAT']
STOCK_SYS = os.environ['STOCK_SYS']
SUBSYS_RE = re.compile(os.environ['SUBSYS_RE'])
DRY_RUN = os.environ.get('DRY_RUN') == '1'

DISPLAY_CLASS = '{4d36e968-e325-11ce-bfc1-08002be10318}'
CATROOT_GUID = '{F750E6C3-38EE-11D1-85E5-00C04FC295EE}'
EXPECTED_VERSION = '100.101.104.28500'
EXPECTED_DIGESTS = {
    'inf': '48abd56644386e1f0d85c54cd64db93e62a4eb33bc7acb2613f237c6e1c6a0ee',
    'cat': 'b5122b2e060ec0c2f0157afcdc64c728ec31646819055c8b79ae3f4227472078',
    'sys': '04e873ad57387a518ad8ccae5116989c63170503c14b9cca0b2067e63876af89',
}


def get_regular_file_metadata(path, label, allow_missing=False):
    """Return lstat metadata for a plain file without following links.

    The helper runs as root against an offline Windows disk.  A dangling link,
    directory or unreadable entry is not equivalent to a missing published INF:
    treating it as missing could overwrite an unexpected filesystem object.
    """

    try:
        metadata = os.lstat(path)
    except FileNotFoundError:
        if allow_missing:
            return None
        raise RuntimeError(f'{label} missing: {path}') from None
    except OSError as exc:
        raise RuntimeError(f'{label} cannot be inspected: {path}: {exc}') from exc

    if not stat.S_ISREG(metadata.st_mode):
        raise RuntimeError(f'{label} is not a plain file: {path}')
    return metadata


def get_plain_directory_metadata(path, label):
    """Return lstat metadata for a directory without following links."""

    try:
        metadata = os.lstat(path)
    except FileNotFoundError as exc:
        raise RuntimeError(f'{label} missing: {path}') from exc
    except OSError as exc:
        raise RuntimeError(f'{label} cannot be inspected: {path}: {exc}') from exc
    if not stat.S_ISDIR(metadata.st_mode):
        raise RuntimeError(f'{label} is not a plain directory: {path}')
    return metadata


def get_windows_directory(*parts):
    """Resolve a fixed directory below Windows without crossing reparse paths."""

    if not os.path.isabs(WINDOWS_ROOT):
        raise RuntimeError(f'Windows root must be absolute: {WINDOWS_ROOT}')
    current = WINDOWS_ROOT
    root_metadata = get_plain_directory_metadata(current, 'Windows root')
    root_device = root_metadata.st_dev
    traversed = []
    for part in parts:
        if (not part or part in ('.', '..') or
                os.path.basename(part) != part):
            raise RuntimeError(f'invalid Windows directory component: {part!r}')
        traversed.append(part)
        current = os.path.join(current, part)
        label = 'Windows directory ' + '\\'.join(traversed)
        metadata = get_plain_directory_metadata(current, label)
        if metadata.st_dev != root_device:
            raise RuntimeError(f'{label} crosses the Windows filesystem: {current}')
    return current


def verified_payload(path, expected_digest, label):
    """Read one stable regular file and require its pinned SHA-256 digest."""

    expected_metadata = get_regular_file_metadata(path, label)
    flags = os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0)
    try:
        descriptor = os.open(path, flags)
    except FileNotFoundError as exc:
        raise RuntimeError(f'{label} missing: {path}') from exc
    except OSError as exc:
        raise RuntimeError(f'{label} cannot be read safely: {path}: {exc}') from exc

    try:
        with os.fdopen(descriptor, 'rb') as source:
            opened_metadata = os.fstat(source.fileno())
            if not stat.S_ISREG(opened_metadata.st_mode):
                raise RuntimeError(f'{label} is not a plain file: {path}')
            if (
                    expected_metadata.st_dev != opened_metadata.st_dev
                    or expected_metadata.st_ino != opened_metadata.st_ino):
                raise RuntimeError(f'{label} changed while being verified: {path}')
            payload = source.read()
    except OSError as exc:
        raise RuntimeError(f'{label} cannot be read safely: {path}: {exc}') from exc
    digest = hashlib.sha256(payload).hexdigest()
    if digest != expected_digest:
        raise RuntimeError(f'{label} digest mismatch: {digest}')
    return payload


def publish_missing_inf(published, payload, source_mode):
    """Publish a verified INF only when its destination is still absent.

    ``os.replace`` is atomic but can overwrite a name created after the
    initial absence check.  Hard-linking a fully fsynced temporary file is an
    atomic no-replace operation on the same offline NTFS volume.  Any race or
    unsupported filesystem fails closed instead of replacing an existing file.
    """

    inf_dir = os.path.dirname(published)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(
                mode='wb', dir=inf_dir, prefix='.stealthgpu-inf-',
                delete=False) as output:
            temporary = output.name
            output.write(payload)
            output.flush()
            os.fchmod(output.fileno(), source_mode)
            os.fsync(output.fileno())
        try:
            os.link(temporary, published, follow_symlinks=False)
        except FileExistsError as exc:
            raise RuntimeError(
                f'published INF appeared while restoring: {published}'
            ) from exc
        except OSError as exc:
            raise RuntimeError(
                f'cannot publish missing INF without replacing a file: '
                f'{published}: {exc}'
            ) from exc
    finally:
        if temporary is not None:
            try:
                os.unlink(temporary)
            except FileNotFoundError:
                pass

    # A directory fsync is not supported by all ntfs-3g builds.  The file has
    # already been fsynced before the atomic link, so lack of directory fsync
    # is not treated as a reason to undo a correctly published INF.
    directory_flags = os.O_RDONLY | getattr(os, 'O_DIRECTORY', 0)
    try:
        directory_descriptor = os.open(inf_dir, directory_flags)
    except OSError:
        return
    try:
        os.fsync(directory_descriptor)
    except OSError:
        pass
    finally:
        os.close(directory_descriptor)


def locate_active_inf():
    hive = hivex.Hivex(HIVE)
    root = hive.root()

    def walk(node, parts):
        for part in parts:
            node = hive.node_get_child(node, part)
            if node is None:
                return None
        return node

    def required_string(node, name, label):
        value = hive.node_get_value(node, name)
        if value is None:
            raise RuntimeError(f'{label} missing registry value {name}')
        text = hive.value_string(value)
        if not isinstance(text, str) or not text:
            raise RuntimeError(f'{label} has invalid registry value {name}')
        return text

    select = walk(root, ['Select'])
    current_value = None if select is None else hive.node_get_value(
        select, 'Current'
    )
    if current_value is None:
        raise RuntimeError('SYSTEM hive lacks Select\\Current')
    current = hive.value_dword(current_value)
    if current < 1 or current > 999:
        raise RuntimeError(f'SYSTEM Select\\Current is invalid: {current}')
    control_set = f'ControlSet{current:03d}'
    pci = walk(root, [control_set, 'Enum', 'PCI'])
    if pci is None:
        print(f'  {control_set}\\Enum\\PCI absent; signed package preflight skipped')
        return None

    active = []
    for vendor_node in hive.node_children(pci):
        vendor_name = hive.node_name(vendor_node)
        if not SUBSYS_RE.search(vendor_name):
            continue
        for instance_node in hive.node_children(vendor_node):
            service_value = hive.node_get_value(instance_node, 'Service')
            service = '' if service_value is None else hive.value_string(
                service_value
            )
            if service.casefold() != 'viogpudod':
                continue
            instance_name = hive.node_name(instance_node)
            label = f'{vendor_name}\\{instance_name}'
            driver_ref = required_string(instance_node, 'Driver', label)
            match = re.fullmatch(
                re.escape(DISPLAY_CLASS) + r'\\([0-9]{4})',
                driver_ref,
                re.IGNORECASE,
            )
            if match is None:
                raise RuntimeError(f'{label} has invalid Driver {driver_ref!r}')
            class_node = walk(
                root,
                [
                    control_set,
                    'Control',
                    'Class',
                    DISPLAY_CLASS,
                    match.group(1),
                ],
            )
            if class_node is None:
                raise RuntimeError(f'{label} active Display Class is missing')
            inf_path = required_string(class_node, 'InfPath', driver_ref)
            inf_section = required_string(class_node, 'InfSection', driver_ref)
            version = required_string(class_node, 'DriverVersion', driver_ref)
            if (
                    re.fullmatch(
                        r'oem[0-9]+\.inf', inf_path, re.IGNORECASE
                    ) is None
                    or inf_section.casefold() != 'viogpudod_inst'
                    or version != EXPECTED_VERSION):
                raise RuntimeError(
                    f'{driver_ref} unexpected INF state: '
                    f'{inf_path}/{inf_section}/{version}'
                )
            active.append((label, inf_path.casefold()))
    if len(active) != 1:
        raise RuntimeError(
            f'expected exactly one active VioGpuDod instance, got {active!r}'
        )
    print(f'  signed package target: {active[0][0]} / {active[0][1]}')
    return active[0][1]


def main():
    inf_path = locate_active_inf()
    if inf_path is None:
        return

    stock_inf = verified_payload(
        STOCK_INF, EXPECTED_DIGESTS['inf'], 'pinned viogpudo.inf'
    )
    verified_payload(
        STOCK_CAT, EXPECTED_DIGESTS['cat'], 'pinned viogpudo.cat'
    )
    verified_payload(
        STOCK_SYS, EXPECTED_DIGESTS['sys'], 'pinned viogpudo.sys'
    )

    inf_directory = get_windows_directory('INF')
    published = os.path.join(inf_directory, inf_path)
    published_metadata = get_regular_file_metadata(
        published, f'published {inf_path}', allow_missing=True
    )
    published_missing = published_metadata is None
    if not published_missing:
        verified_payload(
            published, EXPECTED_DIGESTS['inf'], f'published {inf_path}'
        )
        print(f'  published INF verified: {published}')

    cat_name = os.path.splitext(inf_path)[0] + '.cat'
    verified_payload(
        os.path.join(
            get_windows_directory('System32', 'CatRoot', CATROOT_GUID), cat_name
        ),
        EXPECTED_DIGESTS['cat'],
        f'installed catalog {cat_name}',
    )
    verified_payload(
        os.path.join(
            get_windows_directory('System32', 'drivers'), 'viogpudo.sys'
        ),
        EXPECTED_DIGESTS['sys'],
        'active viogpudo.sys',
    )

    repository_root = get_windows_directory(
        'System32', 'DriverStore', 'FileRepository'
    )
    matching_repositories = []
    for name in os.listdir(repository_root):
        if not name.casefold().startswith('viogpudo.inf_'):
            continue
        directory = get_windows_directory(
            'System32', 'DriverStore', 'FileRepository', name
        )
        try:
            for suffix, digest in EXPECTED_DIGESTS.items():
                verified_payload(
                    os.path.join(directory, f'viogpudo.{suffix}'),
                    digest,
                    f'DriverStore {name} {suffix.upper()}',
                )
        except RuntimeError:
            continue
        matching_repositories.append(name)
    if not matching_repositories:
        raise RuntimeError('no DriverStore viogpudo package matches pinned triad')
    print(
        '  signed payload verified: '
        + ', '.join(sorted(matching_repositories))
    )

    if not published_missing:
        return
    if DRY_RUN:
        print(f'  DRY_RUN: would restore missing {published}')
        return

    source_mode = stat.S_IMODE(
        get_regular_file_metadata(STOCK_INF, 'pinned viogpudo.inf').st_mode
    )
    publish_missing_inf(published, stock_inf, source_mode)
    verified_payload(
        published, EXPECTED_DIGESTS['inf'], f'published {inf_path}'
    )
    print(f'  published INF restored: {published} (was missing)')


if __name__ == '__main__':
    main()
