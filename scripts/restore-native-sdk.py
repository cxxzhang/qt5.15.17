#!/usr/bin/env python3
"""Reuse a native build only when recorded source and build configuration match."""

import argparse
import base64
import hashlib
import json
import os
import re
from pathlib import Path, PurePosixPath
import subprocess
import tempfile
import time
import urllib.request
import urllib.error
import zipfile


def api(path):
    path += ('&' if '?' in path else '?') + '_qt_native_ci=' + str(time.time_ns())
    request = urllib.request.Request('https://api.github.com/repos/' + os.environ['GITHUB_REPOSITORY'] + path,
                                     headers={'Authorization': 'Bearer ' + os.environ['GH_TOKEN'],
                                              'Accept': 'application/vnd.github+json', 'User-Agent': 'qt-native-reuse',
                                              'Cache-Control': 'no-cache'})
    for attempt in range(6):
        try:
            with urllib.request.urlopen(request, timeout=45) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            if error.code not in (429, 500, 502, 503, 504) or attempt == 5:
                raise
            print('Transient GitHub API status {}; retrying'.format(error.code), flush=True)
        except (urllib.error.URLError, TimeoutError):
            if attempt == 5:
                raise
            print('Transient GitHub API connection failure; retrying', flush=True)
        time.sleep(min(2 ** (attempt + 1), 60))


def native_configuration(content, job):
    lines = content.splitlines()
    start = lines.index('  ' + job + ':')
    end = next((i for i in range(start + 1, len(lines)) if re.match(r'^  \S', lines[i])), len(lines))
    block = lines[start:end]
    steps = block.index('    steps:')
    selected = block[:steps]
    sections = []
    for line in block[steps + 1:]:
        if line.startswith('    - '):
            sections.append([])
        if sections:
            sections[-1].append(line)
    for section in sections:
        if any(marker in section[0] for marker in (
                'name: Clone repository', 'name: Set up VC-LTL', 'name: Build qt5', 'uses: actions/checkout@')):
            selected.extend(line for line in section if "if: steps.native-cache.outputs.restored" not in line)
    for key in ('env:', 'defaults:'):
        if key in lines:
            first = lines.index(key)
            last = next((i for i in range(first + 1, len(lines)) if lines[i] and not lines[i][0].isspace()), len(lines))
            selected.extend(lines[first:last])
    return '\n'.join(line.rstrip() for line in selected if line.strip())


def inputs(commit, kind, job=None):
    tree = api('/git/trees/' + commit + '?recursive=1')
    if tree.get('truncated'):
        raise ValueError('Cannot verify a truncated source tree')
    result = {}
    for entry in tree['tree']:
        name = entry['path']
        selected = (entry['type'] == 'commit' or name in ('.gitmodules', 'configure', 'configure.bat', 'qt.pro', '.qmake.conf')
                    or '/' not in name and name.endswith(('.pri', '.pro', '.conf')) or name.startswith('openssl/'))
        if kind == 'windows':
            script = 'onekey-build-' + job + '.bat' if job else None
            selected |= (name == script if script else name.startswith('onekey-build-windows-')) or name == 'apply-patches.bat'
            selected |= name == 'Patches/0001-qtbase-support-xp.patch'
            selected |= name in ('.github/workflows/setup-vc-ltl.bat', '.github/workflows/VC-LTL helper for nmake.cmd')
            selected |= name in ('scripts/force-runtime.ps1', 'scripts/verify-vc-ltl.ps1')
            selected |= name.startswith('YY-Thunks/objs/')
        else:
            script = 'onekey-build-' + job + '.sh' if job else None
            selected |= name == script if script else name.startswith('onekey-build-macos-')
        if selected:
            result[name] = entry['sha']
    if not any(name == 'qtbase' for name in result):
        raise ValueError('Missing Qt source identities')
    if job:
        workflow = next(entry for entry in tree['tree'] if entry['path'] == '.github/workflows/BuildBinaries.yml')
        blob = api('/git/blobs/' + workflow['sha'])
        content = base64.b64decode(blob['content']).decode('utf-8')
        config = native_configuration(content, job)
        result['@native-job-configuration'] = hashlib.sha256(config.encode('utf-8')).hexdigest()
    return result


def output(restored):
    with open(os.environ['GITHUB_OUTPUT'], 'a', encoding='utf-8') as stream:
        stream.write('restored=' + str(restored).lower() + '\n')


