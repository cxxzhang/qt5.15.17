#!/usr/bin/env python3
"""Separate native debug files and verify their binary identities."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import tempfile
import zipfile


def require(value, message):
    if not value:
        raise ValueError(message)


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def pdb_identity(path):
    # MSF 7.0 superblock, stream directory and PDB information stream (#1).
    with path.open('rb') as stream:
        header = stream.read(56)
        require(header[:32] == b'Microsoft C/C++ MSF 7.00\r\n\x1aDS\0\0\0', 'Unsupported PDB: ' + str(path))
        block, _, count, size, _, directory = struct.unpack_from('<6I', header, 32)
        require(block in (512, 1024, 2048, 4096, 8192) and size < count * block, 'Invalid PDB directory')
        blocks = (size + block - 1) // block
        stream.seek(directory * block)
        pages = struct.unpack('<' + 'I' * blocks, stream.read(4 * blocks))
        data = bytearray()
        for page in pages:
            stream.seek(page * block)
            data.extend(stream.read(block))
        streams = struct.unpack_from('<I', data)[0]
        require(streams > 1, 'PDB has no information stream')
        sizes = struct.unpack_from('<' + 'I' * streams, data, 4)
        offset = 4 + streams * 4
        for index, length in enumerate(sizes[:2]):
            pages = 0 if length == 0xffffffff else (length + block - 1) // block
            if index == 1:
                require(length >= 28 and pages, 'Truncated PDB information stream')
                page = struct.unpack_from('<I', data, offset)[0]
                stream.seek(page * block)
                info = stream.read(28)
                return dict(guid=info[12:28].hex(), age=struct.unpack_from('<I', info, 8)[0])
            offset += pages * 4


def pe_identity(path):
    with path.open('rb') as stream:
        data = stream.read()
    require(data[:2] == b'MZ', 'Invalid PE: ' + str(path))
    pe = struct.unpack_from('<I', data, 60)[0]
    require(data[pe:pe + 4] == b'PE\0\0', 'Missing PE signature')
    sections = struct.unpack_from('<H', data, pe + 6)[0]
    optional_size = struct.unpack_from('<H', data, pe + 20)[0]
    optional = pe + 24
    magic = struct.unpack_from('<H', data, optional)[0]
    require(magic in (0x10b, 0x20b), 'Unknown PE optional header')
    directories = optional + (112 if magic == 0x20b else 96)
    rva, size = struct.unpack_from('<II', data, directories + 6 * 8)
    if not rva or not size:
        return None
    table = optional + optional_size
    offset = None
    for index in range(sections):
        section = table + 40 * index
        virtual_size, virtual, raw_size, raw = struct.unpack_from('<4I', data, section + 8)
        if virtual <= rva < virtual + max(virtual_size, raw_size):
            offset = raw + rva - virtual
            break
    require(offset is not None, 'PE debug directory is outside sections')
    records = []
    for entry in range(offset, offset + size, 28):
        kind, length, _, pointer = struct.unpack_from('<4I', data, entry + 12)
        if kind != 2:
            continue
        info = data[pointer:pointer + length]
        require(info[:4] == b'RSDS' and len(info) >= 25, 'Unsupported PE CodeView record')
        records.append(dict(guid=info[4:20].hex(), age=struct.unpack_from('<I', info, 20)[0],
                            pdb=info[24:].split(b'\0', 1)[0].decode('utf-8').replace('\\', '/').split('/')[-1]))
    require(len(records) <= 1, 'Expected at most one PE PDB record: ' + str(path))
    return records[0] if records else None


def windows(sdk, output):
    pdbs = {path.relative_to(sdk).as_posix(): path for path in sdk.rglob('*.pdb')}
    require(pdbs, 'No installed Windows PDBs')
    identities = {name: pdb_identity(path) for name, path in pdbs.items()}
    records = []
    for binary in sorted(sdk.rglob('*')):
        if not binary.is_file() or binary.suffix.lower() not in ('.dll', '.exe'):
            continue
        codeview = pe_identity(binary)
        # Third-party prebuilt runtime DLLs without PDB records are not Qt symbols.
        if codeview is None:
            continue
        matches = [name for name, identity in identities.items()
                   if Path(name).name.lower() == codeview['pdb'].lower()
                   and identity == {key: codeview[key] for key in ('guid', 'age')}]
        require(len(matches) == 1, 'Missing/mismatched PDB: ' + str(binary.relative_to(sdk)))
        name = matches[0]
        records.append(dict(binary=binary.relative_to(sdk).as_posix(), binary_sha256=digest(binary),
                            symbol=name, symbol_sha256=digest(pdbs[name]), **identities[name]))
    require(records, 'No matching binary/PDB pairs')
    record = dict(schema=1, platform='windows', source_run=os.environ.get('GITHUB_RUN_ID'),
                  source_commit=os.environ.get('GITHUB_SHA'), binaries=records,
                  files={name: digest(path) for name, path in pdbs.items()})
    output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(output, 'w', zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
        for name, path in sorted(pdbs.items()):
            archive.write(path, name)
        archive.writestr('native-symbols.json', json.dumps(record, indent=2) + '\n')
    print('Packaged', len(pdbs), 'PDBs;', len(records), 'binary GUID/age matches:', output)
    return record


def module():
    spec = importlib.util.spec_from_file_location('macos_sdk', Path(__file__).with_name('macos-sdk.py'))
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


def uuids(path):
    result = subprocess.check_output(['dwarfdump', '--uuid', str(path)], text=True)
    records = re.findall(r'UUID: ([0-9A-Fa-f-]+) \(([^)]+)\)', result)
    require(records and len({arch for _, arch in records}) == len(records), 'Missing/duplicate Mach-O UUID: ' + str(path))
    return {arch: uuid.upper() for uuid, arch in records}


def capture_macos(sdk):
    # Run while the native build objects referenced by the debug map still exist.
    for relative, binary in module().binaries(sdk).items():
        if binary.suffix == '.a':
            continue
        destination = sdk / 'share/ci-dsym' / (str(relative) + '.dSYM')
        destination.parent.mkdir(parents=True, exist_ok=True)
        subprocess.check_call(['dsymutil', str(binary), '-o', str(destination)])
        dwarf = destination / 'Contents/Resources/DWARF' / binary.name
        require(dwarf.is_file() and uuids(dwarf) == uuids(binary), 'Generated dSYM UUID mismatch')
        subprocess.check_call(['dwarfdump', '--verify', str(dwarf)], stdout=subprocess.DEVNULL)
        # A UUID-only dSYM without DWARF is not a useful debug symbol file.
        sections = subprocess.check_output(['otool', '-l', str(dwarf)], text=True)
        if '__debug_info' not in sections:
            require(relative.as_posix() == 'bin/qmake', 'Generated dSYM has no debug information: ' + str(relative))
            shutil.rmtree(destination)


def macos(sdk, runtime, symbols):
    with tempfile.TemporaryDirectory(prefix='qt-macos-symbols-') as temporary:
        base = Path(temporary)
        stripped, debug = base / 'sdk', base / 'symbols'
        shutil.copytree(sdk, stripped, symlinks=True)
        debug.mkdir()
        dsym_root = stripped / 'share/ci-dsym'
        require(dsym_root.is_dir(), 'Native dSYMs must be captured before build objects disappear')
        shutil.move(str(dsym_root), str(debug / 'dSYM'))
        records = []
        for relative, binary in module().binaries(stripped).items():
            original = sdk / relative
            if binary.suffix == '.a':
                destination = debug / 'static' / relative
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(original, destination)
                subprocess.check_call(['strip', '-arch', 'all', '-S', str(binary)])
                records.append(dict(binary=relative.as_posix(), binary_sha256=digest(binary),
                                    symbol=destination.relative_to(debug).as_posix(), symbol_sha256=digest(destination),
                                    kind='static archive with original DWARF'))
                continue
            dsym = debug / 'dSYM' / (str(relative) + '.dSYM') / 'Contents/Resources/DWARF' / binary.name
            kind = 'dSYM'
            if not dsym.is_file():
                require(relative.as_posix() == 'bin/qmake', 'Missing dSYM: ' + str(relative))
                dsym = debug / 'bootstrap' / relative
                dsym.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(binary, dsym)
                kind = 'bootstrap symbol table (no source DWARF)'
            require(uuids(dsym) == uuids(binary), 'Mismatched dSYM: ' + str(relative))
            subprocess.check_call(['strip', '-arch', 'all', '-S', '-x', str(binary)])
            # Re-sign modified arm64 binaries with an ad-hoc signature.
            subprocess.check_call(['codesign', '--force', '--sign', '-', str(binary)],
                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            require(uuids(dsym) == uuids(binary), 'Stripping changed Mach-O UUID')
            require('__debug_info' not in subprocess.check_output(['otool', '-arch', 'all', '-l', str(binary)], text=True),
                    'DWARF remains in delivered binary')
            records.append(dict(binary=relative.as_posix(), binary_sha256=digest(binary),
                                symbol=dsym.relative_to(debug).as_posix(), symbol_sha256=digest(dsym),
                                uuids=uuids(binary), kind=kind))
        record = dict(schema=1, platform='macos', source_run=os.environ.get('GITHUB_RUN_ID'),
                      source_commit=os.environ.get('GITHUB_SHA'), binaries=records)
        (debug / 'native-symbols.json').write_text(json.dumps(record, indent=2) + '\n')
        for source, output in ((stripped, runtime), (debug, symbols)):
            output.parent.mkdir(parents=True, exist_ok=True)
            subprocess.check_call(['tar', '-C', str(source), '-czf', str(output.resolve()), '.'])
            subprocess.check_call(['gzip', '-t', str(output.resolve())])
    print('Packaged stripped macOS SDK and matching symbols:', runtime, symbols)


def restore_macos(sdk, symbols):
    with tempfile.TemporaryDirectory(prefix='qt-macos-restore-symbols-') as temporary:
        root = Path(temporary)
        subprocess.check_call(['tar', '-xzf', str(symbols), '-C', str(root)])
        shutil.copytree(root / 'dSYM', sdk / 'share/ci-dsym', dirs_exist_ok=True)
        for path in (root / 'static').rglob('*'):
            if path.is_file():
                shutil.copy2(path, sdk / path.relative_to(root / 'static'))
        for path in (root / 'bootstrap').rglob('*'):
            if path.is_file():
                shutil.copy2(path, sdk / path.relative_to(root / 'bootstrap'))


def verify(sdk, symbols, source_run=None, source_commit=None):
    with tempfile.TemporaryDirectory(prefix='qt-native-symbol-check-') as temporary:
        root = Path(temporary)
        if symbols.suffix == '.zip':
            with zipfile.ZipFile(symbols) as archive:
                archive.extractall(root)
        else:
            subprocess.check_call(['gzip', '-t', str(symbols)])
            subprocess.check_call(['tar', '-xzf', str(symbols), '-C', str(root)])
        proof = json.loads((root / 'native-symbols.json').read_text())
        require(proof['source_run'] == (source_run or os.environ.get('GITHUB_RUN_ID'))
                and proof['source_commit'] == (source_commit or os.environ.get('GITHUB_SHA')), 'Symbol provenance mismatch')
        require(proof['binaries'], 'Empty symbols manifest')
        for name, checksum in proof.get('files', {}).items():
            require(digest(root / name) == checksum, 'Symbol file hash mismatch: ' + name)
            pdb_identity(root / name)
        covered = set()
        for record in proof['binaries']:
            binary, symbol = sdk / record['binary'], root / record['symbol']
            require(digest(binary) == record['binary_sha256'] and digest(symbol) == record['symbol_sha256'],
                    'Binary/symbol hash mismatch: ' + record['binary'])
            if proof['platform'] == 'windows':
                pe = pe_identity(binary)
                pdb = pdb_identity(symbol)
                require(pdb == {key: pe[key] for key in ('guid', 'age')}
                        == {key: record[key] for key in ('guid', 'age')}, 'PDB GUID/age mismatch')
            elif record['kind'] != 'static archive with original DWARF':
                require(uuids(binary) == uuids(symbol) == record['uuids'], 'dSYM UUID mismatch')
                if record['kind'] == 'dSYM':
                    subprocess.check_call(['dwarfdump', '--verify', str(symbol)], stdout=subprocess.DEVNULL)
                    require('__debug_info' in subprocess.check_output(['otool', '-l', str(symbol)], text=True),
                            'dSYM has no source debug information')
            if proof['platform'] == 'macos':
                require('__debug_info' not in subprocess.check_output(['otool', '-arch', 'all', '-l', str(binary)], text=True),
                        'DWARF remains in binary SDK: ' + record['binary'])
            covered.add(record['binary'])
        if proof['platform'] == 'windows':
            require(not list(sdk.rglob('*.pdb')), 'PDBs remain in binary SDK')
            expected = {p.relative_to(sdk).as_posix() for p in sdk.rglob('*')
                        if p.is_file() and p.suffix.lower() in ('.dll', '.exe') and pe_identity(p) is not None}
        else:
            expected = {p.as_posix() for p in module().binaries(sdk)}
        require(covered == expected, 'Incomplete binary/symbol coverage')
    return dict(archive=symbols.name, sha256=digest(symbols), binaries=len(covered),
                checks=['complete binary coverage', 'binary and symbol hashes', 'matching debug identities'])


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=('capture-macos', 'macos', 'windows', 'restore-macos', 'verify'))
    parser.add_argument('sdk', type=Path)
    parser.add_argument('output', type=Path, nargs='?')
    parser.add_argument('symbols', type=Path, nargs='?')
    parser.add_argument('--source-run')
    parser.add_argument('--source-commit')
    args = parser.parse_args()
    if args.command == 'capture-macos': capture_macos(args.sdk)
    elif args.command == 'macos': macos(args.sdk, args.output, args.symbols)
    elif args.command == 'windows': windows(args.sdk, args.output)
    elif args.command == 'restore-macos': restore_macos(args.sdk, args.output)
    else: print(json.dumps(verify(args.sdk, args.output, args.source_run, args.source_commit)))
