#!/bin/sh
# Exercises tool/release.sh's sign phase (#95) without an identity, a
# keychain or a toolchain: a prepared fixture — tiny C programs standing
# in for the app, a framework, the terminal client and a dylib, ad-hoc
# signed and sealed the way `prepare` seals — and a fake `security` and
# `codesign` on PATH that record every call and answer as the test
# scripts them. HOME and dist/ point into a scratch directory; the real
# keychains are never opened. Run it from anywhere:
# sh tool/test/release_sign_test.sh
set -eu
cd "$(dirname "$0")/../.."

work=$(mktemp -d "${TMPDIR:-/tmp}/sai-sign-test.XXXXXX")
trap 'rm -rf "$work"' EXIT INT TERM
export HOME="$work/home"
export SAI_RELEASE_DIST="$work/dist"
# A checkout mid-change is fine here: nothing is built from it.
export SAI_RELEASE_DIRTY=1
export FAKE="$work/fake"
mkdir -p "$HOME/Library/Keychains" "$FAKE" "$work/bin"
real_path=$PATH
keychain="$HOME/Library/Keychains/sai-signing.keychain-db"
version=$(sed -n 's/^version: //p' packages/sai_core/pubspec.yaml)
short=${version%%-*}
head=$(git rev-parse HEAD)
dist="$SAI_RELEASE_DIST/sai-v$version"
prepared="$dist/prepared"
release="$dist/release"
hash=0123456789ABCDEF0123456789ABCDEF01234567

passed=0
pass() { passed=$((passed + 1)); echo "ok $passed - $*"; }
fail() { echo "not ok - $*" >&2; exit 1; }

# --- the fake toolchain ---------------------------------------------------
cat > "$work/bin/security" <<'FAKE'
#!/bin/sh
echo "$*" >> "$FAKE/security.log"
cat "$FAKE/identities"
exit "$(cat "$FAKE/security_exit")"
FAKE
cat > "$work/bin/codesign" <<'FAKE'
#!/bin/sh
echo "$*" >> "$FAKE/codesign.log"
case " $* " in
  *" -dv "*)
    if [ -e "$FAKE/display_signed" ]; then echo "Authority=fake" >&2; else echo "Signature=adhoc" >&2; fi
    exit 0 ;;
  *" --verify "*) exit 0 ;;
  *" --sign "*)
    n=$(( $(cat "$FAKE/signs" 2>/dev/null || echo 0) + 1 ))
    echo "$n" > "$FAKE/signs"
    if [ "$n" = "$(cat "$FAKE/fail_at" 2>/dev/null || echo 0)" ]; then
      echo "codesign: User interaction is not allowed." >&2
      exit 1
    fi
    exit 0 ;;
esac
exit 0
FAKE
chmod +x "$work/bin/security" "$work/bin/codesign"

