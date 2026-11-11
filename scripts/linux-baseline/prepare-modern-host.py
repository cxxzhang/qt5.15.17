#!/usr/bin/env python3
"""Supply missing graphical runtime libraries without changing host GNU/libc."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess


ROOTS = '''libxcb-icccm.so.4 libxcb-image.so.0 libxcb-keysyms.so.1
libxcb-render-util.so.0 libxcb-xinerama.so.0 libxcb-xkb.so.1
libxkbcommon-x11.so.0 libfontconfig.so.1 libfreetype.so.6
libGL.so.1 libEGL.so.1 libdbus-1.so.3 libdrm.so.2'''.split()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('toolchain', type=Path)
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    if os.geteuid() != 0:
        raise ValueError('Run in the disposable CI host as root')
    for command in ('gcc', 'g++', 'make', 'pkg-config', 'openssl', 'readelf', 'ldconfig'):
        subprocess.check_call(['which', command])
    prefix = args.toolchain.resolve()
    if not list(prefix.glob('.accepted-*')):
        raise ValueError('Expected a verified published native snapshot')
    cache = subprocess.check_output(['ldconfig', '-p'], text=True)
    available = set(re.findall(r'^\s*(\S+)\s+\(', cache, re.M))
    destination = Path('/usr/local/lib/qt-modern-graphics')
    destination.mkdir(parents=True, exist_ok=True)
    pending, copied = list(ROOTS), {}
    while pending:
        name = pending.pop()
        if name in available or name in copied:
            continue
        # The modern consumer must retain Ubuntu's C/C++ runtime providers.
        if name.startswith(('libstdc++', 'libgcc_s', 'libc.', 'libpthread.',
                            'libm.', 'libdl.', 'librt.', 'ld-linux', 'ld-')):
            raise ValueError('Missing host core runtime: ' + name)
        source = (prefix / 'sysroot/usr/lib64' / name).resolve()
        source.relative_to(prefix)
        if not source.is_file():
            raise ValueError('Missing graphical dependency in published snapshot: ' + name)
        header = subprocess.check_output(['readelf', '-h', str(source)], text=True)
        host_header = subprocess.check_output(['readelf', '-h', '/bin/sh'], text=True)
        if re.search(r'Machine:\s+(.+)', header)[1] != re.search(r'Machine:\s+(.+)', host_header)[1]:
            raise ValueError('Graphical dependency architecture mismatch: ' + name)
        target = destination / name
        shutil.copy2(source, target)
        copied[name] = dict(source=str(source), sha256=hashlib.sha256(target.read_bytes()).hexdigest())
        dynamic = subprocess.check_output(['readelf', '-d', str(source)], text=True)
        pending.extend(re.findall(r'\(NEEDED\).*\[([^\]]+)\]', dynamic))
    # Minimal runners can have the GL runtime without the development link
    # name required by QtGui's public link interface. Prefer the host runtime.
    gl_link = destination / 'libGL.so'
    gl_runtime = destination / 'libGL.so.1'
    if not gl_runtime.is_file():
        candidates = re.findall(r'^\s*libGL\.so\.1\s+\([^\n]+?=>\s+(\S+)', cache, re.M)
        if not candidates:
            raise ValueError('No GL runtime provider for the consumer linker')
        gl_runtime = Path(candidates[0])
    if gl_link.is_symlink():
        gl_link.unlink()
    gl_link.symlink_to(gl_runtime)
    Path('/etc/ld.so.conf.d/qt-modern-graphics.conf').write_text(str(destination) + '\n')
    subprocess.check_call(['ldconfig'])
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(dict(
        source_snapshot=prefix.name, copied=copied, linker_aliases={'libGL.so': str(gl_runtime)},
        policy='Reuse installed host providers; supplement only missing graphics libraries; retain host GNU/libc'),
        indent=2) + '\n')
    print('Modern host graphical dependencies ready: ' + ', '.join(sorted(copied)))


if __name__ == '__main__':
    main()