def safe_zip(archive):
    for name in archive.namelist():
        path = PurePosixPath(name.replace('\\', '/'))
        if path.is_absolute() or '..' in path.parts or ':' in str(path):
            raise ValueError('Unsafe source archive path')


def extract_windows_sdk(archive, destination, artifact):
    with zipfile.ZipFile(archive) as outer:
        safe_zip(outer)
        files = [i.filename for i in outer.infolist() if not i.is_dir()]
        if files == [artifact]:
            with tempfile.TemporaryDirectory(prefix='qt-prepacked-sdk-') as temporary:
                outer.extractall(temporary)
                with zipfile.ZipFile(Path(temporary, artifact)) as inner:
                    safe_zip(inner)
                    inner.extractall(destination)
        else:
            outer.extractall(destination)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run', required=True)
    parser.add_argument('--job', required=True)
    parser.add_argument('--artifact', required=True)
    parser.add_argument('--kind', choices=('windows', 'macos'), required=True)
    parser.add_argument('--destination', type=Path, required=True)
    parser.add_argument('--wait-seconds', type=int, default=5 * 3600)
    args = parser.parse_args()
    if not args.run.isdigit() or args.run == os.environ['GITHUB_RUN_ID']:
        raise ValueError('Expected a different numeric source run')
    source = api('/actions/runs/' + args.run)
    if source['path'].split('@')[0] != '.github/workflows/BuildBinaries.yml':
        raise ValueError('Native reuse requires the repository build workflow')
    original = inputs(source['head_sha'], args.kind, args.job)
    if original != inputs(os.environ['GITHUB_SHA'], args.kind, args.job):
        print('Native compilation inputs changed; rebuild instead of reusing this run')
        output(False)
        return
    deadline = time.monotonic() + args.wait_seconds
    while True:
        jobs = api('/actions/runs/' + args.run + '/jobs?per_page=100')['jobs']
        matches = [job for job in jobs if job['name'] == args.job]
        if len(matches) != 1:
            raise ValueError('Expected exactly one source native job: ' + args.job)
        job = matches[0]
        if job['status'] == 'completed':
            break
        if time.monotonic() > deadline:
            print('No completed source SDK within the reuse wait budget; build in this job')
            output(False)
            return
        print('Waiting for source build ' + args.job, flush=True)
        time.sleep(60)
    if job['conclusion'] != 'success':
        print('Source native build did not succeed; build locally in this job')
        output(False)
        return
    artifacts = api('/actions/runs/' + args.run + '/artifacts?per_page=100')['artifacts']
    matches = [item for item in artifacts if item['name'] == args.artifact and not item['expired']]
    if len(matches) != 1:
        raise ValueError('Expected one successful source SDK artifact')
    with tempfile.TemporaryDirectory(prefix='qt-native-restore-') as temp:
        archive = Path(temp, 'artifact.zip')
        with archive.open('wb') as stream:
            subprocess.check_call(['gh', 'api', 'repos/' + os.environ['GITHUB_REPOSITORY'] +
                                   '/actions/artifacts/' + str(matches[0]['id']) + '/zip'], stdout=stream)
        destination = args.destination.resolve()
        if destination.exists() and any(destination.iterdir()):
            raise ValueError('Refusing to mix SDK directories: ' + str(destination))
        destination.mkdir(parents=True, exist_ok=True)
        if args.kind == 'windows':
            extract_windows_sdk(archive, destination, args.artifact)
        else:
            with zipfile.ZipFile(archive) as sdk:
                safe_zip(sdk)
                sdk.extractall(temp)
                packages = list(Path(temp).glob('*.tar.gz'))
                if len(packages) != 1:
                    raise ValueError('Expected the prepackaged macOS SDK')
                subprocess.check_call(['tar', '-xzf', str(packages[0]), '-C', str(destination)])
        record = dict(source_run=args.run, source_commit=source['head_sha'], source_job=job['id'],
                      source_artifact=matches[0]['id'], packaging_commit=os.environ['GITHUB_SHA'],
                      compilation_inputs=original, policy='Unverified install; all current packaging and acceptance gates repeat')
        provenance = destination / 'share/ci-native-source.json'
        if provenance.is_file():
            record['previous'] = json.loads(provenance.read_text(encoding='utf-8'))
        provenance.parent.mkdir(parents=True, exist_ok=True)
        provenance.write_text(json.dumps(record, indent=2) + '\n', encoding='utf-8')
    output(True)
    print('Restored native SDK from matching source inputs; current acceptance is still required')


if __name__ == '__main__':
    main()
