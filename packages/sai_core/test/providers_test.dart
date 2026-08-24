import 'dart:convert';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
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

    test(
      'todayProvider rolls over at local midnight and cancels its timer',
      () {
        fakeAsync((async) {
          final start = DateTime(2026, 8, 24, 23, 59);
          final container = ProviderContainer.test(
            overrides: [
              clockProvider.overrideWithValue(() => start.add(async.elapsed)),
            ],
          );
          expect(
            container.read(todayProvider),
            const CalendarDate(2026, 8, 24),
          );
          expect(async.nonPeriodicTimerCount, 1);
          async.elapse(const Duration(minutes: 1));
          expect(
            container.read(todayProvider),
            const CalendarDate(2026, 8, 25),
          );
          expect(async.nonPeriodicTimerCount, 1);
          container.dispose();
          expect(async.pendingTimers, isEmpty);
        });
      },
    );

    test('archive events are stamped with clockProvider', () async {
      final tmp = Directory.systemTemp.createTempSync('sai_providers_test');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final container = ProviderContainer.test(
        overrides: [
          archiveRootProvider.overrideWithValue(tmp),
          eventSourceProvider.overrideWithValue('sai/test'),
          clockProvider.overrideWithValue(
            () => DateTime(2026, 8, 24, 12, 30, 15, 123, 456),
          ),
        ],
      );
      await container.read(tasksProvider.future);
      await container.read(tasksProvider.notifier).store.createTask(title: 'x');
      final archive = await container.read(archiveProvider.future);
      final stored = await archive.events().single;
      expect(
        stored.event.ts,
        DateTime(2026, 8, 24, 12, 30, 15, 123, 456).toUtc(),
      );
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

    test(
      'taskViewProvider updates synchronously after a committed command',
      () async {
        final tmp = Directory.systemTemp.createTempSync(
          'sai_view_provider_test',
        );
        addTearDown(() => tmp.deleteSync(recursive: true));
        final container = ProviderContainer.test(
          overrides: [
            archiveRootProvider.overrideWithValue(tmp),
            eventSourceProvider.overrideWithValue('sai/test'),
            clockProvider.overrideWithValue(() => DateTime(2026, 8, 24, 12)),
          ],
        );
        await container.read(tasksProvider.future);
        final provider = taskViewProvider(const ListSection(TaskList.inbox));
        expect(container.read(provider).requireValue.tasks, isEmpty);
        await container
            .read(tasksProvider.notifier)
            .store
            .createTask(title: 'x');
        expect(container.read(provider).requireValue.tasks.single.title, 'x');
      },
    );

    test('taskViewProvider changes at midnight without a task mutation', () {
      final event = Event.seal(
        TaskCreated(
          title: 'tomorrow',
          when: const TaskWhen.date(CalendarDate(2026, 8, 25)),
        ).toDraft(source: 'sai/test'),
        prev: null,
        ts: DateTime.utc(2026, 8, 24, 12),
      );
      final projection = TaskProjection.empty.apply(
        StoredEvent(id: event.deriveId(), event: event),
      );
      fakeAsync((async) {
        final start = DateTime(2026, 8, 24, 23, 59);
        final container = ProviderContainer.test(
          overrides: [
            tasksProvider.overrideWithBuild((ref, notifier) => projection),
            clockProvider.overrideWithValue(() => start.add(async.elapsed)),
          ],
        );
        final section = const ListSection(TaskList.today);
        container.listen(taskViewProvider(section), (_, _) {});
        async.flushMicrotasks();
        expect(
          container.read(taskViewProvider(section)).requireValue.tasks,
          isEmpty,
        );
        async.elapse(const Duration(minutes: 1));
        expect(
          container
              .read(taskViewProvider(section))
              .requireValue
              .tasks
              .single
              .title,
          'tomorrow',
        );
        container.dispose();
      });
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

    late InMemorySecretStore secrets;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('sai_llm_providers_test');
      root = Directory('${tmp.path}/archive');
      secrets = InMemorySecretStore();
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    ProviderContainer make({
      List<Override> overrides = const [],
      SecretStore? store,
    }) => ProviderContainer.test(
      overrides: [
        archiveRootProvider.overrideWithValue(root),
        settingsFileProvider.overrideWithValue(
          File('${tmp.path}/settings.json'),
        ),
        eventSourceProvider.overrideWithValue('sai/test'),
        secretStoreProvider.overrideWithValue(store ?? secrets),
        ...overrides,
      ],
    );

    test('the settings file is resolved from the environment', () {
      final container = ProviderContainer.test(
        overrides: [
          environmentProvider.overrideWithValue({
            'SAI_SETTINGS_FILE': '${tmp.path}/elsewhere.json',
          }),
        ],
      );
      expect(
        container.read(settingsFileProvider).path,
        '${tmp.path}/elsewhere.json',
      );
    });

    test('the registry holds the fake and rejects duplicate ids', () {
      final container = make();
      expect(container.read(llmRegistryProvider).keys, ['fake']);
      final first = FakeLlmProvider();
      final second = FakeLlmProvider();
      final dupes = make(
        overrides: [
          installedLlmsProvider.overrideWithValue([first, second]),
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
      expect(first.isClosed, isTrue, reason: 'nothing constructed leaks');
      expect(second.isClosed, isTrue);
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

    group('configured providers', () {
      final lan = ProviderConfig(
        id: 'lan',
        kind: 'fake',
        defaultModel: 'qwen',
        credential: 'provider:lan',
      );

      test('a configured provider joins the registry and can be selected', () {
        final container = make();
        final settings = container.read(settingsProvider.notifier);
        settings.upsertProvider(lan);
        expect(container.read(llmRegistryProvider).keys, ['fake', 'lan']);
        settings.selectLlm('lan');
        expect(container.read(activeLlmProvider)?.defaultModel, 'qwen');
        expect(
          container.read(llmStatusProvider),
          'lan (qwen) — local · no key',
        );
        expect(
          jsonDecode(File('${tmp.path}/settings.json').readAsStringSync()),
          {
            'version': 0,
            'llm': 'lan',
            'providers': [
              {
                'id': 'lan',
                'kind': 'fake',
                'default_model': 'qwen',
                'credential': 'provider:lan',
              },
            ],
          },
        );
      });

      test('selecting does not rebuild the providers; configuring does', () {
        final container = make();
        final settings = container.read(settingsProvider.notifier);
        settings.upsertProvider(lan);
        final before = container.read(llmRegistryProvider)['lan']!;
        settings.selectLlm('lan');
        settings.selectLlm('fake');
        expect(
          identical(container.read(llmRegistryProvider)['lan'], before),
          isTrue,
        );
        expect((before as FakeLlmProvider).isClosed, isFalse);
        settings.upsertProvider(lan.copyWith(defaultModel: () => 'other'));
        final after = container.read(llmRegistryProvider)['lan']!;
        expect(identical(after, before), isFalse);
        expect(before.isClosed, isTrue, reason: 'the old one is released');
        expect(after.defaultModel, 'other');
      });

      test('reconfiguring keeps the built-in and untouched providers open', () {
        final container = make();
        final settings = container.read(settingsProvider.notifier);
        settings.upsertProvider(lan);
        final fake = container.read(llmRegistryProvider)['fake']!;
        final lanBefore = container.read(llmRegistryProvider)['lan']!;
        settings.upsertProvider(ProviderConfig(id: 'other', kind: 'fake'));
        final registry = container.read(llmRegistryProvider);
        expect(registry.keys, ['fake', 'lan', 'other']);
        expect(identical(registry['fake'], fake), isTrue);
        expect((fake as FakeLlmProvider).isClosed, isFalse);
        expect(identical(registry['lan'], lanBefore), isTrue);
        expect((lanBefore as FakeLlmProvider).isClosed, isFalse);
        // An identical re-write is no change at all.
        settings.upsertProvider(lan);
        expect(
          identical(container.read(llmRegistryProvider)['lan'], lanBefore),
          isTrue,
        );
        // Removing one closes exactly that one.
        final other = registry['other'] as FakeLlmProvider;
        settings.removeProvider('other');
        // Lazy, like everything riverpod: the rebuild happens on read.
        expect(container.read(llmRegistryProvider).keys, ['fake', 'lan']);
        expect(other.isClosed, isTrue);
        expect(lanBefore.isClosed, isFalse);
        expect(fake.isClosed, isFalse);
        container.dispose();
        expect(lanBefore.isClosed, isTrue, reason: 'disposal closes all');
        expect(fake.isClosed, isTrue);
      });

      test(
        'an in-flight call survives an unrelated configuration edit',
        () async {
          final container = make();
          final settings = container.read(settingsProvider.notifier);
          settings.upsertProvider(lan);
          settings.upsertProvider(ProviderConfig(id: 'slow', kind: 'fake'));
          final slow = container.read(llmRegistryProvider)['slow']!;
          final call = slow.start(
            LlmRequest(messages: [const LlmMessage(LlmRole.user, 'hi there')]),
          );
          settings.upsertProvider(lan.copyWith(defaultModel: () => 'edited'));
          final result = await call.done;
          expect(result.finish, LlmFinish.stop);
          expect(result.text, 'hi there');
        },
      );

      test('a configured provider may take over a built-in id', () {
        final container = make();
        container
            .read(settingsProvider.notifier)
            .upsertProvider(
              ProviderConfig(id: 'fake', kind: 'fake', defaultModel: 'mine'),
            );
        expect(container.read(llmRegistryProvider).keys, ['fake']);
        expect(
          container.read(llmRegistryProvider)['fake']!.defaultModel,
          'mine',
        );
      });

      test('an unknown kind is kept, named, and not built', () {
        final container = make();
        final settings = container.read(settingsProvider.notifier);
        settings.upsertProvider(ProviderConfig(id: 'cloud', kind: 'future'));
        settings.selectLlm('cloud');
        expect(container.read(llmRegistryProvider).keys, ['fake']);
        expect(container.read(activeLlmProvider), isNull);
        expect(
          container.read(llmStatusProvider),
          "provider 'cloud' has kind 'future', which this sai cannot build — "
          'local only',
        );
        expect(make().read(settingsProvider).provider('cloud')?.kind, 'future');
      });

      test('removing a provider clears its selection', () {
        final container = make();
        final settings = container.read(settingsProvider.notifier);
        settings.upsertProvider(lan);
        settings.selectLlm('lan');
        settings.removeProvider('lan');
        expect(container.read(settingsProvider).llm, isNull);
        expect(container.read(llmRegistryProvider).keys, ['fake']);
        expect(container.read(llmStatusProvider), noProviderStatus);
      });

      test('credential status follows the store and the configuration', () {
        final container = make();
        final settings = container.read(settingsProvider.notifier);
        expect(
          container.read(credentialStatusProvider('fake')),
          CredentialStatus.none,
        );
        expect(
          container.read(credentialStatusProvider('nope')),
          CredentialStatus.none,
        );
        settings.upsertProvider(lan);
        settings.selectLlm('lan');
        final seen = <String>[];
        container.listen(llmStatusProvider, (_, next) => seen.add(next));
        expect(
          container.read(credentialStatusProvider('lan')),
          CredentialStatus.missing,
        );

        container
            .read(credentialsProvider.notifier)
            .set('lan', 'sk-test-value');
        expect(
          container.read(credentialStatusProvider('lan')),
          CredentialStatus.set,
        );
        expect(secrets.read('provider:lan'), 'sk-test-value');
        expect(container.read(llmStatusProvider), 'lan (qwen) — local');

        expect(
          container.read(credentialsProvider.notifier).clear('lan'),
          isTrue,
        );
        expect(
          container.read(llmStatusProvider),
          'lan (qwen) — local · no key',
        );
        expect(
          container.read(credentialsProvider.notifier).clear('lan'),
          isFalse,
        );
        expect(
          container.read(credentialStatusProvider('lan')),
          CredentialStatus.missing,
        );
        expect(seen, ['lan (qwen) — local', 'lan (qwen) — local · no key']);

        settings.upsertProvider(lan.copyWith(credential: () => null));
        expect(
          container.read(credentialStatusProvider('lan')),
          CredentialStatus.none,
        );
        expect(container.read(settingsProvider).llm, 'lan');
      });

      test('a keyless or unknown provider refuses a credential', () {
        final container = make();
        final credentials = container.read(credentialsProvider.notifier);
        expect(() => credentials.set('nope', 'v'), throwsStateError);
        container
            .read(settingsProvider.notifier)
            .upsertProvider(ProviderConfig(id: 'local', kind: 'fake'));
        expect(() => credentials.set('local', 'v'), throwsStateError);
        expect(() => credentials.clear('local'), throwsStateError);
        expect(secrets.accounts, isEmpty);
      });

      test('a store that fails reads as unavailable', () {
        final container = make(store: _BrokenStore());
        final settings = container.read(settingsProvider.notifier);
        settings.upsertProvider(lan);
        settings.selectLlm('lan');
        expect(
          container.read(credentialStatusProvider('lan')),
          CredentialStatus.unavailable,
        );
        expect(
          container.read(llmStatusProvider),
          'lan (qwen) — local · keychain unavailable',
        );
      });
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

final class _BrokenStore implements SecretStore {
  @override
  String? read(String account) =>
      throw const SecretStoreException('broken', status: -25293);

  @override
  bool has(String account) => read(account) != null;

  @override
  void write(String account, String value) => read(account);

  @override
  bool delete(String account) => read(account) != null;
}
