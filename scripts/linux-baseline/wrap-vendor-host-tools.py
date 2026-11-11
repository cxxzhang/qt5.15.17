#!/usr/bin/env python3
"""Make vendor LLVM host tools locate private libffi even in a clean environment."""

import argparse
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('prefix', type=Path)
    args = parser.parse_args()
    prefix = args.prefix.resolve()
    bindir = prefix / 'llvm/bin'
    marker = bindir / '.baseline-host-tools-wrapped'
    if marker.is_file():
        return
    # Resolve every original multicall alias before replacing any path.
    # Raw payloads stay beside the wrappers, preserving $ORIGIN/../lib.
    tools = {}
    for path in bindir.iterdir():
        if path.name.startswith('.') or not path.is_file():
            continue
        with path.open('rb') as stream:
            if stream.read(4) != b'\x7fELF':
                continue
        real = path.resolve()
        if real.parent != bindir:
            raise ValueError('Unexpected external LLVM tool alias: ' + str(path))
        tools[path.name] = real.name
    if not tools:
        raise ValueError('No LLVM executable payloads to wrap')
    for real in sorted(set(tools.values())):
        (bindir / real).rename(bindir / ('.baseline-original-' + real))
    for name, real in sorted(tools.items()):
        path = bindir / name
        if path.is_symlink() or path.exists():
            path.unlink()
        path.write_text('''#!/usr/bin/env bash
prefix="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export LD_LIBRARY_PATH="$prefix/host-libs/usr/lib/x86_64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
exec -a "''' + name + '''" "$prefix/llvm/bin/.baseline-original-''' + real + '''" "$@"
''')
        path.chmod(0o755)
    marker.write_text('Private host libffi; original LLVM argv[0] and payload bytes preserved\n')
    print('Wrapped {} LLVM host tool names with private libffi resolution'.format(len(tools)))


if __name__ == '__main__':
    main()
