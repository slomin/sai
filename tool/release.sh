#!/bin/sh
# Builds the release: a signed sai.app and the signed terminal-client
# bundle, version-stamped, zipped and checksummed under dist/, from one
# command; then publishes them as a GitHub pre-release — or installs
# them on this Mac as the dogfood copy (#87).
#
#   SAI_CODESIGN_IDENTITY="…" tool/release.sh                # build stable
#   SAI_CODESIGN_IDENTITY="…" tool/release.sh build dev      # build the dev flavor
#   SAI_CODESIGN_IDENTITY="…" tool/release.sh publish        # tag + release (stable only)
#   SAI_CODESIGN_IDENTITY="…" tool/release.sh local-install  # build + install stable here
#   SAI_CODESIGN_IDENTITY="…" tool/release.sh local-install dev  # build + install dev here
#   SAI_CODESIGN_IDENTITY="…" tool/release.sh local-install [dev] --dry-run  # say what would happen
#   tool/release.sh install <dir>                            # reinstall a kept version
#
# Two flavors and no third (ADR 0019): stable is the daily-use copy,
# dev the isolated one — sai-dev.app, sai_tui-dev, ~/.local/share/sai-dev,
# its own data and Keychain service. The flavor is a closed word here,
# never a destination: it picks the Xcode scheme, the entry point and
# the artefact names (sai-dev-v…, sai_tui-dev-v…), and is sealed into
# the staged dist/ (a `flavor` file, `SaiFlavor` in the app's plist,
# `bundle/flavor` in the client's) for tool/install-local.sh to check.
# `publish` takes no flavor and refuses a dist/ that is not stable.
#
# The version is the one in packages/sai_core/pubspec.yaml (tests keep
# saiVersion and the other pubspecs equal to it); the app's Info.plist
# takes the numeric part and the commit count as its build number, since
# CFBundleShortVersionString must be numeric, and a SaiCommit key with
# the full commit. The app is signed after `flutter build` — frameworks
# first, then the bundle — so the Xcode project keeps no identity (ADR
# 0017); the terminal client goes through tool/sign-tui.sh and carries
# its commit in bundle/commit. One Apple Development identity signs
# both, so the Keychain items trust each release the way they trusted
# the last one (ADR 0008); the identity may be given by name or SHA-1
# fingerprint and is never printed. Nothing is notarised: the first
# launch on another Mac is the Gatekeeper step in docs/release/README.md.
# A dirty worktree is refused unless SAI_RELEASE_DIRTY=1, so a release is
# what its commit says it is; the build records its commit under dist/,
# and `publish` refuses a dist built from another commit, a HEAD that is
# not on origin/main, or an existing v<version> tag that points
# elsewhere. `local-install` builds and hands dist/ to
# tool/install-local.sh, which validates in staging and installs under
# ~/Applications, ~/.local/share/sai and ~/.local/bin; `install <dir>`
# reinstalls a kept version (rollback) through the same path.
set -eu
cd "$(dirname "$0")/.."

version=$(sed -n 's/^version: //p' packages/sai_core/pubspec.yaml)
[ -n "$version" ] || { echo "release: no version in packages/sai_core/pubspec.yaml" >&2; exit 1; }
short=${version%%-*}
number=$(git rev-list --count HEAD)
commit=$(git rev-parse --short HEAD)
head=$(git rev-parse HEAD)

# flavor <stable|dev>: the closed mapping every path below derives from.
flavor() {
  flavor=$1
  case "$flavor" in
    stable) slug=sai; tui=sai_tui; label=sai ;;
    dev) slug=sai-dev; tui=sai_tui-dev; label="sai dev" ;;
    *) echo "release: unknown flavor '$flavor' (stable or dev)" >&2; exit 2 ;;
  esac
  dist="dist/$slug-v$version"
}

identity() {
  identity="${SAI_CODESIGN_IDENTITY:?set SAI_CODESIGN_IDENTITY to the signing identity name or fingerprint}"
}

clean_tree() {
  if [ -n "$(git status --porcelain)" ] && [ "${SAI_RELEASE_DIRTY:-}" != 1 ]; then
    echo "release: the worktree is dirty; commit first or set SAI_RELEASE_DIRTY=1" >&2
    exit 1
  fi
}

