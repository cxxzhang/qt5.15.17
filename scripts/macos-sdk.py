#!/usr/bin/env python3
"""Audit macOS SDK architectures and merge complete universal SDKs."""

import argparse
import json
import os
import re
from pathlib import Path
import shutil
import subprocess


MAGIC = {b'\xfe\xed\xfa\xce', b'\xce\xfa\xed\xfe', b'\xfe\xed\xfa\xcf',
         b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca',
         b'\xca\xfe\xba\xbf', b'\xbf\xba\xfe\xca'}


def binaries(root):
    found = {}
    for path in root.rglob('*'):
        if path.is_symlink() or not path.is_file():
            continue
        with path.open('rb') as stream:
            magic = stream.read(8)
        if magic[:4] in MAGIC or magic == b'!<arch>\n':
            found[path.relative_to(root)] = path
    if not found:
        raise ValueError('No Mach-O binaries or static archives in ' + str(root))
    return found


def audit(root, architectures):
    files = binaries(root)
    for relative, path in files.items():
        actual = set(subprocess.check_output(['lipo', '-archs', str(path)], text=True).split())
        if actual != set(architectures):
            raise ValueError('{}: expected {}, got {}'.format(relative, architectures, actual))
    qmake = root / 'bin/qmake'
    if not qmake.is_file() or not qmake.stat().st_mode & 0o111:
        raise ValueError('Missing executable qmake')
    print('Verified architectures and executable permissions for {} macOS binaries/archives'.format(len(files)))


def advertise_universal(root):
    config = root / 'mkspecs/qconfig.pri'
    content, count = re.subn(r'^QT_ARCHS\s*=.*$', 'QT_ARCHS = x86_64 arm64',
                             config.read_text(), flags=re.M)
    if count != 1:
        raise ValueError('Expected exactly one generated macOS QT_ARCHS setting')
    config.write_text(content)


def merge(x64, arm64, output):
    audit(x64, ['x86_64'])
    audit(arm64, ['arm64'])
    xfiles, afiles = binaries(x64), binaries(arm64)
    if set(xfiles) != set(afiles):
        raise ValueError('Unmatched architecture files: ' + str(sorted(set(xfiles) ^ set(afiles))))
    if output.exists():
        raise ValueError('Universal output already exists: ' + str(output))
    shutil.copytree(arm64, output, symlinks=True)
    advertise_universal(output)
    for relative in afiles:
        destination = output / relative
        subprocess.check_call(['lipo', '-create', str(xfiles[relative]), str(afiles[relative]),
                               '-output', str(destination)])
        shutil.copystat(afiles[relative], destination)
    # Configure-generated feature headers can differ between architectures.
    # Keep both exact headers and select the matching one in consumer builds.
    for arm_header in arm64.rglob('*.h'):
        if arm_header.is_symlink() or not arm_header.is_file():
            continue
        relative = arm_header.relative_to(arm64)
        x_header = x64 / relative
        if x_header.is_file() and x_header.read_bytes() != arm_header.read_bytes():
            header = output / relative
            shutil.copy2(x_header, header.with_name(header.name + '.x86_64'))
            shutil.copy2(arm_header, header.with_name(header.name + '.arm64'))
            header.write_text('#if defined(__x86_64__)\n#include "' + header.name + '.x86_64"\n'
                              '#elif defined(__aarch64__) || defined(__arm64__)\n#include "' + header.name + '.arm64"\n'
                              '#else\n#error Unsupported SDK architecture\n#endif\n')
    sources = {}
    for name, sdk in (('x86_64', x64), ('arm64', arm64)):
        record = sdk / 'share/ci-native-source.json'
        sources[name] = json.loads(record.read_text()) if record.is_file() else dict(
            source_run=os.environ.get('GITHUB_RUN_ID'), source_commit=os.environ.get('GITHUB_SHA'))
    provenance = output / 'share/ci-universal-sources.json'
    provenance.parent.mkdir(parents=True, exist_ok=True)
    provenance.write_text(json.dumps(sources, indent=2) + '\n')
    audit(output, ['x86_64', 'arm64'])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    check = commands.add_parser('audit')
    check.add_argument('sdk', type=Path)
    check.add_argument('architectures', nargs='+')
    combine = commands.add_parser('merge')
    combine.add_argument('x64', type=Path)
    combine.add_argument('arm64', type=Path)
    combine.add_argument('output', type=Path)
    args = parser.parse_args()
    if args.command == 'audit':
        audit(args.sdk, args.architectures)
    else:
        merge(args.x64, args.arm64, args.output)


if __name__ == '__main__':
    main()
