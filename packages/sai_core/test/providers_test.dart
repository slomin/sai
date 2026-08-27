import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:riverpod/misc.dart' show Override, ProviderException;
import 'package:riverpod/riverpod.dart';
import 'package:sai_core/sai_core.dart';
import 'package:test/test.dart';

import 'llm/stub_server.dart';

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

    test('todayProvider samples state and its deadline from one instant', () {
      fakeAsync((async) {
        var calls = 0;
        final container = ProviderContainer.test(
          overrides: [
            clockProvider.overrideWithValue(() {
              calls++;
              return calls == 1
                  ? DateTime(2026, 8, 24, 23, 59, 59, 999)
                  : DateTime(2026, 8, 25);
            }),
          ],
        );
        expect(container.read(todayProvider), const CalendarDate(2026, 8, 24));
        async.elapse(const Duration(milliseconds: 1));
        expect(container.read(todayProvider), const CalendarDate(2026, 8, 25));
        container.dispose();
      });
    });

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

    test('reload() surfaces appends made behind the store', () async {
      final tmp = Directory.systemTemp.createTempSync('sai_providers_test');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final container = ProviderContainer.test(
        overrides: [
          archiveRootProvider.overrideWithValue(tmp),
          eventSourceProvider.overrideWithValue('sai/test'),
        ],
      );
      final notifier = container.read(tasksProvider.notifier);
      expect(notifier.reload, throwsStateError);
      await container.read(tasksProvider.future);

      // Another process: its own archive handle and store over the root.
      final other = await Archive.open(tmp);
      final otherStore = await TaskStore.open(other, source: 'sai/app');
      await otherStore.createTask(title: 'from the app');
      otherStore.dispose();
      await other.close();

      expect(container.read(tasksProvider).requireValue.tasks, isEmpty);
      await notifier.reload();
      expect(
        container.read(tasksProvider).requireValue.tasks.values.single.title,
        'from the app',
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
      'a store opened after provider disposal is immediately closed',
      () async {
        final tmp = Directory.systemTemp.createTempSync('sai_providers_test');
        addTearDown(() => tmp.deleteSync(recursive: true));
        final archive = await Archive.open(tmp);
        addTearDown(archive.close);
        final lateStore = await TaskStore.open(archive, source: 'sai/test');
        final opening = Completer<TaskStore>();
        final started = Completer<void>();
        final container = ProviderContainer.test(
          overrides: [
            archiveRootProvider.overrideWithValue(tmp),
            eventSourceProvider.overrideWithValue('sai/test'),
            taskStoreOpenerProvider.overrideWithValue((
              archive, {
              required source,
            }) {
              started.complete();
              return opening.future;
            }),
          ],
        );
        final notifier = container.read(tasksProvider.notifier);
        final build = container.read(tasksProvider.future);
        await started.future;

        container.dispose();
        opening.complete(lateStore);
        await build;

        expect(() => notifier.store, throwsStateError);
        expect(lateStore.hasChangeListeners, isFalse);
        await expectLater(
          lateStore.createTask(title: 'too late'),
          throwsA(isA<StateError>()),
        );
        await expectLater(lateStore.reload(), throwsA(isA<StateError>()));
      },
    );

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
    final taskA = BlobRef.sha256OfBytes([1]);

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

    test(
      'archiveLineCountProvider counts every writer, not just tasks',
      () async {
        final tmp = Directory.systemTemp.createTempSync('sai_archive_count');
        addTearDown(() => tmp.deleteSync(recursive: true));
        final container = ProviderContainer.test(
          overrides: [
            archiveRootProvider.overrideWithValue(tmp),
            eventSourceProvider.overrideWithValue(EventSources.tui),
          ],
        );
        container.listen(archiveLineCountProvider, (_, _) {});
        expect(await container.read(archiveLineCountProvider.future), 0);
        final store = container.read(tasksProvider.notifier).store;
        await store.createTask(title: 'one');
        expect(await container.read(archiveLineCountProvider.future), 1);
        // A line no task command wrote still counts once the tasks move.
        final archive = await container.read(archiveProvider.future);
        await archive.append(
          EventDraft(
            type: 'chat.message',
            actor: Actor.user,
            source: 'sai/tui',
            payload: {},
          ),
        );
        await store.createTask(title: 'two');
        expect(await container.read(archiveLineCountProvider.future), 3);
      },
    );

    test('selectedTaskProvider starts empty, selects and clears', () {
      final container = ProviderContainer.test();
      expect(container.read(selectedTaskProvider), isNull);
      container.read(selectedTaskProvider.notifier).select(taskA);
      expect(container.read(selectedTaskProvider), taskA);
      container.read(selectedTaskProvider.notifier).clear();
      expect(container.read(selectedTaskProvider), isNull);
    });

    test('selectedTaskProvider is independent of the section', () {
      final container = ProviderContainer.test();
      container.read(selectedTaskProvider.notifier).select(taskA);
      container
          .read(selectedSectionProvider.notifier)
          .select(const ListSection(TaskList.inbox));
      expect(container.read(selectedTaskProvider), taskA);
    });

    test('chatVisibleProvider starts shown and toggles', () {
      final container = ProviderContainer.test();
      expect(container.read(chatVisibleProvider), isTrue);
      container.read(chatVisibleProvider.notifier).toggle();
      expect(container.read(chatVisibleProvider), isFalse);
      container.read(chatVisibleProvider.notifier).toggle();
      expect(container.read(chatVisibleProvider), isTrue);
      container.read(chatVisibleProvider.notifier).set(false);
      expect(container.read(chatVisibleProvider), isFalse);
    });

    test('collapsedAreasProvider toggles and stays quiet on no change', () {
      final container = ProviderContainer.test();
      final areaA = BlobRef.sha256OfBytes([10]);
      final areaB = BlobRef.sha256OfBytes([11]);
      var notified = 0;
      container.listen(collapsedAreasProvider, (_, _) => notified++);
      expect(container.read(collapsedAreasProvider), isEmpty);
      final areas = container.read(collapsedAreasProvider.notifier);
      areas.toggle(areaA);
      expect(container.read(collapsedAreasProvider), {areaA});
      areas.set([areaA]);
      areas.set({areaA});
      expect(notified, 1, reason: 'the same set is not a change');
      areas.set([areaB, areaA]);
      expect(container.read(collapsedAreasProvider), {areaA, areaB});
      areas.toggle(areaA);
      expect(container.read(collapsedAreasProvider), {areaB});
      expect(notified, 3);
    });

    test('workspaceStateProvider mirrors the workspace in settings form', () {
      final container = ProviderContainer.test();
      final areaA = BlobRef.sha256OfBytes([10]);
      expect(
        container.read(workspaceStateProvider),
        const WorkspaceState(section: 'list:today', assistantVisible: true),
      );
      container
          .read(selectedSectionProvider.notifier)
          .select(AreaSection(areaA));
      container.read(selectedTaskProvider.notifier).select(taskA);
      container.read(collapsedAreasProvider.notifier).toggle(areaA);
      container.read(chatVisibleProvider.notifier).toggle();
      expect(
        container.read(workspaceStateProvider),
        WorkspaceState(
          section: 'area:$areaA',
          task: '$taskA',
          collapsedAreas: ['$areaA'],
          assistantVisible: false,
        ),
      );
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
      bool shipped = false,
    }) => ProviderContainer.test(
      overrides: [
        archiveRootProvider.overrideWithValue(root),
        settingsFileProvider.overrideWithValue(
          File('${tmp.path}/settings.json'),
        ),
        eventSourceProvider.overrideWithValue('sai/test'),
        secretStoreProvider.overrideWithValue(store ?? secrets),
        // The fake alone, nothing selected, unless a test says otherwise.
        if (!shipped) ...[
          builtinLlmsProvider.overrideWithValue([FakeLlmProvider.new]),
          defaultLlmIdProvider.overrideWithValue(null),
        ],
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

    test('the workspace is written, once per change, and read back', () {
      final container = make();
      final settings = container.read(settingsProvider.notifier);
      final file = File('${tmp.path}/settings.json');
      settings.setWorkspace(WorkspaceState.empty);
      expect(file.existsSync(), isFalse, reason: 'nothing to remember');
      const left = WorkspaceState(section: 'trash', assistantVisible: false);
      settings.setWorkspace(left);
      expect(
        file.readAsStringSync(),
        '{"llm":null,"version":0,"workspace":{"assistant_visible":false,'
        '"section":"trash"}}',
      );
      final stamp = file.lastModifiedSync();
      settings.setWorkspace(left);
      expect(file.lastModifiedSync(), stamp, reason: 'no change, no write');
      expect(make().read(settingsProvider).workspace, left);
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

      test('the build ships the fake, LM Studio and the LAN box (#23)', () {
        final container = make(shipped: true);
        final registry = container.read(llmRegistryProvider);
        expect(registry.keys, ['fake', lmStudioProviderId, lanProviderId]);
        final lmstudio = registry[lmStudioProviderId]!;
        expect(lmstudio.displayName, 'lmstudio @ http://127.0.0.1:1234');
        expect(lmstudio.defaultModel, OpenAiCompatibleProvider.loadedModel);
        expect(lmstudio.privacy, LlmPrivacy.local);
        final lan = registry[lanProviderId]!;
        expect(lan.displayName, 'lan @ http://192.168.1.5:8080');
        expect(lan.defaultModel, lanModel);
        expect(lan.privacy, LlmPrivacy.local);
        // Neither takes a key.
        expect(
          container.read(credentialStatusProvider(lanProviderId)),
          CredentialStatus.none,
        );
        // A configured one still takes over.
        container
            .read(settingsProvider.notifier)
            .upsertProvider(
              ProviderConfig(
                id: lanProviderId,
                kind: 'openai_compatible',
                endpoint: 'http://10.0.0.9:8080/v1',
                defaultModel: 'mine',
              ),
            );
        expect(
          container.read(llmRegistryProvider)[lanProviderId]!.displayName,
          'lan @ http://10.0.0.9:8080',
        );
      });

      test('a configured id hides its built-in even when it cannot be '
          'built', () {
        final container = make(shipped: true);
        final settings = container.read(settingsProvider.notifier);
        settings.upsertProvider(
          ProviderConfig(id: lanProviderId, kind: 'future'),
        );
        settings.selectLlm(lanProviderId);
        expect(container.read(llmRegistryProvider).keys, [
          'fake',
          lmStudioProviderId,
        ]);
        expect(container.read(activeLlmProvider), isNull);
        expect(
          container.read(llmStatusProvider),
          unavailableKindStatus(lanProviderId, 'future'),
        );
        settings.upsertProvider(
          ProviderConfig(id: lanProviderId, kind: 'openai_compatible'),
        );
        expect(container.read(activeLlmProvider), isNull);
        expect(
          container.read(llmStatusProvider),
          misconfiguredStatus(lanProviderId, 'endpoint'),
        );
      });

      test('a first run selects LM Studio and writes nothing (#23)', () {
        final file = File('${tmp.path}/settings.json');
        final container = make(shipped: true);
        expect(container.read(settingsProvider).llm, lmStudioProviderId);
        expect(container.read(activeLlmProvider)?.id, lmStudioProviderId);
        expect(file.existsSync(), isFalse);
        expect(
          container.read(llmStatusProvider),
          'lmstudio @ http://127.0.0.1:1234 (loaded model) — local',
        );
        // Choosing none is kept: the file, once it exists, is the word.
        container.read(settingsProvider.notifier).selectLlm(null);
        expect(file.existsSync(), isTrue);
        final again = make(shipped: true);
        expect(again.read(settingsProvider).llm, isNull);
        expect(again.read(llmStatusProvider), noProviderStatus);
      });

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

      test(
        'an openai_compatible provider is built from its endpoint',
        () async {
          final stub = await StubServer.start();
          addTearDown(stub.close);
          stub.routes['POST /v1/chat/completions'] = (req) =>
              StubServer.stream(req, ['ready'], tokensPerSecond: 30);
          stub.routes['GET /v1/models'] = (req) => StubServer.json(req, {
            'data': [
              {'id': 'qwen'},
            ],
          });
          final container = make();
          final settings = container.read(settingsProvider.notifier);
          settings.upsertProvider(
            ProviderConfig(
              id: 'local',
              kind: 'openai_compatible',
              endpoint: stub.v1.toString(),
              defaultModel: 'qwen',
            ),
          );
          settings.selectLlm('local');
          final active = container.read(activeLlmProvider);
          expect(active, isA<OpenAiCompatibleProvider>());
          // Storing a key binds it without rebuilding the provider a call
          // may be running on: the binding is pushed into the live one.
          settings.upsertProvider(
            container
                .read(settingsProvider)
                .provider('local')!
                .copyWith(credential: () => 'provider:local'),
          );
          final keyed = container.read(activeLlmProvider);
          expect(
            identical(keyed, active),
            isFalse,
            reason: 'credential changed',
          );
          container.read(credentialsProvider.notifier).set('local', 'k');
          expect(
            identical(container.read(activeLlmProvider), keyed),
            isTrue,
            reason: 'a key save is not a rebuild',
          );
          expect(
            (container.read(
              activeLlmProvider,
            ) as OpenAiCompatibleProvider).credentialOrigin,
            stub.origin,
          );
          container.read(credentialsProvider.notifier).clear('local');
          settings.upsertProvider(
            container
                .read(settingsProvider)
                .provider('local')!
                .copyWith(credential: () => null),
          );
          expect(
            container.read(llmStatusProvider),
            'local @ ${stub.origin} (qwen) — local',
          );
          final info = await container.read(
            endpointInfoProvider('local').future,
          );
          expect(info.health, EndpointHealth.ok);
          expect(info.models, ['qwen']);
          expect(
            await container.read(endpointInfoProvider('fake').future),
            isA<EndpointInfo>().having(
              (i) => i.health,
              'health',
              EndpointHealth.unknown,
            ),
          );
          final recorder = await container.read(llmRecorderProvider.future);
          final call = await recorder.start(
            container.read(activeLlmProvider)!,
            providerTestRequest(),
          );
          final result = await call.done;
          expect(result.text, 'ready');
          expect(result.usage!.tokensPerSecond, 30);
          expect(stub.requests.last.body, contains(providerTestPrompt));
        },
      );

      test('an openai_compatible provider without what it needs is named', () {
        final container = make();
        final settings = container.read(settingsProvider.notifier);
        settings.upsertProvider(
          ProviderConfig(id: 'bare', kind: 'openai_compatible'),
        );
        settings.selectLlm('bare');
        expect(container.read(llmRegistryProvider).keys, ['fake']);
        expect(container.read(misconfiguredLlmsProvider), {'bare': 'endpoint'});
        expect(misconfiguredNote('endpoint'), 'missing its endpoint');
        expect(
          container.read(llmStatusProvider),
          "provider 'bare' is missing its endpoint — local only",
        );
        settings.upsertProvider(
          ProviderConfig(
            id: 'bare',
            kind: 'openai_compatible',
            endpoint: 'http://127.0.0.1:1/v1',
          ),
        );
        expect(container.read(misconfiguredLlmsProvider), {
          'bare': 'default_model',
        });
        settings.upsertProvider(
          ProviderConfig(
            id: 'bare',
            kind: 'openai_compatible',
            endpoint: 'http://127.0.0.1:1/v1',
            defaultModel: 'm',
          ),
        );
        expect(container.read(misconfiguredLlmsProvider), isEmpty);
        expect(container.read(llmRegistryProvider).keys, ['fake', 'bare']);
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

      test('storing a key binds it to the endpoint origin of the moment', () {
        final container = make();
        final settings = container.read(settingsProvider.notifier);
        settings.upsertProvider(
          ProviderConfig(
            id: 'lan',
            kind: 'fake',
            endpoint: 'https://lan.example:8443/v1',
            credential: 'provider:lan',
          ),
        );
        expect(
          container.read(settingsProvider).provider('lan')!.keyBound,
          isFalse,
        );
        // The binding is written before the secret: a store that refuses
        // leaves "no key", never a key that can never be sent.
        final refusing = make(store: _RefusingStore());
        refusing
            .read(settingsProvider.notifier)
            .upsertProvider(
              ProviderConfig(
                id: 'lan',
                kind: 'fake',
                endpoint: 'https://lan.example:8443/v1',
                credential: 'provider:lan',
              ),
            );
        expect(
          () => refusing.read(credentialsProvider.notifier).set('lan', 'k'),
          throwsA(isA<SecretStoreException>()),
        );
        expect(
          refusing.read(settingsProvider).provider('lan')!.credentialOrigin,
          'https://lan.example:8443',
        );
        container.read(credentialsProvider.notifier).set('lan', 'k1');
        final bound = container.read(settingsProvider).provider('lan')!;
        expect(bound.credentialOrigin, 'https://lan.example:8443');
        expect(bound.keyBound, isTrue);
        expect(
          File('${tmp.path}/settings.json').readAsStringSync(),
          contains('"credential_origin":"https://lan.example:8443"'),
        );
        // Moving the endpoint unbinds; entering the key again rebinds.
        settings.upsertProvider(
          bound.copyWith(endpoint: () => 'https://other.example/v1'),
        );
        expect(
          container.read(settingsProvider).provider('lan')!.keyBound,
          isFalse,
        );
        expect(
          container.read(credentialStatusProvider('lan')),
          CredentialStatus.set,
        );
        container.read(credentialsProvider.notifier).set('lan', 'k2');
        expect(
          container.read(settingsProvider).provider('lan')!.credentialOrigin,
          'https://other.example',
        );
        // A provider without an endpoint records nothing.
        settings.upsertProvider(
          ProviderConfig(id: 'f', kind: 'fake', credential: 'provider:f'),
        );
        container.read(credentialsProvider.notifier).set('f', 'k');
        expect(
          container.read(settingsProvider).provider('f')!.credentialOrigin,
          isNull,
        );
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

    group('the privacy policy (#27)', () {
      final cloudy = ProviderConfig(
        id: 'cloudy',
        kind: 'fake',
        privacy: LlmPrivacy.cloud,
      );

      test('follows the settings switch', () {
        final container = make();
        expect(container.read(privacyPolicyProvider), const PrivacyPolicy());
        container.read(settingsProvider.notifier).setShareTasksWithCloud(true);
        expect(
          container.read(privacyPolicyProvider),
          const PrivacyPolicy(shareTasksWithCloud: true),
        );
        expect(
          jsonDecode(File('${tmp.path}/settings.json').readAsStringSync()),
          containsPair('share_tasks_with_cloud', true),
        );
      });

      test('a configured fake takes its tag from settings', () {
        final container = make();
        final settings = container.read(settingsProvider.notifier);
        settings.upsertProvider(cloudy);
        expect(
          container.read(llmRegistryProvider)['cloudy']!.privacy,
          LlmPrivacy.cloud,
        );
        expect(
          container.read(llmRegistryProvider)['fake']!.privacy,
          LlmPrivacy.local,
        );
      });

      test('an openai_compatible endpoint is tagged by its host', () {
        final container = make();
        final settings = container.read(settingsProvider.notifier);
        ProviderConfig at(String id, String endpoint, {LlmPrivacy? privacy}) =>
            ProviderConfig(
              id: id,
              kind: 'openai_compatible',
              endpoint: endpoint,
              defaultModel: 'm',
              privacy: privacy,
            );
        settings.upsertProvider(at('local', 'http://127.0.0.1:1234/v1'));
        settings.upsertProvider(at('lan', 'https://potato.local:8443/v1'));
        settings.upsertProvider(at('hosted', 'https://api.example.com/v1'));
        settings.upsertProvider(
          at('tunnel', 'https://10.0.0.9/v1', privacy: LlmPrivacy.cloud),
        );
        final registry = container.read(llmRegistryProvider);
        expect(registry['local']!.privacy, LlmPrivacy.local);
        expect(registry['lan']!.privacy, LlmPrivacy.local);
        expect(registry['hosted']!.privacy, LlmPrivacy.cloud);
        expect(registry['tunnel']!.privacy, LlmPrivacy.cloud);
        settings.selectLlm('hosted');
        expect(
          container.read(llmStatusProvider),
          'hosted @ https://api.example.com (m) — cloud · tasks withheld',
        );
        // Re-tagging rebuilds the provider with the new tag.
        settings.upsertProvider(
          at('hosted', 'https://api.example.com/v1', privacy: LlmPrivacy.local),
        );
        expect(
          container.read(llmRegistryProvider)['hosted']!.privacy,
          LlmPrivacy.local,
        );
      });

      test('a recorder held across a rebuild still reads the policy', () async {
        final container = make();
        final settings = container.read(settingsProvider.notifier);
        settings.upsertProvider(cloudy);
        final provider = container.read(llmRegistryProvider)['cloudy']!;
        final recorder = await container.read(llmRecorderProvider.future);
        container.invalidate(archiveProvider);
        await container.read(archiveProvider.future);
        settings.setShareTasksWithCloud(true);
        final call = await recorder.start(
          provider,
          LlmRequest(
            messages: [const LlmMessage(LlmRole.user, 'hi')],
            taskContext: 'Today: x',
          ),
        );
        await call.done;
        expect(call.taskContextWithheld, isFalse);
      });

      test('the status line and the warning say tasks are withheld', () {
        final container = make();
        final settings = container.read(settingsProvider.notifier);
        settings.upsertProvider(cloudy);
        expect(container.read(activeLlmWarningProvider), isNull);
        settings.selectLlm('cloudy');
        expect(
          container.read(llmStatusProvider),
          'cloudy (fake-1) — cloud · tasks withheld',
        );
        expect(
          container.read(activeLlmWarningProvider),
          "cloud provider 'cloudy' will not see your tasks until sharing is on",
        );
        settings.setShareTasksWithCloud(true);
        expect(container.read(llmStatusProvider), 'cloudy (fake-1) — cloud');
        expect(container.read(activeLlmWarningProvider), isNull);
        settings.selectLlm('fake');
        settings.setShareTasksWithCloud(false);
        expect(container.read(llmStatusProvider), 'fake (fake-1) — local');
        expect(container.read(activeLlmWarningProvider), isNull);
      });

      test('the recorder applies the switch as it stands per call', () async {
        final container = make();
        final settings = container.read(settingsProvider.notifier);
        settings.upsertProvider(cloudy);
        final provider = container.read(llmRegistryProvider)['cloudy']!;
        final recorder = await container.read(llmRecorderProvider.future);
        LlmRequest request() => LlmRequest(
          messages: [const LlmMessage(LlmRole.user, 'due?')],
          taskContext: 'Today: x',
        );
        final withheld = await recorder.start(provider, request());
        await withheld.done;
        settings.setShareTasksWithCloud(true);
        final sent = await recorder.start(provider, request());
        await sent.done;
        expect(withheld.taskContextWithheld, isTrue);
        expect(sent.taskContextWithheld, isFalse);
        final archive = await container.read(archiveProvider.future);
        final events = await archive.events().toList();
        final decisions = events
            .where((e) => e.event.type == EventTypes.policyDecision)
            .map((e) => e.event.payload['task_context'])
            .toList();
        expect(decisions, ['withheld', 'sent']);
        expect(events, hasLength(8));
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

final class _RefusingStore implements SecretStore {
  @override
  String? read(String account) => null;
  @override
  bool has(String account) => false;
  @override
  void write(String account, String value) =>
      throw const SecretStoreException('refused');
  @override
  bool delete(String account) => false;
}
