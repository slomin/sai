#!/bin/sh
# Installs a staged release on this Mac as the dogfood copy (#87): the
# app under ~/Applications, the terminal client's bundle under
# ~/.local/share/sai and a symlink in ~/.local/bin. Nothing here builds,
# signs, tags or publishes — tool/release.sh does the first two and hands
# over its dist/ directory (`local-install`), or a kept copy of an older
# release (`install <dir>`, the rollback).
#
#   tool/install-local.sh <dist-dir> [--dry-run]
#
# The directory holds the zip, the tarball, checksums.txt and commit as
# tool/release.sh stages them. Everything is checked before anything is
# replaced: the checksums, the code signatures (--deep --strict), the
# commit both artefacts carry against the commit file, the version the
# plist and `sai_tui version` report. The artefacts are unpacked into
# staging directories beside their destinations — the same file system,
# so the replacement is a rename — and the app and the bundle are swapped
# back to back; if the second swap fails the first is undone, so the pair
# never mismatches. Only one sai.app ever exists: the copy that was there
# is removed after the swap, and the artefacts that were installed are
# kept under references/releases/<name>/ (gitignored) for
# `tool/release.sh install`. A running sai, a dirty checksum, a broken
# signature or a wrong commit stops the install with the previous copy
# untouched. ~/.local/share/sai/installed records what is installed
# (version, commit, time, kept directory) — never the signing identity.
# The archive, the settings file and the Keychain are never touched.
# The roots are overridable for tests: SAI_INSTALL_APPS_DIR,
# SAI_INSTALL_SHARE_DIR, SAI_INSTALL_BIN_DIR, SAI_INSTALL_KEEP_DIR.
set -eu

