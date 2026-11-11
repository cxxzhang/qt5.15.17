#!/usr/bin/env python3
"""Exercise matrix/provenance/hash gates; fixtures are not SDK runtime acceptance."""

import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location('collector', Path(__file__).with_name('collect-acceptance.py'))
COLLECTOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(COLLECTOR)


class AcceptanceGate(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.sdk, self.proofs, self.modern = (self.root / p for p in ('sdk', 'proofs', 'modern'))
        for path in (self.sdk, self.proofs, self.modern):
            path.mkdir()
        self.commit = 'a' * 40
        self.targets = {'x64': {'glibc': '2.17'}, 'mips64el': {'glibc': '2.17'}}
        self.tools = {a: dict(gnu_runtime_policy='baseline-system', sha256='b' * 64) for a in self.targets}
        for arch in self.targets:
            name = 'qt5.15.17_linux_' + arch
            archives = {}
            for suffix in ('.tar.gz', '-symbols.tar.gz'):
                path = self.sdk / (name + suffix)
                path.write_bytes((arch + suffix).encode())
                archives[suffix] = COLLECTOR.digest(path)
            base = dict(accepted=True, source_run='123', source_commit=self.commit,
                        verifier_commit=self.commit, target=arch, variant='release')
            proof = dict(base, glibc='2.17', gnu_runtime_policy='baseline-system', archives=archives,
                         checks=['ELF ABI/versions/strip', 'matching symbols/debuglink CRC',
                                 'selected C++ runtime resolution', 'extracted qmake C++17 consumer',
                                 'offscreen GUI/QML/fonts/TLS runtime'])
            self.write(self.proofs / ('verified-' + arch + '-release.json'), proof)
            gnu = dict(base, files={'lib/libQt5Core.so': ['GLIBCXX_3.4.19']}, missing={},
                       maximum_required_versions={'GLIBCXX': 'GLIBCXX_3.4.19', 'CXXABI': 'CXXABI_1.3.7', 'GCC': 'GCC_3.0'})
            self.write(self.proofs / ('gnu-requirements-' + arch + '-release.json'), gnu)
            if arch == 'mips64el':
                self.write(self.proofs / ('gnu-requirements-' + arch + '-release-host.json'), gnu)
            else:
                modern = dict(base, archives={name + suffix: value for suffix, value in archives.items()},
                              compilers={'gcc': 'GCC fixture', 'clang': 'Clang fixture'},
                              checks=['same extracted Qt SDK', 'no bundled GNU shared runtime',
                                      'GCC and Clang C++17 consumers', 'GUI/QML/fonts/TLS execution'])
                self.write(self.modern / 'modern-consumers-x64-release.json', modern)

    def write(self, path, record):
        path.write_text(json.dumps(record))

    def run_gate(self, variants=('release',)):
        return COLLECTOR.collect(self.sdk, self.proofs, self.modern, tuple(self.targets), variants,
                                 '123', self.commit, self.targets, self.tools)

    def test_complete_native_and_cross_matrix(self):
        self.assertEqual(len(self.run_gate()['sdks']), 2)

    def test_missing_variant_blocks_acceptance(self):
        with self.assertRaisesRegex(ValueError, 'Expected exactly one'):
            self.run_gate(('release', 'debug'))

    def test_changed_archive_blocks_acceptance(self):
        (self.sdk / 'qt5.15.17_linux_x64.tar.gz').write_bytes(b'different archive')
        with self.assertRaisesRegex(ValueError, 'archive hash mismatch'):
            self.run_gate()

    def test_missing_modern_consumer_blocks_acceptance(self):
        (self.modern / 'modern-consumers-x64-release.json').unlink()
        with self.assertRaisesRegex(ValueError, 'Expected exactly one'):
            self.run_gate()

    def test_different_source_commit_blocks_acceptance(self):
        path = self.proofs / 'verified-x64-release.json'
        record = json.loads(path.read_text())
        record['source_commit'] = 'c' * 40
        self.write(path, record)
        with self.assertRaisesRegex(ValueError, 'source commit mismatch'):
            self.run_gate()

    def test_unselected_archive_blocks_acceptance(self):
        (self.sdk / 'unexpected-sdk.tar.gz').write_bytes(b'unselected')
        with self.assertRaisesRegex(ValueError, 'Unexpected or duplicate'):
            self.run_gate()

    def test_high_runtime_policy_blocks_acceptance(self):
        path = self.proofs / 'verified-x64-release.json'
        record = json.loads(path.read_text())
        record['gnu_runtime_policy'] = 'legacy-bundled'
        self.write(path, record)
        with self.assertRaisesRegex(ValueError, 'legacy GNU policy'):
            self.run_gate()


if __name__ == '__main__':
    unittest.main()