# identities <n>: what the fake `security find-identity` lists.
identities() {
  case "$1" in
    0) printf '     0 valid identities found\n' ;;
    1) printf '  1) %s "Apple Development: Test Person (TEAM123456)"\n     1 valid identities found\n' "$hash" ;;
    2) printf '  1) %s "Apple Development: Test Person (TEAM123456)"\n  2) %s "Apple Development: Other (TEAM123456)"\n     2 valid identities found\n' "$hash" "$(echo "$hash" | tr 0 9)" ;;
  esac > "$FAKE/identities"
}
reset_fake() {
  rm -f "$FAKE"/*
  identities 1
  echo 0 > "$FAKE/security_exit"
}

# --- the prepared fixture --------------------------------------------------
manifest() {
  (cd "$1" && find . -type f ! -name manifest.txt ! -name seal -exec shasum -a 256 {} + | LC_ALL=C sort -k 2)
}
seal_prepared() {
  manifest "$1" > "$1/manifest.txt"
  {
    echo "manifest $(shasum -a 256 "$1/manifest.txt" | cut -d' ' -f1)"
    echo "flavor $(cat "$1/flavor")"
    echo "commit $(cat "$1/commit")"
    echo "version $(cat "$1/version")"
  } > "$1/seal"
}
# fixture [commit] [flavor]: a sealed prepared/ for this checkout's version.
fixture() {
  commit=${1:-$head} flavor=${2:-stable}
  rm -rf "$prepared"
  app="$prepared/sai.app"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks/Foo.framework" "$prepared/tui/bundle/bin" "$prepared/tui/bundle/lib"
  cat > "$work/sai.c" <<C
#include <stdio.h>
int main(void) { puts("sai app fixture"); return 0; }
C
  cat > "$work/tui.c" <<C
#include <stdio.h>
int main(int argc, char **argv) { if (argc > 1) { printf("sai_tui %s\n", "$version"); return 0; } return 2; }
C
  printf 'int foo(void) { return 1; }\n' > "$work/foo.c"
  cc -o "$app/Contents/MacOS/sai" "$work/sai.c"
  cc -o "$prepared/tui/bundle/bin/sai_tui" "$work/tui.c"
  cc -dynamiclib -o "$app/Contents/Frameworks/Foo.framework/Foo" "$work/foo.c"
  mkdir -p "$app/Contents/Frameworks/Foo.framework/Resources"
  cat > "$app/Contents/Frameworks/Foo.framework/Resources/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>Foo</string>
	<key>CFBundleIdentifier</key><string>me.slominski.sai.fixture.Foo</string>
	<key>CFBundlePackageType</key><string>FMWK</string>
	<key>CFBundleVersion</key><string>1</string>
</dict>
</plist>
PLIST
  cc -dynamiclib -o "$prepared/tui/bundle/lib/libfoo.dylib" "$work/foo.c"
  cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>sai</string>
	<key>CFBundleIdentifier</key><string>me.slominski.sai.fixture</string>
	<key>SaiFlavor</key><string>stable</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>$short</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>SaiCommit</key><string>$commit</string>
</dict>
</plist>
PLIST
  for f in "$app/Contents/Frameworks/Foo.framework" "$app" "$prepared/tui/bundle/lib/libfoo.dylib" "$prepared/tui/bundle/bin/sai_tui"; do
    /usr/bin/codesign --force --sign - "$f" >/dev/null 2>&1
  done
  echo "$commit" > "$prepared/tui/bundle/commit"
  echo stable > "$prepared/tui/bundle/flavor"
  echo "$commit" > "$prepared/commit"
  echo "$flavor" > "$prepared/flavor"
  echo "$version" > "$prepared/version"
  seal_prepared "$prepared"
}

# sign: runs the phase under the fake toolchain, capturing everything.
sign() {
  PATH="$work/bin:$real_path" tool/release.sh sign >"$work/out" 2>&1
}
refused() {
  if sign; then fail "sign succeeded: $1"; fi
  grep -q "$2" "$work/out" || fail "wrong refusal for $1: $(cat "$work/out")"
}

reset_fake
touch "$keychain"

# --- refusals before any identity is touched -------------------------------
refused "nothing prepared" "nothing prepared"
[ ! -e "$FAKE/security.log" ] || fail "security was asked with nothing prepared"

fixture
printf 'x' >> "$prepared/tui/bundle/commit"
refused "a modified prepared tree" "changed after it was sealed"
fixture
rm "$prepared/seal"
refused "an unsealed prepared tree" "carries no seal"
fixture 4444444444444444444444444444444444444444
refused "a stale prepared tree" "was built from 4444444"
fixture "$head" dev
refused "a dev prepared tree" "is a dev release, not stable"
fixture
touch "$FAKE/display_signed"
refused "an already signed tree" "already signed"
rm -f "$FAKE/display_signed"
[ ! -e "$FAKE/security.log" ] || fail "security was asked for a refused tree: $(cat "$FAKE/security.log")"
pass "sign refuses an unprepared, modified, unsealed, stale, dev or already signed tree first"

# --- the keychain and its identity -------------------------------------------
fixture
rm -f "$keychain"
refused "no dedicated keychain" "no dedicated signing keychain"
[ ! -e "$FAKE/security.log" ] || fail "security was asked with no keychain file"
touch "$keychain"
echo 1 > "$FAKE/security_exit"
refused "an unreadable keychain" "could not be read"
echo 0 > "$FAKE/security_exit"
identities 0
refused "no identity" "no usable code-signing identity"
identities 2
refused "two identities" "must hold exactly one"
[ "$(cat "$FAKE/security.log")" = "find-identity -v -p codesigning $keychain
find-identity -v -p codesigning $keychain
find-identity -v -p codesigning $keychain" ] || fail "unexpected security calls: $(cat "$FAKE/security.log")"
grep -q "$hash\|Apple Development" "$work/out" && fail "the identity leaked into the output"
[ ! -e "$release" ] || fail "a refusal produced a release"
pass "sign fails closed on a missing, unreadable, empty or ambiguous keychain, and says nothing about identities"

# --- a cancelled authorization -----------------------------------------------
reset_fake
fixture
before=$(manifest "$prepared")
mkdir -p "$release" && echo previous > "$release/seal"
echo 3 > "$FAKE/fail_at"
refused "a cancelled authorization" "User interaction is not allowed"
[ "$(manifest "$prepared")" = "$before" ] || fail "the prepared tree changed"
[ "$(cat "$release/seal")" = previous ] || fail "the previous release was replaced"
[ -z "$(ls -A "$dist" | grep '^\.')" ] || fail "staging left behind: $(ls -A "$dist")"
grep -q "$hash" "$work/out" && fail "the identity leaked into the output"
pass "a cancelled authorization leaves the prepared tree and the previous release intact"

# --- the signing order -----------------------------------------------------------
reset_fake
sign || { cat "$work/out"; fail "sign failed"; }
signs=$(grep -- '--sign' "$FAKE/codesign.log")
expected="--force --sign $hash --timestamp=none --keychain $keychain $dist/.signing.PID/sai.app/Contents/Frameworks/Foo.framework
--force --sign $hash --timestamp=none --keychain $keychain --entitlements apps/sai_app/macos/Runner/Release.entitlements $dist/.signing.PID/sai.app
--force --sign $hash --timestamp=none --keychain $keychain $dist/.signing.PID/tui/bundle/lib/libfoo.dylib
--force --sign $hash --timestamp=none --keychain $keychain $dist/.signing.PID/tui/bundle/bin/sai_tui"
[ "$(echo "$signs" | sed 's/\.signing\.[0-9]*/.signing.PID/')" = "$expected" ] || fail "signing order or arguments differ:
$signs"
grep -- '--sign' "$FAKE/codesign.log" | grep -q -- '--deep' && fail "signed with --deep"
grep -q -- "--verify --deep --strict $dist/.signing.[0-9]*/sai.app" "$FAKE/codesign.log" || fail "the app was not verified deep and strict"
grep -q -- "--verify --strict $dist/.signing.[0-9]*/tui/bundle/bin/sai_tui" "$FAKE/codesign.log" || fail "the client was not verified strict"
grep -q -- "--verify --strict $dist/.signing.[0-9]*/tui/bundle/lib/libfoo.dylib" "$FAKE/codesign.log" || fail "the dylib was not verified strict"
[ "$(cat "$FAKE/security.log")" = "find-identity -v -p codesigning $keychain" ] || fail "security was called more than once"
grep -q "$hash\|Apple Development" "$work/out" && fail "the identity leaked into the output"
grep -rq "$hash\|Apple Development" "$dist" && fail "the identity leaked into dist/"
[ "$(sed -n 's/^signer //p' "$release/seal")" = stable ] || fail "the release is not sealed as stable"
[ "$(cat "$release/commit")" = "$head" ] || fail "the release commit is wrong"
[ "$(cat "$release/flavor")" = stable ] || fail "the release flavor is wrong"
[ "$(manifest "$prepared")" = "$before" ] || fail "sign changed the prepared tree"
[ -z "$(ls -A "$dist" | grep '^\.')" ] || fail "staging left behind: $(ls -A "$dist")"
pass "sign goes inside out — framework, app, dylib, client — from the dedicated keychain, verifies, seals and leaves no trace of the identity"

# --- the signed release is what the installer and publish accept ----------------
export SAI_INSTALL_APPS_DIR="$work/home/Applications"
export SAI_INSTALL_SHARE_ROOT="$work/home/.local/share"
export SAI_INSTALL_BIN_DIR="$work/home/.local/bin"
export SAI_INSTALL_KEEP_DIR="$work/keep"
export SAI_INSTALL_SYSTEM_APPS_DIR="$work/system"
tool/release.sh local-install stable --dry-run >"$work/out" 2>&1 || { cat "$work/out"; fail "local-install stable --dry-run refused the signed release"; }
grep -q "dry run; nothing written" "$work/out" || fail "no dry run: $(cat "$work/out")"
tool/install-local.sh "$release" >"$work/out" 2>&1 || { cat "$work/out"; fail "the installer refused the signed release: $(cat "$work/out")"; }
[ -x "$SAI_INSTALL_SHARE_ROOT/sai/bundle/bin/sai_tui" ] || fail "not installed"
sed -i '' 's/^signer stable$/signer dev/' "$release/seal"
if tool/release.sh local-install stable >"$work/out" 2>&1; then fail "local-install stable took a release not sealed by sign"; fi
grep -q "not sealed by the signing phase" "$work/out" || fail "wrong refusal: $(cat "$work/out")"
pass "local-install stable takes only a release sealed by the signing phase"

echo "# $passed passed; scratch under $work removed"
