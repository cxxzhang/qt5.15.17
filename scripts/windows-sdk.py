#!/usr/bin/env python3
"""Make installed Windows SDKs independent of the Qt source directory."""
import argparse
import configparser
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import struct
import zipfile
import importlib.util


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(path):
    result = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            result.update(block)
    return result.hexdigest()


def coff_machine(path):
    with path.open('rb') as stream:
        header = stream.read(8)
    require(len(header) == 8, 'Truncated COFF object: ' + str(path))
    if header[:4] == b'\0\0\xff\xff':
        return struct.unpack_from('<H', header, 6)[0]
    return struct.unpack_from('<H', header)[0]


def relocate(sdk, source):
    objects = {}
    for arch, machine in (('x86', 0x14c), ('x64', 0x8664)):
        relative = 'mkspecs/YY-Thunks/objs/' + arch + '/YY_Thunks_for_WinXP.obj'
        original = source / 'YY-Thunks/objs' / arch / 'YY_Thunks_for_WinXP.obj'
        require(coff_machine(original) == machine, 'Incorrect thunk object machine: ' + arch)
        objects[arch] = dict(path=relative, sha256=digest(original), machine=machine)
    config = sdk / 'mkspecs/common/msvc-desktop.conf'
    lines = config.read_text(encoding='utf-8').splitlines()
    changed = set()
    for index, line in enumerate(lines):
        for arch in ('x86', 'x64'):
            bare = 'YY-Thunks/objs/' + arch + '/YY_Thunks_for_WinXP.obj'
            if bare in line and re.match(r'\s*LIBS\s*\+=', line):
                value = '$$quote($$[QT_INSTALL_LIBS]/../mkspecs/' + bare + ')'
                previous = '$$quote($$[QT_HOST_DATA]/mkspecs/' + bare + ')'
                require(line.split('+=', 1)[1].strip() in (bare, value, previous), 'Unexpected thunk mkspec statement')
                lines[index] = '    LIBS += ' + value
                changed.add(arch)
        if re.match(r'\s*QMAKE_LFLAGS\s*=', line):
            lines[index] = re.sub(r'\s+/LIBPATH:(?:\.\./)+(?=\s|$)', '', line)
    require(changed == {'x86', 'x64'}, 'Missing expected Windows thunk mkspec branches')
    config.write_text('\n'.join(lines) + '\n', encoding='utf-8')
    # Static module PRLs are also read by generated Qt CMake packages, which
    # expand the standard QT_INSTALL_LIBS placeholder themselves.
    for prl in (sdk / 'lib').glob('*.prl'):
        text = prl.read_text(encoding='utf-8')
        original = text
        for arch in ('x86', 'x64'):
            bare = 'YY-Thunks/objs/' + arch + '/YY_Thunks_for_WinXP.obj'
            text = re.sub(r'(?<![/\\\w])' + re.escape(bare),
                          lambda match: '$$[QT_INSTALL_LIBS]/../mkspecs/' + match[0], text)
        if text != original:
            prl.write_text(text, encoding='utf-8')
    for arch, record in objects.items():
        destination = sdk / record['path']
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source / 'YY-Thunks/objs' / arch / 'YY_Thunks_for_WinXP.obj', destination)
    license_path = sdk / 'share/licenses/YY-Thunks-LICENSE'
    license_path.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source / 'YY-Thunks/LICENSE', license_path)
    # Installed qmake must resolve its data paths relative to the extracted SDK.
    qtconf = configparser.ConfigParser(interpolation=None)
    qtconf.optionxform = str
    path = sdk / 'bin/qt.conf'
    if path.exists():
        qtconf.read(path, encoding='utf-8-sig')
    if not qtconf.has_section('Paths'):
        qtconf.add_section('Paths')
    qtconf['Paths']['Prefix'] = '..'
    qtconf['Paths']['HostPrefix'] = '..'
    if qtconf.has_section('EffectivePaths'):
        qtconf['EffectivePaths']['Prefix'] = '..'
    with path.open('w', encoding='utf-8') as stream:
        qtconf.write(stream)
    return objects


