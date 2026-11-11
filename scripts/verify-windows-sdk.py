#!/usr/bin/env python3
"""Consume a delivered Windows SDK outside all Qt source/build directories."""
import argparse
import importlib.util
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import stat
import struct
import subprocess
import sys
import tempfile
import zipfile

if hasattr(sys.stdout, 'reconfigure'):
    sys.stdout.reconfigure(errors='backslashreplace')

spec = importlib.util.spec_from_file_location('windows_sdk', Path(__file__).with_name('windows-sdk.py'))
sdk_tools = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sdk_tools)


def run(command, cwd, log, env=None, timeout=300):
    with log.open('wb') as stream:
        process = subprocess.Popen(command, cwd=cwd, env=env, stdout=stream, stderr=subprocess.STDOUT,
                                   creationflags=subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0)
        try:
            code = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            if process.poll() is None:
                if os.name == 'nt':
                    subprocess.run(['taskkill', '/PID', str(process.pid), '/T', '/F'],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                else:
                    process.kill()
                process.wait()
            raise RuntimeError('SDK consumer timed out: ' + str(command[0])) from None
    if code:
        print(log.read_text(encoding='utf-8', errors='replace')[-16000:])
        raise RuntimeError('SDK consumer command failed (exit {} / 0x{:08x}): {}'.format(
            code, code & 0xffffffff, command[0]))


def extract(archive, destination):
    with zipfile.ZipFile(archive) as sdk:
        seen = set()
        for item in sdk.infolist():
            path = PurePosixPath(item.filename.replace('\\', '/'))
            sdk_tools.require(not path.is_absolute() and '..' not in path.parts and ':' not in str(path),
                              'Unsafe Windows SDK archive member')
            sdk_tools.require(not stat.S_ISLNK(item.external_attr >> 16), 'Unexpected SDK symlink')
            if not item.is_dir():
                key = str(path).casefold()
                sdk_tools.require(key not in seen, 'Duplicate Windows SDK archive member')
                seen.add(key)
        sdk.extractall(destination)


def fixture(source, work, variant):
    text = (source / 'scripts/smoke-linux.sh').read_text(encoding='utf-8').replace('\r\n', '\n')
    for name in ('main.cpp', 'tls.qrc', 'smoke.pro'):
        marker = 'cat >"$work/' + name + '" <<\'EOF\'\n'
        sdk_tools.require(text.count(marker) == 1, 'Cannot locate shared SDK fixture: ' + name)
        body = text.split(marker, 1)[1].split('\nEOF', 1)[0] + '\n'
        if name == 'smoke.pro':
            body += 'CONFIG -= debug release debug_and_release\nCONFIG += ' + variant + '\nDESTDIR = .\n'
        (work / name).write_text(body, encoding='utf-8')
    for name in ('server.crt', 'server.key'):
        shutil.copyfile(source / 'scripts/smoke-tls' / name, work / name)


def verify(archive, target, variant, source_run, source_commit, source, logs):
    logs.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='qt-windows-consumer-') as temporary:
        base = Path(temporary)
        sdk, work = base / 'Qt SDK with spaces', base / 'application with spaces'
        sdk.mkdir()
        work.mkdir()
        extract(archive, sdk)
        packaging = json.loads((sdk / 'share/ci-windows-packaging.json').read_text(encoding='utf-8'))
        sdk_tools.require(packaging['target_arch'] == target and packaging['variant'] == variant
                          and packaging['source_run'] == str(source_run)
                          and packaging['source_commit'] == source_commit, 'Windows packaging provenance mismatch')
        runtime = json.loads((sdk / 'share/ci-windows-toolchain.json').read_text(encoding='utf-8'))
        sdk_tools.require(runtime.get('vc_ltl_active') is True and runtime['target_arch'] == target
                          and runtime['variant'] == variant, 'Invalid SDK compiler/runtime proof')
        consumer_runtime = packaging['consumer_runtime']
        sdk_tools.require(consumer_runtime['version'] == runtime['runtime_version']
                          and consumer_runtime['platform'] == runtime['platform'], 'Consumer CRT does not match Qt')
        for path, checksum in consumer_runtime['files'].items():
            sdk_tools.require(sdk_tools.digest(sdk / path) == checksum, 'Consumer CRT file changed: ' + path)
        for arch, machine in (('x86', 0x14c), ('x64', 0x8664)):
            record = packaging['thunk_objects'][arch]
            path = sdk / ('mkspecs/YY-Thunks/objs/' + arch + '/YY_Thunks_for_WinXP.obj')
            sdk_tools.require(sdk_tools.coff_machine(path) == machine and sdk_tools.digest(path) == record['sha256'],
                              'Packaged thunk does not match its proof: ' + arch)
        qmake = str(sdk / 'bin/qmake.exe')
        version = subprocess.check_output([qmake, '-query', 'QT_VERSION'], cwd=work, text=True).strip()
        prefix = subprocess.check_output([qmake, '-query', 'QT_INSTALL_PREFIX'], cwd=work, text=True).strip()
        sdk_tools.require(version == '5.15.17', 'Incorrect extracted qmake version')
        sdk_tools.require(str(Path(prefix).resolve()).casefold() == str(sdk.resolve()).casefold(),
                          'Extracted qmake still uses a build/install path: ' + prefix)
        fixture(source, work, variant)
        environment = dict(os.environ)
        for name in ('QTDIR', 'QMAKEPATH', 'QMAKEFEATURES', 'QMAKESPEC', 'QT_PLUGIN_PATH', 'QT_QPA_PLATFORM_PLUGIN_PATH'):
            environment.pop(name, None)
        environment['PATH'] = str(sdk / 'bin') + os.pathsep + environment['PATH']
        run([qmake, 'smoke.pro'], work, logs / 'windows-qmake.log', environment)
        run(['nmake', '/nologo'], work, logs / 'windows-build.log', environment)
        program = work / 'smoke.exe'
        with program.open('rb') as stream:
            header = stream.read(64)
            sdk_tools.require(header[:2] == b'MZ', 'Consumer is not a PE executable')
            stream.seek(struct.unpack_from('<I', header, 60)[0])
            coff = stream.read(6)
        sdk_tools.require(coff[:4] == b'PE\0\0' and struct.unpack_from('<H', coff, 4)[0] ==
                          {'x86': 0x14c, 'x64': 0x8664, 'arm64': 0xaa64}[target], 'Incorrect consumer machine')
        environment.update(QT_QPA_PLATFORM='offscreen', QML2_IMPORT_PATH=str(sdk / 'qml'),
                           QT_QPA_FONTDIR=str(Path(os.environ['WINDIR']) / 'Fonts'), QT_FORCE_STDERR_LOGGING='1')
        run([str(program)], work, logs / 'windows-runtime.log', environment, timeout=90)
        static = base / 'static consumer with spaces'
        static.mkdir()
        (static / 'main.cpp').write_text(r'''#include <QtWidgets/QApplication>
#include <QtWidgets/QWidget>
#include <QtUiTools/QUiLoader>
#include <QtCore/QBuffer>
#include <QtCore/QScopedPointer>
int main(int argc, char **argv) {
    QApplication app(argc, argv);
    QBuffer xml;
    xml.setData("<ui version=\"4.0\"><class>Probe</class><widget class=\"QWidget\" name=\"staticSdkProbe\"/></ui>");
    if (!xml.open(QIODevice::ReadOnly)) return 1;
    QUiLoader loader;
    QScopedPointer<QWidget> widget(loader.load(&xml));
    return !(widget && widget->objectName() == QStringLiteral("staticSdkProbe"));
}
''', encoding='utf-8')
        (static / 'static.pro').write_text('QT += widgets uitools\nTEMPLATE = app\nTARGET = static-probe\n'
            'CONFIG += console c++17\nCONFIG -= debug release debug_and_release\nCONFIG += ' + variant
            + '\nDESTDIR = .\nSOURCES += main.cpp\n', encoding='utf-8')
        run([qmake, 'static.pro'], static, logs / 'windows-static-qmake.log', environment)
        run(['nmake', '/nologo'], static, logs / 'windows-static-build.log', environment)
        run([str(static / 'static-probe.exe')], static, logs / 'windows-static-runtime.log', environment, timeout=90)
    proof = dict(accepted=True, target_arch=target, variant=variant, source_run=str(source_run),
                 source_commit=source_commit, verifier_commit=os.environ['GITHUB_SHA'], archive=archive.name,
                 sha256=sdk_tools.digest(archive), compiler=os.environ.get('VCToolsVersion'),
                 checks=['standalone extracted SDK', 'relocated qmake prefix', 'bundled thunk objects',
                         'C++17 qmake consumer', 'ordinary and wide string round trips',
                         'offscreen GUI/QML/fonts/TLS runtime', 'consumer PE architecture',
                         'matching bundled VC-LTL consumer runtime', 'qmake static UiTools consumer'])
    (logs / ('verified-windows-' + target + '-' + variant + '.json')).write_text(
        json.dumps(proof, indent=2) + '\n', encoding='utf-8')
    print('Extracted Windows SDK consumer passed:', target, variant)
    return proof


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archive', type=Path, required=True)
    parser.add_argument('--target', choices=('x86', 'x64', 'arm64'), required=True)
    parser.add_argument('--variant', choices=('release', 'debug'), required=True)
    parser.add_argument('--source-run', required=True)
    parser.add_argument('--source-commit', required=True)
    parser.add_argument('--logs', type=Path, default=Path('build-temp/logs'))
    args = parser.parse_args()
    verify(args.archive.resolve(), args.target, args.variant, args.source_run, args.source_commit,
           Path(__file__).resolve().parents[1], args.logs.resolve())
