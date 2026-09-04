import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:riverpod/misc.dart' show Override;
import 'package:riverpod/riverpod.dart';
import 'package:sai_core/sai_core.dart';
import 'package:test/test.dart';

/// A local provider the warmer will touch: probeable like a real
/// endpoint, answering like the fake.
final class _Warmy implements LlmProvider, LlmEndpointProbe {
  _Warmy({Duration delta = Duration.zero})
    : _delegate = FakeLlmProvider(id: 'warmy', delta: delta);

  FakeLlmProvider _delegate;
  var probes = 0;

  /// Swaps how calls answer; the id stays `warmy`.
  set answersWith(FakeLlmProvider delegate) => _delegate = delegate;

  @override
  String get id => _delegate.id;
  @override
  String get displayName => _delegate.displayName;
  @override
  LlmPrivacy get privacy => LlmPrivacy.local;
  @override
  String get defaultModel => _delegate.defaultModel;
  @override
  LlmCall start(LlmRequest request) => _delegate.start(request);
  @override
  void releaseIdle() {}

  @override
  Future<void> close() => _delegate.close();
  @override
  Future<EndpointInfo> probe() async {
    probes++;
    return const EndpointInfo(health: EndpointHealth.ok);
  }
}

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('sai_warmer'));
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<ProviderContainer> make(
    _Warmy warmy, {
    Duration? debounce = Duration.zero,
    List<Override> overrides = const [],
  }) async {
    final container = ProviderContainer.test(
      overrides: [
        archiveRootProvider.overrideWithValue(Directory('${tmp.path}/archive')),
        settingsFileProvider.overrideWithValue(File('${tmp.path}/s.json')),
        eventSourceProvider.overrideWithValue('sai/test'),
        secretStoreProvider.overrideWithValue(InMemorySecretStore()),
        builtinLlmsProvider.overrideWithValue([() => warmy]),
        defaultLlmIdProvider.overrideWithValue(null),
        connectionProbeEveryProvider.overrideWithValue(null),
        warmDebounceProvider.overrideWithValue(debounce),
        warmTickEveryProvider.overrideWithValue(null),
        ...overrides,
      ],
    );
    await container.read(tasksProvider.future);
    return container;
  }

  List<Map<String, Object?>> requests(Directory tmp) {
    final dir = Directory('${tmp.path}/archive/events');
    if (!dir.existsSync()) return const [];
    final files = dir.listSync().whereType<File>().toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    return [
      for (final file in files)
        for (final line in file.readAsStringSync().split('\n'))
          if (line.isNotEmpty)
            if (jsonDecode(line) case final Map<String, Object?> map
                when map['type'] == 'provider.request')
              map,
    ];
  }

  List<Map<String, Object?>> allLines(Directory tmp) {
    final dir = Directory('${tmp.path}/archive/events');
    if (!dir.existsSync()) return const [];
    final files = dir.listSync().whereType<File>().toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    return [
      for (final file in files)
        for (final line in file.readAsStringSync().split('\n'))
          if (line.isNotEmpty) jsonDecode(line) as Map<String, Object?>,
    ];
  }

  Future<void> settle() async {
    // Probe microtask, debounce timer at zero, then the warm call.
    for (var i = 0; i < 6; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }

  test('warms the profile+catalog prefix once the endpoint is ready', () async {
    final warmy = _Warmy();
    final c = await make(warmy);
    final store = c.read(tasksProvider.notifier).store;
    await store.createTask(title: 'Feed the gargoyle');
    c.read(settingsProvider.notifier).selectLlm('warmy');
    final sub = c.listen(cacheWarmerProvider, (_, _) {});
    await settle();
    expect(c.read(cacheWarmerProvider).phase, WarmPhase.warm);
    final sent = requests(tmp);
    expect(sent, hasLength(1));
    final payload = sent.single['payload']! as Map<String, Object?>;
    final messages = payload['messages']! as List;
    // Profile, catalog, and the one-word user line chat templates
    // demand — the shared prefix ends before it.
    expect(messages, hasLength(3));
    expect((messages[0] as Map)['text'], defaultProfile);
    expect((messages[1] as Map)['text'], contains('Feed the gargoyle'));
    expect((messages[1] as Map)['text'], contains('TASK CATALOG'));
    expect(messages[2], {'role': 'user', 'text': warmupPrompt});
    expect(payload['max_tokens'], 1);
    sub.close();
  });

  test('warms the provider the order resolved to, and records what it '
      'passed over (#62)', () async {
    final warmy = _Warmy();
    final c = await make(warmy);
    final store = c.read(tasksProvider.notifier).store;
    await store.createTask(title: 'Feed the gargoyle');
    final settings = c.read(settingsProvider.notifier);
    settings.upsertProvider(
      ProviderConfig(id: 'keyed', kind: 'fake', credential: 'provider:keyed'),
    );
    settings.setLlmOrder(['keyed', 'warmy']);
    expect(c.read(activeLlmProvider)?.id, 'warmy');
    final sub = c.listen(cacheWarmerProvider, (_, _) {});
    await settle();
    expect(c.read(cacheWarmerProvider).phase, WarmPhase.warm);
    final sent = requests(tmp);
    expect(sent, hasLength(1), reason: 'the first choice was never asked');
    expect(sent.single['model'], {'provider': 'warmy', 'id': 'fake-1'});
    final log = allLines(tmp);
    final fallback = log.firstWhere((l) => l['type'] == 'policy.fallback');
    expect(fallback['payload'], {
      'first': 'keyed',
      'chosen': 'warmy',
      'skipped': [
        {'provider': 'keyed', 'reason': 'no_key', 'detail': 'no key'},
      ],
    });
    sub.close();
  });

  test('a changed catalog re-warms; an unchanged one does not', () async {
    final warmy = _Warmy();
    final c = await make(warmy);
    final store = c.read(tasksProvider.notifier).store;
    await store.createTask(title: 'One');
    c.read(settingsProvider.notifier).selectLlm('warmy');
    final sub = c.listen(cacheWarmerProvider, (_, _) {});
    await settle();
    expect(requests(tmp), hasLength(1));
    // Nothing changed: reading again schedules nothing new.
    await settle();
    expect(requests(tmp), hasLength(1));
    await store.createTask(title: 'Two');
    await settle();
    final sent = requests(tmp);
    expect(sent, hasLength(2));
    final last = (sent.last['payload']! as Map)['messages']! as List;
    expect((last[1] as Map)['text'], contains('Two'));
    sub.close();
  });

  test('a real turn marks the prefix warm instead of re-sending it', () async {
    final warmy = _Warmy();
    // No scheduling: the only ingestion is the chat turn's own.
    final c = await make(warmy, debounce: null);
    final store = c.read(tasksProvider.notifier).store;
    await store.createTask(title: 'One');
    c.read(settingsProvider.notifier).selectLlm('warmy');
    final sub = c.listen(cacheWarmerProvider, (_, _) {});
    await settle();
    expect(requests(tmp), isEmpty);
    await c.read(chatProvider.notifier).send('due?');
    await settle();
    expect(c.read(cacheWarmerProvider).phase, WarmPhase.warm);
    expect(requests(tmp), hasLength(1), reason: 'the turn, no warm');
    sub.close();
  });

  test(
    'never warms while a turn is running; a task edit cancels a warm',
    () async {
      final warmy = _Warmy(delta: const Duration(milliseconds: 120));
      final c = await make(warmy);
      final store = c.read(tasksProvider.notifier).store;
      await store.createTask(title: 'One');
      c.read(settingsProvider.notifier).selectLlm('warmy');
      final sub = c.listen(cacheWarmerProvider, (_, _) {});
      // Wait for the warm to actually be streaming (slowly), then edit
      // a task under it — condition-polled, not wall-clocked, so a slow
      // runner cannot miss either window (CI flaked at fixed delays).
      await _until(
        () => c.read(cacheWarmerProvider).phase == WarmPhase.warming,
      );
      await store.createTask(title: 'Two');
      await _until(() => c.read(cacheWarmerProvider).phase == WarmPhase.warm);
      final sent = requests(tmp);
      expect(sent, hasLength(2), reason: 'the stale warm, then the fresh one');
      sub.close();
    },
  );

  test('a finished warm lands in the daily totals', () async {
    // The warm's usage line is written by the recorder behind every
    // watcher's back; the warmer bumps the revision so Settings › Usage
    // does not sit stale until an unrelated change (review, #107).
    final warmy = _Warmy();
    final c = await make(warmy);
    final store = c.read(tasksProvider.notifier).store;
    await store.createTask(title: 'One');
    c.read(settingsProvider.notifier).selectLlm('warmy');
    final sub = c.listen(cacheWarmerProvider, (_, _) {});
    final usageSub = c.listen(dailyUsageProvider, (_, _) {});
    await settle();
    expect(c.read(cacheWarmerProvider).phase, WarmPhase.warm);
    final usage = await c.read(dailyUsageProvider.future);
    final today = CalendarDate.fromLocal(DateTime.now());
    expect(usage.onDay(today).single.provider, 'warmy');
    expect(usage.onDay(today).single.calls, 1);
    usageSub.close();
    sub.close();
  });

  test('a re-read of the same archive keeps the warm running', () async {
    // The warm's own lines make the TUI poll and reload every two
    // seconds; a content-identical projection must not cancel it, or
    // one warm becomes a stutter of one-second bursts (measured).
    final warmy = _Warmy(delta: const Duration(milliseconds: 150));
    final c = await make(warmy);
    final store = c.read(tasksProvider.notifier).store;
    await store.createTask(title: 'One');
    c.read(settingsProvider.notifier).selectLlm('warmy');
    final sub = c.listen(cacheWarmerProvider, (_, _) {});
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(c.read(cacheWarmerProvider).phase, WarmPhase.warming);
    await c.read(tasksProvider.notifier).reload();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(c.read(cacheWarmerProvider).phase, WarmPhase.warming);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(c.read(cacheWarmerProvider).phase, WarmPhase.warm);
    expect(requests(tmp), hasLength(1), reason: 'one warm, not a stutter');
    sub.close();
  });

  test('the fake, unprobeable, never warms; disabled never warms', () async {
    final plain = FakeLlmProvider();
    final c = ProviderContainer.test(
      overrides: [
        archiveRootProvider.overrideWithValue(Directory('${tmp.path}/archive')),
        settingsFileProvider.overrideWithValue(File('${tmp.path}/s.json')),
        eventSourceProvider.overrideWithValue('sai/test'),
        secretStoreProvider.overrideWithValue(InMemorySecretStore()),
        builtinLlmsProvider.overrideWithValue([() => plain]),
        defaultLlmIdProvider.overrideWithValue(null),
        connectionProbeEveryProvider.overrideWithValue(null),
        warmDebounceProvider.overrideWithValue(Duration.zero),
        warmTickEveryProvider.overrideWithValue(null),
      ],
    );
    await c.read(tasksProvider.future);
    c.read(settingsProvider.notifier).selectLlm('fake');
    final sub = c.listen(cacheWarmerProvider, (_, _) {});
    await settle();
    expect(requests(tmp), isEmpty);
    expect(c.read(cacheWarmerProvider).phase, WarmPhase.idle);
    sub.close();

    final warmy = _Warmy();
    final off = await make(
      warmy,
      overrides: [warmEnabledProvider.overrideWithValue(false)],
    );
    off.read(settingsProvider.notifier).selectLlm('warmy');
    final sub2 = off.listen(cacheWarmerProvider, (_, _) {});
    await settle();
    expect(off.read(cacheWarmerProvider).phase, WarmPhase.idle);
    sub2.close();
  });

  test('a failed warm goes quiet until something changes', () async {
    final warmy = _Warmy();
    warmy.answersWith = FakeLlmProvider(
      id: 'warmy',
      failWith: const LlmFailure(LlmFailureKind.internal, 'no'),
    );
    final c = await make(warmy);
    final store = c.read(tasksProvider.notifier).store;
    await store.createTask(title: 'One');
    c.read(settingsProvider.notifier).selectLlm('warmy');
    final sub = c.listen(cacheWarmerProvider, (_, _) {});
    await settle();
    expect(c.read(cacheWarmerProvider).phase, WarmPhase.idle);
    final after = requests(tmp).length;
    await settle();
    expect(requests(tmp), hasLength(after), reason: 'no retry loop');
    // A change is a new attempt.
    warmy.answersWith = FakeLlmProvider(id: 'warmy');
    await store.createTask(title: 'Two');
    await settle();
    expect(c.read(cacheWarmerProvider).phase, WarmPhase.warm);
    sub.close();
  });

  test('the words', () {
    expect(warmingWord(null), 'warming up…');
    expect(warmingWord(0.43), 'warming up 43%');
  });
}

/// Polls [ready] with real waits, bounded — deterministic on any
/// runner, unlike a fixed delay.
Future<void> _until(bool Function() ready) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!ready()) {
    if (DateTime.now().isAfter(deadline)) fail('condition never held');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
