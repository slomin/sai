#!/bin/sh
# tool/vendor-app-server.sh (#26) against fixtures: two cc-built slices
# packed like the official archives, a pin naming their digests, and a
# fake curl on PATH that serves them — so the script's rules are proven
# without the network and without the real binary: the pinned URLs and
# nothing else are asked for, a wrong digest is fatal before anything is
# extracted, the placed helper is universal and the client's slice is the
# host's, LICENSE and NOTICE ride along, and the downloaded binary is
# never executed (the stub writes a tripwire if it ever runs). Then
# prepare's rule: a dev tree gets no sidecar.
set -eu
cd "$(dirname "$0")/../.."

passed=0
pass() { passed=$((passed + 1)); echo "ok $passed - $1"; }
fail() { echo "not ok - $1" >&2; exit 1; }

work=$(mktemp -d "${TMPDIR:-/tmp}/sai-vendor-test.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/fixtures" "$work/cache" "$work/app/Contents/MacOS" "$work/tui/bundle/bin"
real_path=$PATH
tripwire="$work/tripwire"

# --- the fixtures: two slices, packed like upstream ---------------------------
cat > "$work/stub.c" <<C
#include <stdio.h>
int main(void) { FILE *f = fopen("$tripwire", "w"); if (f) { fputs("ran\\n", f); fclose(f); } puts("codex-app-server stub"); return 0; }
C
cc -arch arm64 -o "$work/fixtures/codex-app-server-arm64" "$work/stub.c"
cc -arch x86_64 -o "$work/fixtures/codex-app-server-x86_64" "$work/stub.c"
mkdir -p "$work/fixtures/aarch64" "$work/fixtures/x86_64"
cp "$work/fixtures/codex-app-server-arm64" "$work/fixtures/aarch64/codex-app-server-aarch64-apple-darwin"
cp "$work/fixtures/codex-app-server-x86_64" "$work/fixtures/x86_64/codex-app-server-x86_64-apple-darwin"
tar -C "$work/fixtures/aarch64" -czf "$work/fixtures/codex-app-server-aarch64-apple-darwin.tar.gz" codex-app-server-aarch64-apple-darwin
tar -C "$work/fixtures/x86_64" -czf "$work/fixtures/codex-app-server-x86_64-apple-darwin.tar.gz" codex-app-server-x86_64-apple-darwin
printf 'Apache License fixture\n' > "$work/fixtures/LICENSE"
printf 'OpenAI Codex fixture notice\n' > "$work/fixtures/NOTICE"
sum() { shasum -a 256 "$1" | cut -d' ' -f1; }

# pin [bad-arch]: the pin file over the fixtures, one digest wrong when asked.
pin() {
  a=$(sum "$work/fixtures/codex-app-server-aarch64-apple-darwin.tar.gz")
  x=$(sum "$work/fixtures/codex-app-server-x86_64-apple-darwin.tar.gz")
  [ "${1:-}" = aarch64 ] && a=0000000000000000000000000000000000000000000000000000000000000000
  [ "${1:-}" = x86_64 ] && x=0000000000000000000000000000000000000000000000000000000000000000
  cat > "$work/pin" <<P
tag rust-v0.0.0-fixture
url_aarch64 https://github.com/openai/codex/releases/download/rust-v0.0.0-fixture/codex-app-server-aarch64-apple-darwin.tar.gz
sha256_aarch64 $a
url_x86_64 https://github.com/openai/codex/releases/download/rust-v0.0.0-fixture/codex-app-server-x86_64-apple-darwin.tar.gz
sha256_x86_64 $x
url_license https://raw.githubusercontent.com/openai/codex/rust-v0.0.0-fixture/LICENSE
sha256_license $(sum "$work/fixtures/LICENSE")
url_notice https://raw.githubusercontent.com/openai/codex/rust-v0.0.0-fixture/NOTICE
sha256_notice $(sum "$work/fixtures/NOTICE")
P
}

# A fake curl: records the URL, copies the fixture the URL names.
cat > "$work/bin/curl" <<'SH'
#!/bin/sh
out=""; url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    -*) shift ;;
    *) url=$1; shift ;;
  esac
done
echo "$url" >> "$FIXTURES/curl.log"
cp "$FIXTURES/$(basename "$url")" "$out"
SH
chmod +x "$work/bin/curl"
export FIXTURES="$work/fixtures"
export SAI_VENDOR_PIN="$work/pin"
export SAI_VENDOR_CACHE="$work/cache"
vendor() { PATH="$work/bin:$real_path" tool/vendor-app-server.sh "$@" >"$work/out" 2>&1; }

