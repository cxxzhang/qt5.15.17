#!/usr/bin/env bash
# Start packaging from the original runtime, before any patchelf expansion.
set -euo pipefail
prefix="${1:?accepted cross prefix required}"
destination="${2:?destination required}"
mkdir -p "$destination"
for name in libstdc++.so.6 libgcc_s.so.1; do
  if [[ -f "$prefix/runtime/lib/$name" ]]; then
    provider="$prefix/runtime/lib/$name"
  else
    provider="$("$prefix/bin/clang++" -print-file-name="$name")"
    [[ "$provider" == "$prefix/"* && -f "$provider" ]] || {
      echo "Missing original target runtime: $provider" >&2; exit 1;
    }
  fi
  cp -L "$provider" "$destination/$name"
  sha256sum "$provider" "$destination/$name"
done
