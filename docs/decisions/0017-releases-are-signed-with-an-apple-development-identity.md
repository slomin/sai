# 17. Releases are signed with an Apple Development identity and installed by hand

Date: 2026-08-27 · Status: accepted · Issue: #42 · Builds on: [0001](0001-macos-app-runs-without-the-app-sandbox.md), [0008](0008-secrets-live-in-the-file-keychain.md)

## Context

sai has one user, who installs it on Macs he owns. #42 asks for a
signed app that launches on a clean account, the terminal client, both
from one script, with the version stamped and a pre-release on GitHub.
ADR 0008 tied the Keychain items to one stable signing identity and
pencilled in Developer ID for releases.

Developer ID means the paid developer program, a notarisation
round-trip per build and the hardened runtime; what it buys is a first
launch without a visit to System Settings. An ad-hoc signature costs
nothing and changes every build, so every upgrade re-prompts for the
provider keys. A self-signed certificate is stable on the machine that
made it and unknown to any other.

## Decision

- **Releases are signed with the Apple Development identity** already in
  the developer's login Keychain (`SAI_CODESIGN_IDENTITY`, never in the
  tree). It chains to Apple, so the Keychain's designated-requirement
  check passes on another Mac too; it is renewed yearly with the same
  subject and team, so the requirement — and the items — survive a
  renewal. Nothing is notarised, and the Xcode project keeps its ad-hoc
  default: `tool/release.sh` signs after `flutter build`, frameworks
  first, then the bundle, with the release entitlements; the terminal
  client goes through `tool/sign-tui.sh`.
- **The developer's copy is installed from the tree** (#87, 2026-08-29):
  `tool/release.sh local-install` runs the same build and hands `dist/`
  to `tool/install-local.sh`, which verifies checksums, signatures, the
  commit both artefacts carry (`SaiCommit` in `Info.plist`,
  `bundle/commit`) and the reported version in staging, then swaps the
  app and the bundle in under `~/Applications`, `~/.local/share/sai` and
  `~/.local/bin` by rename. The artefacts it installed are kept under
  `references/releases/` (gitignored) and reinstalled by
  `tool/release.sh install <dir>` — the rollback goes through the same
  checks, and only one `sai.app` ever exists, so LaunchServices never
  sees two. The identity may be given by name or SHA-1 fingerprint; the
  scripts never print it and the install records version, commit, time
  and kept directory only.
- **Gatekeeper is a documented step, not a build step.** A downloaded
  copy is opened once through System Settings › Privacy & Security ›
  Open Anyway, or its `com.apple.quarantine` attribute is cleared;
  `docs/release/README.md` says so and the release notes point there.
- **The version has one source.** `packages/sai_core/pubspec.yaml`
  (tests keep `saiVersion` and the other pubspecs equal); the app's
  `Info.plist` gets its numeric part and the commit count as the build
  number, because `CFBundleShortVersionString` cannot carry
  `-dev.1`. `sai_tui version` prints the full string.
- **Artefacts** are a `ditto -c -k` zip of the app (the one archive
  format that keeps a bundle's signature whole), a tarball of the
  terminal client's `bundle` directory, and `checksums.txt`; the script
  stages them under `dist/` (gitignored) and `publish` attaches them to
  a pre-release tagged `v<version>` on a commit that is on `main`.
- **No release job in CI.** The identity lives on one machine; the
  script runs there. CI keeps proving that the tree builds.

## Consequences

- `spctl -a -t exec sai.app` reports *rejected* on every release; that
  is the missing notarisation, and `codesign --verify --deep --strict`
  is the check that matters.
- App Store distribution stays off the table (ADR 0001); notarisation
  and Developer ID come back only if someone other than the developer is
  meant to install sai.
- A release built on a Mac with an expired or missing identity fails in
  `codesign`, before anything is staged.
- A local install that fails any check leaves the previous copy in
  place; a running sai stops it before staging.
- The v0.1.0 tag and release belong to the retired Go prototype (ADR
  0002); the Dart line starts at v0.0.1-dev.1 and counts up from there.
