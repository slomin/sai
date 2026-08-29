#!/bin/sh
# Exercises tool/install-local.sh against temporary roots (#87, #90). The
# release it installs is a fixture: a minimal app and terminal-client
# bundle whose executables are tiny C programs, ad-hoc signed — so the
# signature checks run for real without any identity or Keychain — zipped,
# tarred and checksummed the way tool/release.sh stages them, for either
# flavor (ADR 0019) or as a pre-flavor stable release. HOME and every root
# point into a scratch directory; nothing here reads or writes the real
# home. Run it from anywhere: sh tool/test/install_local_test.sh
set -eu
cd "$(dirname "$0")/../.."

work=$(mktemp -d "${TMPDIR:-/tmp}/sai-install-test.XXXXXX")
trap 'pkill -f "^$work/" 2>/dev/null || true; rm -rf "$work"' EXIT INT TERM
export HOME="$work/home"
export SAI_INSTALL_APPS_DIR="$work/home/Applications"
export SAI_INSTALL_SHARE_ROOT="$work/home/.local/share"
export SAI_INSTALL_BIN_DIR="$work/home/.local/bin"
export SAI_INSTALL_KEEP_DIR="$work/keep"
export SAI_INSTALL_SYSTEM_APPS_DIR="$work/system"
mkdir -p "$HOME"
share_stable="$SAI_INSTALL_SHARE_ROOT/sai"
share_dev="$SAI_INSTALL_SHARE_ROOT/sai-dev"

passed=0
pass() { passed=$((passed + 1)); echo "ok $passed - $*"; }
fail() { echo "not ok - $*" >&2; exit 1; }

# fixture <dir> <version> <commit> [stable|dev|legacy]: a staged release
# for that version; `legacy` is a stable one from before flavors existed
# (no flavor files, no SaiFlavor), which must still install as stable.
fixture() {
  dir=$1 version=$2 commit=$3 short=${2%%-*} kind=${4:-stable}
  case "$kind" in
    dev) slug=sai-dev tui=sai_tui-dev ;;
    *) slug=sai tui=sai_tui ;;
  esac
  rm -rf "$dir"
  mkdir -p "$dir/stage/$slug.app/Contents/MacOS" "$dir/tui/bundle/bin" "$dir/tui/bundle/lib"
  # Both stubs sleep when told to, so a test can hold the installed copy open.
  cat > "$work/sai.c" <<EOF
#include <stdio.h>
#include <unistd.h>
int main(int argc, char **argv) { if (argc > 1) sleep(60); puts("sai app fixture"); return 0; }
EOF
  cat > "$work/tui.c" <<EOF
#include <stdio.h>
#include <string.h>
#include <unistd.h>
int main(int argc, char **argv) {
  if (argc > 1 && strcmp(argv[1], "sleep") == 0) { sleep(60); return 0; }
  if (argc > 1) { printf("$tui %s\n", "$version"); return 0; }
  return 2;
}
EOF
  cc -o "$dir/stage/$slug.app/Contents/MacOS/$slug" "$work/sai.c"
  cc -o "$dir/tui/bundle/bin/$tui" "$work/tui.c"
  flavor_key=""
  [ "$kind" = legacy ] || flavor_key="<key>SaiFlavor</key><string>$kind</string>"
  cat > "$dir/stage/$slug.app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>$slug</string>
	<key>CFBundleIdentifier</key><string>me.slominski.$slug.fixture</string>
	$flavor_key
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>$short</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>SaiCommit</key><string>$commit</string>
</dict>
</plist>
EOF
  codesign --force --sign - "$dir/stage/$slug.app" >/dev/null 2>&1
  codesign --force --sign - "$dir/tui/bundle/bin/$tui" >/dev/null 2>&1
  echo "$commit" > "$dir/tui/bundle/commit"
  if [ "$kind" != legacy ]; then
    echo "$kind" > "$dir/tui/bundle/flavor"
    echo "$kind" > "$dir/flavor"
  fi
  repack "$dir" "$version"
  echo "$commit" > "$dir/commit"
}