build() {
  identity
  dart pub get >/dev/null
  clean_tree
  echo "release: $label v$version (plist $short build $number) at $commit"
  rm -rf "$dist"
  mkdir -p "$dist/stage"

  (cd apps/sai_app && flutter build macos --release --flavor "$flavor" --build-name "$short" --build-number "$number")
  app="$dist/stage/$slug.app"
  ditto "apps/sai_app/build/macos/Build/Products/Release-$flavor/$slug.app" "$app"
  built_flavor=$(/usr/libexec/PlistBuddy -c 'Print :SaiFlavor' "$app/Contents/Info.plist" 2>/dev/null || true)
  [ "$built_flavor" = "$flavor" ] || { echo "release: the built app says flavor '${built_flavor:-none}', not $flavor" >&2; exit 1; }
  /usr/libexec/PlistBuddy -c "Add :SaiCommit string $head" "$app/Contents/Info.plist"
  for fw in "$app"/Contents/Frameworks/*.framework; do
    codesign --force --sign "$identity" --timestamp=none "$fw"
  done
  codesign --force --sign "$identity" --timestamp=none \
    --entitlements apps/sai_app/macos/Runner/Release.entitlements "$app"
  codesign --verify --deep --strict --verbose=2 "$app"
  codesign --display --verbose=2 "$app" 2>&1 | grep -E '^Identifier' || true
  archs=$(lipo -archs "$app/Contents/MacOS/$slug")
  case "$archs" in
    *x86_64*arm64*|*arm64*x86_64*) app_arch=universal ;;
    *) app_arch=$archs ;;
  esac
  (cd "$dist/stage" && ditto -c -k --keepParent "$slug.app" "../$slug-v$version-macos-$app_arch.zip")

  SAI_CODESIGN_IDENTITY="$identity" tool/sign-tui.sh "$dist/tui" "$flavor"
  echo "$head" > "$dist/tui/bundle/commit"
  echo "$flavor" > "$dist/tui/bundle/flavor"
  tar -C "$dist/tui" -czf "$dist/$tui-v$version-macos-$(uname -m).tar.gz" bundle

  (cd "$dist" && shasum -a 256 *.zip *.tar.gz > checksums.txt)
  echo "$head" > "$dist/commit"
  echo "$flavor" > "$dist/flavor"
  {
    echo "Pre-release build of $label v$version (commit $commit)."
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

built_here() {
  [ -f "$dist/checksums.txt" ] || { echo "release: nothing built in $dist; run the build first" >&2; exit 1; }
  staged=$(cat "$dist/flavor" 2>/dev/null || echo stable)
  if [ "$staged" != "$flavor" ]; then
    echo "release: $dist is a $staged build, not $flavor" >&2
    exit 1
  fi
  built=$(cat "$dist/commit" 2>/dev/null || true)
  if [ "$built" != "$head" ]; then
    echo "release: $dist was built from ${built:-an unknown commit}, not $head; run the build again" >&2
    exit 1
  fi
}

publish() {
  # Publishing is stable-only: a dev artefact never reaches a release.
  flavor stable
  built_here
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

local_install() {
  case "${1:-}" in
    stable|dev) flavor "$1"; shift ;;
    *) flavor stable ;;
  esac
  case "${1:-}" in
    --dry-run)
      identity
      clean_tree
      echo "release: would build $label v$version (plist $short build $number) at $commit, then install it"
      built=$(cat "$dist/commit" 2>/dev/null || true)
      if [ -f "$dist/checksums.txt" ] && [ "$built" = "$head" ]; then
        tool/install-local.sh "$dist" --dry-run
      else
        if [ -n "$built" ]; then
          echo "release: $dist is stale (built from $built); the install would use the fresh build"
        else
          echo "release: nothing built in $dist yet; the install would use the fresh build"
        fi
      fi
      ;;
    '')
      build
      built_here
      tool/install-local.sh "$dist"
      ;;
    *) echo "usage: tool/release.sh local-install [stable|dev] [--dry-run]" >&2; exit 2 ;;
  esac
}

case "${1:-build}" in
  build) flavor "${2:-stable}"; build ;;
  publish) [ $# -eq 1 ] || { echo "usage: tool/release.sh publish (stable only)" >&2; exit 2; }; publish ;;
  local-install) shift; local_install "$@" ;;
  install)
    [ $# -eq 2 ] || { echo "usage: tool/release.sh install <dir>" >&2; exit 2; }
    echo "release: reinstalling $2 as kept (its commit need not be HEAD)"
    tool/install-local.sh "$2"
    ;;
  *) echo "usage: tool/release.sh [build [stable|dev]|publish|local-install [stable|dev] [--dry-run]|install <dir>]" >&2; exit 2 ;;
esac