# --- the real pin is one exact stable release ------------------------------
real_pin=tool/vendor/codex-app-server.pin
tag=$(sed -n 's/^tag //p' "$real_pin")
case "$tag" in
  rust-v[0-9]*.[0-9]*.[0-9]) ;;
  *) fail "the pin's tag '$tag' is not one exact stable rust-vX.Y.Z release" ;;
esac
grep -q "static const release = '$tag';" packages/sai_core/lib/src/llm/codex_app_server/protocol.dart \
  || fail "packages/sai_core's protocol pin differs from $real_pin ($tag)"
for k in url_aarch64 url_x86_64; do
  grep -q "^$k https://github.com/openai/codex/releases/download/$tag/codex-app-server-" "$real_pin" || fail "$k is not under the pinned release"
done
for k in sha256_aarch64 sha256_x86_64 sha256_license sha256_notice; do
  grep -Eq "^$k [0-9a-f]{64}$" "$real_pin" || fail "$k is not a SHA-256"
done
grep -v '^#' "$real_pin" | grep -q 'latest\|alpha' && fail "the pin floats"
pass "the real pin names one exact stable release, its two slices by digest, and matches the protocol pin"

# --- fetch: the pinned URLs and nothing else, verified, extracted, never run
pin
vendor fetch || { cat "$work/out"; fail "fetch failed"; }
[ "$(sort "$work/fixtures/curl.log")" = "$(printf '%s\n' \
  https://github.com/openai/codex/releases/download/rust-v0.0.0-fixture/codex-app-server-aarch64-apple-darwin.tar.gz \
  https://github.com/openai/codex/releases/download/rust-v0.0.0-fixture/codex-app-server-x86_64-apple-darwin.tar.gz \
  https://raw.githubusercontent.com/openai/codex/rust-v0.0.0-fixture/LICENSE \
  https://raw.githubusercontent.com/openai/codex/rust-v0.0.0-fixture/NOTICE | sort)" ] || fail "curl asked for more or other than the pinned URLs: $(cat "$work/fixtures/curl.log")"
[ -f "$work/cache/aarch64/codex-app-server" ] && [ -f "$work/cache/x86_64/codex-app-server" ] || fail "the slices were not extracted"
[ "$(lipo -archs "$work/cache/aarch64/codex-app-server")" = arm64 ] || fail "wrong arch in the aarch64 slice"
[ "$(lipo -archs "$work/cache/x86_64/codex-app-server")" = x86_64 ] || fail "wrong arch in the x86_64 slice"
[ ! -e "$tripwire" ] || fail "the downloaded binary was executed"
# A second fetch asks for nothing: the cache holds verified files.
: > "$work/fixtures/curl.log"
vendor fetch || fail "second fetch failed"
[ ! -s "$work/fixtures/curl.log" ] || fail "a verified cache was fetched again"
pass "fetch asks for the pinned URLs alone, verifies, extracts, and never runs what it fetched"

# --- a wrong digest is fatal before anything is extracted --------------------
for arch in aarch64 x86_64; do
  rm -rf "$work/cache"
  mkdir -p "$work/cache"
  pin "$arch"
  if vendor fetch; then fail "fetch accepted a wrong $arch digest"; fi
  grep -q "does not match its pinned digest" "$work/out" || fail "wrong refusal: $(cat "$work/out")"
  grep -q "nothing was extracted" "$work/out" || fail "the refusal does not say nothing was extracted"
  [ ! -e "$work/cache/aarch64/codex-app-server" ] && [ ! -e "$work/cache/x86_64/codex-app-server" ] || fail "something was extracted after a bad $arch digest"
  [ ! -e "$work/cache/codex-app-server-$arch-apple-darwin.tar.gz" ] || fail "the file with the wrong digest was kept"
  [ ! -e "$tripwire" ] || fail "the downloaded binary was executed"
done
pass "a digest that does not match is fatal, the file is removed, nothing is extracted"

# --- place: universal helper in the app, host slice in the client, notices ---
rm -rf "$work/cache"; mkdir -p "$work/cache"
pin
vendor place "$work/app" "$work/tui/bundle" || { cat "$work/out"; fail "place failed"; }
helper="$work/app/Contents/Helpers/codex-app-server"
sidecar="$work/tui/bundle/libexec/codex-app-server"
[ -x "$helper" ] || fail "no helper in the app"
[ -x "$sidecar" ] || fail "no sidecar in the client"
case "$(lipo -archs "$helper")" in
  *x86_64*arm64*|*arm64*x86_64*) ;;
  *) fail "the app's helper is $(lipo -archs "$helper"), not universal" ;;
