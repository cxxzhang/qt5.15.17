#!/usr/bin/env python3
"""Bind independently verified Linux SDK archives to one source run and commit."""

import argparse
import hashlib
import json
from pathlib import Path


TARGETS = ('x64', 'arm64', 'mips64el', 'loong64-oldworld', 'loong64-newworld')


def require(condition, message):
    if not condition:
        raise ValueError(message)


def one(root, name):
    matches = list(root.rglob(name))
    require(len(matches) == 1, 'Expected exactly one ' + name)
    return matches[0]


def digest(path):
    result = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            result.update(block)
    return result.hexdigest()


def bound(record, run, commit, description):
    require(record.get('accepted') is True, description + ': not accepted')
    require(str(record.get('source_run')) == str(run), description + ': source run mismatch')
    require(record.get('source_commit') == commit, description + ': source commit mismatch')


def collect(sdk_root, verification_root, modern_root, targets, variants, run, commit, target_spec, toolchains):
    records = []
    for arch in targets:
        for variant in variants:
            label = arch + '/' + variant
            proof = json.loads(one(verification_root, 'verified-' + arch + '-' + variant + '.json').read_text())
            bound(proof, run, commit, label)
            require(proof.get('target') == arch and proof.get('variant') == variant, label + ': wrong verification subject')
            require(proof.get('verifier_commit') == commit, label + ': verifier commit mismatch')
            require(proof.get('glibc') == target_spec[arch]['glibc'], label + ': glibc mismatch')
            require(proof.get('gnu_runtime_policy') == 'baseline-system', label + ': legacy GNU policy')
            required = {'ELF ABI/versions/strip', 'matching symbols/debuglink CRC',
                        'selected C++ runtime resolution', 'extracted qmake C++17 consumer',
                        'offscreen GUI/QML/fonts/TLS runtime'}
            require(required <= set(proof.get('checks', [])), label + ': incomplete verification')
            require(toolchains[arch].get('gnu_runtime_policy') == 'baseline-system', label + ': toolchain policy')
            name = 'qt5.15.17_linux_' + arch.replace('-', '_') + ('_debug' if variant == 'debug' else '')
            archives = {}
            for suffix in ('.tar.gz', '-symbols.tar.gz'):
                filename = name + suffix
                checksum = digest(one(sdk_root, filename))
                require(checksum == proof.get('archives', {}).get(suffix), label + ': archive hash mismatch: ' + filename)
                archives[filename] = checksum
            gnu = json.loads(one(verification_root, 'gnu-requirements-' + arch + '-' + variant + '.json').read_text())
            bound(gnu, run, commit, label + ' GNU imports')
            require(gnu.get('files') and not gnu.get('missing'), label + ': incomplete GNU audit')
            if arch not in ('x64', 'arm64'):
                host = json.loads(one(verification_root, 'gnu-requirements-' + arch + '-' + variant + '-host.json').read_text())
                bound(host, run, commit, label + ' host GNU imports')
                require(host.get('files') and not host.get('missing'), label + ': incomplete host GNU audit')
            else:
                modern = json.loads(one(modern_root, 'modern-consumers-' + arch + '-' + variant + '.json').read_text())
                bound(modern, run, commit, label + ' modern consumers')
                require(modern.get('target') == arch and modern.get('variant') == variant, label + ': wrong modern consumer subject')
                require(modern.get('verifier_commit') == commit, label + ': modern verifier commit mismatch')
                require(modern.get('archives') == archives, label + ': modern consumer archive mismatch')
                require(all(modern.get('compilers', {}).get(c) for c in ('gcc', 'clang')), label + ': missing compiler versions')
                require({'same extracted Qt SDK', 'no bundled GNU shared runtime',
                         'GCC and Clang C++17 consumers', 'GUI/QML/fonts/TLS execution'}
                        <= set(modern.get('checks', [])), label + ': incomplete modern consumers')
            records.append(dict(target=arch, variant=variant, glibc=proof['glibc'],
                                gnu_runtime_policy=proof['gnu_runtime_policy'],
                                maximum_required_gnu=gnu['maximum_required_versions'],
                                toolchain_sha256=toolchains[arch]['sha256'], archives=archives))
    expected = {name for record in records for name in record['archives']}
    actual = list(sdk_root.rglob('*.tar.gz'))
    require(len(actual) == len(expected) and {p.name for p in actual} == expected,
            'Unexpected or duplicate SDK archives outside the selected matrix')
    return dict(schema=1, accepted=True, source_run=str(run), source_commit=commit, sdks=records)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('sdk', 'verification', 'modern', 'targets-spec', 'toolchains', 'output'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--target', choices=('all', 'native', 'cross') + TARGETS, default='all')
    parser.add_argument('--variant', choices=('all', 'release', 'debug'), default='all')
    parser.add_argument('--source-run', required=True)
    parser.add_argument('--source-commit', required=True)
    args = parser.parse_args()
    targets = TARGETS if args.target == 'all' else ('x64', 'arm64') if args.target == 'native' else TARGETS[2:] if args.target == 'cross' else (args.target,)
    variants = ('release', 'debug') if args.variant == 'all' else (args.variant,)
    record = collect(args.sdk, args.verification, args.modern, targets, variants,
                     args.source_run, args.source_commit, json.loads(args.targets_spec.read_text())['targets'],
                     json.loads(args.toolchains.read_text())['targets'])
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(record, indent=2) + '\n')
    print('Accepted {} independently verified SDK/variant pairs'.format(len(record['sdks'])))


if __name__ == '__main__':
    main()
