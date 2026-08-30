#!/bin/sh
# Builds the terminal client's bundle and gives every Mach-O in it an
# ad-hoc signature, so the tree verifies as it stands. No identity is
# involved here (#95): a dev release is re-signed with the low-authority
# `sai dev` identity by tool/release.sh, and a stable one is signed in
# tool/release.sh's separate `sign` phase from the dedicated keychain.
#
#   tool/build-tui.sh [output-dir] [stable|dev]
#
# The client is a bundle (#18): the binary at <output-dir>/bundle/bin/
# sai_tui — sai_tui-dev for the dev flavor (ADR 0019), from its own entry
# point — beside the SQLite library package:sqlite3 builds through its
# hook, which is why this is `dart build cli` and not `dart compile exe`.
# Output defaults to build/tui and the flavor to stable.
set -eu
cd "$(dirname "$0")/.."
out="${1:-build/tui}"
case "$out" in
  stable|dev) echo "tool/build-tui.sh: the flavor comes second: tool/build-tui.sh <output-dir> $out" >&2; exit 2 ;;
esac
case "${2:-stable}" in
  stable) tui=sai_tui ;;
  dev) tui=sai_tui-dev ;;
  *) echo "usage: tool/build-tui.sh [output-dir] [stable|dev]" >&2; exit 2 ;;
esac
dart build cli -t "apps/sai_tui/bin/$tui.dart" --root-package=sai_tui -o "$out"
for lib in "$out"/bundle/lib/*.dylib; do
  [ -e "$lib" ] || continue
  codesign --force --sign - "$lib"
done
bin="$out/bundle/bin/$tui"
codesign --force --sign - "$bin"
codesign --verify --strict "$bin"
