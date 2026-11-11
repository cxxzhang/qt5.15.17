#!/usr/bin/env python3
"""Require the exact platform archive set and bind it to successful verifiers."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import struct
import zipfile


def digest(path):
    result = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            result.update(block)
    return result.hexdigest()


def require(condition, message):
    if not condition:
        raise ValueError(message)


def collect(packages, proofs, scope, run, commit):
    linux = json.loads((packages / 'linux-acceptance-manifest.json').read_text())
    require(linux['accepted'] is True and linux['source_run'] == str(run)
            and linux['source_commit'] == commit, 'Linux release provenance mismatch')
    require({(s['target'], s['variant']) for s in linux['sdks']} ==
            {(a, v) for a in ('x64', 'arm64', 'mips64el', 'loong64-oldworld', 'loong64-newworld')
             for v in ('release', 'debug')} and len(linux['sdks']) == 10, 'Incomplete Linux matrix')
    expected = {'linux-acceptance-manifest.json'}
    for sdk in linux['sdks']:
        for filename, checksum in sdk['archives'].items():
            expected.add(filename)
            require(digest(packages / filename) == checksum, 'Linux archive changed: ' + filename)
    if scope == 'all':
        for arch, machine in (('x86', 0x14c), ('x64', 0x8664), ('arm64', 0xaa64)):
            for debug in (False, True):
                filename = 'qt5.15.17_windows_' + arch + ('_debug' if debug else '') + '.zip'
                expected.add(filename)
                with zipfile.ZipFile(packages / filename) as sdk:
                    names = set(sdk.namelist())
                    require('bin/qmake.exe' in names, filename + ': missing qmake')
                    suffix = 'd' if debug else ''
                    for module in ('Core', 'Gui', 'Network', 'Qml'):
                        require('bin/Qt5' + module + suffix + '.dll' in names,
                                filename + ': missing Qt module ' + module)
                    require('lib/Qt5Core' + suffix + '.lib' in names, filename + ': missing import library')
                    count = 0
                    for name in names:
                        if not name.lower().endswith('.dll'):
                            continue
                        with sdk.open(name) as stream:
                            header = stream.read(64)
                            require(header[:2] == b'MZ', filename + ': invalid DLL ' + name)
                            offset = struct.unpack_from('<I', header, 60)[0]
                            stream.seek(offset)
                            coff = stream.read(6)
                        require(coff[:4] == b'PE\0\0' and struct.unpack_from('<H', coff, 4)[0] == machine,
                                filename + ': incorrect DLL architecture ' + name)
                        count += 1
                    require(count > 0, filename + ': no DLLs')
                    proof_name = 'share/ci-windows-toolchain.json'
                    require(proof_name in names, filename + ': missing VC-LTL toolchain proof')
                    proof = json.loads(sdk.read(proof_name))
                    require(proof.get('vc_ltl_active') is True and proof.get('target_arch') == arch
                            and proof.get('variant') == ('debug' if debug else 'release')
                            and proof.get('toolset_version', '').startswith('14.44.')
                            and proof.get('visual_studio_version') in ('17.0', '18.0')
                            and proof.get('runtime_version') == {'x86': '5.1.2600.0', 'x64': '5.2.3790.0', 'arm64': '10.0.10240.0'}[arch]
                            and proof.get('platform') == {'x86': 'Win32', 'x64': 'x64', 'arm64': 'arm64'}[arch],
                            filename + ': invalid VC-LTL toolchain proof')
                    require({'VC-LTL header precedence', 'VC-LTL library precedence',
                             'release and debug CRT libraries present', 'matching target platform'}
                            <= set(proof.get('checks', [])), filename + ': incomplete VC-LTL checks')
                    require(str(proof.get('source_run', '')).isdigit()
                            and re.fullmatch('[0-9a-f]{40}', proof.get('source_commit') or '') is not None,
                            filename + ': missing VC-LTL compilation provenance')
                    require('share/ci-windows-packaging.json' in names and 'bin/qt.conf' in names,
                            filename + ': missing portable Windows packaging proof')
                    packaging = json.loads(sdk.read('share/ci-windows-packaging.json'))
                    require(packaging.get('target_arch') == arch and packaging.get('variant') == ('debug' if debug else 'release')
                            and packaging.get('source_run') == str(run) and packaging.get('source_commit') == commit,
                            filename + ': Windows packaging provenance mismatch')
                    runtime = packaging.get('consumer_runtime', {})
                    require(runtime.get('version') == proof['runtime_version'] and runtime.get('platform') == proof['platform'],
                            filename + ': consumer CRT mismatch')
                    runtime_files = runtime.get('files', {})
                    runtime_base = 'mkspecs/VC-LTL/TargetPlatform/'
                    required_runtime = {runtime_base + 'header/corecrt.h',
                        runtime_base + proof['runtime_version'] + '/header/vcruntime.h', 'share/licenses/VC-LTL-LICENSE'}
                    required_runtime |= {runtime_base + proof['runtime_version'] + '/lib/' + proof['platform'] + '/' + name
                        for name in ('libucrt.lib', 'libucrtd.lib', 'libvcruntime.lib', 'libvcruntimed.lib')}
                    require(required_runtime <= runtime_files.keys(), filename + ': incomplete consumer CRT')
                    for path, checksum in runtime_files.items():
                        require(path in names and hashlib.sha256(sdk.read(path)).hexdigest() == checksum,
                                filename + ': consumer CRT hash mismatch: ' + path)
                    for cpu, coff_machine in (('x86', 0x14c), ('x64', 0x8664)):
                        path = 'mkspecs/YY-Thunks/objs/' + cpu + '/YY_Thunks_for_WinXP.obj'
                        require(path in names, filename + ': missing thunk object ' + cpu)
                        data = sdk.read(path)
                        require(len(data) >= 8, filename + ': truncated thunk object')
                        object_machine = struct.unpack_from('<H', data, 6 if data[:4] == b'\0\0\xff\xff' else 0)[0]
                        record = packaging.get('thunk_objects', {}).get(cpu, {})
                        require(object_machine == coff_machine and record.get('machine') == object_machine and record.get('path') == path
                                and record.get('sha256') == hashlib.sha256(data).hexdigest(), filename + ': invalid thunk object proof')
                    license_path = 'share/licenses/YY-Thunks-LICENSE'
                    require(license_path in names and packaging.get('thunk_license', {}).get('path') == license_path
                            and packaging['thunk_license'].get('sha256') == hashlib.sha256(sdk.read(license_path)).hexdigest(),
                            filename + ': missing thunk license/provenance')
                proof_name = 'verified-windows-' + arch + '-' + ('debug' if debug else 'release') + '.json'
                matches = list(proofs.rglob(proof_name))
                require(len(matches) == 1, 'Expected one Windows consumer proof: ' + proof_name)
                consumer = json.loads(matches[0].read_text())
                require(consumer.get('accepted') is True and consumer.get('source_run') == str(run)
                        and consumer.get('source_commit') == commit and consumer.get('verifier_commit') == commit
                        and consumer.get('target_arch') == arch and consumer.get('variant') == ('debug' if debug else 'release'),
                        filename + ': invalid Windows consumer provenance')
                require(consumer.get('archive') == filename and consumer.get('sha256') == digest(packages / filename),
                        filename + ': Windows consumer archive hash mismatch')
                require({'standalone extracted SDK', 'relocated qmake prefix', 'bundled thunk objects',
                         'C++17 qmake consumer', 'ordinary and wide string round trips',
                         'offscreen GUI/QML/fonts/TLS runtime', 'consumer PE architecture',
                         'matching bundled VC-LTL consumer runtime', 'qmake static UiTools consumer'}
                        <= set(consumer.get('checks', [])), filename + ': incomplete Windows consumer checks')
        for target, architectures, consumers in (
                ('x64', {'x86_64'}, ('x86_64',)), ('arm64', {'arm64'}, ('arm64',)),
                ('universal', {'x86_64', 'arm64'}, ('x86_64', 'arm64'))):
            filename = 'qt5.15.17_macos_' + target + '.tar.gz'
            expected.add(filename)
            for consumer in consumers:
                name = 'verified-macos-' + target + '-' + consumer + '.json'
                matches = list(proofs.rglob(name))
                require(len(matches) == 1, 'Expected one macOS proof: ' + name)
                proof = json.loads(matches[0].read_text())
                require(proof.get('accepted') is True and proof.get('source_run') == str(run)
                        and proof.get('source_commit') == commit, 'macOS proof provenance: ' + name)
                require(proof.get('target') == target and proof.get('consumer_arch') == consumer
                        and set(proof.get('architectures', [])) == architectures, 'macOS proof architecture: ' + name)
                require({'extracted executable permissions', 'all Mach-O and static archive architectures',
                         'advertised qmake architectures', 'default native qmake consumer',
                         'qmake C++17 consumer', 'offscreen GUI/QML/fonts/TLS execution'}
                        <= set(proof.get('checks', [])), 'Incomplete macOS checks: ' + name)
                if target == 'universal':
                    require('explicit dual-architecture consumer' in proof['checks'], 'Missing universal app check: ' + name)
                require(proof.get('archive') == filename and proof.get('sha256') == digest(packages / filename),
                        'macOS archive hash mismatch: ' + name)
    actual = {p.name for p in packages.iterdir() if p.is_file()}
    require(actual == expected, 'Unexpected/missing release assets: ' + str(sorted(actual ^ expected)))
    manifest = dict(accepted=True, source_run=str(run), source_commit=commit, scope=scope,
                    assets={name: digest(packages / name) for name in sorted(expected)})
    (packages / 'release-acceptance-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    (packages / 'SHA256SUMS').write_text(''.join(
        digest(path) + '  ' + path.name + '\n' for path in sorted(packages.iterdir())
        if path.is_file() and path.name != 'SHA256SUMS'))
    print('Validated {} release inputs; wrote complete provenance and SHA256SUMS'.format(len(expected)))
    return manifest


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--packages', type=Path, required=True)
    parser.add_argument('--proofs', type=Path, required=True)
    parser.add_argument('--scope', choices=('all', 'linux'), required=True)
    parser.add_argument('--run', required=True)
    parser.add_argument('--commit', required=True)
    args = parser.parse_args()
    collect(args.packages, args.proofs, args.scope, args.run, args.commit)
