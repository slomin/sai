#!/bin/sh
# Compiles the terminal client and signs it with one stable identity, so
# the Keychain items it creates keep trusting it across rebuilds
# (ADR 0008). An ad-hoc signature changes every build and re-prompts.
#
#   SAI_CODESIGN_IDENTITY=sai-dev tool/sign-tui.sh [output]
#
# The identity is never in the tree: a self-signed "Code Signing"
# certificate made in Keychain Access works for development; #42 uses
# Developer ID for release. Output defaults to build/sai_tui.
set -eu
cd "$(dirname "$0")/.."
identity="${SAI_CODESIGN_IDENTITY:?set SAI_CODESIGN_IDENTITY to the signing identity's name}"
out="${1:-build/sai_tui}"
mkdir -p "$(dirname "$out")"
dart compile exe apps/sai_tui/bin/sai_tui.dart -o "$out"
codesign --force --sign "$identity" --timestamp=none "$out"
codesign --verify --verbose=2 "$out"
codesign --display --verbose=2 "$out" 2>&1 | grep -E '^(Identifier|Authority|Signature)' || true
echo "signed $out with '$identity'"
