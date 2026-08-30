#!/bin/sh
# Builds the release in two phases (#95): `prepare` does everything that
# runs a toolchain — dependency resolution, Flutter and the terminal
# client's build hooks, version stamping, notes, a manifest — and seals
# the result under dist/ unsigned (ad-hoc); `sign` takes only a sealed
# stable prepared directory, asks the dedicated signing keychain for its
# one identity, and signs from the inside out with nothing else running.
# A dev release never sees the stable identity: it is signed in `prepare`
# with the low-authority self-signed `sai dev` identity when this Mac has
# one, ad-hoc otherwise, and installs as the isolated copy.
#
#   tool/release.sh prepare stable        # build + seal, unsigned
#   tool/release.sh sign                  # sign the prepared stable release (prompts)
#   tool/release.sh local-install stable  # install the signed release here
#   tool/release.sh publish               # tag + GitHub pre-release (stable only)
#   tool/release.sh local-install dev     # prepare + install the dev copy
#   tool/release.sh local-install [dev] --dry-run
#   tool/release.sh install <dir>         # reinstall a kept version
#
# Layout under dist/<slug>-v<version>/: `prepared/` (the app, the client's
# bundle, flavor, commit, version, manifest.txt and its seal) and
# `release/` (the zip, the tarball, checksums.txt, commit, flavor, notes
# and a seal naming who signed). `sign` replaces `release/` atomically and
# leaves `prepared/` as it found it; a refusal or a cancelled
# authorization leaves the previous `release/` intact.
#
# The stable identity is never named: no environment variable, argument,
# file or log carries it. `sign` runs exactly one `security` command —
# `find-identity -v -p codesigning` against the dedicated keychain at
# ~/Library/Keychains/sai-signing.keychain-db — keeps its output in a
# variable, and uses the single hash it lists. Keeping that keychain
# locked and out of the search list is what makes macOS ask before the
# key is used (docs/release/README.md). The scripts never unlock a
# keychain, change a search list, an ACL or a partition list.
#
# Two flavors and no third (ADR 0019): stable is the daily-use copy, dev
# the isolated one — sai-dev.app, sai_tui-dev, ~/.local/share/sai-dev,
# its own data and no credentials. The flavor is a closed word here,
# never a destination. The version is the one in packages/sai_core/
# pubspec.yaml; the app's Info.plist takes the numeric part and the
# commit count as its build number and a SaiCommit key with the full
# commit. Nothing is notarised: the first launch on another Mac is the
# Gatekeeper step in docs/release/README.md. A dirty worktree is refused
# unless SAI_RELEASE_DIRTY=1. `publish` refuses a release built from
# another commit, a HEAD that is not on origin/main, or an existing
# v<version> tag that points elsewhere. Installs go through
# tool/install-local.sh, which verifies in staging (tool/verify-release.sh)
# and swaps atomically.
set -eu
cd "$(dirname "$0")/.."

version=$(sed -n 's/^version: //p' packages/sai_core/pubspec.yaml)
[ -n "$version" ] || { echo "release: no version in packages/sai_core/pubspec.yaml" >&2; exit 1; }
short=${version%%-*}
number=$(git rev-list --count HEAD)
commit=$(git rev-parse --short HEAD)
head=$(git rev-parse HEAD)
signing_keychain="$HOME/Library/Keychains/sai-signing.keychain-db"

fail() { echo "release: $*" >&2; exit 1; }

# flavor <stable|dev>: the closed mapping every path below derives from.
flavor() {
  flavor=$1
  case "$flavor" in
    stable) slug=sai; tui=sai_tui; label=sai ;;
    dev) slug=sai-dev; tui=sai_tui-dev; label="sai dev" ;;
    *) echo "release: unknown flavor '$flavor' (stable or dev)" >&2; exit 2 ;;
  esac
  # SAI_RELEASE_DIST names another parent than dist/ (the tests do).
  dist="${SAI_RELEASE_DIST:-dist}/$slug-v$version"
  prepared="$dist/prepared"
  release="$dist/release"
}

clean_tree() {
  if [ -n "$(git status --porcelain)" ] && [ "${SAI_RELEASE_DIRTY:-}" != 1 ]; then
    fail "the worktree is dirty; commit first or set SAI_RELEASE_DIRTY=1"
  fi
}

# --- the seal of a prepared directory -----------------------------------
# manifest <dir>: one line per file, sorted, so two trees compare by text.
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