def bundle_runtime(sdk, root, target, proof):
    version = proof['runtime_version']
    platform = {'x86': 'Win32', 'x64': 'x64', 'arm64': 'arm64'}[target]
    paths = list((root / 'TargetPlatform/header').glob('*.h'))
    paths += list((root / 'TargetPlatform' / version / 'header').glob('*.h'))
    libraries = root / 'TargetPlatform' / version / 'lib' / platform
    for name in ('libucrt.lib', 'libucrtd.lib', 'libvcruntime.lib', 'libvcruntimed.lib'):
        require((libraries / name).is_file(), 'Missing consumer VC-LTL runtime: ' + name)
    require((root / 'TargetPlatform/header/corecrt.h') in paths
            and (root / 'TargetPlatform' / version / 'header/vcruntime.h') in paths,
            'Missing consumer VC-LTL headers')
    paths += list(libraries.glob('*.lib'))
    paths += [root / 'Readme.md', root / 'Readme.osc.md']
    files = {}
    for path in paths:
        relative = 'mkspecs/VC-LTL/' + path.relative_to(root).as_posix()
        destination = sdk / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, destination)
        files[relative] = digest(destination)
    # Use the same CRT as the DLLs for allocations crossing the SDK boundary.
    config = sdk / 'mkspecs/common/msvc-desktop.conf'
    text = config.read_text(encoding='utf-8')
    marker = '# Bundled SDK consumer CRT\n'
    text = text.split(marker, 1)[0]
    prefix = '$$[QT_INSTALL_LIBS]/../mkspecs/VC-LTL/TargetPlatform/'
    text += marker + 'QMAKE_INCDIR = $$quote(' + prefix + 'header) $$quote(' + prefix + version + '/header) $$QMAKE_INCDIR\n'
    text += 'QMAKE_LIBDIR = $$quote(' + prefix + version + '/lib/' + platform + ') $$QMAKE_LIBDIR\n'
    config.write_text(text, encoding='utf-8')
    return dict(version=version, platform=platform, files=files)


def package(sdk, source, target, variant, run, commit, output, runtime_root=None, symbols=None):
    require(sdk.is_dir() and (sdk / 'bin/qmake.exe').is_file(), 'Not an installed Windows SDK')
    core = 'Qt5Core' + ('d' if variant == 'debug' else '') + '.dll'
    require((sdk / 'bin' / core).is_file(), 'Missing installed ' + core)
    proof = json.loads((sdk / 'share/ci-windows-toolchain.json').read_text(encoding='utf-8'))
    require(proof.get('vc_ltl_active') is True and proof.get('target_arch') == target
            and proof.get('variant') == variant, 'Cannot package an SDK without a matching active CRT proof')
    require(not output.resolve().is_relative_to(sdk.resolve()), 'SDK archive cannot be inside its input directory')
    objects = relocate(sdk, source)
    runtime = bundle_runtime(sdk, runtime_root or source / '.github/VC-LTL', target, proof)
    runtime_license = sdk / 'share/licenses/VC-LTL-LICENSE'
    shutil.copyfile(source / 'scripts/VC-LTL-LICENSE', runtime_license)
    runtime['files']['share/licenses/VC-LTL-LICENSE'] = digest(runtime_license)
    record = dict(schema=1, target_arch=target, variant=variant, source_run=str(run), source_commit=commit,
                  consumer_runtime=runtime, thunk_objects=objects, thunk_license=dict(path='share/licenses/YY-Thunks-LICENSE',
                      sha256=digest(sdk / 'share/licenses/YY-Thunks-LICENSE')),
                  checks=['bundled x86/x64 thunk objects', 'matching COFF machines',
                                                'SDK-relative thunk mkspec', 'relative qmake configuration'])
    (sdk / 'share/ci-windows-packaging.json').write_text(json.dumps(record, indent=2) + '\n', encoding='utf-8')
    if symbols:
        spec = importlib.util.spec_from_file_location('native_symbols', Path(__file__).with_name('native-symbols.py'))
        debug = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(debug)
        debug.windows(sdk, symbols)
    output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(output, 'w', zipfile.ZIP_DEFLATED, compresslevel=6, allowZip64=True) as archive:
        for path in sorted(sdk.rglob('*')):
            if path.is_file():
                if symbols and path.suffix.lower() == '.pdb':
                    continue
                archive.write(path, path.relative_to(sdk).as_posix())
    print('Packaged portable Windows SDK:', output, digest(output))
    return record


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sdk', type=Path, required=True)
    parser.add_argument('--source-root', type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument('--target', choices=('x86', 'x64', 'arm64'), required=True)
    parser.add_argument('--variant', choices=('release', 'debug'), required=True)
    parser.add_argument('--run', default=os.environ.get('GITHUB_RUN_ID'), required='GITHUB_RUN_ID' not in os.environ)
    parser.add_argument('--commit', default=os.environ.get('GITHUB_SHA'), required='GITHUB_SHA' not in os.environ)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--runtime-root', type=Path)
    parser.add_argument('--symbols', type=Path)
    args = parser.parse_args()
    package(args.sdk, args.source_root, args.target, args.variant, args.run, args.commit, args.output, args.runtime_root, args.symbols)
