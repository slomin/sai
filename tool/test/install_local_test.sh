#!/bin/sh
# Exercises tool/install-local.sh against temporary roots (#87). The
# release it installs is a fixture: a minimal sai.app and terminal-client
# bundle whose executables are tiny C programs, ad-hoc signed — so the
# signature checks run for real without any identity or Keychain — zipped,
# tarred and checksummed the way tool/release.sh stages them. HOME and
# every root point into a scratch directory; nothing here reads or writes
# the real home. Run it from anywhere: sh tool/test/install_local_test.sh
set -eu
cd "$(dirname "$0")/../.."

work=$(mktemp -d "${TMPDIR:-/tmp}/sai-install-test.XXXXXX")
trap 'pkill -f "$work/running/sai.app/Contents/MacOS/sai\$" 2>/dev/null || true; rm -rf "$work"' EXIT INT TERM
export HOME="$work/home"
export SAI_INSTALL_APPS_DIR="$work/home/Applications"
export SAI_INSTALL_SHARE_DIR="$work/home/.local/share/sai"
export SAI_INSTALL_BIN_DIR="$work/home/.local/bin"
export SAI_INSTALL_KEEP_DIR="$work/keep"
mkdir -p "$HOME"

passed=0
pass() { passed=$((passed + 1)); echo "ok $passed - $*"; }
fail() { echo "not ok - $*" >&2; exit 1; }

# fixture <dir> <version> <commit>: a staged release for that version.
fixture() {
  dir=$1 version=$2 commit=$3 short=${2%%-*}
  rm -rf "$dir"
  mkdir -p "$dir/stage/sai.app/Contents/MacOS" "$dir/tui/bundle/bin" "$dir/tui/bundle/lib"
  cat > "$work/sai.c" <<EOF
#include <stdio.h>
int main(void) { puts("sai app fixture"); return 0; }
EOF
  cat > "$work/tui.c" <<EOF
#include <stdio.h>
int main(int argc, char **argv) {
  if (argc > 1) { printf("sai_tui %s\n", "$version"); return 0; }
  return 2;
}
EOF
  cc -o "$dir/stage/sai.app/Contents/MacOS/sai" "$work/sai.c"
  cc -o "$dir/tui/bundle/bin/sai_tui" "$work/tui.c"
  cat > "$dir/stage/sai.app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>sai</string>
	<key>CFBundleIdentifier</key><string>me.slominski.sai.fixture</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>$short</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>SaiCommit</key><string>$commit</string>
</dict>
</plist>
EOF
  codesign --force --sign - "$dir/stage/sai.app" >/dev/null 2>&1
  codesign --force --sign - "$dir/tui/bundle/bin/sai_tui" >/dev/null 2>&1
  echo "$commit" > "$dir/tui/bundle/commit"
  (cd "$dir/stage" && ditto -c -k --keepParent sai.app "../sai-v$version-macos-arm64.zip")
  tar -C "$dir/tui" -czf "$dir/sai_tui-v$version-macos-arm64.tar.gz" bundle
  (cd "$dir" && shasum -a 256 *.zip *.tar.gz > checksums.txt)
  echo "$commit" > "$dir/commit"
}

# snapshot: one line per installed file with its hash, for "unchanged" checks.
snapshot() {
  if [ -d "$HOME/Applications" ] || [ -d "$HOME/.local" ]; then
    (cd "$HOME" && find Applications .local -type f -o -type l 2>/dev/null | sort | while read -r f; do
      if [ -L "$f" ]; then echo "$f -> $(readlink "$f")"; else shasum -a 256 "$f"; fi
    done)
  fi
}

installed_version() { "$SAI_INSTALL_BIN_DIR/sai_tui" version; }

c1=1111111111111111111111111111111111111111
c2=2222222222222222222222222222222222222222
fixture "$work/dist1" 0.0.1-test.1 "$c1"
fixture "$work/dist2" 0.0.1-test.2 "$c2"

# --- dry run writes nothing --------------------------------------------
out=$(tool/install-local.sh "$work/dist1" --dry-run)
echo "$out" | grep -q "dry run; nothing written" || fail "dry run did not say so: $out"
echo "$out" | grep -q "Applications/sai.app (create)" || fail "dry run did not plan the app: $out"
[ ! -e "$SAI_INSTALL_APPS_DIR" ] && [ ! -e "$SAI_INSTALL_SHARE_DIR" ] && [ ! -e "$work/keep" ] \
  || fail "dry run created something"
pass "dry run prints the plan and writes nothing"

