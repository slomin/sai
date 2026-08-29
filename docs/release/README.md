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
`bundle` over `~/.local/share/sai/bundle`. Every release is signed with
the same identity, so the Keychain items that hold provider keys keep
trusting the new build without a prompt (ADR 0008). The archive is an
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
| Provider keys | login Keychain, service `me.slominski.sai`, one item per `provider:<id>` | service `me.slominski.sai.dev` | — |
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
SAI_CODESIGN_IDENTITY="…" tool/release.sh local-install       # stable
SAI_CODESIGN_IDENTITY="…" tool/release.sh local-install dev   # the dev flavor
```

builds the release exactly as `build` does (a dirty worktree is
refused), then installs it: `~/Applications/sai.app`,
`~/.local/share/sai/bundle/` and the symlink `~/.local/bin/sai_tui` —
or, for dev, `sai-dev.app`, `~/.local/share/sai-dev/bundle/` and
`sai_tui-dev`. The flavor is a closed word (`stable` or `dev`, ADR
0019), never a destination: it picks the Xcode scheme and the entry
point, and is sealed into the staged directory (`dist/sai-dev-v…/flavor`,
`SaiFlavor` in the app's `Info.plist`, `bundle/flavor` beside the
client) so the installer can check that every artefact is what the
release says. Installing one flavor is allowed while the other runs.
No tag, no GitHub release, and the archive, the settings file and the
Keychain are not touched — the same identity signs every build, so the
provider keys keep working (ADR 0008). Before anything is replaced the
staged artefacts are checked in full: `checksums.txt`; `codesign
--verify --deep --strict` on the app and `--verify --strict` on every
Mach-O in the bundle; that both are signed the way the installed copies
are (a different certificate would strand the Keychain items, ADR 0008 —
`SAI_INSTALL_ALLOW_RESIGN=1` accepts the change knowingly); the commit
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

## Publishing on GitHub

On the machine that holds the identity:

```sh
SAI_CODESIGN_IDENTITY="Apple Development: <name> (<team>)" tool/release.sh
```

`tool/release.sh` refuses a dirty worktree, reads the version from
`packages/sai_core/pubspec.yaml` (bump `saiVersion` and the three
pubspecs first; tests keep them equal), builds the app with
`flutter build macos --release` stamping the numeric part as
`CFBundleShortVersionString` and the commit count as `CFBundleVersion`,
signs the frameworks and the bundle, builds and signs the terminal client
through `tool/sign-tui.sh`, and stages `dist/sai-v<version>/` with the
zip (`ditto -c -k`, the only zip that keeps a signature whole), the
tarball, `checksums.txt` and a `notes.md`. `codesign --verify --deep
--strict` must pass; `spctl -a -t exec sai.app` is expected to say
*rejected* — that is Gatekeeper reporting the missing notarisation, not a
broken signature.

Once the release commit is on `main`:

```sh
SAI_CODESIGN_IDENTITY="…" tool/release.sh publish
```

creates the `v<version>` tag on that commit and the pre-release with the
three files attached. This is the only path that publishes anything;
`local-install` never does, and only stable is ever published — `publish`
takes no flavor and refuses a `dist/` sealed as dev. Publish from the
merged commit, never from a branch: the script refuses a `dist/` built
from another commit (the build writes its commit there), a `HEAD` that
is not on `origin/main`, and an existing `v<version>` tag that points
anywhere else.

Why not Developer ID and notarisation: one person installs this, on
their own Macs. The paid program, the notarisation round-trip and the
hardened runtime would buy a first launch without the Privacy & Security
visit and nothing else; ADR 0017 records the trade and when to revisit
it.
