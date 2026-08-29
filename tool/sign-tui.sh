#!/bin/sh
# Builds the terminal client and signs it with one stable identity, so
# the Keychain items it creates keep trusting it across rebuilds
# (ADR 0008). An ad-hoc signature changes every build and re-prompts.
#
#   SAI_CODESIGN_IDENTITY=sai-dev tool/sign-tui.sh [output-dir] [stable|dev]
#
# The identity is never in the tree: a self-signed "Code Signing"
# certificate made in Keychain Access works for development; a release
# uses the Apple Development identity through tool/release.sh (ADR
# 0017). The client is a bundle (#18): the binary at
# <output-dir>/bundle/bin/sai_tui — sai_tui-dev for the dev flavor
# (ADR 0019), from its own entry point — beside the SQLite library
# package:sqlite3 builds through its hook, which is why this is
# `dart build cli` and not `dart compile exe`. Output defaults to
# build/tui and the flavor to stable; every Mach-O in the bundle is
# signed.
set -eu
cd "$(dirname "$0")/.."
identity="${SAI_CODESIGN_IDENTITY:?set SAI_CODESIGN_IDENTITY to the signing identity name}"
out="${1:-build/tui}"
case "${2:-stable}" in
  stable) tui=sai_tui ;;
  dev) tui=sai_tui-dev ;;
  *) echo "usage: tool/sign-tui.sh [output-dir] [stable|dev]" >&2; exit 2 ;;
esac
dart build cli -t "apps/sai_tui/bin/$tui.dart" --root-package=sai_tui -o "$out"
for lib in "$out"/bundle/lib/*.dylib; do
  [ -e "$lib" ] || continue
  codesign --force --sign "$identity" --timestamp=none "$lib"
done
bin="$out/bundle/bin/$tui"
codesign --force --sign "$identity" --timestamp=none "$bin"
codesign --verify --verbose=2 "$bin"
codesign --display --verbose=2 "$bin" 2>&1 | grep -E '^(Identifier|Signature)' || true