# check_prepared: the sealed stable tree `sign` may take, and nothing else.
check_prepared() {
  [ -d "$prepared" ] || fail "nothing prepared in $prepared; run tool/release.sh prepare $flavor first"
  [ -f "$prepared/seal" ] && [ -f "$prepared/manifest.txt" ] || fail "$prepared carries no seal; prepare it again"
  [ "$(sed -n 's/^flavor //p' "$prepared/seal")" = "$flavor" ] \
    || fail "$prepared is a $(sed -n 's/^flavor //p' "$prepared/seal") release, not $flavor"
  [ "$(sed -n 's/^manifest //p' "$prepared/seal")" = "$(shasum -a 256 "$prepared/manifest.txt" | cut -d' ' -f1)" ] \
    || fail "the seal in $prepared does not match its manifest; prepare it again"
  if [ "$(manifest "$prepared")" != "$(cat "$prepared/manifest.txt")" ]; then
    fail "$prepared changed after it was sealed; prepare it again"
  fi
  built=$(cat "$prepared/commit" 2>/dev/null || true)
  [ "$built" = "$head" ] || fail "$prepared was built from ${built:-an unknown commit}, not $head; prepare it again"
}

# adhoc <path>: whether a Mach-O or bundle carries only an ad-hoc signature.
adhoc() {
  codesign -dv "$1" 2>&1 | grep -q '^Signature=adhoc'
}

# --- dev signing: a low-authority identity, or none ----------------------
# The self-signed `sai dev` certificate (README) keeps the dev copy's
# code-directory hash stable across builds so macOS stops re-asking its
# permissions; codesign resolves the name itself, no keychain is asked.
dev_identity() {
  probe=$(mktemp "${TMPDIR:-/tmp}/sai-dev-sign.XXXXXX")
  printf '#!/bin/sh\n' > "$probe"
  if codesign --force --sign "sai dev" "$probe" >/dev/null 2>&1; then
    dev_identity="sai dev"
  else
    dev_identity="-"
  fi
  rm -f "$probe"
}

