#!/bin/sh
# Puts the pinned Codex App Server into a prepared stable tree (#26, ADR
# 0013): the two official macOS slices from one pinned GitHub release,
# each verified against its pinned SHA-256 before anything is extracted,
# joined into one universal helper beside the app's executable
# (Contents/Helpers/codex-app-server, its LICENSE and NOTICE under
# Contents/Resources, where a bundle keeps text) and the host's slice
# beside the terminal client (bundle/libexec/codex-app-server, the texts
# beside it). Nothing here runs a downloaded binary; the
# digest is its version. Nothing is discovered on this Mac — not a
# Homebrew or npm Codex, not the person's own installation — and nothing
# is downloaded at run time: what this places is all a release carries.
#
#   tool/vendor-app-server.sh fetch [cache]
#   tool/vendor-app-server.sh place <app.app> <tui-bundle> [cache]
#
# The pin is tool/vendor/codex-app-server.pin (SAI_VENDOR_PIN moves it
# for the tests); the cache defaults to build/vendor/codex-app-server
# (SAI_VENDOR_CACHE), outside the repository's tracked tree. A digest
# that does not match is fatal, and the file that failed is removed.
# Moving the pin to a newer release is its own change: it re-diffs the
# protocol fixtures and reruns the whole suite (docs/release/README.md).
set -eu
cd "$(dirname "$0")/.."

pin="${SAI_VENDOR_PIN:-tool/vendor/codex-app-server.pin}"
cache="${SAI_VENDOR_CACHE:-build/vendor/codex-app-server}"
fail() { echo "vendor: $*" >&2; exit 1; }

[ -f "$pin" ] || fail "no pin at $pin"
# pin <key>: one value from the pin file, `key value`.
pinned() {
  v=$(sed -n "s/^$1 //p" "$pin")
  [ -n "$v" ] || fail "the pin names no $1"
  printf '%s\n' "$v"
}
tag=$(pinned tag)

# verify <file> <sha256>: refuse, and remove, a file whose digest differs.
verify() {
  got=$(shasum -a 256 "$1" | cut -d' ' -f1)
  if [ "$got" != "$2" ]; then
    rm -f "$1"
    fail "$(basename "$1") does not match its pinned digest (got $got); nothing was extracted"
  fi
}

# fetch_one <name> <url> <sha256>: into the cache, verified. A file
# already there with the right digest is left alone.
fetch_one() {
  name=$1 url=$2 sum=$3
  target="$cache/$name"
  if [ -f "$target" ] && [ "$(shasum -a 256 "$target" | cut -d' ' -f1)" = "$sum" ]; then
    return 0
  fi
  echo "vendor: fetching $name from $tag"
  curl -fsSL --proto '=https' --tlsv1.2 -o "$target.part" "$url" || { rm -f "$target.part"; fail "could not fetch $name"; }
  mv "$target.part" "$target"
  verify "$target" "$sum"
}

fetch() {
  mkdir -p "$cache"
  for arch in aarch64 x86_64; do
    fetch_one "codex-app-server-$arch-apple-darwin.tar.gz" "$(pinned "url_$arch")" "$(pinned "sha256_$arch")"
  done
  fetch_one LICENSE "$(pinned url_license)" "$(pinned sha256_license)"
  fetch_one NOTICE "$(pinned url_notice)" "$(pinned sha256_notice)"
  # Extract each slice into its own directory, after — never before — its
  # digest held; the binary inside is never run.
  for arch in aarch64 x86_64; do
    dir="$cache/$arch"
    rm -rf "$dir"
    mkdir -p "$dir"
    tar -xzf "$cache/codex-app-server-$arch-apple-darwin.tar.gz" -C "$dir"
    bin=$(find "$dir" -type f -name 'codex-app-server*' | head -n 1)
    [ -n "$bin" ] || fail "the $arch archive holds no codex-app-server"
    mv "$bin" "$dir/codex-app-server"
    chmod 755 "$dir/codex-app-server"
    # Upstream's own signature does not survive being joined and re-signed
    # inside sai's bundle; it is stripped here so lipo joins clean slices.
    codesign --remove-signature "$dir/codex-app-server" 2>/dev/null || true
  done
  echo "vendor: $tag verified in $cache"
}

place() {
  app=$1 bundle=$2
  [ -d "$app/Contents/MacOS" ] || fail "$app is not an app bundle"
  [ -d "$bundle/bin" ] || fail "$bundle is not the terminal client's bundle"
  # Nothing extracted earlier is trusted: the archives are checked against
  # the pin again (fetched when one is missing or differs) and re-extracted,
  # so slices a cache holds from another pin are never placed. Then the
  # slices are checked to be what lipo expects before they are joined.
  fetch
  a=$(lipo -archs "$cache/aarch64/codex-app-server")
  x=$(lipo -archs "$cache/x86_64/codex-app-server")
  [ "$a" = arm64 ] || fail "the aarch64 slice is $a, not arm64"
  [ "$x" = x86_64 ] || fail "the x86_64 slice is $x, not x86_64"
  mkdir -p "$app/Contents/Helpers" "$bundle/libexec"
  lipo -create "$cache/aarch64/codex-app-server" "$cache/x86_64/codex-app-server" \
    -output "$app/Contents/Helpers/codex-app-server"
  chmod 755 "$app/Contents/Helpers/codex-app-server"
  case "$(uname -m)" in
    arm64) host=aarch64 ;;
    x86_64) host=x86_64 ;;
    *) fail "unknown host architecture $(uname -m)" ;;
  esac
  cp "$cache/$host/codex-app-server" "$bundle/libexec/codex-app-server"
  chmod 755 "$bundle/libexec/codex-app-server"
  # A bundle's Helpers hold code alone (codesign seals text there as
  # unsealed contents); the notices go under Resources.
  mkdir -p "$app/Contents/Resources"
  for dir in "$app/Contents/Resources" "$bundle/libexec"; do
    cp "$cache/LICENSE" "$dir/codex-app-server.LICENSE"
    cp "$cache/NOTICE" "$dir/codex-app-server.NOTICE"
    echo "$tag" > "$dir/codex-app-server.version"
  done
  echo "vendor: placed codex-app-server $tag ($(lipo -archs "$app/Contents/Helpers/codex-app-server") in the app, $host in the client)"
}

case "${1:-}" in
  fetch) [ $# -le 2 ] || { echo "usage: tool/vendor-app-server.sh fetch [cache]" >&2; exit 2; }
         [ $# -eq 2 ] && cache=$2
         fetch ;;
  place) [ $# -eq 3 ] || [ $# -eq 4 ] || { echo "usage: tool/vendor-app-server.sh place <app.app> <tui-bundle> [cache]" >&2; exit 2; }
         [ $# -eq 4 ] && cache=$4
         place "$2" "$3" ;;
  *) echo "usage: tool/vendor-app-server.sh fetch [cache] | place <app.app> <tui-bundle> [cache]" >&2; exit 2 ;;
esac
