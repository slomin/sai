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
# The directory holds the zip, the tarball, checksums.txt, commit, flavor
# and seal as tool/release.sh stages them under dist/<name>/release/. The flavor (ADR 0019) is read
# from the directory, never from an argument: `stable` installs sai.app,
# ~/.local/share/sai and sai_tui; `dev` installs sai-dev.app,
# ~/.local/share/sai-dev and sai_tui-dev, beside stable and never over
# it. A dist with no flavor file is a pre-flavor stable release. Every
# artefact must agree with that word — the names, the app's SaiFlavor,
# the bundle's flavor file, what the client's `version` prints, and the
# copy already installed at the destination — or nothing is replaced.
# Everything is checked before anything is replaced (tool/verify-release.sh,
# #95): the checksums; the seal — a stable release must be sealed by the
# signing phase, a dev one as dev; the code signatures (`--deep --strict`
# on the app, every Mach-O in the bundle); the commit both artefacts carry
# against the commit file; the version the plist and `sai_tui version`
# report. A stable app and bundle must also be signed the way the
# installed ones are (their designated requirements match — a different
# certificate would strand the Keychain items, ADR 0008;
# SAI_INSTALL_ALLOW_RESIGN=1 accepts the change knowingly); a dev copy
# holds no credentials and may be signed differently from the last. The artefacts are unpacked into
# staging directories beside their destinations — the same file system,
# so the replacement is a rename — and the app and the bundle are
# swapped back to back; if the second swap fails both are put back, so
# the pair never mismatches. Only one app of a flavor ever exists: the
# copy that was there is removed after the swap, and the artefacts that
# were installed are kept under references/releases/<name>/ (gitignored)
# for `tool/release.sh install`; the kept copy is prepared before the
# swap, so a failure there never follows a committed install. The same
# flavor's app in /Applications (a download) is refused — one Mac keeps
# one copy of it, or LaunchServices may open the other. The installed
# copies of that flavor's app and client running, a dirty checksum, a
# broken signature or a wrong commit stop the install with the previous
# copy untouched — the other flavor running is no reason to refuse; a
# backup left by an interrupted run is recovered, never discarded, until
# a replacement has committed. ~/.local/share/<sai|sai-dev>/installed
# records what is installed (flavor, version, commit, time, kept
# directory, the backup job) — never the signing identity. The hourly
# backup job (#15, ADR 0025) is a LaunchAgent per flavor,
# ~/Library/LaunchAgents/<bundle id>.backup.plist, running the installed
# client's `archive backup` and logging to
# ~/.local/share/<sai|sai-dev>/backup.log; it is unloaded once the
# release has verified — a copy in flight would look like the client
# running — written after the swap and loaded again, and put back by the
# exit handler if the swap does not commit. Loading it can fail (no GUI
# session over ssh); that is a warning naming the command, never a
# failed install. The archive, the settings file and the Keychain are
# never touched. The roots are overridable for tests:
# SAI_INSTALL_APPS_DIR, SAI_INSTALL_SHARE_ROOT (the parent of sai/ and
# sai-dev/), SAI_INSTALL_BIN_DIR, SAI_INSTALL_KEEP_DIR,
# SAI_INSTALL_SYSTEM_APPS_DIR (where a download would sit) and
# SAI_INSTALL_LAUNCH_AGENTS_DIR. Every root is a parent; the flavor's own
# directory, app name and job label are never overridable, so no
# override can point two flavors at one place.
set -eu

[ $# -ge 1 ] || { echo "usage: tool/install-local.sh <dist-dir> [--dry-run]" >&2; exit 2; }
dist=$(cd "$1" 2>/dev/null && pwd) || { echo "install: no such directory: $1" >&2; exit 1; }
dry=0
[ "${2:-}" = --dry-run ] && dry=1
[ $# -le 2 ] && { [ $# -eq 1 ] || [ "$dry" = 1 ]; } || { echo "usage: tool/install-local.sh <dist-dir> [--dry-run]" >&2; exit 2; }
cd "$(dirname "$0")/.."

fail() { echo "install: $*" >&2; exit 1; }

# --- what is being installed ------------------------------------------
[ -f "$dist/checksums.txt" ] || fail "$dist has no checksums.txt; it is not a staged release"
[ -f "$dist/commit" ] || fail "$dist has no commit file; it is not a staged release"
commit=$(cat "$dist/commit")
[ -n "$commit" ] || fail "$dist/commit is empty"
# The flavor seal (ADR 0019). A release staged before flavors existed
# has no file and is stable — that is what it was.
flavor=$(cat "$dist/flavor" 2>/dev/null || echo stable)
case "$flavor" in
  stable) slug=sai; tui=sai_tui; label=sai; bundle_id=me.slominski.sai ;;
  dev) slug=sai-dev; tui=sai_tui-dev; label="sai dev"; bundle_id=me.slominski.sai.dev ;;
  *) fail "$dist/flavor says '$flavor'; only stable and dev exist" ;;
