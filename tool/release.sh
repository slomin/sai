#!/bin/sh
# Builds the release: a signed sai.app and the signed terminal-client
# bundle, version-stamped, zipped and checksummed under dist/, from one
# command; then publishes them as a GitHub pre-release.
#
#   SAI_CODESIGN_IDENTITY="Apple Development: …" tool/release.sh          # build
#   SAI_CODESIGN_IDENTITY="Apple Development: …" tool/release.sh publish  # tag + release
#
# The version is the one in packages/sai_core/pubspec.yaml (tests keep
# saiVersion and the other pubspecs equal to it); the app's Info.plist
# takes the numeric part and the commit count as its build number, since
# CFBundleShortVersionString must be numeric. The app is signed after
# `flutter build` — frameworks first, then the bundle — so the Xcode
# project keeps no identity (ADR 0017); the terminal client goes through
# tool/sign-tui.sh. One Apple Development identity signs both, so the
# Keychain items trust each release the way they trusted the last one
# (ADR 0008). Nothing is notarised: the first launch on another Mac is
# the Gatekeeper step in docs/release/README.md. A dirty worktree is
# refused unless SAI_RELEASE_DIRTY=1, so a release is what its commit
# says it is; the build records its commit under dist/, and `publish`
# refuses a dist built from another commit, a HEAD that is not on
# origin/main, or an existing v<version> tag that points elsewhere.
set -eu
cd "$(dirname "$0")/.."

identity="${SAI_CODESIGN_IDENTITY:?set SAI_CODESIGN_IDENTITY to the signing identity name}"
version=$(sed -n 's/^version: //p' packages/sai_core/pubspec.yaml)
[ -n "$version" ] || { echo "release: no version in packages/sai_core/pubspec.yaml" >&2; exit 1; }
short=${version%%-*}
number=$(git rev-list --count HEAD)
commit=$(git rev-parse --short HEAD)
dist="dist/sai-v$version"

build() {
  if [ -n "$(git status --porcelain)" ] && [ "${SAI_RELEASE_DIRTY:-}" != 1 ]; then
    echo "release: the worktree is dirty; commit first or set SAI_RELEASE_DIRTY=1" >&2
    exit 1
  fi
  echo "release: sai v$version (plist $short build $number) at $commit"
  rm -rf "$dist"
  mkdir -p "$dist/stage"
  dart pub get

  (cd apps/sai_app && flutter build macos --release --build-name "$short" --build-number "$number")
  app="$dist/stage/sai.app"
  ditto apps/sai_app/build/macos/Build/Products/Release/sai.app "$app"
  for fw in "$app"/Contents/Frameworks/*.framework; do
    codesign --force --sign "$identity" --timestamp=none "$fw"
  done
  codesign --force --sign "$identity" --timestamp=none \
    --entitlements apps/sai_app/macos/Runner/Release.entitlements "$app"
  codesign --verify --deep --strict --verbose=2 "$app"
  codesign --display --verbose=2 "$app" 2>&1 | grep -E '^(Identifier|Authority|TeamIdentifier)' || true
  archs=$(lipo -archs "$app/Contents/MacOS/sai")
  case "$archs" in
    *x86_64*arm64*|*arm64*x86_64*) app_arch=universal ;;
    *) app_arch=$archs ;;
  esac
  (cd "$dist/stage" && ditto -c -k --keepParent sai.app "../sai-v$version-macos-$app_arch.zip")

  SAI_CODESIGN_IDENTITY="$identity" tool/sign-tui.sh "$dist/tui"
  tar -C "$dist/tui" -czf "$dist/sai_tui-v$version-macos-$(uname -m).tar.gz" bundle

  (cd "$dist" && shasum -a 256 *.zip *.tar.gz > checksums.txt)
  git rev-parse HEAD > "$dist/commit"
  {
    echo "Pre-release build of sai v$version (commit $commit)."
    echo
    echo "Install, upgrade, rollback and where the data lives: docs/release/README.md."
    echo "The app is signed but not notarised; the first launch on another Mac"
    echo "needs System Settings › Privacy & Security › Open Anyway."
    echo
    echo '```'
    cat "$dist/checksums.txt"
    echo '```'
  } > "$dist/notes.md"
  echo "release: staged in $dist"
  ls -l "$dist"
  cat "$dist/checksums.txt"
}

publish() {
  [ -f "$dist/checksums.txt" ] || { echo "release: nothing built in $dist; run the build first" >&2; exit 1; }
  head=$(git rev-parse HEAD)
  built=$(cat "$dist/commit" 2>/dev/null || true)
  if [ "$built" != "$head" ]; then
    echo "release: $dist was built from ${built:-an unknown commit}, not $head; run the build again" >&2
    exit 1
  fi
  git fetch -q origin main
  if ! git merge-base --is-ancestor "$head" origin/main; then
    echo "release: HEAD is not on origin/main; merge first" >&2
    exit 1
  fi
  tag=$(git ls-remote --tags origin "refs/tags/v$version" "refs/tags/v$version^{}" | tail -n 1 | cut -f1)
  if [ -n "$tag" ] && [ "$tag" != "$head" ]; then
    echo "release: tag v$version already exists on origin at $tag, not at $head; delete or move it first" >&2
    exit 1
  fi
  gh release create "v$version" --prerelease --title "sai v$version" \
    --target "$head" --notes-file "$dist/notes.md" \
    "$dist"/*.zip "$dist"/*.tar.gz "$dist/checksums.txt"
}

case "${1:-build}" in
  build) build ;;
  publish) publish ;;
  *) echo "usage: tool/release.sh [build|publish]" >&2; exit 2 ;;
esac
