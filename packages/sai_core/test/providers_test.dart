import 'dart:io';

import 'package:riverpod/misc.dart' show Override, ProviderException;
import 'package:riverpod/riverpod.dart';
import 'package:sai_core/sai_core.dart';
import 'package:test/test.dart';

void main() {
  test('appInfoProvider exposes the workspace version', () {
    final container = ProviderContainer.test();
    final info = container.read(appInfoProvider);
    expect(info.name, 'sai');
    expect(info.version, saiVersion);
  });

  test('shellGreetingProvider renders name, version and the empty note', () {
    final container = ProviderContainer.test();
    expect(
      container.read(shellGreetingProvider),
      'sai 2.0.0-dev — nothing here yet',
    );
  });

  test('shellGreetingProvider derives from appInfoProvider', () {
    final container = ProviderContainer.test(
      overrides: [
        appInfoProvider.overrideWithValue(
          const AppInfo(name: 'test', version: '9.9.9'),
        ),
      ],
    );
    expect(
      container.read(shellGreetingProvider),
      'test 9.9.9 — nothing here yet',
    );
  });

  group('task providers', () {
    test('eventSourceProvider refuses to run unoverridden', () {
      final container = ProviderContainer.test();
      expect(
        () => container.read(eventSourceProvider),
        throwsA(predicate((e) => e.toString().contains('eventSourceProvider'))),
      );
    });

    test('todayProvider is the local calendar day of clockProvider', () {
      final container = ProviderContainer.test(
        overrides: [
          clockProvider.overrideWithValue(() => DateTime(2026, 8, 24, 23, 30)),
        ],
      );
      expect(container.read(todayProvider), const CalendarDate(2026, 8, 24));
    });

    test('tasksProvider opens the store and reflects its commands', () async {
      final tmp = Directory.systemTemp.createTempSync('sai_providers_test');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final container = ProviderContainer.test(
        overrides: [
          archiveRootProvider.overrideWithValue(tmp),
          eventSourceProvider.overrideWithValue('sai/test'),
        ],
      );
      final notifier = container.read(tasksProvider.notifier);
      expect(
        () => notifier.store,
        throwsStateError,
        reason: 'the store is not open until the provider future resolves',
      );

      final initial = await container.read(tasksProvider.future);
      expect(initial.tasks, isEmpty);

      final id = await notifier.store.createTask(title: 'from the provider');
      // No microtask gap: an awaited command is already visible in state.
      final projection = container.read(tasksProvider).value!;
      expect(projection.task(id)!.title, 'from the provider');
      expect(projection.eventCount, 1);
    });

    test('canUndoProvider follows the store, false until it settles', () async {
      final tmp = Directory.systemTemp.createTempSync('sai_providers_test');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final container = ProviderContainer.test(
        overrides: [
          archiveRootProvider.overrideWithValue(tmp),
          eventSourceProvider.overrideWithValue('sai/test'),
        ],
      );
      expect(container.read(canUndoProvider), isFalse);

      await container.read(tasksProvider.future);
      expect(container.read(canUndoProvider), isFalse);

      final store = container.read(tasksProvider.notifier).store;
      await store.createTask(title: 'x');
      expect(container.read(canUndoProvider), isTrue);

      await store.undo();
      expect(container.read(canUndoProvider), isFalse);
    });
  });

  group('shell providers', () {
    test('selectedSectionProvider opens on Today and moves on select', () {
      final container = ProviderContainer.test();
      expect(
        container.read(selectedSectionProvider),
        const ListSection(TaskList.today),
      );
      container
          .read(selectedSectionProvider.notifier)
          .select(const TrashSection());
      expect(container.read(selectedSectionProvider), const TrashSection());
    });

    test('chatVisibleProvider starts shown and toggles', () {
      final container = ProviderContainer.test();
      expect(container.read(chatVisibleProvider), isTrue);
      container.read(chatVisibleProvider.notifier).toggle();
      expect(container.read(chatVisibleProvider), isFalse);
      container.read(chatVisibleProvider.notifier).toggle();
      expect(container.read(chatVisibleProvider), isTrue);
    });
  });

  group('llm providers', () {
    late Directory tmp;
    late Directory root;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('sai_llm_providers_test');
      root = Directory('${tmp.path}/archive');
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    ProviderContainer make({List<Override> overrides = const []}) =>
        ProviderContainer.test(
          overrides: [
            archiveRootProvider.overrideWithValue(root),
            eventSourceProvider.overrideWithValue('sai/test'),
            ...overrides,
          ],
        );

    test('settings live beside the archive root', () {
      final container = make();
      expect(
        container.read(settingsFileProvider).path,
        '${tmp.path}/settings.json',
      );
    });

    test('the registry holds the fake and rejects duplicate ids', () {
      final container = make();
      expect(container.read(llmRegistryProvider).keys, ['fake']);
      final dupes = make(
        overrides: [
          installedLlmsProvider.overrideWithValue([
            FakeLlmProvider(),
            FakeLlmProvider(),
          ]),
        ],
      );
      expect(
        () => dupes.read(llmRegistryProvider),
        throwsA(
          isA<ProviderException>().having(
            (e) => e.exception,
            'exception',
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('share the id "fake"'),
            ),
          ),
        ),
      );
    });

    test('nothing is selected until someone selects', () {
      final container = make();
      expect(container.read(settingsProvider).llm, isNull);
      expect(container.read(activeLlmProvider), isNull);
      expect(container.read(llmStatusProvider), noProviderStatus);
      expect(noProviderStatus, 'no provider — local only');
      expect(File('${tmp.path}/settings.json').existsSync(), isFalse);
    });

    test('selecting switches the active provider without a rebuild', () {
      final container = make();
      final seen = <String>[];
      container.listen(llmStatusProvider, (_, next) => seen.add(next));
      container.read(settingsProvider.notifier).selectLlm('fake');
      expect(container.read(activeLlmProvider)?.id, 'fake');
      expect(container.read(llmStatusProvider), 'fake (fake-1) — local');
      expect(seen, ['fake (fake-1) — local']);
      expect(
        File('${tmp.path}/settings.json').readAsStringSync(),
        '{"llm":"fake","version":0}',
      );
    });

    test('the selection survives into a fresh container', () {
      make().read(settingsProvider.notifier).selectLlm('fake');
      final again = make();
      expect(again.read(activeLlmProvider)?.id, 'fake');
      expect(again.read(llmStatusProvider), 'fake (fake-1) — local');
    });

    test('an unknown selection is named, and null clears it', () {
      final container = make();
      final notifier = container.read(settingsProvider.notifier);
      notifier.selectLlm('nope');
      expect(container.read(activeLlmProvider), isNull);
      expect(
        container.read(llmStatusProvider),
        "provider 'nope' is not available — local only",
      );
      notifier.selectLlm(null);
      expect(container.read(llmStatusProvider), noProviderStatus);
    });

    test('unusable settings are said so in the status line', () {
      File('${tmp.path}/settings.json').writeAsStringSync('nope');
      final container = make();
      expect(container.read(settingsProvider).problem, isNotNull);
      expect(container.read(llmStatusProvider), unreadableSettingsStatus);
      expect(unreadableSettingsStatus, 'settings unreadable — local only');
    });

    test('llmRecorderProvider records with the client source', () async {
      final container = make();
      final recorder = await container.read(llmRecorderProvider.future);
      final call = await recorder.start(
        FakeLlmProvider(),
        LlmRequest(messages: [const LlmMessage(LlmRole.user, 'hi')]),
      );
      await call.done;
      final archive = await container.read(archiveProvider.future);
      final events = await archive.events().toList();
      expect(events.map((e) => e.event.type), [
        'provider.request',
        'provider.response',
        'provider.usage',
      ]);
      expect(events.every((e) => e.event.source == 'sai/test'), isTrue);
    });
  });
}
