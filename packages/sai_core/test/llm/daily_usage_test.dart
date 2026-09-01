import 'dart:io';

import 'package:riverpod/riverpod.dart';
import 'package:sai_core/sai_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late ProviderContainer container;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('sai_daily_usage_test');
    container = ProviderContainer.test(
      overrides: [
        archiveRootProvider.overrideWithValue(Directory('${tmp.path}/archive')),
        settingsFileProvider.overrideWithValue(File('${tmp.path}/s.json')),
        eventSourceProvider.overrideWithValue('sai/test'),
        builtinLlmsProvider.overrideWithValue([FakeLlmProvider.new]),
        defaultLlmIdProvider.overrideWithValue(null),
        warmEnabledProvider.overrideWithValue(false),
      ],
    );
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  CalendarDate today() => CalendarDate.fromLocal(DateTime.now());

  test('an untouched archive has no usage', () async {
    container.listen(dailyUsageProvider, (_, _) {});
    await container.read(tasksProvider.future);
    final usage = await container.read(dailyUsageProvider.future);
    expect(usage.isEmpty, isTrue);
  });

  test('a bump re-reads what the recorder wrote (#30)', () async {
    container.listen(dailyUsageProvider, (_, _) {});
    await container.read(tasksProvider.future);
    expect((await container.read(dailyUsageProvider.future)).isEmpty, isTrue);
    // A writer the watchers cannot see: the recorder, straight in.
    final recorder = await container.read(llmRecorderProvider.future);
    final call = await recorder.start(
      container.read(llmRegistryProvider)['fake']!,
      providerTestRequest(effort: ReasoningEffort.none),
    );
    await call.done;
    expect((await container.read(dailyUsageProvider.future)).isEmpty, isTrue);
    container.read(archiveRevisionProvider.notifier).bump();
    final usage = await container.read(dailyUsageProvider.future);
    final row = usage.onDay(today()).single;
    expect(row.provider, 'fake');
    expect(row.calls, 1);
    expect(row.failed, 0);
    expect(row.tokens, greaterThan(0));
  });

  test('a chat turn refreshes the totals without a bump', () async {
    container.listen(dailyUsageProvider, (_, _) {});
    await container.read(tasksProvider.future);
    container.read(settingsProvider.notifier).selectLlm('fake');
    await container.read(chatProvider.notifier).send('hello?');
    final usage = await container.read(dailyUsageProvider.future);
    expect(usage.onDay(today()).single.calls, 1);
  });
}