sign_tree() {
  # sign_tree <identity> <app> <bundle> [codesign options…]: inside out.
  who=$1 app=$2 bundle=$3
  shift 3
  for fw in "$app"/Contents/Frameworks/*.framework; do
    [ -e "$fw" ] || continue
    codesign --force --sign "$who" --timestamp=none "$@" "$fw"
  done
  for helper in "$app"/Contents/Helpers/* "$app"/Contents/MacOS/*; do
    [ -f "$helper" ] || continue
    [ "$helper" = "$app/Contents/MacOS/$slug" ] && continue
    codesign --force --sign "$who" --timestamp=none "$@" "$helper"
  done
  codesign --force --sign "$who" --timestamp=none "$@" \
    --entitlements apps/sai_app/macos/Runner/Release.entitlements "$app"
  for lib in "$bundle"/lib/*.dylib; do
    [ -e "$lib" ] || continue
    codesign --force --sign "$who" --timestamp=none "$@" "$lib"
  done
  codesign --force --sign "$who" --timestamp=none "$@" "$bundle/bin/$tui"
  codesign --verify --deep --strict "$app"
  codesign --verify --strict "$bundle/bin/$tui"
  for lib in "$bundle"/lib/*.dylib; do
    [ -e "$lib" ] || continue
    codesign --verify --strict "$lib"
  done
}

# --- packaging a signed (or dev) tree into a release directory ------------
# package_release <tree> <out> <signer>
package_release() {
  tree=$(cd "$1" && pwd) signer=$3
  rm -rf "$2"
  mkdir -p "$2"
  out=$(cd "$2" && pwd)
  archs=$(lipo -archs "$tree/$slug.app/Contents/MacOS/$slug")
  case "$archs" in
    *x86_64*arm64*|*arm64*x86_64*) app_arch=universal ;;
    *) app_arch=$archs ;;
  esac
  (cd "$tree" && ditto -c -k --keepParent "$slug.app" "$out/$slug-v$version-macos-$app_arch.zip")
  tar -C "$tree/tui" -czf "$out/$tui-v$version-macos-$(uname -m).tar.gz" bundle
  (cd "$out" && shasum -a 256 *.zip *.tar.gz > checksums.txt)
  cp "$tree/commit" "$tree/flavor" "$out/"
  {
    echo "signer $signer"
    echo "checksums $(shasum -a 256 "$out/checksums.txt" | cut -d' ' -f1)"
    echo "flavor $flavor"
    echo "commit $(cat "$tree/commit")"
    echo "version $version"
  } > "$out/seal"
  {
    echo "Pre-release build of $label v$version (commit $commit)."
    echo
    echo "Install, upgrade, rollback and where the data lives: docs/release/README.md."
    echo "The app is signed but not notarised; the first launch on another Mac"
    echo "needs System Settings › Privacy & Security › Open Anyway."
    echo
    echo '```'
    cat "$out/checksums.txt"
    echo '```'
  } > "$out/notes.md"
}

# --- prepare: every toolchain runs here, no identity is in reach ---------
prepare() {
  dart pub get >/dev/null
  clean_tree
  echo "release: preparing $label v$version (plist $short build $number) at $commit"
  mkdir -p "$dist"
  work="$dist/.prepared.$$"
  rm -rf "$work"
  mkdir -p "$work"
  trap 'rm -rf "$work"' EXIT

  (cd apps/sai_app && flutter build macos --release --flavor "$flavor" --build-name "$short" --build-number "$number")
  app="$work/$slug.app"
  ditto "apps/sai_app/build/macos/Build/Products/Release-$flavor/$slug.app" "$app"
  built_flavor=$(/usr/libexec/PlistBuddy -c 'Print :SaiFlavor' "$app/Contents/Info.plist" 2>/dev/null || true)
  [ "$built_flavor" = "$flavor" ] || fail "the built app says flavor '${built_flavor:-none}', not $flavor"
  /usr/libexec/PlistBuddy -c "Add :SaiCommit string $head" "$app/Contents/Info.plist"

  tool/build-tui.sh "$work/tui" "$flavor"
  echo "$head" > "$work/tui/bundle/commit"
  echo "$flavor" > "$work/tui/bundle/flavor"
  echo "$head" > "$work/commit"
  echo "$flavor" > "$work/flavor"
  echo "$version" > "$work/version"

  case "$flavor" in
    dev)
      dev_identity
      sign_tree "$dev_identity" "$app" "$work/tui/bundle"
      if [ "$dev_identity" = "-" ]; then
        echo "release: no 'sai dev' identity on this Mac; the dev copy is ad-hoc signed (README)"
      else
        echo "release: the dev copy is signed with the 'sai dev' identity"
      fi
      ;;
    stable)
      # Ad-hoc, so the tree verifies as it stands; `sign` replaces this.
      sign_tree - "$app" "$work/tui/bundle"
      ;;
  esac
  seal_prepared "$work"
  rm -rf "$prepared"
  mv "$work" "$prepared"
  trap - EXIT
  echo "release: prepared $prepared"
  if [ "$flavor" = dev ]; then
    package_release "$prepared" "$dist/.release.$$" dev
    rm -rf "$release"
    mv "$dist/.release.$$" "$release"
    echo "release: staged $release"
    cat "$release/checksums.txt"
  else
    echo "release: unsigned; run tool/release.sh sign to sign it from the dedicated keychain"
  fi
}

# --- the stable identity: one query, one keychain, never printed ---------
stable_identity() {
  [ -f "$signing_keychain" ] || fail "no dedicated signing keychain at $signing_keychain (docs/release/README.md sets it up)"
  found=$(security find-identity -v -p codesigning "$signing_keychain" 2>/dev/null) \
    || fail "the signing keychain at $signing_keychain could not be read"
  count=$(printf '%s\n' "$found" | sed -n 's/^ *\([0-9][0-9]*\) valid identit[a-z]* found$/\1/p')
  case "${count:-0}" in
    1) ;;
    0) fail "the signing keychain holds no usable code-signing identity" ;;
    *) fail "the signing keychain holds $count code-signing identities; it must hold exactly one" ;;
  esac
  stable_identity=$(printf '%s\n' "$found" | sed -n 's/^ *1) \([0-9A-Fa-f]\{40\}\) .*$/\1/p')
  [ -n "$stable_identity" ] || fail "the signing keychain's identity could not be read"
  unset found
}

# --- sign: from the sealed stable tree, inside out, nothing else running --
sign() {
  flavor stable
  check_prepared
  if ! adhoc "$prepared/$slug.app" || ! adhoc "$prepared/tui/bundle/bin/$tui"; then
    fail "$prepared is already signed; prepare it again before signing"
  fi
  staging="$dist/.signing.$$"
  rm -rf "$staging"
  trap 'rm -rf "$staging"' EXIT
  ditto "$prepared" "$staging"
  rm -f "$staging/manifest.txt" "$staging/seal"
  stable_identity
  echo "release: signing $label v$version at $commit from the dedicated keychain (macOS asks now)"
  sign_tree "$stable_identity" "$staging/$slug.app" "$staging/tui/bundle" --keychain "$signing_keychain"
  unset stable_identity
  package_release "$staging" "$staging/release" stable
  if [ -e "$release" ]; then mv "$release" "$dist/.release.old.$$"; fi
  mv "$staging/release" "$release"
  rm -rf "$dist/.release.old.$$" "$staging"
  trap - EXIT
  echo "release: signed and staged $release"
  cat "$release/checksums.txt"
}

# signed_release: the release `local-install stable` and `publish` accept.
signed_release() {
  [ -f "$release/seal" ] || fail "nothing signed in $release; run tool/release.sh prepare stable, then sign"
  [ "$(sed -n 's/^signer //p' "$release/seal")" = stable ] || fail "$release is not sealed by the signing phase; run tool/release.sh sign"
  built=$(cat "$release/commit" 2>/dev/null || true)
  [ "$built" = "$head" ] || fail "$release was built from ${built:-an unknown commit}, not $head; prepare and sign again"
}

verify_release() {
  scratch=$(mktemp -d "${TMPDIR:-/tmp}/sai-release.XXXXXX")
  trap 'rm -rf "$scratch"' EXIT
  ditto -x -k "$release"/"$slug"-v*-macos-*.zip "$scratch"
  tar -C "$scratch" -xzf "$release"/"$tui"-v*-macos-*.tar.gz
  tool/verify-release.sh "$release" "$scratch/$slug.app" "$scratch/bundle"
  rm -rf "$scratch"
  trap - EXIT
}

publish() {
  # Publishing is stable-only: a dev artefact never reaches a release.
  flavor stable
  signed_release
  verify_release
  git fetch -q origin main
  if ! git merge-base --is-ancestor "$head" origin/main; then
    fail "HEAD is not on origin/main; merge first"
  fi
  tag=$(git ls-remote --tags origin "refs/tags/v$version" "refs/tags/v$version^{}" | tail -n 1 | cut -f1)
  if [ -n "$tag" ] && [ "$tag" != "$head" ]; then
    fail "tag v$version already exists on origin at $tag, not at $head; delete or move it first"
  fi
  gh release create "v$version" --prerelease --title "sai v$version" \
    --target "$head" --notes-file "$release/notes.md" \
    "$release"/*.zip "$release"/*.tar.gz "$release/checksums.txt"
}

local_install() {
  case "${1:-}" in
    stable|dev) flavor "$1"; shift ;;
    *) flavor stable ;;
  esac
  case "${1:-}" in
    --dry-run)
      clean_tree
      case "$flavor" in
        dev)
          echo "release: would prepare $label v$version (plist $short build $number) at $commit, then install it"
          built=$(cat "$release/commit" 2>/dev/null || true)
          if [ -f "$release/seal" ] && [ "$built" = "$head" ]; then
            tool/install-local.sh "$release" --dry-run
          elif [ -n "$built" ]; then
            echo "release: $release is stale (built from $built); the install would use the fresh build"
          else
            echo "release: nothing prepared in $dist yet; the install would use the fresh build"
          fi
          ;;
        stable)
          signed_release
          tool/install-local.sh "$release" --dry-run
          ;;
      esac
      ;;
    '')
      case "$flavor" in
        dev) prepare ;;
        stable) signed_release ;;
      esac
      tool/install-local.sh "$release"
      ;;
    *) echo "usage: tool/release.sh local-install [stable|dev] [--dry-run]" >&2; exit 2 ;;
  esac
}

case "${1:-}" in
  prepare) [ $# -eq 2 ] || { echo "usage: tool/release.sh prepare stable|dev" >&2; exit 2; }; flavor "$2"; prepare ;;
  sign) [ $# -eq 1 ] || { echo "usage: tool/release.sh sign (the prepared stable release)" >&2; exit 2; }; sign ;;
  publish) [ $# -eq 1 ] || { echo "usage: tool/release.sh publish (stable only)" >&2; exit 2; }; publish ;;
  local-install) shift; local_install "$@" ;;
  install)
    [ $# -eq 2 ] || { echo "usage: tool/release.sh install <dir>" >&2; exit 2; }
    echo "release: reinstalling $2 as kept (its commit need not be HEAD)"
    tool/install-local.sh "$2"
    ;;
  *) echo "usage: tool/release.sh prepare stable|dev | sign | publish | local-install [stable|dev] [--dry-run] | install <dir>" >&2; exit 2 ;;
esac