esac
zip=$(ls "$dist"/"$slug"-v*-macos-*.zip 2>/dev/null | head -n 1)
tarball=$(ls "$dist"/"$tui"-v*-macos-*.tar.gz 2>/dev/null | head -n 1)
[ -n "$zip" ] || fail "$dist has no $flavor app zip ($slug-v…)"
[ -n "$tarball" ] || fail "$dist has no $flavor terminal-client tarball ($tui-v…)"
version=$(basename "$zip" | sed -n "s/^$slug-v\(.*\)-macos-.*\.zip\$/\1/p")
[ -n "$version" ] || fail "cannot read the version from $(basename "$zip")"
name="$slug-v$version-$(printf %.7s "$commit")"

apps="${SAI_INSTALL_APPS_DIR:-$HOME/Applications}"
share="${SAI_INSTALL_SHARE_ROOT:-$HOME/.local/share}/$slug"
bin="${SAI_INSTALL_BIN_DIR:-$HOME/.local/bin}"
keep="${SAI_INSTALL_KEEP_DIR:-references/releases}"
system_app="${SAI_INSTALL_SYSTEM_APPS_DIR:-/Applications}/$slug.app"
agents="${SAI_INSTALL_LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}"

app_dst="$apps/$slug.app"
bundle_dst="$share/bundle"
link_dst="$bin/$tui"
agent_label="$bundle_id.backup"
plist="$agents/$agent_label.plist"
agent_domain="gui/$(id -u)"

# What a bundle at a path says it is: its SaiFlavor, stable when it
# predates the key. Empty when there is no app there.
flavor_of() {
  [ -f "$1/Contents/Info.plist" ] || return 0
  /usr/libexec/PlistBuddy -c 'Print :SaiFlavor' "$1/Contents/Info.plist" 2>/dev/null || echo stable
}

# --- refusals that need no unpacking -----------------------------------
[ -L "$app_dst" ] && fail "$app_dst is a symlink; move it aside first"
if [ -e "$system_app" ] && [ "$system_app" != "$app_dst" ]; then
  fail "$system_app exists; one Mac keeps one $slug.app, or the Dock and Spotlight may open the other — remove it (or move it aside) first"
fi
# An interrupted run may have left the live copy under a .old name and
# its destination empty: put it back before anything is judged. A .old
# beside a present destination stays until this run commits.
recover() {
  for old in "$1".old.*; do
    [ -e "$old" ] || continue
    if [ ! -e "$2" ]; then
      mv "$old" "$2"
      echo "install: recovered $2 from an interrupted install"
    fi
  done
}
if [ -e "$link_dst" ] && [ ! -L "$link_dst" ]; then
  fail "$link_dst exists and is not a symlink; move it aside first"
fi

# The installed copies of this flavor only: the app by the path it is
# launched from (Finder, the Dock and drive.sh all pass the full path),
# the terminal client by process name — through the symlink its argv is
# just `sai_tui` (or `sai_tui-dev`). Another checkout's app, a `dart run`
# TUI or the other flavor is not ours.
running() {
  pids=$(pgrep -f "^$app_dst/Contents/MacOS/$slug" 2>/dev/null) && s1=0 || s1=$?
  tuis=$(pgrep -x "$tui" 2>/dev/null) && s2=0 || s2=$?
  [ "$s1" -le 1 ] && [ "$s2" -le 1 ] || fail "cannot list processes to check whether $label is running (pgrep exit $s1/$s2)"
  echo "$pids $tuis" | tr -s ' \n' ' ' | sed 's/^ //;s/ $//'
}

if [ "$dry" = 0 ]; then
  recover "$apps/.$slug.app" "$app_dst"
  recover "$share/.bundle" "$bundle_dst"
fi
# Judged after the recovery, so a live copy put back is the one judged.
installed_flavor=$(flavor_of "$app_dst")
if [ -n "$installed_flavor" ] && [ "$installed_flavor" != "$flavor" ]; then
  fail "$app_dst is a $installed_flavor build; a $flavor release does not replace it — move it aside first"
