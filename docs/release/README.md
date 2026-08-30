# Installing and releasing sai

sai is distributed by hand (#42): a zip with the signed `sai.app`, a
tarball with the signed terminal client, and a `checksums.txt`, attached
to a GitHub pre-release — or, on the Mac that builds it, installed
straight from the tree as the dogfood copy (#87, below). The app is signed with an Apple Development
identity and not notarised (ADR 0017), so the first launch on a Mac that
did not build it needs one Gatekeeper step. There is no updater; an
upgrade is the same steps again.

## Install

1. Download `sai-v<version>-macos-<arch>.zip`,
   `sai_tui-v<version>-macos-<arch>.tar.gz` and `checksums.txt` from the
   release, into one directory, and check them:

   ```sh
   shasum -a 256 -c checksums.txt
   ```

2. The app: unzip (Finder, or `ditto -x -k sai-v*.zip .`, which keeps
   the signature intact) and move `sai.app` to `/Applications`. Open it.
   A download carries Gatekeeper's `com.apple.quarantine` attribute, and
   macOS refuses an app it cannot check with Apple. Either:
   - open System Settings › Privacy & Security, scroll to the notice
     about sai and click **Open Anyway**, then **Open** in the dialog
     (once per install; Sequoia and later no longer offer the
     control-click shortcut), or
   - clear the attribute before the first launch:
     `xattr -dr com.apple.quarantine /Applications/sai.app`.

   A copy made by `scp`, `curl` or AirDrop from a machine you own is not
   quarantined and opens without either.

3. The terminal client is a directory, not a single file — the binary
   dlopens the SQLite library beside it — so it stays a directory:

   ```sh
   mkdir -p ~/.local/share/sai ~/.local/bin
   tar -C ~/.local/share/sai -xzf sai_tui-v*.tar.gz     # → ~/.local/share/sai/bundle
   ln -sf ~/.local/share/sai/bundle/bin/sai_tui ~/.local/bin/sai_tui
   sai_tui version
   ```

   The symlink works because the bundle looks for its library beside the
   *resolved* executable; `~/.local/bin` on `PATH` is the usual way. A
   quarantined binary run from the shell is refused the same way the app
   is; `xattr -dr com.apple.quarantine ~/.local/share/sai/bundle` clears
   it.

4. First launch: an empty archive shows the welcome — start empty or
   import from Things 3 (both write `setup: done` to the settings file).
   The About panel shows the version; `sai_tui version` prints it.

## Upgrade

Replace the bundle: quit sai, move the new `sai.app` over the old one
(Finder asks; or `ditto` the new one and `rm -rf` the old), untar the new
`bundle` over `~/.local/share/sai/bundle`. Every stable release is
signed with the same identity, so the Keychain items that hold provider
keys keep trusting the new build without a prompt (ADR 0008). The archive is an
append-only log whose every line names its schema version, and the
settings file carries `version` — a newer build reads both as they are.

## Rollback

Keep the previous release's zip and tarball (or download them again;
releases stay up). Quit sai, put the older `sai.app` and `bundle` back.
What the older build finds:

- **The archive** is fine: lines it does not know it skips, everything
  else it reads. Nothing is rewritten in place, ever.
- **The settings file** is refused when the newer build raised its
  `version`: the older build leaves it untouched, runs on defaults, says
  so on the Settings › General page, and **will not save** — any change
  to a setting fails until the file is dealt with (see
  [settings v0](../settings/settings-v0.md)). To keep using the older
  build, quit it and move the file aside by hand
  (`mv ~/Library/Application\ Support/sai/settings.json settings.json.newer`),
  then relaunch and set things up again; provider keys stay in the
  Keychain and re-adding a provider with the same id picks them up.
  Going back to the newer build later reads the moved file again once
  it is moved back.

## Where the data lives

| What | Stable | Dev | Override |
| --- | --- | --- | --- |
| Archive (the task and chat log) | `~/Library/Application Support/sai/archive/` | `~/Library/Application Support/sai-dev/archive/` | `SAI_ARCHIVE_ROOT` |
| Settings | `~/Library/Application Support/sai/settings.json` | `…/sai-dev/settings.json` | `SAI_SETTINGS_FILE` |
| Provider keys | login Keychain, service `me.slominski.sai`, one item per `provider:<id>` | none — dev holds no credentials (#95) | — |
| The app | `/Applications/sai.app` (a download) or `~/Applications/sai.app` (the dogfood install) — one Mac keeps one, never both | `~/Applications/sai-dev.app` | — |
| The terminal client | `~/.local/share/sai/bundle/`, `~/.local/bin/sai_tui` | `~/.local/share/sai-dev/bundle/`, `~/.local/bin/sai_tui-dev` | — |
| What the dogfood install installed | `~/.local/share/sai/installed` | `~/.local/share/sai-dev/installed` | — |
| Kept dogfood releases | `references/releases/sai-v<version>-<commit>/` in the checkout (gitignored) | `references/releases/sai-dev-v<version>-<commit>/` | `SAI_INSTALL_KEEP_DIR` |

Stable is the daily-use copy and the only one a release page ever
carries; dev is the developer's isolated copy (ADR 0019) — its own app,
data, settings, Keychain service and window, installed beside stable
and never over it, and nothing is ever copied between the two. Both
clients of a flavor read the same archive and settings; a scratch run
sets both overrides, for either flavor. Until #15 lands, a backup by hand is a copy of the
`Application Support/sai` directory taken while sai is quit; the Keychain
items are not in it and are re-entered, never copied.

Uninstall: delete the app, the bundle and the symlink; delete
`~/Library/Application Support/sai` if the archive should go too; `sai_tui
secret clear <id>` for each provider removes the Keychain items (do that
before removing the binary).

## The dogfood install

The developer's own copy comes from the tree, not from a release:

```sh
tool/release.sh local-install dev                 # the dev flavor: build, sign low, install
tool/release.sh prepare stable && tool/release.sh sign && tool/release.sh local-install stable
```

Dev is one step: `prepare` builds and seals it, signs it with the
self-signed `sai dev` identity when this Mac has one (ad-hoc otherwise),
and the installer takes it. Stable is three, and only the middle one
reaches a signing key — see *Signing* below. Both refuse a dirty
worktree. The install puts in place: `~/Applications/sai.app`,
`~/.local/share/sai/bundle/` and the symlink `~/.local/bin/sai_tui` —
or, for dev, `sai-dev.app`, `~/.local/share/sai-dev/bundle/` and
`sai_tui-dev`. The flavor is a closed word (`stable` or `dev`, ADR
0019), never a destination: it picks the Xcode scheme and the entry
point, and is sealed into the staged directory (`dist/sai-dev-v…/flavor`,
`SaiFlavor` in the app's `Info.plist`, `bundle/flavor` beside the
client) so the installer can check that every artefact is what the
release says. Installing one flavor is allowed while the other runs.
No tag, no GitHub release, and the archive, the settings file and the
Keychain are not touched — the same identity signs every stable build,
so the provider keys keep working (ADR 0008). Before anything is
replaced the staged artefacts are checked in full
(`tool/verify-release.sh`): `checksums.txt`; the seal — a stable release
must be sealed by the signing phase, a dev one as dev, and the seal must
match the checksums, flavor and commit; `codesign --verify --deep
--strict` on the app and `--verify --strict` on every Mach-O in the
bundle; for stable, that both are signed the way the installed copies
are (a different certificate would strand the Keychain items, ADR 0008 —
`SAI_INSTALL_ALLOW_RESIGN=1` accepts the change knowingly; a dev copy
holds no credentials and may be signed differently from the last); the commit
each carries (`SaiCommit`
in the app's `Info.plist`, `bundle/commit` beside the terminal client)
against the commit that built them, the version the plist and
`sai_tui version` report, and the flavor every artefact carries against
the directory's seal (a dev app in a stable release, a client that
names itself wrongly, or a dev app already sitting at `sai.app` all
stop it). The app and the bundle are unpacked beside
their destinations and swapped in by rename, the pair together; if that
fails part-way the app swap is undone. That flavor's installed app or
client running is refused (quit them first) — the other flavor running
is not — as is a stray file where the symlink goes and a
`/Applications/sai.app` from a download (one Mac keeps one copy of a
flavor). A backup left by an interrupted run is put back on the
next run before anything is judged. `tool/release.sh local-install
--dry-run` prints what would be built and replaced without writing
anything.

The install stage is its own script, so a build that already exists —
the `dist/` a release is about to be published from, say — installs
without rebuilding:

```sh
tool/install-local.sh dist/sai-v<version>       # or dist/sai-dev-v<version>
```

An upgrade is the same command on a newer commit. The artefacts that
were installed are kept under `references/releases/sai-v<version>-<commit>/`
(`sai-dev-v…` for dev; gitignored, this checkout only — `git clean -xdf`
or removing the checkout removes them) and `~/.local/share/sai/installed`
(`sai-dev/installed`) says which one is in place, flavor included (it
describes the dogfood install only; untarring a download over the
bundle bypasses it). A kept release from before flavors existed carries
no seal and installs as stable. Rollback is quitting that flavor and
reinstalling a kept one through the same checks:

```sh
tool/release.sh install references/releases/sai-v0.0.1-dev.1-6a8e367
tool/release.sh install references/releases/sai-dev-v0.0.1-dev.1-6a8e367
```

What an older build finds in a newer archive and settings file is the
same as for a downloaded release (Rollback, above).

The app icons carry the same identity: stable is the canonical
near-white/ink/red Sai mark; dev adds the large diagonal green corner.
The source masters and their prompt provenance are in
`apps/sai_app/macos/Runner/IconSources/`; from the repository root,
`swift tool/app-icons.swift prepare` regenerates both committed catalogs
and `swift tool/app-icons.swift check` proves the sizes are current and
distinct. Release and local-install builds select the catalog belonging
to their flavor; the other catalog is not compiled into the bundle.

## Signing

Building and signing are two phases (#95, ADR 0017), and only the second
can use the stable key:

```sh
tool/release.sh prepare stable    # every toolchain runs here; nothing can sign
tool/release.sh sign              # only codesign runs here; macOS asks first
```

`prepare` refuses a dirty worktree, reads the version from
`packages/sai_core/pubspec.yaml` (bump `saiVersion` and the three
pubspecs first; tests keep them equal), builds the app with
`flutter build macos --release` stamping the numeric part as
`CFBundleShortVersionString` and the commit count as `CFBundleVersion`,
builds the terminal client through `tool/build-tui.sh`, ad-hoc signs
everything so the tree verifies as it stands, and seals
`dist/sai-v<version>/prepared/` with a manifest of every file. No
identity is in reach while `pub`, Flutter, `dart build cli` and the
sqlite3 build hook run.

`sign` takes only that sealed tree — unmodified since the seal, built
from `HEAD`, stable, still ad-hoc — copies it aside, and asks the
dedicated keychain for its one identity. Because that keychain is locked
and outside the search list, macOS puts up its dialog for the key at
that moment, and at no other: click *Allow* (or enter the keychain's
password) for this one run — **never *Always Allow***, which would let
any later process sign silently. The script signs from the inside out —
the app's frameworks and helpers, the app with its entitlements, every
dylib in the client's bundle, then the client — verifies (`--deep
--strict` on the app, `--strict` on each client Mach-O; nothing is ever
signed with `--deep`), and stages `dist/sai-v<version>/release/` with
the zip (`ditto -c -k`, the only zip that keeps a signature whole), the
tarball, `checksums.txt`, a `notes.md` and a seal naming the signing
phase. A cancelled dialog or a refusal leaves `prepared/` and the
previous `release/` exactly as they were. Nothing but `codesign` and the
packaging tools runs after the keychain has been asked. `spctl -a -t
exec sai.app` is expected to say *rejected* — that is Gatekeeper
reporting the missing notarisation, not a broken signature.

### The dedicated signing keychain, once

The stable identity lives in its own keychain at
`~/Library/Keychains/sai-signing.keychain-db`, and `sign` is the only
thing that reads it — with one command, `security find-identity -v -p
codesigning <that keychain>`, whose output it never prints. Set it up by
hand in Keychain Access:

1. *File › New Keychain…*, name `sai-signing`, saved in
   `~/Library/Keychains` (the default), with a password of its own.
2. In the login keychain's *My Certificates*, drag the *Apple
   Development* certificate (with its private key) into `sai-signing`;
   then delete it from the login keychain, so nothing else can find it.
3. In Keychain Access, *right-click `sai-signing` › Remove Keychain
   “sai-signing”*: this takes it out of the search list without deleting
   the file (`sign` opens it by path). Lock it (*File › Lock*).
4. Never choose *Always Allow* in the dialog `sign` raises, and never
   change the key's access control to allow `codesign` silently.

No script unlocks that keychain, changes the search list, an access
control list or a key-partition list; the identity's name or fingerprint
is never given to a script through the environment, an argument, a file
or a log. `sign` fails closed when the keychain is missing, cannot be
read, holds no usable identity or more than one, or the dialog is
cancelled.

**Recovery and rotation.** A lost keychain means a new identity: make
one in Xcode (Accounts › Manage Certificates), file it the same way,
then install the next release once with `SAI_INSTALL_ALLOW_RESIGN=1` and
enter the provider keys again — the Keychain items were bound to the old
certificate. A renewal of the same Apple Development identity keeps the
subject and team, so the designated requirement and the items survive
it. The signing keychain is not in any backup sai makes; keep it in the
Mac's own backup, or re-create the identity.

**Dev holds no credentials.** The dev flavor never opens a Keychain: a
credential-backed provider is *no credentials in dev* in the app, the
connection light and `sai_tui-dev provider list`, and `sai_tui-dev secret
…` refuses. Items an earlier dev copy filed under `me.slominski.sai.dev`
are left untouched and never read; remove them by hand in Keychain
Access (search for `me.slominski.sai.dev`) when you want them gone. A
cloud smoke uses a stable-signed bundle with scratch archive and
settings overrides, never the dev flavor.

## Publishing on GitHub

Once the release commit is on `main` and `sign` has run on it:

```sh
tool/release.sh publish
```

creates the `v<version>` tag on that commit and the pre-release with the
three files attached. This is the only path that publishes anything;
`local-install` never does, and only stable is ever published — `publish`
takes no flavor and refuses a release not sealed by the signing phase,
and verifies the whole graph (`tool/verify-release.sh`) before uploading.
Publish from the merged commit, never from a branch: the script refuses
a release built from another commit (the build writes its commit
there), a `HEAD` that is not on `origin/main`, and an existing
`v<version>` tag that points anywhere else.

Why not Developer ID and notarisation: one person installs this, on
their own Macs. The paid program, the notarisation round-trip and the
hardened runtime would buy a first launch without the Privacy & Security
visit and nothing else; ADR 0017 records the trade and when to revisit
it.
