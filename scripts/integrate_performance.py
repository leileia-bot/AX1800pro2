#!/usr/bin/env python3
"""Integrate Arthur forwarding and USB RPS protections into OpenWrt source."""
import os
import pathlib
import sys


def replace_once(path, old, new):
    text = path.read_text(encoding='utf-8')
    if old not in text:
        raise ValueError(f'Anchor missing in {path}: {old!r}')
    if text.count(old) != 1:
        raise ValueError(f'Anchor not unique in {path}: {old!r}')
    path.write_text(text.replace(old, new, 1), encoding='utf-8')


def append_if_missing(path, marker, block):
    text = path.read_text(encoding='utf-8')
    if marker in text:
        return
    if not text.endswith('\n'):
        text += '\n'
    path.write_text(text + block, encoding='utf-8')


def replace_first_after(path, marker, old, new):
    text = path.read_text(encoding='utf-8')
    idx = text.find(marker)
    if idx < 0:
        raise ValueError(f'Anchor missing in {path}: {marker!r}')
    head, tail = text[:idx], text[idx:]
    if old not in tail:
        raise ValueError(f'Sub-anchor missing in {path}: {old!r}')
    path.write_text(head + tail.replace(old, new, 1), encoding='utf-8')


def require_guard_package(makefile):
    text = makefile.read_text(encoding='utf-8')
    if 'define Package/$(PKG_NAME)' not in text:
        raise ValueError('OpenClash dependency anchor changed')


def integrate(source, build_id):
    source = pathlib.Path(source)
    openclash_root = source / 'package/custom/luci-app-openclash'
    require_guard_package(openclash_root / 'Makefile')

    init_script = openclash_root / 'root/etc/init.d/openclash'
    replace_once(
        init_script,
        'start_service()\n{\n',
        'start_service()\n{\n   [ ! -x /usr/libexec/arthur-performance ] || /usr/libexec/arthur-performance protect start\n',
    )
    replace_once(
        init_script,
        'stop_service()\n{\n',
        'stop_service()\n{\n   [ ! -x /usr/libexec/arthur-performance ] || /usr/libexec/arthur-performance protect stop\n',
    )
    replace_first_after(
        init_script,
        'reload_service()',
        'start\n',
        'start\n   [ ! -x /usr/libexec/arthur-performance ] || /usr/libexec/arthur-performance protect reload\n',
    )

    f50 = source / 'files/etc/hotplug.d/net/90-f50'
    append_if_missing(
        f50,
        'arthur-performance',
        '\n[ ! -x /usr/libexec/arthur-performance ] || /usr/libexec/arthur-performance reconcile >/dev/null 2>&1 || true\n',
    )

    keep = source / 'package/base-files/files/lib/upgrade/keep.d/base-files-essential'
    append_if_missing(keep, '/etc/config/arthur', '\n/etc/config/arthur\n')

    if os.access(init_script, os.X_OK) is False:
        init_script.chmod(0o755)


if __name__ == '__main__':
    if len(sys.argv) != 4 or sys.argv[1] != 'integrate':
        raise SystemExit('Usage: integrate_performance.py integrate <source> <build_id>')
    integrate(sys.argv[2], sys.argv[3])