fi

(cd "$dist" && shasum -a 256 -c --quiet checksums.txt) || fail "checksums do not match in $dist"

# --- the plan ----------------------------------------------------------
state() { if [ -e "$1" ]; then echo replace; else echo create; fi; }
echo "install: $label v$version at $commit from $dist"
echo "  app     $app_dst ($(state "$app_dst"))"
echo "  bundle  $bundle_dst ($(state "$bundle_dst"))"
echo "  symlink $link_dst -> $bundle_dst/bin/$tui ($(state "$link_dst"))"
echo "  agent   $plist ($(state "$plist"))"
echo "  kept    $keep/$name"
busy=$(running)
if [ "$dry" = 1 ]; then
  [ -z "$busy" ] || echo "install: $label is running (pid $busy); the install would refuse until it is quit"
  echo "install: dry run; nothing written"
  exit 0
fi
[ -z "$busy" ] || fail "$label is running (pid $busy); quit $label first"

# --- stage on the destination file systems -----------------------------
rm -rf "$apps"/."$slug".app.new.* "$share"/.bundle.new.*
mkdir -p "$apps" "$share" "$bin"
stage_app="$apps/.$slug.app.new.$$"
stage_bundle="$share/.bundle.new.$$"
old_app="$apps/.$slug.app.old.$$"
old_bundle="$share/.bundle.old.$$"
kept="$keep/$name"
kept_new="$kept.new.$$"
plist_new="$plist.new.$$"
swapped=0
app_placed=0
bundle_placed=0
had_agent=0
# One EXIT handler for every exit, normal or not; INT/TERM turn into an
# exit so the script never resumes after the handler. Until the swap has
# committed the handler removes what this run put in place and puts
# back whatever it moved aside.
on_exit() {
  status=$?
  if [ "$swapped" = 0 ]; then
    if [ "$bundle_placed" = 1 ]; then rm -rf "$bundle_dst"; fi
    if [ -e "$old_bundle" ]; then mv "$old_bundle" "$bundle_dst"; fi
    if [ "$app_placed" = 1 ]; then rm -rf "$app_dst"; fi
    if [ -e "$old_app" ]; then mv "$old_app" "$app_dst"; fi
    # The backup job was unloaded for the swap that did not happen: the
    # previous copy is back, so its job comes back too.
    if [ "$had_agent" = 1 ]; then launchctl bootstrap "$agent_domain" "$plist" 2>/dev/null || true; fi
  fi
  rm -rf "$stage_app" "$stage_bundle" "$kept_new" "$plist_new"
  exit "$status"
}
trap on_exit EXIT
trap 'exit 130' INT TERM
mkdir -p "$stage_app" "$stage_bundle"
ditto -x -k "$zip" "$stage_app"
tar -C "$stage_bundle" -xzf "$tarball"
app_new="$stage_app/$slug.app"
bundle_new="$stage_bundle/bundle"
[ -d "$app_new" ] || fail "the zip does not unpack to $slug.app"
[ -x "$bundle_new/bin/$tui" ] || fail "the tarball does not unpack to bundle/bin/$tui"

# --- validate in staging -----------------------------------------------
# The whole graph — checksums, the seal (#95), every signature, and the
# agreement of flavor, commit and version — is tool/verify-release.sh's.
tool/verify-release.sh "$dist" "$app_new" "$bundle_new" || fail "the release does not verify"
# The designated requirement names the certificate without printing it;
# a different one than the installed copy's would strand the Keychain
# items (ADR 0008). Never echoed, only compared. Dev holds no credentials
# (#95), so a dev copy may be signed differently from the one before —
# a rotated or missing `sai dev` identity is no reason to refuse.
requirement() { codesign -d -r- "$1" 2>&1 | sed -n 's/^# designated => //p'; }
same_signer() {
  [ -e "$2" ] || return 0
  [ "$(requirement "$1")" = "$(requirement "$2")" ]
}
if [ "$flavor" = stable ] && [ "${SAI_INSTALL_ALLOW_RESIGN:-}" != 1 ]; then
  same_signer "$app_new" "$app_dst" || fail "the app is signed differently from the installed one; the Keychain items would stop trusting it (ADR 0008) — SAI_INSTALL_ALLOW_RESIGN=1 accepts that"
  same_signer "$bundle_new/bin/$tui" "$bundle_dst/bin/$tui" || fail "the terminal client is signed differently from the installed one (ADR 0008) — SAI_INSTALL_ALLOW_RESIGN=1 accepts that"
