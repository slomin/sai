# 17. Releases are signed with an Apple Development identity and installed by hand

Date: 2026-08-27 · Amended: 2026-08-30 (#95) · Status: accepted · Issue: #42 · Builds on: [0001](0001-macos-app-runs-without-the-app-sandbox.md), [0008](0008-secrets-live-in-the-file-keychain.md)

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

- **Releases are signed with the Apple Development identity**, kept
  (since #95) in a dedicated keychain at
  `~/Library/Keychains/sai-signing.keychain-db`, locked and outside the
  search list, so macOS asks before the key is used. It chains to
  Apple, so the Keychain's designated-requirement check passes on
  another Mac too; it is renewed yearly with the same subject and team,
  so the requirement — and the items — survive a renewal. Nothing is
  notarised, and the Xcode project keeps its ad-hoc default.
- **Building and signing are two phases** (#95). `tool/release.sh
  prepare stable` runs every toolchain — `pub`, Flutter, the client's
  `dart build cli` and its build hook — with no identity in reach,
  ad-hoc signs and seals `dist/<name>/prepared/` with a manifest.
  `tool/release.sh sign` takes only a sealed, unmodified, current,
  stable, still-ad-hoc tree, discovers the one identity with `security
  find-identity -v -p codesigning <keychain>` (its output never
  printed), and signs from the inside out — frameworks and helpers,
  the app with its entitlements, every client dylib, the client —
  verifying `--deep --strict` on the app and `--strict` on each client
  Mach-O, never signing with `--deep`; it packages, seals as `stable`
  and replaces `release/` atomically, leaving `prepared/` and any
  previous `release/` intact on refusal or a cancelled dialog. Nothing
  but `codesign` and the packaging tools runs after the keychain is
  asked. No identity name, fingerprint, keychain password or unlock
  reaches a script through the environment, an argument, a file or a
  log; the environment variable that once named it is retired.
  `install` and `publish`
  accept a stable release only with that seal and the full
  verification graph (`tool/verify-release.sh`).
- **Dev builds carry no stable authority.** `tool/release.sh
  local-install dev` signs with the self-signed `sai dev` identity when
  this Mac has one (codesign resolves the name; no keychain is asked),
  ad-hoc otherwise, and the installer accepts a rotated dev signature;
  the dev flavor holds no credentials (ADR 0008, 0019).
- **The developer's copy is installed from the tree** (#87, 2026-08-29):
  `tool/release.sh local-install` runs the same build and hands `dist/`
  to `tool/install-local.sh`, which verifies checksums, signatures, the
  commit both artefacts carry (`SaiCommit` in `Info.plist`,
  `bundle/commit`) and the reported version in staging, then swaps the
  app and the bundle in under `~/Applications`, `~/.local/share/sai` and
  `~/.local/bin` by rename. The artefacts it installed are kept under
  `references/releases/` (gitignored) and reinstalled by
  `tool/release.sh install <dir>` — the rollback goes through the same
  checks, and only one app per flavor ever exists — one `sai.app` until
  ADR 0019 added `sai-dev.app` beside it — so LaunchServices never sees
  two of a kind. The scripts never print the identity and the install
  records flavor, version, commit, time and kept directory only.
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
  script runs there. CI keeps proving that the tree builds, and runs
  the sign phase against a fake `security`/`codesign`
  (`tool/test/release_sign_test.sh`).

## Consequences

- `spctl -a -t exec sai.app` reports *rejected* on every release; that
  is the missing notarisation, and `codesign --verify --deep --strict`
  is the check that matters.
- App Store distribution stays off the table (ADR 0001); notarisation
  and Developer ID come back only if someone other than the developer is
  meant to install sai.
- A release built on a Mac with an expired or missing identity fails in
  `sign`, before anything is staged; a lost signing keychain means a new
  identity and one install with `SAI_INSTALL_ALLOW_RESIGN=1`, after
  which the provider keys are entered again.
- A local install that fails any check leaves the previous copy in
  place; a running sai stops it before staging.
- The v0.1.0 tag and release belong to the retired Go prototype (ADR
  0002); the Dart line starts at v0.0.1-dev.1 and counts up from there.