esac
case "$(uname -m)" in
  arm64) [ "$(lipo -archs "$sidecar")" = arm64 ] || fail "the client's slice is not the host's" ;;
  x86_64) [ "$(lipo -archs "$sidecar")" = x86_64 ] || fail "the client's slice is not the host's" ;;
esac
[ -z "$(ls "$work/app/Contents/Helpers" | grep -v '^codex-app-server$')" ] || fail "Helpers holds more than code: $(ls "$work/app/Contents/Helpers")"
for dir in "$work/app/Contents/Resources" "$work/tui/bundle/libexec"; do
  [ "$(cat "$dir/codex-app-server.LICENSE")" = "Apache License fixture" ] || fail "no LICENSE in $dir"
  [ "$(cat "$dir/codex-app-server.NOTICE")" = "OpenAI Codex fixture notice" ] || fail "no NOTICE in $dir"
  [ "$(cat "$dir/codex-app-server.version")" = rust-v0.0.0-fixture ] || fail "no version note in $dir"
done
grep -q "placed codex-app-server rust-v0.0.0-fixture" "$work/out" || fail "place did not say what it placed"
[ ! -e "$tripwire" ] || fail "the placed binary was executed"
pass "place joins a universal helper for the app, the host's slice for the client, with LICENSE, NOTICE and the tag under Resources and libexec"

# --- a cache extracted for another pin is not trusted: place re-verifies ---
rm -rf "$work/cache"; mkdir -p "$work/cache/aarch64" "$work/cache/x86_64"
cp "$work/fixtures/codex-app-server-arm64" "$work/cache/aarch64/codex-app-server"
cp "$work/fixtures/codex-app-server-arm64" "$work/cache/x86_64/codex-app-server"
: > "$work/fixtures/curl.log"
pin
vendor place "$work/app" "$work/tui/bundle" || { cat "$work/out"; fail "place over a stale cache failed"; }
grep -q 'codex-app-server-x86_64-apple-darwin.tar.gz' "$work/fixtures/curl.log" || fail "a stale cache was placed without fetching the pinned archives"
[ "$(lipo -archs "$work/cache/x86_64/codex-app-server")" = x86_64 ] || fail "the stale slice was kept"
case "$(lipo -archs "$helper")" in
  *x86_64*arm64*|*arm64*x86_64*) ;;
  *) fail "the helper is not universal after a stale cache" ;;
esac
pass "place trusts no slice it did not verify this run: the pinned archives are fetched and re-extracted"

# --- an archive whose slice is not the pinned architecture is refused -------
cp "$work/fixtures/codex-app-server-x86_64-apple-darwin.tar.gz" "$work/x86_64.tar.gz.good"
tar -C "$work/fixtures/aarch64" -czf "$work/fixtures/codex-app-server-x86_64-apple-darwin.tar.gz" codex-app-server-aarch64-apple-darwin
rm -rf "$work/cache"; mkdir -p "$work/cache"
pin
if vendor place "$work/app" "$work/tui/bundle"; then fail "place joined two slices of one arch"; fi
grep -q "the x86_64 slice is arm64, not x86_64" "$work/out" || fail "wrong refusal: $(cat "$work/out")"
mv "$work/x86_64.tar.gz.good" "$work/fixtures/codex-app-server-x86_64-apple-darwin.tar.gz"
pass "place refuses a slice that is not the architecture the pin names"

# --- prepare's rule: the dev flavor carries no sidecar ----------------------------
grep -q 'stable) tool/vendor-app-server.sh place "$app" "$work/tui/bundle" ;;' tool/release.sh || fail "prepare does not place the sidecar for stable"
! grep -q 'dev) tool/vendor-app-server.sh' tool/release.sh || fail "prepare places the sidecar for dev"
grep -q 'a dev release carries a codex-app-server' tool/verify-release.sh || fail "verify does not refuse a dev release with a sidecar"
grep -q "codex-app-server helper is .*not universal" tool/verify-release.sh || fail "verify does not check the helper's architectures"
pass "prepare places the sidecar for stable alone, and verify refuses it in dev"

echo "# $passed passed; scratch under $work removed"
