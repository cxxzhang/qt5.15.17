#!/usr/bin/env python3
"""Reuse a successful native build only when every compilation input matches."""

import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import urllib.request
import zipfile


def api(path):
    request = urllib.request.Request('https://api.github.com/repos/' + os.environ['GITHUB_REPOSITORY'] + path,
                                     headers={'Authorization': 'Bearer ' + os.environ['GH_TOKEN'],
                                              'Accept': 'application/vnd.github+json', 'User-Agent': 'qt-native-reuse'})
    with urllib.request.urlopen(request, timeout=45) as response:
        return json.load(response)


def inputs(commit, kind):
    tree = api('/git/trees/' + commit + '?recursive=1')
    if tree.get('truncated'):
        raise ValueError('Cannot verify a truncated source tree')
    result = {}
    for entry in tree['tree']:
        name = entry['path']
        selected = (entry['type'] == 'commit' or name in ('.gitmodules', 'configure', 'configure.bat', 'qt.pro', '.qmake.conf')
                    or '/' not in name and name.endswith(('.pri', '.pro', '.conf')) or name.startswith('openssl/'))
        if kind == 'windows':
            selected |= name.startswith('onekey-build-windows-') or name == 'apply-patches.bat'
            selected |= name == 'Patches/0001-qtbase-support-xp.patch'
            selected |= name in ('.github/workflows/setup-vc-ltl.bat', '.github/workflows/VC-LTL helper for nmake.cmd')
        else:
            selected |= name.startswith('onekey-build-macos-')
        if selected:
            result[name] = entry['sha']
    if not any(name == 'qtbase' for name in result):
        raise ValueError('Missing Qt source identities')
    return result


def output(restored):
    with open(os.environ['GITHUB_OUTPUT'], 'a', encoding='utf-8') as stream:
        stream.write('restored=' + str(restored).lower() + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run', required=True)
    parser.add_argument('--job', required=True)
    parser.add_argument('--artifact', required=True)
    parser.add_argument('--kind', choices=('windows', 'macos'), required=True)
    parser.add_argument('--destination', type=Path, required=True)
    args = parser.parse_args()
    if not args.run.isdigit() or args.run == os.environ['GITHUB_RUN_ID']:
        raise ValueError('Expected a different numeric source run')
    source = api('/actions/runs/' + args.run)
    if source['path'].split('@')[0] != '.github/workflows/BuildBinaries.yml':
        raise ValueError('Native reuse requires the repository build workflow')
    original = inputs(source['head_sha'], args.kind)
    if original != inputs(os.environ['GITHUB_SHA'], args.kind):
        print('Native compilation inputs changed; rebuild instead of reusing this run')
        output(False)
        return
    deadline = time.monotonic() + 5 * 3600
    while True:
        jobs = api('/actions/runs/' + args.run + '/jobs?per_page=100')['jobs']
        matches = [job for job in jobs if job['name'] == args.job]
        if len(matches) != 1:
            raise ValueError('Expected exactly one source native job: ' + args.job)
        job = matches[0]
        if job['status'] == 'completed':
            break
        if time.monotonic() > deadline:
            raise TimeoutError('Source native build did not finish')
        print('Waiting for source build ' + args.job, flush=True)
        time.sleep(30)
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
        with zipfile.ZipFile(archive) as sdk:
            for name in sdk.namelist():
                if not (Path(temp) / name).resolve().is_relative_to(Path(temp).resolve()):
                    raise ValueError('Unsafe source archive path')
            if args.kind == 'windows':
                sdk.extractall(destination)
            else:
                sdk.extractall(temp)
                packages = list(Path(temp).glob('*.tar.gz'))
                if len(packages) != 1:
                    raise ValueError('Expected the prepackaged macOS SDK')
                subprocess.check_call(['tar', '-xzf', str(packages[0]), '-C', str(destination)])
        record = dict(source_run=args.run, source_commit=source['head_sha'], source_job=job['id'],
                      source_artifact=matches[0]['id'], packaging_commit=os.environ['GITHUB_SHA'],
                      compilation_inputs=original, policy='Unverified install; all current packaging and acceptance gates repeat')
        provenance = destination / 'share/ci-native-source.json'
        provenance.parent.mkdir(parents=True, exist_ok=True)
        provenance.write_text(json.dumps(record, indent=2) + '\n', encoding='utf-8')
    output(True)
    print('Restored native SDK from matching source inputs; current acceptance is still required')


if __name__ == '__main__':
    main()
