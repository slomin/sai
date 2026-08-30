import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sai_app/theme/motion.dart';
import 'package:sai_app/theme/sai_theme.dart';
import 'package:sai_app/theme/sai_tokens.dart';
import 'package:sai_app/widgets/check_mark.dart';
import 'package:sai_app/widgets/chip.dart';
import 'package:sai_app/widgets/empty_state.dart';
import 'package:sai_app/widgets/eyebrow.dart';

import 'harness.dart';

void main() {
  group('SaiMotion', () {
    testWidgets('resolves durations to zero under Reduce Motion', (
      tester,
    ) async {
      late Duration full;
      late Duration reduced;
      await tester.pumpWidget(
        Builder(
          builder: (context) {
            full = SaiMotion.resolve(context, SaiDurations.hold);
            return SaiMotion(
              reduce: true,
              child: Builder(
                builder: (context) {
                  reduced = SaiMotion.resolve(context, SaiDurations.hold);
                  return const SizedBox.shrink();
                },
              ),
            );
          },
        ),
      );
      expect(full, SaiDurations.hold);
      expect(reduced, Duration.zero);
    });

    testWidgets('the app places the policy from the platform flag', (
      tester,
    ) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await pumpApp(tester, reduceMotion: false);
      expect(SaiMotion.reduced(tester.element(find.byType(Scaffold))), isTrue);
    });
  });

  group('the theme', () {
    testWidgets('is light, in the system face, over the near-white ground', (
      tester,
    ) async {
      await pumpApp(tester);
      final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
      expect(app.themeMode, ThemeMode.light);
      final theme = Theme.of(tester.element(find.byType(Scaffold)));
      expect(theme.brightness, Brightness.light);
      expect(theme.scaffoldBackgroundColor, SaiColors.bg);
      expect(theme.textTheme.bodyMedium?.fontFamily, SaiFonts.sans);
      expect(theme.extension<SaiText>(), isNotNull);
    });

    testWidgets('display roles keep Space Grotesk with its weight axis; '
        'functional roles take the system face (#99)', (tester) async {
      const text = SaiText();
      for (final role in [text.title, text.emptyTitle, text.brand]) {
        expect(role.fontFamily, SaiFonts.display);
        expect(role.fontVariations, [const FontVariation.weight(700)]);
      }
      for (final role in [
        text.body,
        text.bodyDim,
        text.note,
        text.small,
        text.sidebar,
        text.button,
      ]) {
        expect(role.fontFamily, SaiFonts.sans);
        expect(role.fontVariations, isNull);
      }
      expect(SaiFonts.sans, 'CupertinoSystemText');
      final theme = saiTheme();
      expect(theme.textTheme.bodyMedium?.fontFamily, SaiFonts.sans);
      expect(theme.inputDecorationTheme.hintStyle?.fontFamily, SaiFonts.sans);
      expect(text.meta.fontFamily, SaiFonts.mono);
    });

    testWidgets('the loaded system face is the real one, not Ahem', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: saiTheme(),
          home: Row(
            children: [
              Text('iiii', style: sans(40)),
              Text('MMMM', style: sans(40)),
            ],
          ),
        ),
      );
      expect(
        tester.getSize(find.text('iiii')).width,
        lessThan(tester.getSize(find.text('MMMM')).width),
      );
    });
  });

  group('the primitives', () {
    testWidgets('render as the reference draws them', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: saiTheme(),
          home: const Scaffold(
            body: Padding(
              padding: EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Eyebrow('Tuesday 25 August'),
                  Eyebrow('6 tasks · 3 with deadlines', dim: true),
                  SizedBox(height: 12),
                  Row(
                    children: [
                      SaiChip('due tue 25 aug', tone: ChipTone.due),
                      SizedBox(width: 6),
                      SaiChip('fri 28 aug', tone: ChipTone.tonal),
                      SizedBox(width: 6),
                      SaiChip('errand'),
                    ],
                  ),
                  SizedBox(height: 12),
                  Row(
                    children: [
                      CheckMark(checked: false),
                      CheckMark(checked: true),
                      CheckMark(checked: false, cancelled: true),
                    ],
                  ),
                  EmptyState(
                    eyebrow: 'Inbox',
                    title: 'Inbox is clear.',
                    body:
                        'Half-thoughts land here first. Press ⌘N and type one '
                        'line — filing can wait.',
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      expect(find.text('TUESDAY 25 AUGUST'), findsOneWidget);
      expect(find.text('DUE TUE 25 AUG'), findsOneWidget);
      expect(find.text('Inbox is clear.'), findsOneWidget);
      await expectLater(
        find.byType(Scaffold),
        matchesGoldenFile('goldens/primitives.png'),
      );
    });
  });
}