fi
echo "install: verified $slug.app and $tui $version at $commit"

# --- prepare the kept copy, so nothing after the swap can fail ---------
refresh_kept=0
same_seal() { { [ ! -f "$dist/seal" ] && [ ! -f "$kept/seal" ]; } || cmp -s "$dist/seal" "$kept/seal" 2>/dev/null; }
if [ ! -f "$kept/checksums.txt" ] || ! cmp -s "$kept/checksums.txt" "$dist/checksums.txt" || ! same_seal; then
  refresh_kept=1
  rm -rf "$kept_new"
  mkdir -p "$kept_new" || fail "cannot create $kept_new to keep the release"
  cp "$zip" "$tarball" "$dist/checksums.txt" "$dist/commit" "$kept_new/" || fail "cannot copy the release into $kept_new"
  echo "$flavor" > "$kept_new/flavor"
  # The seal travels with the kept copy, so a rollback verifies as the
  # install did (#95); a pre-#95 release has none to keep.
  if [ -f "$dist/seal" ]; then cp "$dist/seal" "$kept_new/" || fail "cannot copy the seal into $kept_new"; fi
fi

# --- swap --------------------------------------------------------------
# The hourly backup job (#15) runs the installed client, so a copy in
# flight would read as the client running: unload it now, after the
# release has verified and before the check — a refused release never
# touches it, and the exit handler puts it back if the swap does not
# commit.
if [ -f "$plist" ]; then
  had_agent=1
  launchctl bootout "$agent_domain/$agent_label" 2>/dev/null || true
fi
busy=$(running)
[ -z "$busy" ] || fail "$label is running (pid $busy); quit $label first"
[ -e "$app_dst" ] && mv "$app_dst" "$old_app"
mv "$app_new" "$app_dst"
app_placed=1
[ -e "$bundle_dst" ] && mv "$bundle_dst" "$old_bundle"
mv "$bundle_new" "$bundle_dst"
bundle_placed=1
swapped=1
ln -sfn "$bundle_dst/bin/$tui" "$link_dst"
rm -rf "$apps"/."$slug".app.old.* "$share"/.bundle.old.*

# --- record the install, land the kept copy -----------------------------
{
  echo "flavor: $flavor"
  echo "version: $version"
  echo "commit: $commit"
  echo "installed_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "kept: $kept"
  echo "agent: $plist"
} > "$share/installed"
if [ "$refresh_kept" = 1 ]; then
  rm -rf "$kept"
  mv "$kept_new" "$kept" || echo "install: warning: could not land the kept copy at $kept; the install itself is complete" >&2
fi

# --- the hourly backup job (#15, ADR 0025) -------------------------------
# One LaunchAgent per flavor, naming the installed client by its bundle
# path: `archive backup` copies the log to the configured destination
# and exits at once while none is set, so the job costs nothing until a
# person sets one. Not run at load — the install is not the moment —
# and its lines go to backup.log beside the record. The install has
# committed by now: a job that cannot be written or loaded is a warning
# with the command to run by hand.
write_agent() {
  mkdir -p "$agents" &&
  cat > "$plist_new" <<PLIST &&
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$agent_label</string>
	<key>ProgramArguments</key>
	<array>
		<string>$bundle_dst/bin/$tui</string>
		<string>archive</string>
		<string>backup</string>
	</array>
	<key>StartInterval</key>
	<integer>3600</integer>
	<key>RunAtLoad</key>
	<false/>
	<key>ProcessType</key>
	<string>Background</string>
	<key>StandardOutPath</key>
	<string>$share/backup.log</string>
	<key>StandardErrorPath</key>
	<string>$share/backup.log</string>
</dict>
</plist>
PLIST
  chmod 644 "$plist_new" &&
  mv "$plist_new" "$plist"
}
if write_agent; then
  launchctl bootstrap "$agent_domain" "$plist" 2>/dev/null \
    || echo "install: warning: could not load the backup job $agent_label; run: launchctl bootstrap $agent_domain $plist" >&2
else
  echo "install: warning: could not write the backup job at $plist; the install itself is complete" >&2
fi

echo "install: $label v$version at $commit is installed"
echo "  app     $app_dst"
echo "  bundle  $bundle_dst"
echo "  symlink $link_dst"
echo "  agent   $plist"
echo "  kept    $kept"
echo "  rollback: quit $label, then tool/release.sh install $keep/<an earlier name>"