# repack <dir> <version>: zip, tar and checksum a fixture's stage/ and
# tui/ again, after a test has tampered with what is inside.
repack() {
  dir=$1 version=$2
  slug=$(basename "$dir"/stage/*.app .app)
  tui=$(basename "$dir"/tui/bundle/bin/*)
  rm -f "$dir"/*.zip "$dir"/*.tar.gz
  (cd "$dir/stage" && ditto -c -k --keepParent "$slug.app" "../$slug-v$version-macos-arm64.zip")
  tar -C "$dir/tui" -czf "$dir/$tui-v$version-macos-arm64.tar.gz" bundle
  (cd "$dir" && shasum -a 256 *.zip *.tar.gz > checksums.txt)
}

# snapshot: one line per installed file with its hash, for "unchanged" checks.
snapshot() {
  if [ -d "$HOME/Applications" ] || [ -d "$HOME/.local" ]; then
    (cd "$HOME" && find Applications .local -type f -o -type l 2>/dev/null | sort | while read -r f; do
      if [ -L "$f" ]; then echo "$f -> $(readlink "$f")"; else shasum -a 256 "$f"; fi
    done)
  fi
}

installed_version() { "$SAI_INSTALL_BIN_DIR/${1:-sai_tui}" version; }

c1=1111111111111111111111111111111111111111
c2=2222222222222222222222222222222222222222
fixture "$work/dist1" 0.0.1-test.1 "$c1"
fixture "$work/dist2" 0.0.1-test.2 "$c2"

# --- dry run writes nothing --------------------------------------------
out=$(tool/install-local.sh "$work/dist1" --dry-run)
echo "$out" | grep -q "dry run; nothing written" || fail "dry run did not say so: $out"
echo "$out" | grep -q "Applications/sai.app (create)" || fail "dry run did not plan the app: $out"
[ ! -e "$SAI_INSTALL_APPS_DIR" ] && [ ! -e "$share_stable" ] && [ ! -e "$work/keep" ] \
  || fail "dry run created something"
pass "dry run prints the plan and writes nothing"

# --- first install -----------------------------------------------------
tool/install-local.sh "$work/dist1" >"$work/out1" 2>&1 || { cat "$work/out1"; fail "first install failed"; }
[ -d "$SAI_INSTALL_APPS_DIR/sai.app" ] || fail "no sai.app installed"
[ -x "$share_stable/bundle/bin/sai_tui" ] || fail "no bundle installed"
[ -L "$SAI_INSTALL_BIN_DIR/sai_tui" ] || fail "no symlink"
[ "$(installed_version)" = "sai_tui 0.0.1-test.1" ] || fail "symlink runs the wrong client: $(installed_version)"
[ "$(/usr/libexec/PlistBuddy -c 'Print :SaiCommit' "$SAI_INSTALL_APPS_DIR/sai.app/Contents/Info.plist")" = "$c1" ] \
  || fail "installed app carries the wrong commit"
grep -q "^commit: $c1$" "$share_stable/installed" || fail "installed file lacks the commit"
grep -q "^version: 0.0.1-test.1$" "$share_stable/installed" || fail "installed file lacks the version"
[ -f "$work/keep/sai-v0.0.1-test.1-1111111/checksums.txt" ] || fail "artefacts not kept"
grep -rq "Authority\|Apple Development" "$share_stable/installed" "$work/out1" && fail "identity in metadata or log"
ls -A "$SAI_INSTALL_APPS_DIR" | grep -q '^\.' && fail "staging left behind in Applications: $(ls -A "$SAI_INSTALL_APPS_DIR")"
pass "first install creates the roots, the symlink, the record and the kept copy"

# --- a different signer is refused --------------------------------------
# Ad-hoc signatures carry a per-build designated requirement, so every
# fixture after the first counts as "signed differently" — which is the
# refusal ADR 0008 wants, and the reason the cases below opt in.
tool/install-local.sh "$work/dist2" >"$work/err" 2>&1 && fail "a differently signed app was accepted"
grep -q "signed differently" "$work/err" || fail "wrong message: $(cat "$work/err")"
grep -q "designated\|cdhash\|anchor" "$work/err" && fail "the requirement leaked into the message"
[ "$(installed_version)" = "sai_tui 0.0.1-test.1" ] || fail "the refusal changed the install"
pass "a differently signed build is refused and the requirement is not printed"
export SAI_INSTALL_ALLOW_RESIGN=1

# --- upgrade -----------------------------------------------------------
tool/install-local.sh "$work/dist2" >"$work/out2" 2>&1 || { cat "$work/out2"; fail "upgrade failed"; }
[ "$(installed_version)" = "sai_tui 0.0.1-test.2" ] || fail "upgrade did not switch the client"
[ "$(ls -A "$SAI_INSTALL_APPS_DIR" | wc -l | tr -d ' ')" = 1 ] || fail "more than one thing in Applications: $(ls -A "$SAI_INSTALL_APPS_DIR")"
ls -A "$share_stable" | grep -q '^\.' && fail "staging or backup left behind in share: $(ls -A "$share_stable")"
[ -d "$work/keep/sai-v0.0.1-test.1-1111111" ] && [ -d "$work/keep/sai-v0.0.1-test.2-2222222" ] || fail "kept copies missing"
grep -q "^commit: $c2$" "$share_stable/installed" || fail "installed file not updated"
pass "a second install upgrades in place, one sai.app, both versions kept"

# --- rollback from the kept copy ---------------------------------------
tool/install-local.sh "$work/keep/sai-v0.0.1-test.1-1111111" >/dev/null 2>&1 || fail "rollback failed"
[ "$(installed_version)" = "sai_tui 0.0.1-test.1" ] || fail "rollback did not restore the client"
pass "a kept copy reinstalls as the rollback"

# --- refusals leave the install byte-identical --------------------------
before=$(snapshot)
unchanged() {
  [ "$(snapshot)" = "$before" ] || fail "$1 changed the installation"
}

fixture "$work/bad" 0.0.1-test.3 "$c2"
sed -i '' -e '1s/^0/1/' -e '1t' -e '1s/^./0/' "$work/bad/checksums.txt"
tool/install-local.sh "$work/bad" >"$work/err" 2>&1 && fail "corrupt checksums accepted"
grep -q "checksums do not match" "$work/err" || fail "wrong message: $(cat "$work/err")"
unchanged "a corrupt checksum"
pass "a corrupt checksum is refused"

fixture "$work/bad" 0.0.1-test.3 "$c2"
echo 3333333333333333333333333333333333333333 > "$work/bad/commit"
tool/install-local.sh "$work/bad" >"$work/err" 2>&1 && fail "commit mismatch accepted"
grep -q "was built from $c2, not 3333333" "$work/err" || fail "wrong message: $(cat "$work/err")"
unchanged "a commit mismatch"
pass "an artefact from another commit is refused"

fixture "$work/bad" 0.0.1-test.3 "$c2"
printf 'x' >> "$work/bad/stage/sai.app/Contents/MacOS/sai"
repack "$work/bad" 0.0.1-test.3
tool/install-local.sh "$work/bad" >"$work/err" 2>&1 && fail "tampered app accepted"
grep -q "signature does not verify" "$work/err" || fail "wrong message: $(cat "$work/err")"
unchanged "a broken signature"
pass "a tampered app fails its signature check"

"$SAI_INSTALL_APPS_DIR/sai.app/Contents/MacOS/sai" hold &
sleeper=$!
sleep 0.2
out=$(tool/install-local.sh "$work/dist2" --dry-run) || fail "dry run failed while sai runs"
echo "$out" | grep -q "sai is running (pid $sleeper); the install would refuse" || fail "dry run did not report the running app: $out"
tool/install-local.sh "$work/dist2" >"$work/err" 2>&1 && fail "install ran with the installed app running"
grep -q "sai is running (pid $sleeper); quit sai first" "$work/err" || fail "wrong message: $(cat "$work/err")"
kill "$sleeper"; wait "$sleeper" 2>/dev/null || true
unchanged "a running sai"
pass "the installed app running is refused (and the dry run says so)"

"$SAI_INSTALL_BIN_DIR/sai_tui" sleep &
sleeper=$!
sleep 0.2
tool/install-local.sh "$work/dist2" >"$work/err" 2>&1 && fail "install ran with sai_tui running through the symlink"
grep -q "sai is running (pid $sleeper); quit sai first" "$work/err" || fail "wrong message: $(cat "$work/err")"
kill "$sleeper"; wait "$sleeper" 2>/dev/null || true
unchanged "a running sai_tui"
pass "the installed terminal client running through the symlink is refused"

mkdir -p "$work/other/sai.app/Contents/MacOS"
cp "$SAI_INSTALL_APPS_DIR/sai.app/Contents/MacOS/sai" "$work/other/sai.app/Contents/MacOS/sai"
"$work/other/sai.app/Contents/MacOS/sai" hold &
other=$!
sleep 0.2
tool/install-local.sh "$work/dist2" >"$work/err" 2>&1 || { kill "$other"; fail "another checkout's sai.app blocked the install: $(cat "$work/err")"; }
kill "$other"; wait "$other" 2>/dev/null || true
pass "a sai.app elsewhere does not count as running"
before=$(snapshot)

# The second swap failing after the first: pin the live bundle so its
# rename is refused, and expect the app to come back with nothing left over.
chflags uchg "$share_stable/bundle"
tool/install-local.sh "$work/dist2" >"$work/err" 2>&1 && { chflags nouchg "$share_stable/bundle"; fail "install succeeded with the bundle pinned"; }
chflags nouchg "$share_stable/bundle"
unchanged "a failed bundle swap"
ls -A "$SAI_INSTALL_APPS_DIR" | grep -q '^\.' && fail "orphans after the failed swap: $(ls -A "$SAI_INSTALL_APPS_DIR")"
ls -A "$share_stable" | grep -q '^\.' && fail "orphans after the failed swap: $(ls -A "$share_stable")"
[ "$(installed_version)" = "sai_tui 0.0.1-test.2" ] || fail "the pair mismatches after the failed swap: $(installed_version)"
pass "a failed bundle swap puts the app back and leaves nothing behind"

# A download in /Applications beside the dogfood copy is refused.
mkdir -p "$work/system/sai.app"
tool/install-local.sh "$work/dist2" >"$work/err" 2>&1 && fail "installed beside a system-wide sai.app"
grep -q "one Mac keeps one sai.app" "$work/err" || fail "wrong message: $(cat "$work/err")"
unchanged "a system-wide sai.app"
rm -rf "$work/system"
pass "a sai.app in /Applications is refused"

# An interrupted run left the live app under a .old name: the next run
# puts it back before judging the incoming release, even a bad one.
mv "$SAI_INSTALL_APPS_DIR/sai.app" "$SAI_INSTALL_APPS_DIR/.sai.app.old.999"
fixture "$work/bad" 0.0.1-test.3 "$c2"
sed -i '' -e '1s/^0/1/' -e '1t' -e '1s/^./0/' "$work/bad/checksums.txt"
tool/install-local.sh "$work/bad" >"$work/err" 2>&1 && fail "corrupt checksums accepted after a recovery"
grep -q "recovered .*sai.app from an interrupted install" "$work/err" || fail "no recovery reported: $(cat "$work/err")"
unchanged "a recovery followed by a refusal"
pass "a backup left by an interrupted run is recovered, not discarded"

# The kept directory cannot be written: refused before anything moves.
chmod 500 "$work/keep"
fixture "$work/dist3" 0.0.1-test.3 "$c2"
tool/install-local.sh "$work/dist3" >"$work/err" 2>&1 && { chmod 700 "$work/keep"; fail "installed without a kept copy"; }
chmod 700 "$work/keep"
grep -q "cannot create" "$work/err" || fail "wrong message: $(cat "$work/err")"
unchanged "an unwritable keep directory"
pass "an unwritable keep directory refuses before the swap"

# A first install whose bundle swap fails must not leave the new app behind.
rm -rf "$work/home2"; mkdir -p "$work/home2/share"
printf 'pinned' > "$work/home2/share/bundle"
chflags uchg "$work/home2/share/bundle"
SAI_INSTALL_APPS_DIR="$work/home2/apps" SAI_INSTALL_SHARE_DIR="$work/home2/share" SAI_INSTALL_BIN_DIR="$work/home2/bin" \
  tool/install-local.sh "$work/dist1" >"$work/err" 2>&1 && { chflags nouchg "$work/home2/share/bundle"; fail "first install succeeded with the bundle path pinned"; }
chflags nouchg "$work/home2/share/bundle"
[ ! -e "$work/home2/apps/sai.app" ] || fail "the new app was left behind after the failed first install"
ls -A "$work/home2/apps" | grep -q '^\.' && fail "orphans after the failed first install: $(ls -A "$work/home2/apps")"
pass "a failed first install removes the app it had placed"

# --- two flavors side by side (#90) --------------------------------------
# Only the stable copy: the dev cases below must leave every line of this
# exactly as it is.
stable_snapshot() { snapshot | grep -v 'sai-dev\|sai_tui-dev' || true; }
stable_before=$(stable_snapshot)
stable_unchanged() {
  [ "$(stable_snapshot)" = "$stable_before" ] || fail "$1 changed the stable installation"
}
d1=4444444444444444444444444444444444444444
d2=5555555555555555555555555555555555555555
fixture "$work/dev1" 0.0.1-test.1 "$d1" dev
fixture "$work/dev2" 0.0.1-test.2 "$d2" dev

out=$(tool/install-local.sh "$work/dev1" --dry-run)
echo "$out" | grep -q "sai dev v0.0.1-test.1" || fail "dev dry run does not name the flavor: $out"
echo "$out" | grep -q "Applications/sai-dev.app (create)" || fail "dev dry run plans the wrong app: $out"
echo "$out" | grep -q "share/sai-dev/bundle (create)" || fail "dev dry run plans the wrong bundle: $out"
echo "$out" | grep -q "bin/sai_tui-dev -> " || fail "dev dry run plans the wrong symlink: $out"
tool/install-local.sh "$work/dev1" >"$work/outd1" 2>&1 || { cat "$work/outd1"; fail "dev install failed"; }
[ -d "$SAI_INSTALL_APPS_DIR/sai-dev.app" ] && [ -d "$SAI_INSTALL_APPS_DIR/sai.app" ] || fail "the two apps do not sit side by side: $(ls -A "$SAI_INSTALL_APPS_DIR")"
[ -x "$share_dev/bundle/bin/sai_tui-dev" ] || fail "no dev bundle"
[ "$(installed_version sai_tui-dev)" = "sai_tui-dev 0.0.1-test.1" ] || fail "sai_tui-dev runs the wrong client: $(installed_version sai_tui-dev)"
[ "$(installed_version)" = "sai_tui 0.0.1-test.2" ] || fail "the dev install touched the stable client"
grep -q "^flavor: dev$" "$share_dev/installed" || fail "the dev record lacks its flavor"
grep -q "^flavor: stable$" "$share_stable/installed" || fail "the stable record lacks its flavor"
[ -f "$work/keep/sai-dev-v0.0.1-test.1-4444444/flavor" ] || fail "dev artefacts not kept under their own name"
[ "$(/usr/libexec/PlistBuddy -c 'Print :SaiFlavor' "$SAI_INSTALL_APPS_DIR/sai-dev.app/Contents/Info.plist")" = dev ] || fail "installed dev app is not dev"
stable_unchanged "installing dev"
pass "dev installs beside stable with its own app, bundle, symlink, record and kept copy"

tool/install-local.sh "$work/dev2" >"$work/outd2" 2>&1 || { cat "$work/outd2"; fail "dev upgrade failed"; }
[ "$(installed_version sai_tui-dev)" = "sai_tui-dev 0.0.1-test.2" ] || fail "dev upgrade did not switch the client"
[ "$(ls -A "$SAI_INSTALL_APPS_DIR" | wc -l | tr -d ' ')" = 2 ] || fail "not exactly one app per flavor: $(ls -A "$SAI_INSTALL_APPS_DIR")"
stable_unchanged "upgrading dev"
tool/install-local.sh "$work/keep/sai-dev-v0.0.1-test.1-4444444" >/dev/null 2>&1 || fail "dev rollback failed"
[ "$(installed_version sai_tui-dev)" = "sai_tui-dev 0.0.1-test.1" ] || fail "dev rollback did not restore the client"
stable_unchanged "rolling dev back"
pass "dev upgrades and rolls back on its own; stable does not move"

fixture "$work/legacy" 0.0.1-test.3 "$c2" legacy
[ ! -e "$work/legacy/flavor" ] || fail "the legacy fixture carries a flavor file"
tool/install-local.sh "$work/legacy" >"$work/err" 2>&1 || { cat "$work/err"; fail "a pre-flavor release did not install"; }
[ "$(installed_version)" = "sai_tui 0.0.1-test.3" ] || fail "the pre-flavor release did not land as stable"
grep -q "^flavor: stable$" "$share_stable/installed" || fail "the pre-flavor install is not recorded as stable"
[ "$(installed_version sai_tui-dev)" = "sai_tui-dev 0.0.1-test.1" ] || fail "the pre-flavor install touched dev"
pass "a kept release from before flavors installs as stable"
before=$(snapshot)

# Each artefact must say what the release says; anything else is refused
# with nothing replaced.
fixture "$work/bad" 0.0.1-test.3 "$d2" dev
/usr/libexec/PlistBuddy -c 'Set :SaiFlavor stable' "$work/bad/stage/sai-dev.app/Contents/Info.plist"
codesign --force --sign - "$work/bad/stage/sai-dev.app" >/dev/null 2>&1
repack "$work/bad" 0.0.1-test.3
tool/install-local.sh "$work/bad" >"$work/err" 2>&1 && fail "a stable app inside a dev release was accepted"
grep -q "the app is a stable build inside a dev release" "$work/err" || fail "wrong message: $(cat "$work/err")"
unchanged "a stable app in a dev release"

fixture "$work/bad" 0.0.1-test.3 "$d2" dev
echo stable > "$work/bad/tui/bundle/flavor"
repack "$work/bad" 0.0.1-test.3
tool/install-local.sh "$work/bad" >"$work/err" 2>&1 && fail "a stable client inside a dev release was accepted"
grep -q "the terminal client is a stable build inside a dev release" "$work/err" || fail "wrong message: $(cat "$work/err")"
unchanged "a stable client in a dev release"

fixture "$work/bad" 0.0.1-test.3 "$c2"
echo dev > "$work/bad/flavor"
tool/install-local.sh "$work/bad" >"$work/err" 2>&1 && fail "a dev seal over stable artefacts was accepted"
grep -q "has no dev app zip" "$work/err" || fail "wrong message: $(cat "$work/err")"
unchanged "a dev seal over stable artefacts"

fixture "$work/bad" 0.0.1-test.3 "$c2"
echo qa > "$work/bad/flavor"
tool/install-local.sh "$work/bad" >"$work/err" 2>&1 && fail "a third flavor was accepted"
grep -q "only stable and dev exist" "$work/err" || fail "wrong message: $(cat "$work/err")"
unchanged "a third flavor"

# A dev app sitting where stable goes is not replaced by a stable release.
mv "$SAI_INSTALL_APPS_DIR/sai.app" "$work/aside.app"
cp -R "$SAI_INSTALL_APPS_DIR/sai-dev.app" "$SAI_INSTALL_APPS_DIR/sai.app"
fixture "$work/dist3" 0.0.1-test.3 "$c2"
tool/install-local.sh "$work/dist3" >"$work/err" 2>&1 && fail "a stable release replaced a dev app at sai.app"
grep -q "is a dev build; a stable release does not replace it" "$work/err" || fail "wrong message: $(cat "$work/err")"
rm -rf "$SAI_INSTALL_APPS_DIR/sai.app"; mv "$work/aside.app" "$SAI_INSTALL_APPS_DIR/sai.app"
unchanged "a dev app at the stable destination"
pass "an app, client, seal or destination of the other flavor is refused"

# Running processes are judged per flavor.
"$SAI_INSTALL_APPS_DIR/sai.app/Contents/MacOS/sai" hold &
sleeper=$!
"$SAI_INSTALL_BIN_DIR/sai_tui" sleep &
sleeper_tui=$!
sleep 0.2
tool/install-local.sh "$work/dev2" >"$work/err" 2>&1 || { kill "$sleeper" "$sleeper_tui"; fail "a running stable blocked the dev install: $(cat "$work/err")"; }
kill "$sleeper" "$sleeper_tui"; wait "$sleeper" "$sleeper_tui" 2>/dev/null || true
[ "$(installed_version sai_tui-dev)" = "sai_tui-dev 0.0.1-test.2" ] || fail "the dev install did not happen"
"$SAI_INSTALL_APPS_DIR/sai-dev.app/Contents/MacOS/sai-dev" hold &
sleeper=$!
sleep 0.2
tool/install-local.sh "$work/keep/sai-dev-v0.0.1-test.1-4444444" >"$work/err" 2>&1 && { kill "$sleeper"; fail "dev installed over a running dev"; }
grep -q "sai dev is running (pid $sleeper); quit sai dev first" "$work/err" || { kill "$sleeper"; fail "wrong message: $(cat "$work/err")"; }
tool/install-local.sh "$work/dist3" >"$work/err" 2>&1 || { kill "$sleeper"; fail "a running dev blocked the stable install: $(cat "$work/err")"; }
kill "$sleeper"; wait "$sleeper" 2>/dev/null || true
"$SAI_INSTALL_BIN_DIR/sai_tui-dev" sleep &
sleeper=$!
sleep 0.2
tool/install-local.sh "$work/keep/sai-dev-v0.0.1-test.1-4444444" >"$work/err" 2>&1 && { kill "$sleeper"; fail "dev installed over a running sai_tui-dev"; }
grep -q "sai dev is running (pid $sleeper)" "$work/err" || { kill "$sleeper"; fail "wrong message: $(cat "$work/err")"; }
kill "$sleeper"; wait "$sleeper" 2>/dev/null || true
[ "$(installed_version)" = "sai_tui 0.0.1-test.3" ] || fail "stable is not what was installed while dev ran"
pass "one flavor running never blocks the other, and still blocks itself"

# A failed dev swap puts dev back and never touches stable.
stable_before=$(stable_snapshot)
before=$(snapshot)
chflags uchg "$share_dev/bundle"
tool/install-local.sh "$work/keep/sai-dev-v0.0.1-test.1-4444444" >"$work/err" 2>&1 && { chflags nouchg "$share_dev/bundle"; fail "dev install succeeded with its bundle pinned"; }
chflags nouchg "$share_dev/bundle"
unchanged "a failed dev swap"
stable_unchanged "a failed dev swap"
[ "$(installed_version sai_tui-dev)" = "sai_tui-dev 0.0.1-test.2" ] || fail "the dev pair mismatches after the failed swap"
pass "a failed dev swap restores dev and leaves stable alone"

rm "$SAI_INSTALL_BIN_DIR/sai_tui"
echo stray > "$SAI_INSTALL_BIN_DIR/sai_tui"
tool/install-local.sh "$work/dist2" >"$work/err" 2>&1 && fail "install clobbered a real file"
grep -q "is not a symlink" "$work/err" || fail "wrong message: $(cat "$work/err")"
[ "$(cat "$SAI_INSTALL_BIN_DIR/sai_tui")" = stray ] || fail "the stray file was touched"
pass "a real file where the symlink goes is refused"

echo "# $passed passed; scratch under $work removed"