[ $# -ge 1 ] || { echo "usage: tool/install-local.sh <dist-dir> [--dry-run]" >&2; exit 2; }
dist=$(cd "$1" 2>/dev/null && pwd) || { echo "install: no such directory: $1" >&2; exit 1; }
dry=0
[ "${2:-}" = --dry-run ] && dry=1
[ $# -le 2 ] && { [ $# -eq 1 ] || [ "$dry" = 1 ]; } || { echo "usage: tool/install-local.sh <dist-dir> [--dry-run]" >&2; exit 2; }
cd "$(dirname "$0")/.."

apps="${SAI_INSTALL_APPS_DIR:-$HOME/Applications}"
share="${SAI_INSTALL_SHARE_DIR:-$HOME/.local/share/sai}"
bin="${SAI_INSTALL_BIN_DIR:-$HOME/.local/bin}"
keep="${SAI_INSTALL_KEEP_DIR:-references/releases}"

fail() { echo "install: $*" >&2; exit 1; }

# --- what is being installed ------------------------------------------
[ -f "$dist/checksums.txt" ] || fail "$dist has no checksums.txt; it is not a staged release"
[ -f "$dist/commit" ] || fail "$dist has no commit file; it is not a staged release"
commit=$(cat "$dist/commit")
[ -n "$commit" ] || fail "$dist/commit is empty"
zip=$(ls "$dist"/sai-v*-macos-*.zip 2>/dev/null | head -n 1)
tarball=$(ls "$dist"/sai_tui-v*-macos-*.tar.gz 2>/dev/null | head -n 1)
[ -n "$zip" ] || fail "$dist has no app zip"
[ -n "$tarball" ] || fail "$dist has no terminal-client tarball"
version=$(basename "$zip" | sed -n 's/^sai-v\(.*\)-macos-.*\.zip$/\1/p')
[ -n "$version" ] || fail "cannot read the version from $(basename "$zip")"
short=${version%%-*}
name="sai-v$version-$(printf %.7s "$commit")"

app_dst="$apps/sai.app"
bundle_dst="$share/bundle"
link_dst="$bin/sai_tui"

# --- refusals that need no unpacking -----------------------------------
[ -L "$app_dst" ] && fail "$app_dst is a symlink; move it aside first"
if [ -e "$link_dst" ] && [ ! -L "$link_dst" ]; then
  fail "$link_dst exists and is not a symlink; move it aside first"
fi

running() {
  pids=$(pgrep -f 'sai\.app/Contents/MacOS/sai$' '/bundle/bin/sai_tui$' 2>/dev/null) && status=0 || status=$?
  [ "$status" -le 1 ] || fail "cannot list processes to check whether sai is running (pgrep exit $status)"
  if [ -n "$pids" ]; then
    fail "sai is running (pid $(echo "$pids" | tr '\n' ' ' | sed 's/ $//')); quit sai first"
  fi
}
running

(cd "$dist" && shasum -a 256 -c --quiet checksums.txt) || fail "checksums do not match in $dist"

# --- dry run -----------------------------------------------------------
state() { if [ -e "$1" ]; then echo replace; else echo create; fi; }
echo "install: sai v$version at $commit from $dist"
echo "  app     $app_dst ($(state "$app_dst"))"
echo "  bundle  $bundle_dst ($(state "$bundle_dst"))"
echo "  symlink $link_dst -> $bundle_dst/bin/sai_tui ($(state "$link_dst"))"
echo "  kept    $keep/$name"
if [ "$dry" = 1 ]; then
  echo "install: dry run; nothing written"
  exit 0
fi

# --- stage on the destination file systems -----------------------------
rm -rf "$apps"/.sai.app.new.* "$share"/.bundle.new.*
mkdir -p "$apps" "$share" "$bin"
stage_app="$apps/.sai.app.new.$$"
stage_bundle="$share/.bundle.new.$$"
old_app="$apps/.sai.app.old.$$"
old_bundle="$share/.bundle.old.$$"
scratch=$(mktemp -d "${TMPDIR:-/tmp}/sai-install.XXXXXX")
cleanup() {
  rm -rf "$stage_app" "$stage_bundle" "$scratch"
}
trap cleanup EXIT INT TERM
mkdir -p "$stage_app" "$stage_bundle"
ditto -x -k "$zip" "$stage_app"
tar -C "$stage_bundle" -xzf "$tarball"
app_new="$stage_app/sai.app"
bundle_new="$stage_bundle/bundle"
[ -d "$app_new" ] || fail "the zip does not unpack to sai.app"
[ -x "$bundle_new/bin/sai_tui" ] || fail "the tarball does not unpack to bundle/bin/sai_tui"

# --- validate in staging -----------------------------------------------
codesign --verify --deep --strict "$app_new" || fail "the app's signature does not verify"
codesign --verify --strict "$bundle_new/bin/sai_tui" || fail "the terminal client's signature does not verify"
plist="$app_new/Contents/Info.plist"
app_commit=$(/usr/libexec/PlistBuddy -c 'Print :SaiCommit' "$plist" 2>/dev/null || true)
[ "$app_commit" = "$commit" ] || fail "the app was built from ${app_commit:-no recorded commit}, not $commit"
app_short=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist" 2>/dev/null || true)
[ "$app_short" = "$short" ] || fail "the app reports version ${app_short:-none}, not $short"
tui_commit=$(cat "$bundle_new/commit" 2>/dev/null || true)
[ "$tui_commit" = "$commit" ] || fail "the terminal client was built from ${tui_commit:-no recorded commit}, not $commit"
tui_version=$(SAI_SETTINGS_FILE="$scratch/settings.json" SAI_ARCHIVE_ROOT="$scratch/archive" \
  "$bundle_new/bin/sai_tui" version 2>/dev/null || true)
[ "$tui_version" = "sai_tui $version" ] || fail "the terminal client reports '${tui_version:-nothing}', not 'sai_tui $version'"
echo "install: verified sai.app and sai_tui $version at $commit"

# --- swap --------------------------------------------------------------
running
undo() {
  # The bundle swap failed after the app swap: put the app back.
  if [ -e "$old_app" ]; then
    rm -rf "$app_dst"
    mv "$old_app" "$app_dst"
  fi
  cleanup
}
trap undo EXIT INT TERM
[ -e "$app_dst" ] && mv "$app_dst" "$old_app"
mv "$app_new" "$app_dst"
[ -e "$bundle_dst" ] && mv "$bundle_dst" "$old_bundle"
mv "$bundle_new" "$bundle_dst"
trap cleanup EXIT INT TERM
ln -sfn "$bundle_dst/bin/sai_tui" "$link_dst"
rm -rf "$old_app" "$old_bundle"

# --- keep the artefacts, record the install ----------------------------
kept="$keep/$name"
if [ ! -f "$kept/checksums.txt" ] || ! cmp -s "$kept/checksums.txt" "$dist/checksums.txt"; then
  rm -rf "$kept"
  mkdir -p "$kept"
  cp "$zip" "$tarball" "$dist/checksums.txt" "$dist/commit" "$kept/"
fi
{
  echo "version: $version"
  echo "commit: $commit"
  echo "installed_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "kept: $kept"
} > "$share/installed"

echo "install: sai v$version at $commit is installed"
echo "  app     $app_dst"
echo "  bundle  $bundle_dst"
echo "  symlink $link_dst"
echo "  kept    $kept"
echo "  rollback: quit sai, then tool/release.sh install $keep/<an earlier name>"
