# 19. Stable and dev are two installed identities

Date: 2026-08-29 · Amended: 2026-08-29 (#91) · Amended: 2026-08-30 (#95) · Status: accepted · Issue: #90 · Builds on: [0006](0006-settings-live-in-a-file-beside-the-archive.md), [0008](0008-secrets-live-in-the-file-keychain.md), [0015](0015-the-workspace-is-restored-from-settings.md), [0017](0017-releases-are-signed-with-an-apple-development-identity.md)

## Context

The dogfood install (#87) gave one `sai.app`, one `sai_tui`, one data
directory and one Keychain service. Working on sai on the same Mac
then meant quitting the daily copy, or running a debug build against
scratch directories — and even then the window frame (keyed by bundle
id) and the Keychain service were shared, as ADR 0015 noted. #90 asks
for a development copy that is built, installed, launched, tested and
replaced on its own, while the daily copy stays what it is.

## Decision

- **Two flavors and no third.** `stable` is the daily-use copy; `dev`
  is the isolated development and QA copy. Deterministic automation
  keeps using scratch profiles (`SAI_ARCHIVE_ROOT`, `SAI_SETTINGS_FILE`)
  and the fake provider, whichever flavor runs.
- **One identity, every location derived from it.** `SaiIdentity` in
  `sai_core` is the closed mapping; nothing else spells a location:

  | | stable | dev |
  |---|---|---|
  | display name | `sai` | `sai dev` |
  | app bundle / executable | `sai.app` / `sai` | `sai-dev.app` / `sai-dev` |
  | bundle id | `me.slominski.sai` | `me.slominski.sai.dev` |
  | data directory | `Application Support/sai` | `Application Support/sai-dev` |
  | Keychain service | `me.slominski.sai` | none — dev holds no credentials (#95) |
  | window frame autosave | `sai.main` | `sai-dev.main` |
  | terminal command | `sai_tui` | `sai_tui-dev` |
  | local bundle, record | `~/.local/share/sai` | `~/.local/share/sai-dev` |
  | kept releases, dist | `sai-v…` | `sai-dev-v…` |

  Stable's column is exactly what sai was before flavors: an existing
  installation needs no migration.
- **The Xcode scheme is the flavor.** `stable` and `dev` are shared
  schemes over `Debug-/Release-/Profile-<flavor>` configurations, each
  with its own `AppInfo-<flavor>.xcconfig`; `appFlavor` maps to the
  identity at startup. `default-flavor: dev` in the app's pubspec and
  the stock `Debug/Release/Profile` configurations based on the dev
  file mean that a build which names no flavor is dev — nothing
  accidental can look like the daily copy, and no path makes a third.
  The terminal client has two entry points over one bootstrap.
- **Artefacts carry their flavor and the installer checks it.** A
  staged `dist/` is sealed with a `flavor` file, `SaiFlavor` in the
  app's `Info.plist` and `bundle/flavor` beside the terminal client;
  names carry it too. `tool/install-local.sh` reads the flavor from the
  directory, never from an argument, derives every destination from it,
  and refuses when any artefact, what the client prints, or the copy
  already at the destination disagrees. A dist with no seal is a
  pre-flavor stable release and installs as stable.
- **Isolation is per flavor, in both directions.** One flavor running
  never blocks the other's install, upgrade or rollback; each still
  refuses while its own copy runs. Nothing copies or synchronises data
  between the two, and dev has no Keychain items to synchronise.
- **Publishing is stable-only.** `tool/release.sh publish` takes no
  flavor and refuses a dev dist.
- **Dev says so.** The app header wears a `DEV` label at all times, the
  window and menus say `sai dev`, and the terminal client greets as
  `sai dev` and names itself `sai_tui-dev`.
- **The launcher says so too.** Stable uses the canonical
  near-white/ink/red Sai mark. Dev preserves it but replaces the ink
  square's upper-right corner with one large diagonal green field, so
  the distinction survives small sizes and grayscale without text.
  Each flavor's `AppInfo-<flavor>.xcconfig` selects only its own catalog;
  `tool/app-icons.swift` derives every committed size from the curated
  masters under `Runner/IconSources/`.

## Consequences

- Two apps may sit in `~/Applications` and two symlinks in
  `~/.local/bin`; the "one `sai.app`" rule of ADR 0017 becomes one app
  per flavor. Two windows restore independently (ADR 0015's shared
  frame is gone for dev; a scratch run of one flavor still shares that
  flavor's frame).
- The debug bundle CI and the smoke driver use moves to
  `Products/Debug-dev/sai-dev.app`; `drive.sh` finds a window by the
  bundle's display name so both flavors can run during a smoke.
- The two flavors are signed differently (#95): stable with the Apple
  Development identity in a separate `sign` phase from a dedicated
  keychain, dev with a self-signed `sai dev` certificate when this Mac
  has one, ad-hoc otherwise. A dev build never carries stable signing
  authority, so it holds no persistent credentials either: its secret
  store refuses every call, a credential-backed provider is *no
  credentials in dev*, and `sai_tui-dev secret …` refuses. Items an
  earlier dev copy filed under `me.slominski.sai.dev` are neither read
  nor migrated; Keychain Access removes them.
- The two flavors differ in launcher artwork and in credentials; the
  fake and the keyless local providers work in both.
