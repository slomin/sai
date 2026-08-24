import 'dart:io';

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

    test('llmStatusProvider is the no-provider placeholder', () {
      final container = ProviderContainer.test();
      expect(container.read(llmStatusProvider), noProviderStatus);
      expect(noProviderStatus, 'no provider — local only');
    });
  });
}
