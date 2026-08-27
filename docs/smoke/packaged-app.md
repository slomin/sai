# Packaged-app smoke — the release bundle, never a development run

The build a release ships (#42) is exercised once per release candidate
against the artefacts `tool/release.sh` staged: the `sai.app` from the
zip and the `bundle` from the tarball, launched from a scratch directory
with `SAI_ARCHIVE_ROOT=<dir>/archive SAI_SETTINGS_FILE=<dir>/settings.json`
so the real archive is never touched. `flutter run`, the debug bundle
under `apps/sai_app/build`, or `dart run` do not count. An agent drives
the app with `tool/smoke/drive.sh` and the terminal client with
`tool/smoke/tui.py` (AGENTS.md, Manual smoke); the steps a person runs
are marked. Evidence — a screenshot per step, the archive line counts,
the settings file — goes into the PR, **results, not claims**.

Preconditions: `dist/sai-v<version>/` staged from the commit under test;
`codesign --verify --deep --strict` clean on both artefacts;
`sai_tui version` prints the version the tag will carry.

## Journey

1. **Start empty.** Launch, take the welcome, choose *Start empty*.
   Capture five tasks: one for Inbox, one for Today (`@today`), one for a
   future date, one for Someday, one with a deadline. Evidence: the
   sidebar counts and each list's screenshot; `task.created` lines in
   the archive.
2. **Edit.** On one task change the title, notes, checklist, schedule,
   deadline, location (area or project) and tags. Evidence: the
   inspector after each change; the `task.updated` lines.
3. **Organise.** Create an area, a project in it and a heading in the
   project; file tasks under them and reorder; find one with Quick Find;
   move through the sidebar and a list by keyboard only. Evidence:
   screenshots of the project view and Quick Find; the container events.
4. **Complete and restore.** Complete one task and undo; delete another
   and restore it from Trash. Evidence: Logbook and Trash screenshots
   before and after; the archive shows the pairs.
5. **Relaunch.** Quit gracefully (`osascript -e 'tell application "sai"
   to quit'`), relaunch. Evidence: the same workspace, selection, sidebar
   state, assistant visibility and window frame; the settings file's
   `workspace` block.
6. **Verify.** Settings › Archive › Verify hashes → `verified N lines`.
   Evidence: the screenshot; `grep` of the app log for any task title
   finds nothing.
7. **Provider.** With LM Studio serving on the LAN address (or
   `localhost:1234`), select it: the header dot goes green. Stop the
   server: the dot leaves green and the text says why. Start it again:
   green without relaunching sai. Evidence: three screenshots and the
   `provider.*` lines if a prompt was sent.
8. **Import.** In a second scratch profile, preview and import a Things
   database, then import again. With a generated fixture
   (`package:sai_core/things_testing.dart`) an agent runs it; with a real
   database a person runs it and reports **counts only**. Evidence: the
   preview and result screens; the second run reporting nothing to do;
   the archive line count unchanged by the second run.
9. **Terminal client.** Run the packaged `sai_tui` — once through a
   symlink like the install makes — against the same archive: Today
   matches the app; capture one task; the app shows it once after
   reload. Evidence: the TUI snapshot, the app's Today, one
   `task.created` line.
10. **A failure that explains itself.** Point `SAI_THINGS_DB` at a file
    that is not a Things database and import: the headline names the
    problem and the next action; the archive line count is unchanged.

## Clean account — a person

On a Mac without Xcode, in a fresh user account: install from the
release page following `docs/release/README.md`, take the Gatekeeper
step, launch, start empty, capture one task, quit, relaunch. Evidence:
the Privacy & Security screenshot and the relaunched window. Not run for
the first pre-release (v0.0.1-dev.1); the release notes say so.
