# Sourced after source_dir, build and tag have been assigned by a build entry point.
collect_linux_build_diagnostics() {
  local build_exit_code=$?
  local diagnostics="$source_dir/build-temp/logs"
  mkdir -p "$diagnostics"
  for directory in "$build/qt" "$build/qt/qtbase"; do
    for filename in config.log config.summary; do
      if [[ -f "$directory/$filename" ]]; then
        cp "$directory/$filename" "$diagnostics/$tag-$filename" || true
        chmod a+r "$diagnostics/$tag-$filename" || true
      fi
    done
  done
  exit "$build_exit_code"
}
trap collect_linux_build_diagnostics EXIT
