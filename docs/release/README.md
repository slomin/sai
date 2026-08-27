# Installing and releasing sai

sai is distributed by hand (#42): a zip with the signed `sai.app`, a
tarball with the signed terminal client, and a `checksums.txt`, attached
to a GitHub pre-release. The app is signed with an Apple Development
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
- **The settings file** may be refused when the newer build raised its
  `version`: the older build then quarantines the file beside itself
  (`settings.json.quarantine-<timestamp>`, see
  [settings v0](../settings/settings-v0.md)), starts from defaults and
  shows the reason on the Settings › General page. Provider keys stay in
  the Keychain; re-adding a provider with the same id reconnects them.

## Where the data lives

| What | Path | Override |
| --- | --- | --- |
| Archive (the task and chat log) | `~/Library/Application Support/sai/archive/` | `SAI_ARCHIVE_ROOT` |
| Settings | `~/Library/Application Support/sai/settings.json` | `SAI_SETTINGS_FILE` |
| Provider keys | login Keychain, service `me.slominski.sai`, one item per `provider:<id>` | — |
| The app | `/Applications/sai.app` | — |
| The terminal client | `~/.local/share/sai/bundle/`, `~/.local/bin/sai_tui` | — |

Both clients read the same archive and settings; a scratch run sets both
overrides. Until #15 lands, a backup by hand is a copy of the
`Application Support/sai` directory taken while sai is quit; the Keychain
items are not in it and are re-entered, never copied.

Uninstall: delete the app, the bundle and the symlink; delete
`~/Library/Application Support/sai` if the archive should go too; `sai_tui
secret clear <id>` for each provider removes the Keychain items (do that
before removing the binary).

## Building a release

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
three files attached. Publish from the merged commit, never from a
branch: the script checks that `HEAD` is on `origin/main`.

Why not Developer ID and notarisation: one person installs this, on
their own Macs. The paid program, the notarisation round-trip and the
hardened runtime would buy a first launch without the Privacy & Security
visit and nothing else; ADR 0017 records the trade and when to revisit
it.
