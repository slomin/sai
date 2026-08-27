import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sai_app/assistant/assistant_band.dart';
import 'package:sai_app/commands.dart';
import 'package:sai_app/find/quick_find.dart';
import 'package:sai_app/platform/finder.dart';
import 'package:sai_app/settings/archive_page.dart';
import 'package:sai_app/settings/general_page.dart';
import 'package:sai_app/settings/providers_page.dart';
import 'package:sai_app/settings/settings_screen.dart';
import 'package:sai_app/settings/shortcuts_page.dart';
import 'package:sai_core/sai_core.dart';

import 'harness.dart';

/// A Finder that only remembers.
final class _FakeFinder extends FinderPanel {
  const _FakeFinder(this.revealed);

  final List<String> revealed;

  @override
  Future<bool> reveal(String path) async {
    revealed.add(path);
    return true;
  }
}

Future<void> open(WidgetTester tester) async {
  menuItem(menuDelegate.menus, ['sai', 'Settings…']).onSelected!();
  await tester.pump();
  expect(find.byKey(settingsScreenKey), findsOneWidget);
}

Future<void> key(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await tester.pump();
  await tester.pump();
}

void main() {
  group('Settings (#40)', () {
    testWidgets('opens on General, in the reference frame', (tester) async {
      await pumpApp(tester);
      await open(tester);
      expect(find.byType(GeneralPage), findsOneWidget);
      expect(find.text('How sai behaves'), findsOneWidget);
      final box = tester.getSize(find.byKey(settingsScreenKey));
      expect(box, const Size(760, 580));
      for (final section in SettingsSection.values) {
        expect(find.byKey(settingsNavKey(section)), findsOneWidget);
      }
    });

    testWidgets('the rail switches pages by click and by arrow', (
      tester,
    ) async {
      await pumpApp(tester);
      await open(tester);
      await tester.tap(find.byKey(settingsNavKey(SettingsSection.archive)));
      await tester.pump();
      expect(find.byType(ArchivePage), findsOneWidget);
      await key(tester, LogicalKeyboardKey.arrowDown);
      expect(find.byType(ShortcutsPage), findsOneWidget);
      await key(tester, LogicalKeyboardKey.arrowDown);
      expect(find.byType(ShortcutsPage), findsOneWidget, reason: 'the end');
      await key(tester, LogicalKeyboardKey.arrowUp);
      await key(tester, LogicalKeyboardKey.arrowUp);
      expect(find.byType(ProvidersPage), findsOneWidget);
      expect(
        tester.getSemantics(
          find
              .descendant(
                of: find.byKey(settingsNavKey(SettingsSection.providers)),
                matching: find.byType(Semantics),
              )
              .first,
        ),
        isSemantics(label: 'Providers', isButton: true, isSelected: true),
      );
    });

    testWidgets('one screen at a time; Help asks for the Shortcuts page', (
      tester,
    ) async {
      await pumpApp(tester);
      await open(tester);
      menuItem(menuDelegate.menus, ['sai', 'Settings…']).onSelected!();
      await tester.pump();
      expect(find.byKey(settingsScreenKey), findsOneWidget);
      menuItem(menuDelegate.menus, [
        'Help',
        'Keyboard Shortcuts',
      ]).onSelected!();
      await tester.pump();
      expect(find.byKey(settingsScreenKey), findsOneWidget);
      expect(find.byType(ShortcutsPage), findsOneWidget);
      final page = find.byType(ShortcutsPage);
      for (final (chord, what) in shortcutRows) {
        expect(
          find.descendant(of: page, matching: find.text(chord)),
          findsOneWidget,
          reason: chord,
        );
        expect(
          find.descendant(of: page, matching: find.text(what)),
          findsOneWidget,
          reason: what,
        );
      }
    });

    testWidgets('typing inside Settings is not a summons', (tester) async {
      await pumpApp(tester);
      await open(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyW, character: 'w');
      await tester.pump();
      await tester.pump();
      expect(find.byType(QuickFindDialog), findsNothing);
      expect(find.byKey(settingsScreenKey), findsOneWidget);
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('the assistant switch is the band, remembered', (tester) async {
      final tmp = tempDir();
      final container = await pumpApp(tester, tmp: tmp);
      expect(find.byKey(chatFieldKey), findsOneWidget);
      await open(tester);
      expect(
        tester.getSemantics(find.byKey(assistantOnLaunchKey)),
        isSemantics(
          label: 'Open the assistant with the app',
          isButton: true,
          isToggled: true,
        ),
      );
      await tester.tap(find.byKey(assistantOnLaunchKey));
      await tester.pump();
      expect(container.read(chatVisibleProvider), isFalse);
      await key(tester, LogicalKeyboardKey.escape);
      expect(find.byKey(chatFieldKey), findsNothing);
      await tester.pump(const Duration(seconds: 1));
      final written = File('${tmp.path}/settings.json').readAsStringSync();
      expect(written, contains('"assistant_visible":false'));
    });

    testWidgets('the Archive card counts, reveals and verifies', (
      tester,
    ) async {
      final revealed = <String>[];
      final container = await pumpApp(
        tester,
        overrides: [finderProvider.overrideWithValue(_FakeFinder(revealed))],
      );
      await capture(tester, container, 'Buy oat milk');
      await open(tester);
      await tester.tap(find.byKey(settingsNavKey(SettingsSection.archive)));
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
      expect(find.textContaining('1 LINES'), findsOneWidget);
      expect(
        find.textContaining('EVERY LINE HASHES ITS OWN BYTES'),
        findsOneWidget,
      );
      expect(find.textContaining('/archive'), findsOneWidget);
      expect(find.textContaining('oat milk'), findsNothing);
      await tester.tap(find.byKey(revealInFinderKey));
      await tester.pump();
      expect(revealed, [container.read(archiveRootProvider).path]);
      await tester.tap(find.byKey(verifyHashesKey));
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
      expect(
        tester.widget<Text>(find.byKey(verifyStatusKey)).data,
        'verified: 1 lines, every hash matches',
      );
    });

    testWidgets('a corrupted archive fails verification in words', (
      tester,
    ) async {
      final tmp = tempDir();
      final container = await pumpApp(tester, tmp: tmp);
      await capture(tester, container, 'Buy oat milk');
      final day = Directory('${tmp.path}/archive/events')
          .listSync()
          .whereType<File>()
          .single;
      day.writeAsStringSync(day.readAsStringSync().replaceFirst('Buy', 'Bxy'));
      await open(tester);
      await tester.tap(find.byKey(settingsNavKey(SettingsSection.archive)));
      await tester.pump();
      await tester.tap(find.byKey(verifyHashesKey));
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
      final status = tester.widget<Text>(find.byKey(verifyStatusKey)).data!;
      expect(status, startsWith('failed: '));
      expect(status, isNot(contains('oat milk')));
      expect(status, isNot(contains(tmp.path)));
    });

    testWidgets('no Finder here is a notice, not a crash', (tester) async {
      final container = await pumpApp(tester);
      await open(tester);
      await tester.tap(find.byKey(settingsNavKey(SettingsSection.archive)));
      await tester.pump();
      await tester.tap(find.byKey(revealInFinderKey));
      // The channel answers on the platform side's schedule.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
      expect(
        container.read(noticeProvider),
        'the Finder is not available here',
      );
    });

    testWidgets('a refused settings file is said on General', (tester) async {
      final tmp = tempDir();
      File('${tmp.path}/settings.json').writeAsStringSync('{"version":9}');
      await pumpApp(tester, tmp: tmp);
      await open(tester);
      expect(
        tester.widget<Text>(find.byKey(settingsProblemKey)).data,
        contains('version 9'),
      );
    });

    testWidgets('the Archive card re-reads after a provider test', (
      tester,
    ) async {
      final tmp = tempDir();
      final container = await pumpApp(tester, tmp: tmp);
      // A fake with an endpoint: the Test button shows, nothing dials out.
      final settings = container.read(settingsProvider.notifier);
      settings.upsertProvider(
        ProviderConfig(
          id: 'lan',
          kind: 'fake',
          endpoint: 'http://127.0.0.1:1/v1',
          defaultModel: 'qwen',
        ),
      );
      settings.selectLlm('lan');
      await tester.pump();
      await open(tester);
      await tester.tap(find.byKey(settingsNavKey(SettingsSection.archive)));
      await tester.pump();
      // Real I/O lands on a short real-async wait, then a pump reads it.
      Future<void> settle() async {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 200)),
        );
        await tester.pump();
      }

      await settle();
      expect(container.read(archiveStatsProvider).value?.count, 0);
      await tester.tap(find.byKey(settingsNavKey(SettingsSection.providers)));
      await tester.pump();
      await tester.tap(find.text('Test'));
      await tester.pump();
      // The fake streams on the test clock and the recorder writes on the
      // real one: alternate the two, bounded, until its three lines land.
      final root = Directory('${tmp.path}/archive');
      for (var i = 0; i < 20 && archiveLines(root).length < 3; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        await settle();
      }
      final lines = archiveLines(root).length;
      expect(
        lines,
        greaterThanOrEqualTo(3),
        reason: 'request, response, usage',
      );
      // Back on the card, which listens: the bumped future re-reads the
      // files on the next real-async settle.
      await tester.tap(find.byKey(settingsNavKey(SettingsSection.archive)));
      await tester.pump();
      await settle();
      expect(
        container.read(archiveStatsProvider).value?.count,
        lines,
        reason: 'the bump re-read the log',
      );
      expect(find.textContaining('$lines LINES'), findsWidgets);
    });

    testWidgets('formats', (tester) async {
      expect(thousands(18402), '18,402');
      expect(thousands(999), '999');
      expect(thousands(1000000), '1,000,000');
      expect(megabytes(4300000), '4.1 MB');
      expect(megabytes(312 * 1024), '312 KB');
      expect(
        homeRelative('/Users/x/Library/sai/archive', {'HOME': '/Users/x'}),
        '~/Library/sai/archive',
      );
      expect(homeRelative('/tmp/a', {'HOME': '/Users/x'}), '/tmp/a');
    });

    testWidgets('Reduce Motion: the screen is up in one frame', (tester) async {
      await pumpApp(tester);
      menuItem(menuDelegate.menus, ['sai', 'Settings…']).onSelected!();
      await tester.pump();
      expect(find.byType(GeneralPage), findsOneWidget);
      final fade = tester.widget<FadeTransition>(
        find
            .ancestor(
              of: find.byKey(settingsScreenKey),
              matching: find.byType(FadeTransition),
            )
            .first,
      );
      expect(fade.opacity.value, 1.0);
    });

    testWidgets('the layout survives 1.3× text', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await pumpApp(tester);
      await open(tester);
      for (final section in SettingsSection.values) {
        await tester.tap(find.byKey(settingsNavKey(section)));
        await tester.pump();
        expect(tester.takeException(), isNull, reason: section.name);
      }
    });

    testWidgets('General renders in the reference treatment', (tester) async {
      await pumpApp(tester);
      await open(tester);
      // The Archive card's counts are real I/O; let them land.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
      await expectLater(
        find.byKey(settingsScreenKey),
        matchesGoldenFile('goldens/settings-general.png'),
      );
    });
  });
}
