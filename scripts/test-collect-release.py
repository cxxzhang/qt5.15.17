#!/usr/bin/env python3
"""Metadata/PE rejection fixtures; these are not SDK runtime acceptance."""
import importlib.util
import hashlib
import base64
import json
import io
import os
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
win_spec = importlib.util.spec_from_file_location('windows_sdk', Path(__file__).with_name('windows-sdk.py'))
win = importlib.util.module_from_spec(win_spec)
win_spec.loader.exec_module(win)


class PortableWindowsPackage(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.sdk, self.source = self.root / 'SDK with spaces', self.root / 'source'
        for name in ('bin/qmake.exe', 'bin/Qt5Core.dll'):
            path = self.sdk / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b'fixture')
        (self.sdk / 'share').mkdir()
        self.proof = self.sdk / 'share/ci-windows-toolchain.json'
        self.proof.write_text(json.dumps(dict(vc_ltl_active=True, target_arch='x64', variant='release',
                                             runtime_version='5.2.3790.0', platform='x64')))
        runtime = self.source / '.github/VC-LTL'
        for name in ('TargetPlatform/header/corecrt.h', 'TargetPlatform/5.2.3790.0/header/vcruntime.h',
                     'Readme.md', 'Readme.osc.md'):
            path = runtime / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b'fixture')
        for name in ('libucrt.lib', 'libucrtd.lib', 'libvcruntime.lib', 'libvcruntimed.lib'):
            path = runtime / 'TargetPlatform/5.2.3790.0/lib/x64' / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b'fixture')
        (self.source / 'scripts').mkdir()
        (self.source / 'scripts/VC-LTL-LICENSE').write_text('EPL license fixture')
        self.conf = self.sdk / 'mkspecs/common/msvc-desktop.conf'
        self.conf.parent.mkdir(parents=True)
        self.conf.write_text('QMAKE_LFLAGS = /NOLOGO /LIBPATH:../ /LIBPATH:../../../\n' + ''.join(
            'LIBS += YY-Thunks/objs/' + arch + '/YY_Thunks_for_WinXP.obj\n' for arch in ('x86', 'x64')))
        for arch, machine in (('x86', 0x14c), ('x64', 0x8664)):
            path = self.source / 'YY-Thunks/objs' / arch / 'YY_Thunks_for_WinXP.obj'
            path.parent.mkdir(parents=True)
            path.write_bytes(struct.pack('<HHI', machine, 1, 0))
        (self.source / 'YY-Thunks/LICENSE').write_text('MIT license fixture')
        (self.sdk / 'lib').mkdir()
        (self.sdk / 'lib/Qt5UiTools.prl').write_text(
            'QMAKE_PRL_LIBS = YY-Thunks/objs/x64/YY_Thunks_for_WinXP.obj\n'
            'QMAKE_PRL_LIBS_FOR_CMAKE = YY-Thunks/objs/x64/YY_Thunks_for_WinXP.obj;\n')
        self.output = self.root / 'sdk.zip'

    def package(self):
        return win.package(self.sdk, self.source, 'x64', 'release', '123', 'abc', self.output)

    def test_bundles_referenced_objects_and_relocates_paths(self):
        proof = self.package()
        with zipfile.ZipFile(self.output) as sdk:
            for record in proof['thunk_objects'].values():
                self.assertIn(record['path'], sdk.namelist())
            self.assertIn('bin/qt.conf', sdk.namelist())
        config = self.conf.read_text()
        self.assertNotIn('/LIBPATH:../', config)
        self.assertIn('$$quote($$[QT_INSTALL_LIBS]/../mkspecs/YY-Thunks/objs/x64/', config)
        prl = (self.sdk / 'lib/Qt5UiTools.prl').read_text()
        self.assertEqual(prl.count('$$[QT_INSTALL_LIBS]/../mkspecs/YY-Thunks/'), 2)
        win.relocate(self.sdk, self.source)
        self.assertEqual(config, self.conf.read_text())
        self.assertEqual(prl, (self.sdk / 'lib/Qt5UiTools.prl').read_text())

    def test_rejects_wrong_object_machine(self):
        path = self.source / 'YY-Thunks/objs/x64/YY_Thunks_for_WinXP.obj'
        path.write_bytes(struct.pack('<HHI', 0x14c, 1, 0))
        with self.assertRaisesRegex(ValueError, 'Incorrect thunk object machine'):
            self.package()

    def test_rejects_inactive_runtime(self):
        self.proof.write_text(json.dumps(dict(vc_ltl_active=False, target_arch='x64', variant='release')))
        with self.assertRaisesRegex(ValueError, 'active CRT proof'):
            self.package()

    def test_rejects_missing_consumer_runtime(self):
        (self.source / '.github/VC-LTL/TargetPlatform/5.2.3790.0/lib/x64/libucrt.lib').unlink()
        with self.assertRaisesRegex(ValueError, 'Missing consumer VC-LTL runtime'):
            self.package()


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
    def test_symbol_verifier_change_retains_macos_compilation_identity(self):
        tree = [dict(path='qtbase', sha='qt', type='commit'),
                dict(path='onekey-build-macos-x64.sh', sha='compile-with-dwarf', type='blob'),
                dict(path='scripts/native-symbols.py', sha='old-symbol-verifier', type='blob')]
        with mock.patch.object(restore, 'api', return_value=dict(tree=tree)):
            original = restore.inputs('sha', 'macos')
            tree[-1]['sha'] = 'new-symbol-verifier'
            self.assertEqual(original, restore.inputs('sha', 'macos'))
            tree[1]['sha'] = 'changed-compilation'
            self.assertNotEqual(original, restore.inputs('sha', 'macos'))

    def test_transient_api_failure_retried(self):
        error = restore.urllib.error.HTTPError('https://api.github.com/test', 502, 'temporary', None, None)
        with mock.patch.dict(os.environ, {'GITHUB_REPOSITORY': 'fixture/repo', 'GH_TOKEN': 'fixture'}), \
                mock.patch.object(restore.urllib.request, 'urlopen', side_effect=[error, io.BytesIO(b'{"ready":true}')]) as request, \
                mock.patch.object(restore.time, 'sleep'):
            self.assertEqual(restore.api('/test'), {'ready': True})
            self.assertEqual(request.call_count, 2)

    def test_permission_failure_not_retried(self):
        error = restore.urllib.error.HTTPError('https://api.github.com/test', 403, 'denied', None, None)
        with mock.patch.dict(os.environ, {'GITHUB_REPOSITORY': 'fixture/repo', 'GH_TOKEN': 'fixture'}), \
                mock.patch.object(restore.urllib.request, 'urlopen', side_effect=error) as request, \
                mock.patch.object(restore.time, 'sleep'):
            with self.assertRaises(restore.urllib.error.HTTPError): restore.api('/test')
            self.assertEqual(request.call_count, 1)
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
                 'onekey-build-macos-x64.sh': 'mac', '.github/workflows/BuildBinaries.yml': 'workflow',
                 'scripts/verify-vc-ltl.ps1': 'crt-verifier',
                 'YY-Thunks/objs/x64/YY_Thunks_for_WinXP.obj': 'thunks'}
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

    def test_windows_runtime_verifier_change_invalidates_reuse(self):
        self.assertNotEqual(self.identity(), self.identity(**{'scripts/verify-vc-ltl.ps1': 'changed'}))

    def test_thunk_object_change_invalidates_reuse(self):
        self.assertNotEqual(self.identity(), self.identity(**{'YY-Thunks/objs/x64/YY_Thunks_for_WinXP.obj': 'changed'}))

    def test_raw_and_prepacked_windows_restore(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            raw, wrapped = base / 'raw.zip', base / 'wrapper.zip'
            artifact = 'qt5.15.17_windows_x64.zip'
            with zipfile.ZipFile(raw, 'w') as sdk:
                sdk.writestr('bin/qmake.exe', b'qmake')
            with zipfile.ZipFile(wrapped, 'w') as sdk:
                sdk.writestr(artifact, raw.read_bytes())
            for index, archive in enumerate((raw, wrapped)):
                destination = base / str(index)
                destination.mkdir()
                restore.extract_windows_sdk(archive, destination, artifact)
                self.assertEqual((destination / 'bin/qmake.exe').read_bytes(), b'qmake')

    def test_prepacked_restore_rejects_unsafe_inner_path(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            inner, outer = base / 'inner.zip', base / 'outer.zip'
            artifact = 'qt5.15.17_windows_x64.zip'
            with zipfile.ZipFile(inner, 'w') as sdk:
                sdk.writestr('../escape', b'bad')
            with zipfile.ZipFile(outer, 'w') as sdk:
                sdk.writestr(artifact, inner.read_bytes())
            with self.assertRaisesRegex(ValueError, 'Unsafe'):
                restore.extract_windows_sdk(outer, base / 'output', artifact)

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
                    sdk.writestr('share/ci-windows-toolchain.json', json.dumps(dict(
                        vc_ltl_active=True, target_arch=arch, variant='debug' if debug else 'release',
                        toolset_version='14.44.35207', visual_studio_version='18.0',
                        runtime_version={'x86': '5.1.2600.0', 'x64': '5.2.3790.0', 'arm64': '10.0.10240.0'}[arch],
                        platform={'x86': 'Win32', 'x64': 'x64', 'arm64': 'arm64'}[arch],
                        source_run='122', source_commit='f' * 40,
                        checks=['VC-LTL header precedence', 'VC-LTL library precedence',
                                'release and debug CRT libraries present', 'matching target platform'])))
                    objects = {}
                    for cpu, coff_machine in (('x86', 0x14c), ('x64', 0x8664)):
                        name = 'mkspecs/YY-Thunks/objs/' + cpu + '/YY_Thunks_for_WinXP.obj'
                        data = struct.pack('<HHI', coff_machine, 1, 0)
                        sdk.writestr(name, data)
                        objects[cpu] = dict(path=name, sha256=hashlib.sha256(data).hexdigest(), machine=coff_machine)
                    license_path, license_data = 'share/licenses/YY-Thunks-LICENSE', b'license fixture'
                    sdk.writestr(license_path, license_data)
                    sdk.writestr('bin/qt.conf', '[Paths]\nPrefix=..\n')
                    version = {'x86': '5.1.2600.0', 'x64': '5.2.3790.0', 'arm64': '10.0.10240.0'}[arch]
                    platform = {'x86': 'Win32', 'x64': 'x64', 'arm64': 'arm64'}[arch]
                    runtime_paths = ['mkspecs/VC-LTL/TargetPlatform/header/corecrt.h',
                        'mkspecs/VC-LTL/TargetPlatform/' + version + '/header/vcruntime.h', 'share/licenses/VC-LTL-LICENSE']
                    runtime_paths += ['mkspecs/VC-LTL/TargetPlatform/' + version + '/lib/' + platform + '/' + name
                        for name in ('libucrt.lib', 'libucrtd.lib', 'libvcruntime.lib', 'libvcruntimed.lib')]
                    runtime_files = {}
                    for name in runtime_paths:
                        sdk.writestr(name, b'fixture')
                        runtime_files[name] = hashlib.sha256(b'fixture').hexdigest()
                    sdk.writestr('share/ci-windows-packaging.json', json.dumps(dict(
                        target_arch=arch, variant='debug' if debug else 'release', source_run='123', source_commit='abc',
                        consumer_runtime=dict(version=version, platform=platform, files=runtime_files),
                        thunk_objects=objects, thunk_license=dict(path=license_path, sha256=hashlib.sha256(license_data).hexdigest()))))
                self.write(self.proofs / ('verified-windows-' + arch + '-' + ('debug' if debug else 'release') + '.json'),
                           dict(accepted=True, target_arch=arch, variant='debug' if debug else 'release',
                                symbols=self.symbol_fixture(path.name.removesuffix('.zip') + '-symbols.zip'),
                                source_run='123', source_commit='abc', verifier_commit='abc', archive=path.name,
                                sha256=gate.digest(path), checks=['standalone extracted SDK', 'relocated qmake prefix',
                                    'bundled thunk objects', 'C++17 qmake consumer', 'ordinary and wide string round trips',
                                    'offscreen GUI/QML/fonts/TLS runtime', 'consumer PE architecture',
                                    'matching bundled VC-LTL consumer runtime', 'qmake static UiTools consumer']))
        for target, arches in (('x64', ['x86_64']), ('arm64', ['arm64']), ('universal', ['x86_64', 'arm64'])):
            path = self.packages / ('qt5.15.17_macos_' + target + '.tar.gz')
            path.write_bytes(b'fixture')
            for consumer in arches:
                self.write(self.proofs / ('verified-macos-' + target + '-' + consumer + '.json'),
                           dict(accepted=True, source_run='123', source_commit='abc', target=target,
                                symbols=self.symbol_fixture(path.name.removesuffix('.tar.gz') + '-symbols.tar.gz'),
                                consumer_arch=consumer, architectures=arches, archive=path.name, sha256=gate.digest(path),
                                checks=['extracted executable permissions', 'all Mach-O and static archive architectures',
                                        'advertised qmake architectures', 'default native qmake consumer',
                                        'explicit dual-architecture consumer',
                                        'qmake C++17 consumer', 'offscreen GUI/QML/fonts/TLS execution']))

    def write(self, path, value):
        path.write_text(json.dumps(value))

    def symbol_fixture(self, filename):
        path = self.packages / filename
        path.write_bytes(b'symbols fixture')
        return dict(archive=filename, sha256=gate.digest(path), binaries=1,
                    checks=['complete binary coverage', 'binary and symbol hashes', 'matching debug identities'])

    def run_gate(self):
        return gate.collect(self.packages, self.proofs, 'all', '123', 'abc')

    def test_complete_matrix(self):
        self.assertEqual(len(self.run_gate()['assets']), 39)

    def test_native_symbols_tampering(self):
        (self.packages / 'qt5.15.17_macos_universal-symbols.tar.gz').write_bytes(b'wrong symbols')
        with self.assertRaisesRegex(ValueError, 'native symbols archive'):
            self.run_gate()

    def test_missing_windows_consumer(self):
        (self.proofs / 'verified-windows-arm64-debug.json').unlink()
        with self.assertRaisesRegex(ValueError, 'Expected one Windows consumer'):
            self.run_gate()

    def test_windows_consumer_archive_tampering(self):
        path = self.proofs / 'verified-windows-x64-release.json'
        proof = json.loads(path.read_text())
        proof['sha256'] = '0' * 64
        self.write(path, proof)
        with self.assertRaisesRegex(ValueError, 'Windows consumer archive hash'):
            self.run_gate()

    def test_missing_platform(self):
        (self.packages / 'qt5.15.17_windows_arm64.zip').unlink()
        with self.assertRaises(FileNotFoundError):
            self.run_gate()

    def test_missing_windows_compatibility_runtime_proof(self):
        path = self.packages / 'qt5.15.17_windows_x64.zip'
        with zipfile.ZipFile(path) as sdk:
            contents = {n: sdk.read(n) for n in sdk.namelist() if n != 'share/ci-windows-toolchain.json'}
        with zipfile.ZipFile(path, 'w') as sdk:
            for name, data in contents.items():
                sdk.writestr(name, data)
        with self.assertRaisesRegex(ValueError, 'missing VC-LTL'):
            self.run_gate()

    def test_windows_runtime_proof_rejection(self):
        path = self.packages / 'qt5.15.17_windows_x64.zip'
        proof_name = 'share/ci-windows-toolchain.json'
        with zipfile.ZipFile(path) as sdk:
            contents = {n: sdk.read(n) for n in sdk.namelist()}
        original = json.loads(contents[proof_name])
        for change in ({'vc_ltl_active': False}, {'target_arch': 'x86'}, {'variant': 'debug'},
                       {'runtime_version': '10.0.10240.0'}, {'toolset_version': '14.51.0'},
                       {'checks': []}, {'source_run': None}):
            with self.subTest(change=change):
                proof = {**original, **change}
                with zipfile.ZipFile(path, 'w') as sdk:
                    for name, data in contents.items():
                        sdk.writestr(name, json.dumps(proof) if name == proof_name else data)
                with self.assertRaisesRegex(ValueError, 'VC-LTL'):
                    self.run_gate()

    def test_wrong_windows_architecture(self):
        source = self.packages / 'qt5.15.17_windows_x86.zip'
        (self.packages / 'qt5.15.17_windows_arm64.zip').write_bytes(source.read_bytes())
        with self.assertRaisesRegex(ValueError, 'DLL architecture'):
            self.run_gate()

    def test_windows_consumer_runtime_tampering(self):
        path = self.packages / 'qt5.15.17_windows_x64.zip'
        with zipfile.ZipFile(path) as sdk:
            contents = {name: sdk.read(name) for name in sdk.namelist()}
        name = 'mkspecs/VC-LTL/TargetPlatform/5.2.3790.0/lib/x64/libucrt.lib'
        contents[name] = b'changed runtime'
        with zipfile.ZipFile(path, 'w') as sdk:
            for name, data in contents.items():
                sdk.writestr(name, data)
        with self.assertRaisesRegex(ValueError, 'consumer CRT hash mismatch'):
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
