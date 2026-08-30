#!/bin/sh
# Verifies a staged release against its unpacked artefacts — the one
# graph both tool/install-local.sh and tool/release.sh publish run before
# they accept anything (#95). Nothing here signs, prints a certificate or
# reads a keychain.
#
#   tool/verify-release.sh <release-dir> <app.app> <bundle-dir>
#
# The release directory holds the zip, the tarball, checksums.txt, commit,
# flavor and (since #95) a seal naming who signed: `stable` for the
# dedicated-keychain phase, `dev` for a development release. A release
# without a seal predates #95 — a kept copy — and is accepted only when
# every Mach-O carries a real, non-ad-hoc signature. Checked: the checksums; the
# seal against the flavor, the commit and the checksums; the code
# signatures (`--deep --strict` on the app, `--strict` on the client's
# executable and every bundled dylib); that the app's SaiFlavor and
# SaiCommit, the bundle's flavor and commit files and what the client's
# `version` prints all agree with the release. Who signed is bound by the
# installer's designated-requirement comparison with the installed copy;
# this script says only whether the graph is whole.
set -eu

[ $# -eq 3 ] || { echo "usage: tool/verify-release.sh <release-dir> <app.app> <bundle-dir>" >&2; exit 2; }
dist=$1 app=$2 bundle=$3
fail() { echo "verify: $*" >&2; exit 1; }

[ -f "$dist/checksums.txt" ] || fail "$dist has no checksums.txt; it is not a staged release"
[ -f "$dist/commit" ] || fail "$dist has no commit file; it is not a staged release"
commit=$(cat "$dist/commit")
[ -n "$commit" ] || fail "$dist/commit is empty"
flavor=$(cat "$dist/flavor" 2>/dev/null || echo stable)
case "$flavor" in
  stable) slug=sai; tui=sai_tui ;;
  dev) slug=sai-dev; tui=sai_tui-dev ;;
  *) fail "$dist/flavor says '$flavor'; only stable and dev exist" ;;
esac
zip=$(ls "$dist"/"$slug"-v*-macos-*.zip 2>/dev/null | head -n 1)
[ -n "$zip" ] || fail "$dist has no $flavor app zip ($slug-v…)"
version=$(basename "$zip" | sed -n "s/^$slug-v\(.*\)-macos-.*\.zip\$/\1/p")
[ -n "$version" ] || fail "cannot read the version from $(basename "$zip")"
short=${version%%-*}

(cd "$dist" && shasum -a 256 -c --quiet checksums.txt) || fail "checksums do not match in $dist"

# --- the seal ----------------------------------------------------------
# adhoc <path>: whether a Mach-O or bundle carries only an ad-hoc signature.
adhoc() { codesign -dv "$1" 2>&1 | grep -q '^Signature=adhoc'; }
if [ -f "$dist/seal" ]; then
  signer=$(sed -n 's/^signer //p' "$dist/seal")
  sealed_sum=$(sed -n 's/^checksums //p' "$dist/seal")
  sealed_flavor=$(sed -n 's/^flavor //p' "$dist/seal")
  sealed_commit=$(sed -n 's/^commit //p' "$dist/seal")
  [ "$sealed_flavor" = "$flavor" ] || fail "the seal is for a ${sealed_flavor:-?} release, not $flavor"
  [ "$sealed_commit" = "$commit" ] || fail "the seal was made for commit ${sealed_commit:-?}, not $commit"
  [ "$sealed_sum" = "$(shasum -a 256 "$dist/checksums.txt" | cut -d' ' -f1)" ] \
    || fail "the seal does not match checksums.txt; the release changed after it was sealed"
  case "$flavor:$signer" in
    stable:stable|dev:dev) ;;
    stable:*) fail "a stable release must be sealed by the signing phase, not '${signer:-nobody}' — run tool/release.sh sign" ;;
    dev:*) fail "a dev release must be sealed as dev, not '${signer:-nobody}'" ;;
  esac
else
  # A release without a seal predates #95 — a kept copy signed with the
  # stable identity. What it can never be is an ad-hoc tree: that is a
  # prepared, unsigned stable build, or a hand-assembled one.
  unsealed=1
fi

# --- the signatures ----------------------------------------------------
[ -d "$app" ] || fail "no app at $app"
[ -x "$bundle/bin/$tui" ] || fail "no $tui in $bundle/bin"
codesign --verify --deep --strict "$app" || fail "the app's signature does not verify"
codesign --verify --strict "$bundle/bin/$tui" || fail "the terminal client's signature does not verify"
for lib in "$bundle"/lib/*.dylib; do
  [ -e "$lib" ] || continue
  codesign --verify --strict "$lib" || fail "$(basename "$lib") in the terminal client's bundle does not verify"
done
if [ "${unsealed:-0}" = 1 ]; then
  for x in "$app" "$bundle/bin/$tui" "$bundle"/lib/*.dylib; do
    [ -e "$x" ] || continue
    if adhoc "$x"; then
      fail "a release without a seal must carry a real signature, and $(basename "$x") is ad-hoc — a stable release is sealed by tool/release.sh sign, a dev one by prepare dev"
    fi
  done
fi

# --- agreement ---------------------------------------------------------
plist="$app/Contents/Info.plist"
app_flavor=$(/usr/libexec/PlistBuddy -c 'Print :SaiFlavor' "$plist" 2>/dev/null || echo stable)
[ "$app_flavor" = "$flavor" ] || fail "the app is a $app_flavor build inside a $flavor release"
tui_flavor=$(cat "$bundle/flavor" 2>/dev/null || echo stable)
[ "$tui_flavor" = "$flavor" ] || fail "the terminal client is a $tui_flavor build inside a $flavor release"
app_commit=$(/usr/libexec/PlistBuddy -c 'Print :SaiCommit' "$plist" 2>/dev/null || true)
[ "$app_commit" = "$commit" ] || fail "the app was built from ${app_commit:-no recorded commit}, not $commit"
app_short=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist" 2>/dev/null || true)
[ "$app_short" = "$short" ] || fail "the app reports version ${app_short:-none}, not $short"
tui_commit=$(cat "$bundle/commit" 2>/dev/null || true)
[ "$tui_commit" = "$commit" ] || fail "the terminal client was built from ${tui_commit:-no recorded commit}, not $commit"
scratch=$(mktemp -d "${TMPDIR:-/tmp}/sai-verify.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
tui_version=$(SAI_SETTINGS_FILE="$scratch/settings.json" SAI_ARCHIVE_ROOT="$scratch/archive" \
  "$bundle/bin/$tui" version 2>/dev/null || true)
[ "$tui_version" = "$tui $version" ] || fail "the terminal client reports '${tui_version:-nothing}', not '$tui $version'"
echo "verify: $slug.app and $tui $version at $commit verify${signer:+ (sealed by $signer)}"
