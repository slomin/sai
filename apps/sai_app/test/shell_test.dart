import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sai_app/sai_app.dart';
import 'package:sai_core/sai_core.dart';

void main() {
  testWidgets('shell shows the greeting from sai_core', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: SaiApp()));
    expect(find.text('sai $saiVersion — nothing here yet'), findsOneWidget);
  });

  testWidgets('shell reads through the shared provider layer', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appInfoProvider.overrideWithValue(
            const AppInfo(name: 'override', version: '0'),
          ),
        ],
        child: const SaiApp(),
      ),
    );
    expect(find.text('override 0 — nothing here yet'), findsOneWidget);
  });
}