# --- first install -----------------------------------------------------
tool/install-local.sh "$work/dist1" >"$work/out1" 2>&1 || { cat "$work/out1"; fail "first install failed"; }
[ -d "$SAI_INSTALL_APPS_DIR/sai.app" ] || fail "no sai.app installed"
[ -x "$SAI_INSTALL_SHARE_DIR/bundle/bin/sai_tui" ] || fail "no bundle installed"
[ -L "$SAI_INSTALL_BIN_DIR/sai_tui" ] || fail "no symlink"
[ "$(installed_version)" = "sai_tui 0.0.1-test.1" ] || fail "symlink runs the wrong client: $(installed_version)"
[ "$(/usr/libexec/PlistBuddy -c 'Print :SaiCommit' "$SAI_INSTALL_APPS_DIR/sai.app/Contents/Info.plist")" = "$c1" ] \
  || fail "installed app carries the wrong commit"
grep -q "^commit: $c1$" "$SAI_INSTALL_SHARE_DIR/installed" || fail "installed file lacks the commit"
grep -q "^version: 0.0.1-test.1$" "$SAI_INSTALL_SHARE_DIR/installed" || fail "installed file lacks the version"
[ -f "$work/keep/sai-v0.0.1-test.1-1111111/checksums.txt" ] || fail "artefacts not kept"
grep -rq "Authority\|Apple Development" "$SAI_INSTALL_SHARE_DIR/installed" "$work/out1" && fail "identity in metadata or log"
ls "$SAI_INSTALL_APPS_DIR" | grep -q '^\.sai' && fail "staging left behind in Applications"
pass "first install creates the roots, the symlink, the record and the kept copy"

# --- upgrade -----------------------------------------------------------
tool/install-local.sh "$work/dist2" >"$work/out2" 2>&1 || { cat "$work/out2"; fail "upgrade failed"; }
[ "$(installed_version)" = "sai_tui 0.0.1-test.2" ] || fail "upgrade did not switch the client"
[ "$(ls "$SAI_INSTALL_APPS_DIR" | wc -l | tr -d ' ')" = 1 ] || fail "more than one thing in Applications: $(ls "$SAI_INSTALL_APPS_DIR")"
[ -d "$work/keep/sai-v0.0.1-test.1-1111111" ] && [ -d "$work/keep/sai-v0.0.1-test.2-2222222" ] || fail "kept copies missing"
grep -q "^commit: $c2$" "$SAI_INSTALL_SHARE_DIR/installed" || fail "installed file not updated"
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
sed -i '' 's/^[0-9a-f]/0/' "$work/bad/checksums.txt"
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
(cd "$work/bad/stage" && rm ../sai-v*.zip && ditto -c -k --keepParent sai.app "../sai-v0.0.1-test.3-macos-arm64.zip")
(cd "$work/bad" && shasum -a 256 *.zip *.tar.gz > checksums.txt)
tool/install-local.sh "$work/bad" >"$work/err" 2>&1 && fail "tampered app accepted"
grep -q "signature does not verify" "$work/err" || fail "wrong message: $(cat "$work/err")"
unchanged "a broken signature"
pass "a tampered app fails its signature check"

# A copied /bin/sleep would be killed by its launch constraint; build one.
mkdir -p "$work/running/sai.app/Contents/MacOS"
printf '#include <unistd.h>\nint main(void) { sleep(60); return 0; }\n' > "$work/sleep.c"
cc -o "$work/running/sai.app/Contents/MacOS/sai" "$work/sleep.c"
"$work/running/sai.app/Contents/MacOS/sai" &
sleeper=$!
sleep 0.2
tool/install-local.sh "$work/dist2" >"$work/err" 2>&1 && fail "install ran with sai running"
grep -q "sai is running (pid $sleeper); quit sai first" "$work/err" || fail "wrong message: $(cat "$work/err")"
kill "$sleeper"
wait "$sleeper" 2>/dev/null || true
unchanged "a running sai"
pass "a running sai is refused"

rm "$SAI_INSTALL_BIN_DIR/sai_tui"
echo stray > "$SAI_INSTALL_BIN_DIR/sai_tui"
tool/install-local.sh "$work/dist2" >"$work/err" 2>&1 && fail "install clobbered a real file"
grep -q "is not a symlink" "$work/err" || fail "wrong message: $(cat "$work/err")"
[ "$(cat "$SAI_INSTALL_BIN_DIR/sai_tui")" = stray ] || fail "the stray file was touched"
pass "a real file where the symlink goes is refused"

echo "# $passed passed; scratch under $work removed"
