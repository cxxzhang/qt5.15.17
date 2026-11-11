#!/usr/bin/env python3
"""Metadata/PE rejection fixtures; these are not SDK runtime acceptance."""
import importlib.util
import base64
import json
from pathlib import Path
import struct
import tempfile
import unittest
from unittest import mock
import zipfile

spec = importlib.util.spec_from_file_location('release_gate', Path(__file__).with_name('collect-release.py'))
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)
restore_spec = importlib.util.spec_from_file_location('native_restore', Path(__file__).with_name('restore-native-sdk.py'))
restore = importlib.util.module_from_spec(restore_spec)
restore_spec.loader.exec_module(restore)
mac_spec = importlib.util.spec_from_file_location('mac_sdk', Path(__file__).with_name('macos-sdk.py'))
mac = importlib.util.module_from_spec(mac_spec)
mac_spec.loader.exec_module(mac)


class UniversalMetadata(unittest.TestCase):
    def test_architecture_expressions_evaluated_by_qmake(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with mock.patch.object(mac.subprocess, 'check_output', return_value='Project MESSAGE: CI_SDK_ARCHS=x86_64\n'):
                self.assertEqual(mac.advertised_architectures(root, root), {'x86_64'})
            self.assertIn('$$QT_ARCHS', (root / 'sdk-architectures.pro').read_text())

    def test_only_private_openssl_search_paths_removed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = root / 'QtNetwork.prl'
            config.write_text('QMAKE_PRL_LIBS = -L/build/install/macos-x64/lib -L/another/lib -framework Security\n')
            mac.relocate(root)
            self.assertNotIn('/build/install', config.read_text())
            self.assertIn('-L/another/lib', config.read_text())

    def test_both_architectures_advertised(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'mkspecs').mkdir()
            config = root / 'mkspecs/qconfig.pri'
            config.write_text('QT_ARCH = arm64\nQT_ARCHS = arm64\nQT_VERSION = 5.15.17\n')
            mac.advertise_universal(root)
            self.assertIn('QT_ARCHS = x86_64 arm64', config.read_text())
            self.assertIn('QT_ARCH = arm64', config.read_text())

    def test_missing_metadata_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'mkspecs').mkdir()
            (root / 'mkspecs/qconfig.pri').write_text('QT_ARCH = arm64\n')
            with self.assertRaisesRegex(ValueError, 'QT_ARCHS'):
                mac.advertise_universal(root)


class NativeInputs(unittest.TestCase):
    def test_unrelated_architecture_script_does_not_invalidate_reuse(self):
        workflow = 'jobs:\n  windows-x64:\n    runs-on: windows-latest\n    steps:\n    - name: Build qt5\n      run: call onekey-build-windows-x64.bat\n'
        tree = [dict(path='qtbase', sha='qt', type='commit'),
                dict(path='onekey-build-windows-x64.bat', sha='x64', type='blob'),
                dict(path='onekey-build-windows-arm64.bat', sha='arm', type='blob'),
                dict(path='.github/workflows/BuildBinaries.yml', sha='workflow', type='blob')]
        def api(path):
            if '/git/trees/' in path: return dict(tree=tree)
            return dict(content=base64.b64encode(workflow.encode()).decode())
        with mock.patch.object(restore, 'api', side_effect=api):
            original = restore.inputs('sha', 'windows', 'windows-x64')
            tree[2]['sha'] = 'new-arm-compiler'
            self.assertEqual(original, restore.inputs('sha', 'windows', 'windows-x64'))
    def test_native_configuration_changes_invalidate_reuse(self):
        config = 'jobs:\n  windows-x64:\n    runs-on: windows-latest\n    steps:\n    - name: Build qt5\n      run: call build.bat\n    - name: Package SDK\n      run: package\n'
        original = restore.native_configuration(config, 'windows-x64')
        self.assertNotEqual(original, restore.native_configuration(config.replace('call build.bat', 'call changed.bat'), 'windows-x64'))
        self.assertNotEqual(original, restore.native_configuration(config.replace('windows-latest', 'windows-2022'), 'windows-x64'))
        self.assertEqual(original, restore.native_configuration(config.replace('run: package', 'run: changed-package'), 'windows-x64'))
    def identity(self, **changes):
        files = {'qtbase': 'qt', 'configure': 'config', 'onekey-build-windows-x64.bat': 'win',
                 'onekey-build-macos-x64.sh': 'mac', '.github/workflows/BuildBinaries.yml': 'workflow'}
        files.update(changes)
        tree = [dict(path=name, sha=value, type='commit' if name == 'qtbase' else 'blob') for name, value in files.items()]
        with mock.patch.object(restore, 'api', return_value=dict(tree=tree)):
            return restore.inputs('commit', 'windows')

    def test_submodule_change_invalidates_reuse(self):
        self.assertNotEqual(self.identity(), self.identity(qtbase='changed'))

    def test_configure_change_invalidates_reuse(self):
        self.assertNotEqual(self.identity(), self.identity(configure='changed'))

    def test_native_script_change_invalidates_reuse(self):
        self.assertNotEqual(self.identity(), self.identity(**{'onekey-build-windows-x64.bat': 'changed'}))

    def test_packaging_workflow_change_retains_compile_identity(self):
        self.assertEqual(self.identity(), self.identity(**{'.github/workflows/BuildBinaries.yml': 'changed'}))


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
                                        'advertised qmake architectures', 'default native qmake consumer',
                                        'explicit dual-architecture consumer',
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
