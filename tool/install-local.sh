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
# replaced: the checksums; the code signatures (`--deep --strict` on the
# app, every Mach-O in the bundle); that the app and the bundle are
# signed the way the installed ones are (their designated requirements
# match — a different certificate would strand the Keychain items, ADR
# 0008; SAI_INSTALL_ALLOW_RESIGN=1 accepts the change knowingly); the
# commit both artefacts carry against the commit file; the version the
# plist and `sai_tui version` report. The artefacts are unpacked into
# staging directories beside their destinations — the same file system,
# so the replacement is a rename — and the app and the bundle are
# swapped back to back; if the second swap fails both are put back, so
# the pair never mismatches. Only one sai.app ever exists: the copy that
# was there is removed after the swap, and the artefacts that were
# installed are kept under references/releases/<name>/ (gitignored) for
# `tool/release.sh install`. The installed copies of sai.app and sai_tui
# running, a dirty checksum, a broken signature or a wrong commit stop
# the install with the previous copy untouched. ~/.local/share/sai/installed
# records what is installed (version, commit, time, kept directory) —
# never the signing identity. The archive, the settings file and the
# Keychain are never touched. The roots are overridable for tests:
# SAI_INSTALL_APPS_DIR, SAI_INSTALL_SHARE_DIR, SAI_INSTALL_BIN_DIR,
# SAI_INSTALL_KEEP_DIR.
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

# The installed copies only: the app by the path it is launched from
# (Finder, the Dock and drive.sh all pass the full path), the terminal
# client by process name — through the symlink its argv is just
# `sai_tui`. Another checkout's sai.app or a `dart run` TUI is not ours.
running() {
  pids=$(pgrep -f "^$app_dst/Contents/MacOS/sai" 2>/dev/null) && s1=0 || s1=$?
  tuis=$(pgrep -x sai_tui 2>/dev/null) && s2=0 || s2=$?
  [ "$s1" -le 1 ] && [ "$s2" -le 1 ] || fail "cannot list processes to check whether sai is running (pgrep exit $s1/$s2)"
  echo "$pids $tuis" | tr -s ' \n' ' ' | sed 's/^ //;s/ $//'
}

(cd "$dist" && shasum -a 256 -c --quiet checksums.txt) || fail "checksums do not match in $dist"

# --- the plan ----------------------------------------------------------
state() { if [ -e "$1" ]; then echo replace; else echo create; fi; }
echo "install: sai v$version at $commit from $dist"
echo "  app     $app_dst ($(state "$app_dst"))"
echo "  bundle  $bundle_dst ($(state "$bundle_dst"))"
echo "  symlink $link_dst -> $bundle_dst/bin/sai_tui ($(state "$link_dst"))"
echo "  kept    $keep/$name"
busy=$(running)
if [ "$dry" = 1 ]; then
  [ -z "$busy" ] || echo "install: sai is running (pid $busy); the install would refuse until it is quit"
  echo "install: dry run; nothing written"
  exit 0
fi
[ -z "$busy" ] || fail "sai is running (pid $busy); quit sai first"

# --- stage on the destination file systems -----------------------------
rm -rf "$apps"/.sai.app.new.* "$apps"/.sai.app.old.* "$share"/.bundle.new.* "$share"/.bundle.old.*
mkdir -p "$apps" "$share" "$bin"
stage_app="$apps/.sai.app.new.$$"
stage_bundle="$share/.bundle.new.$$"
old_app="$apps/.sai.app.old.$$"
old_bundle="$share/.bundle.old.$$"
scratch=$(mktemp -d "${TMPDIR:-/tmp}/sai-install.XXXXXX")
swapped=0
# One EXIT handler for every exit, normal or not; INT/TERM turn into an
# exit so the script never resumes after the handler. Until the swap has
# committed the handler also puts back whatever was moved aside.
on_exit() {
  status=$?
  if [ "$swapped" = 0 ]; then
    if [ -e "$old_bundle" ]; then rm -rf "$bundle_dst"; mv "$old_bundle" "$bundle_dst"; fi
    if [ -e "$old_app" ]; then rm -rf "$app_dst"; mv "$old_app" "$app_dst"; fi
  fi
  rm -rf "$stage_app" "$stage_bundle" "$scratch"
  exit "$status"
}
trap on_exit EXIT
trap 'exit 130' INT TERM
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
for lib in "$bundle_new"/lib/*.dylib; do
  [ -e "$lib" ] || continue
  codesign --verify --strict "$lib" || fail "$(basename "$lib") in the terminal client's bundle does not verify"
done
# The designated requirement names the certificate without printing it;
# a different one than the installed copy's would strand the Keychain
# items (ADR 0008). Never echoed, only compared.
requirement() { codesign -d -r- "$1" 2>&1 | sed -n 's/^# designated => //p'; }
same_signer() {
  [ -e "$2" ] || return 0
  [ "$(requirement "$1")" = "$(requirement "$2")" ]
}
if [ "${SAI_INSTALL_ALLOW_RESIGN:-}" != 1 ]; then
  same_signer "$app_new" "$app_dst" || fail "the app is signed differently from the installed one; the Keychain items would stop trusting it (ADR 0008) — SAI_INSTALL_ALLOW_RESIGN=1 accepts that"
  same_signer "$bundle_new/bin/sai_tui" "$bundle_dst/bin/sai_tui" || fail "the terminal client is signed differently from the installed one (ADR 0008) — SAI_INSTALL_ALLOW_RESIGN=1 accepts that"
fi
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
busy=$(running)
[ -z "$busy" ] || fail "sai is running (pid $busy); quit sai first"
[ -e "$app_dst" ] && mv "$app_dst" "$old_app"
mv "$app_new" "$app_dst"
[ -e "$bundle_dst" ] && mv "$bundle_dst" "$old_bundle"
mv "$bundle_new" "$bundle_dst"
swapped=1
ln -sfn "$bundle_dst/bin/sai_tui" "$link_dst"
rm -rf "$old_app" "$old_bundle"

# --- record the install, then keep the artefacts ------------------------
{
  echo "version: $version"
  echo "commit: $commit"
  echo "installed_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "kept: $keep/$name"
} > "$share/installed"
kept="$keep/$name"
if [ ! -f "$kept/checksums.txt" ] || ! cmp -s "$kept/checksums.txt" "$dist/checksums.txt"; then
  rm -rf "$kept.new"
  mkdir -p "$kept.new"
  cp "$zip" "$tarball" "$dist/checksums.txt" "$dist/commit" "$kept.new/"
  rm -rf "$kept"
  mv "$kept.new" "$kept"
fi

echo "install: sai v$version at $commit is installed"
echo "  app     $app_dst"
echo "  bundle  $bundle_dst"
echo "  symlink $link_dst"
echo "  kept    $kept"
echo "  rollback: quit sai, then tool/release.sh install $keep/<an earlier name>"
