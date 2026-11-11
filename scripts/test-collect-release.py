#!/usr/bin/env python3
"""Metadata/PE rejection fixtures; these are not SDK runtime acceptance."""
import importlib.util
import json
from pathlib import Path
import struct
import tempfile
import unittest
import zipfile

spec = importlib.util.spec_from_file_location('release_gate', Path(__file__).with_name('collect-release.py'))
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


class ReleaseGate(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.packages, self.proofs = (Path(self.temp.name) / n for n in ('packages', 'proofs'))
        self.packages.mkdir()
        self.proofs.mkdir()
        sdks = []
        for target in ('x64', 'arm64', 'mips64el', 'loong64-oldworld', 'loong64-newworld'):
            for variant in ('release', 'debug'):
                archives = {}
                for suffix in ('.tar.gz', '-symbols.tar.gz'):
                    name = target + '-' + variant + suffix
                    path = self.packages / name
                    path.write_bytes(name.encode())
                    archives[name] = gate.digest(path)
                sdks.append(dict(target=target, variant=variant, archives=archives))
        self.write(self.packages / 'linux-acceptance-manifest.json',
                   dict(accepted=True, source_run='123', source_commit='abc', sdks=sdks))
        for arch, machine in (('x86', 0x14c), ('x64', 0x8664), ('arm64', 0xaa64)):
            for debug in (False, True):
                suffix = 'd' if debug else ''
                path = self.packages / ('qt5.15.17_windows_' + arch + ('_debug' if debug else '') + '.zip')
                pe = bytearray(70)
                pe[:2] = b'MZ'
                struct.pack_into('<I', pe, 60, 64)
                pe[64:68] = b'PE\0\0'
                struct.pack_into('<H', pe, 68, machine)
                with zipfile.ZipFile(path, 'w') as sdk:
                    sdk.writestr('bin/qmake.exe', b'fixture')
                    sdk.writestr('lib/Qt5Core' + suffix + '.lib', b'fixture')
                    for module in ('Core', 'Gui', 'Network', 'Qml'):
                        sdk.writestr('bin/Qt5' + module + suffix + '.dll', pe)
        for target, arches in (('x64', ['x86_64']), ('arm64', ['arm64']), ('universal', ['x86_64', 'arm64'])):
            path = self.packages / ('qt5.15.17_macos_' + target + '.tar.gz')
            path.write_bytes(b'fixture')
            for consumer in arches:
                self.write(self.proofs / ('verified-macos-' + target + '-' + consumer + '.json'),
                           dict(accepted=True, source_run='123', source_commit='abc', target=target,
                                consumer_arch=consumer, architectures=arches, archive=path.name, sha256=gate.digest(path),
                                checks=['extracted executable permissions', 'all Mach-O and static archive architectures',
                                        'qmake C++17 consumer', 'offscreen GUI/QML/fonts/TLS execution']))

    def write(self, path, value):
        path.write_text(json.dumps(value))

    def run_gate(self):
        return gate.collect(self.packages, self.proofs, 'all', '123', 'abc')

    def test_complete_matrix(self):
        self.assertEqual(len(self.run_gate()['assets']), 30)

    def test_missing_platform(self):
        (self.packages / 'qt5.15.17_windows_arm64.zip').unlink()
        with self.assertRaises(FileNotFoundError):
            self.run_gate()

    def test_wrong_windows_architecture(self):
        source = self.packages / 'qt5.15.17_windows_x86.zip'
        (self.packages / 'qt5.15.17_windows_arm64.zip').write_bytes(source.read_bytes())
        with self.assertRaisesRegex(ValueError, 'DLL architecture'):
            self.run_gate()

    def test_universal_needs_both_native_consumers(self):
        (self.proofs / 'verified-macos-universal-x86_64.json').unlink()
        with self.assertRaisesRegex(ValueError, 'Expected one macOS proof'):
            self.run_gate()

    def test_archive_tampering(self):
        (self.packages / 'qt5.15.17_macos_arm64.tar.gz').write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError, 'hash mismatch'):
            self.run_gate()

    def test_different_source_commit(self):
        path = self.proofs / 'verified-macos-arm64-arm64.json'
        value = json.loads(path.read_text())
        value['source_commit'] = 'other'
        self.write(path, value)
        with self.assertRaisesRegex(ValueError, 'provenance'):
            self.run_gate()


if __name__ == '__main__':
    unittest.main()
