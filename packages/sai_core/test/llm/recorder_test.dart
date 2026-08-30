import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sai_core/sai_core.dart';
import 'package:test/test.dart';

LlmRequest ask(String text) =>
    LlmRequest(messages: [LlmMessage(LlmRole.user, text)], temperature: 0.2);

void main() {
  late Directory tmp;
  late Archive archive;
  late LlmRecorder recorder;
  var policy = const PrivacyPolicy();

  var nowMicros = DateTime.utc(2026, 8, 24, 10).microsecondsSinceEpoch;
  DateTime clock() {
    nowMicros += 1000000;
    return DateTime.fromMicrosecondsSinceEpoch(nowMicros, isUtc: true);
  }

  setUp(() async {
    policy = const PrivacyPolicy();
    nowMicros = DateTime.utc(2026, 8, 24, 10).microsecondsSinceEpoch;
    tmp = Directory.systemTemp.createTempSync('sai_llm_recorder_test');
    archive = await Archive.open(tmp, clock: clock);
    recorder = LlmRecorder(
      archive: archive,
      source: 'sai/test',
      clock: clock,
      policy: () => policy,
    );
  });

  tearDown(() async {
    await archive.close();
    tmp.deleteSync(recursive: true);
  });

  List<Map<String, Object?>> lines() {
    final dir = Directory('${tmp.path}/events');
    if (!dir.existsSync()) return const [];
    final files = dir.listSync().whereType<File>().toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    return [
      for (final file in files)
        for (final line in file.readAsStringSync().split('\n'))
          if (line.isNotEmpty) jsonDecode(line) as Map<String, Object?>,
    ];
  }

  test('a successful call is request, response and usage', () async {
    final call = await recorder.start(FakeLlmProvider(), ask('hello world'));
    final result = await call.done;
    expect(result.text, 'hello world');

    final log = lines();
    expect(log.map((l) => l['type']), [
      'provider.request',
      'provider.response',
      'provider.usage',
    ]);
    expect(log.map((l) => l['actor']), ['system', 'assistant', 'system']);
    expect(log.every((l) => l['source'] == 'sai/test'), isTrue);

    final request = log[0];
    expect(request['payload'], {
      'messages': [
        {'role': 'user', 'text': 'hello world'},
      ],
      'temperature': 0.2,
      'context_hash': call.contextHash.toString(),
    });
    expect(
      call.contextHash,
      contextHash(const [LlmMessage(LlmRole.user, 'hello world')]),
    );
    expect(request['model'], {'provider': 'fake', 'id': 'fake-1'});
    expect(request.containsKey('refs'), isFalse);

    final response = log[1];
    expect(response['payload'], {'text': 'hello world', 'finish': 'stop'});
    expect(response['model'], {
      'provider': 'fake',
      'id': 'fake-1',
      'version': 'fake-1',
      'request_id': 'fake-req-1',
    });
    expect(response['refs'], [call.request.toString()]);

    final usage = log[2];
    expect(usage['payload'], {
      'finish': 'stop',
      'duration_ms': isA<int>(),
      'prompt_tokens': 2,
      'completion_tokens': 2,
      'total_tokens': 4,
    });
    expect((usage['payload'] as Map)['duration_ms'], greaterThan(0));
    expect(usage['refs'], [call.request.toString(), call.response.toString()]);
    expect(usage['model'], response['model']);
    expect(call.usage, isNotNull);
  });

  group('the privacy policy (#27)', () {
    LlmRequest withTasks(String text) => LlmRequest(
      messages: [LlmMessage(LlmRole.user, text)],
      taskContext: 'Today: buy milk',
    );

    /// A cloud fake that echoes every message it was given, so the test
    /// reads what the provider saw.
    FakeLlmProvider cloud() => FakeLlmProvider(
      id: 'cloudy',
      privacy: LlmPrivacy.cloud,
      script: (r) =>
          r.messages.map((m) => '${m.role.name}:${m.text}').join(' '),
    );

    test('a cloud call with sharing off withholds the context', () async {
      final call = await recorder.start(cloud(), withTasks('due?'));
      expect(call.taskContextWithheld, isTrue);
      expect(call.decision, isNotNull);
      final result = await call.done;
      expect(result.text, 'user:due?', reason: 'the provider never saw it');

      final log = lines();
      expect(log.map((l) => l['type']), [
        'policy.decision',
        'provider.request',
        'provider.response',
        'provider.usage',
      ]);
      final decision = log[0];
      expect(decision['actor'], 'system');
      expect(decision['payload'], {
        'privacy': 'cloud',
        'share_tasks': false,
        'task_context': 'withheld',
      });
      expect(decision['model'], {'provider': 'cloudy', 'id': 'fake-1'});
      expect(decision.containsKey('refs'), isFalse);
      final request = log[1];
      expect(request['refs'], [call.decision.toString()]);
      expect(request['payload'], {
        'messages': [
          {'role': 'user', 'text': 'due?'},
        ],
        'context_hash': call.contextHash.toString(),
      });
      // The hash names what was sent, so a withheld list changes it.
      expect(
        call.contextHash,
        contextHash(const [LlmMessage(LlmRole.user, 'due?')]),
      );
      expect(jsonEncode(log), isNot(contains('buy milk')));
    });

    test('a cloud call with sharing on sends it as a system message', () async {
      policy = const PrivacyPolicy(shareTasksWithCloud: true);
      final call = await recorder.start(cloud(), withTasks('due?'));
      expect(call.taskContextWithheld, isFalse);
      final result = await call.done;
      expect(result.text, 'system:Today: buy milk user:due?');
      final log = lines();
      expect(log[0]['payload'], {
        'privacy': 'cloud',
        'share_tasks': true,
        'task_context': 'sent',
      });
      expect(log[1]['payload'], {
        'messages': [
          {'role': 'system', 'text': 'Today: buy milk'},
          {'role': 'user', 'text': 'due?'},
        ],
        'context_hash': call.contextHash.toString(),
      });
      expect(call.contextHash, contextHash(withTasks('due?').sent));
    });

    test('a cloud call without context still records the decision', () async {
      final call = await recorder.start(cloud(), ask('hi'));
      await call.done;
      expect(call.taskContextWithheld, isFalse);
      expect(lines()[0]['payload'], {
        'privacy': 'cloud',
        'share_tasks': false,
        'task_context': 'none',
      });
      expect(lines(), hasLength(4));
    });

    test('a local call has no decision line and keeps its context', () async {
      final local = FakeLlmProvider(
        script: (r) => r.messages.map((m) => m.text).join('|'),
      );
      final call = await recorder.start(local, withTasks('due?'));
      expect(call.decision, isNull);
      expect(call.taskContextWithheld, isFalse);
      final result = await call.done;
      expect(result.text, 'Today: buy milk|due?');
      final log = lines();
      expect(log.map((l) => l['type']), [
        'provider.request',
        'provider.response',
        'provider.usage',
      ]);
      expect(log[0].containsKey('refs'), isFalse);
      expect((log[0]['payload'] as Map)['messages'], [
        {'role': 'system', 'text': 'Today: buy milk'},
        {'role': 'user', 'text': 'due?'},
      ]);
    });

    test('sharing on keeps compact history but never catalog turns', () async {
      policy = const PrivacyPolicy(shareTasksWithCloud: true);
      final call = await recorder.start(
        cloud(),
        LlmRequest(
          messages: const [
            LlmMessage(LlmRole.user, 'due?'),
            LlmMessage(
              LlmRole.assistant,
              'Call mom @today',
              provenance: TaskProvenance.compact,
            ),
            LlmMessage(LlmRole.user, 'and the trash?'),
            LlmMessage(
              LlmRole.assistant,
              'Old secret plan',
              provenance: TaskProvenance.catalog,
            ),
            LlmMessage(LlmRole.user, 'now?'),
          ],
          taskContext: 'Today: buy milk',
        ),
      );
      final result = await call.done;
      expect(result.text, contains('Call mom'));
      expect(result.text, contains('Today: buy milk'));
      expect(result.text, isNot(contains('Old secret plan')));
      expect(jsonEncode(lines()), isNot(contains('Old secret plan')));
    });

    test('sharing off drops task-bearing history without a context', () async {
      policy = const PrivacyPolicy();
      final call = await recorder.start(
        cloud(),
        LlmRequest(
          messages: const [
            LlmMessage(LlmRole.user, 'due?'),
            LlmMessage(
              LlmRole.assistant,
              'Call mom @today',
              provenance: TaskProvenance.compact,
            ),
            LlmMessage(LlmRole.user, 'now?'),
          ],
        ),
      );
      final result = await call.done;
      expect(result.text, 'user:due? user:now?');
      expect(jsonEncode(lines()), isNot(contains('Call mom')));
      // Nothing was withheld — the request carried no context — but the
      // history still went without its task-bearing turns.
      expect(call.taskContextWithheld, isFalse);
    });

    test('the policy is read when the call starts, not before', () async {
      final first = await recorder.start(cloud(), withTasks('a'));
      await first.done;
      policy = const PrivacyPolicy(shareTasksWithCloud: true);
      final second = await recorder.start(cloud(), withTasks('b'));
      await second.done;
      expect(first.taskContextWithheld, isTrue);
      expect(second.taskContextWithheld, isFalse);
      expect((await archive.verify()).count, 8);
    });
  });

  test('done resolves after the archive has the lines', () async {
    final call = await recorder.start(FakeLlmProvider(), ask('x'));
    await call.done;
    expect(lines(), hasLength(3));
    expect((await archive.verify()).count, 3);
  });

  test('a call nobody listens to is still fully recorded', () async {
    final call = await recorder.start(FakeLlmProvider(), ask('a b c'));
    await call.done;
    expect(call.text, 'a b c');
    expect(lines(), hasLength(3));
  });

  test('deltas are re-broadcast and text accumulates', () async {
    final call = await recorder.start(FakeLlmProvider(), ask('a b'));
    final one = <String>[];
    final two = <String>[];
    call.deltas.listen((d) => one.add(d.text));
    call.deltas.listen((d) => two.add(d.text));
    await call.done;
    expect(one, ['a ', 'b']);
    expect(two, one);
  });

  test('a cancelled call records the partial text as a response', () async {
    final call = await recorder.start(FakeLlmProvider(), ask('one two three'));
    call.deltas.listen((_) => call.cancel());
    final result = await call.done;
    expect(result.finish, LlmFinish.cancelled);
    final log = lines();
    expect(log.map((l) => l['type']), [
      'provider.request',
      'provider.response',
      'provider.usage',
    ]);
    expect(log[1]['payload'], {'text': 'one ', 'finish': 'cancelled'});
    expect((log[2]['payload'] as Map)['finish'], 'cancelled');
  });

  test('a failed call records a failure and still the usage', () async {
    const failure = LlmFailure(
      LlmFailureKind.unreachable,
      'connection refused',
      endpoint: 'http://lan:8080',
    );
    final fake = FakeLlmProvider(failWith: failure, failAfter: 1);
    final call = await recorder.start(fake, ask('one two'));
    final result = await call.done;
    expect(result.finish, LlmFinish.failed);
    final log = lines();
    expect(log.map((l) => l['type']), [
      'provider.request',
      'provider.failure',
      'provider.usage',
    ]);
    expect(log[1]['actor'], 'system');
    expect(log[1]['payload'], {
      'kind': 'unreachable',
      'message': 'connection refused',
      'endpoint': 'http://lan:8080',
      'text': 'one ',
    });
    expect(log[1]['refs'], [call.request.toString()]);
    expect(call.response, isNull);
    expect(log[2]['refs'], [call.request.toString()]);
    expect((log[2]['payload'] as Map)['finish'], 'failed');
  });

  test('a failure endpoint is written as its origin, nothing more', () async {
    for (final (given, written) in [
      (
        'https://u:sk-x@lan.example:8443/v1?key=sk-x#f',
        'https://lan.example:8443',
      ),
      ('http://[::1]:8080/v1/chat', 'http://[::1]:8080'),
      ('http://localhost/v1', 'http://localhost'),
      ('not a url', 'unparseable endpoint'),
    ]) {
      final fake = FakeLlmProvider(
        failWith: LlmFailure(
          LlmFailureKind.credential,
          'no key stored for this endpoint',
          endpoint: given,
        ),
      );
      final call = await recorder.start(fake, ask('x'));
      await call.done;
      final line = lines().last;
      expect(line['type'], 'provider.usage');
      final failure = lines()[lines().length - 2];
      expect(failure['type'], 'provider.failure');
      expect((failure['payload'] as Map)['endpoint'], written);
      expect((failure['payload'] as Map)['kind'], 'credential');
      expect(jsonEncode(failure), isNot(contains('sk-x')));
    }
  });

  test('a provider that throws from start is recorded as internal', () async {
    final call = await recorder.start(_ThrowingProvider(), ask('x'));
    final result = await call.done;
    expect(result.finish, LlmFinish.failed);
    expect(result.failure?.kind, LlmFailureKind.internal);
    final log = lines();
    expect(log.map((l) => l['type']), [
      'provider.request',
      'provider.failure',
      'provider.usage',
    ]);
    expect((log[1]['payload'] as Map)['kind'], 'internal');
    expect(
      (log[1]['payload'] as Map)['message'],
      'provider.start threw: StateError',
      reason: 'the type, never the text, which could quote a key',
    );
    expect(log[1]['model'], {'provider': 'throwing', 'id': 'm'});
  });

  test('a provider whose stream errors is recorded as internal', () async {
    final call = await recorder.start(_ErroringProvider(), ask('x'));
    final result = await call.done;
    expect(result.finish, LlmFinish.failed);
    expect(result.failure?.kind, LlmFailureKind.internal);
    expect(result.text, 'partial');
    final log = lines();
    expect(log[1]['type'], 'provider.failure');
    expect((log[1]['payload'] as Map)['text'], 'partial');
  });

  test('a response too long for a line is cut and marked', () async {
    final long = 'x' * (maxRecordedTextBytes + 10);
    final fake = FakeLlmProvider(script: (_) => long);
    final call = await recorder.start(fake, ask('x'));
    final result = await call.done;
    expect(result.text, long, reason: 'the caller still gets everything');
    final log = lines();
    final payload = log[1]['payload'] as Map;
    final text = payload['text'] as String;
    expect(text.length, lessThan(long.length));
    expect(text.length, greaterThan(maxRecordedTextBytes - 200));
    expect(payload['truncated'], long.length);
    expect(
      utf8.encode(jsonEncode(payload)).length,
      lessThanOrEqualTo(maxRecordedTextBytes),
    );
    expect(payload['finish'], 'stop');
  });

  test('truncation never splits a rune', () async {
    final long = '€' * (maxRecordedTextBytes ~/ 3 + 10);
    final fake = FakeLlmProvider(script: (_) => long);
    final call = await recorder.start(fake, ask('x'));
    await call.done;
    final text = (lines()[1]['payload'] as Map)['text'] as String;
    expect(utf8.encode(text).length, lessThanOrEqualTo(maxRecordedTextBytes));
    expect(text.runes.every((r) => r == 0x20AC), isTrue);
  });

  test(
    'an archive that refuses the response fails the call, quietly',
    () async {
      final fake = FakeLlmProvider(delta: const Duration(milliseconds: 5));
      final call = await recorder.start(fake, ask('one two'));
      // Pull the log out from under the recorder mid-call.
      Directory('${tmp.path}/events').deleteSync(recursive: true);
      final result = await call.done;
      expect(result.finish, LlmFinish.failed);
      expect(result.failure?.kind, LlmFailureKind.archive);
      expect(result.text, 'one two', reason: 'the answer itself is kept');
      expect(call.archiveError, isA<FileSystemException>());
      expect(call.response, isNull);
      expect(await call.deltas.isEmpty, isTrue, reason: 'the stream closed');
    },
  );

  test('escape-heavy text is cut to fit the encoded line', () async {
    final long = '\\"' * (maxRecordedTextBytes ~/ 2);
    final fake = FakeLlmProvider(script: (_) => long);
    final call = await recorder.start(fake, ask('x'));
    await call.done;
    final log = lines();
    expect(log, hasLength(3));
    final payload = log[1]['payload'] as Map;
    expect(payload['truncated'], utf8.encode(long).length);
    final line = File(Directory('${tmp.path}/events').listSync().single.path)
        .readAsLinesSync()[1];
    expect(utf8.encode(line).length, lessThan(maxLineBytes));
    expect((payload['text'] as String).length, greaterThan(1000));
  });

  test('a huge failure message is cut, never lost', () async {
    final failure = LlmFailure(LlmFailureKind.rejected, 'm' * (700 << 10));
    final fake = FakeLlmProvider(failWith: failure);
    final call = await recorder.start(fake, ask('x'));
    await call.done;
    final log = lines();
    expect(log.map((l) => l['type']), [
      'provider.request',
      'provider.failure',
      'provider.usage',
    ]);
    final message = (log[1]['payload'] as Map)['message'] as String;
    expect(message.length, maxRecordedMessageBytes);
  });

  test('a request that cannot be recorded is not sent', () async {
    final fake = FakeLlmProvider();
    final huge = ask('y' * (maxRecordedTextBytes + 1));
    await expectLater(recorder.start(fake, huge), throwsArgumentError);
    expect(fake.requests, 0);
    expect(lines(), isEmpty);
  });

  test('assembly measures the recorded request to the byte', () async {
    final request = LlmRequest(
      messages: const [LlmMessage(LlmRole.user, 'due? — "quoted" ż')],
      taskContext: 'Today: buy milk',
    );
    final call = await recorder.start(FakeLlmProvider(), request);
    await call.done;
    final payload = lines()[0]['payload'];
    expect(
      utf8.encode(jsonEncode(payload)).length,
      recordedRequestBytes(request),
    );
  });

  test('the request line exists before the provider is started', () async {
    final fake = _SpyProvider(() => lines().length);
    final call = await recorder.start(fake, ask('x'));
    expect(fake.linesAtStart, 1);
    await call.done;
  });
  test('a withholding call drops task-bearing history too', () async {
    policy = const PrivacyPolicy();
    final call = await recorder.start(
      FakeLlmProvider(
        id: 'cloudy',
        privacy: LlmPrivacy.cloud,
        script: (r) =>
            r.messages.map((m) => '${m.role.name}:${m.text}').join(' '),
      ),
      LlmRequest(
        messages: const [
          LlmMessage(LlmRole.user, 'due?'),
          LlmMessage(
            LlmRole.assistant,
            'Call mom @today',
            provenance: TaskProvenance.compact,
          ),
          LlmMessage(LlmRole.user, 'and?'),
        ],
        taskContext: 'Today: Call mom',
      ),
    );
    final result = await call.done;
    expect(result.text, 'user:due? user:and?');
    expect(jsonEncode(lines()), isNot(contains('Call mom')));
    expect(call.taskContextWithheld, isTrue);
  });

  test('a failed call still records the reasoning that came', () async {
    final call = await recorder.start(
      FakeLlmProvider(
        reasoning: (_) => 'hmm',
        failWith: const LlmFailure(LlmFailureKind.internal, 'boom'),
      ),
      ask('go'),
    );
    await call.done;
    final failure = lines()[1];
    expect(failure['type'], 'provider.failure');
    expect(failure['payload'], containsPair('reasoning', 'hmm'));
  });

  test('reasoning is recorded beside the answer, apart from it', () async {
    final call = await recorder.start(
      FakeLlmProvider(
        script: (_) => 'ready.',
        reasoning: (_) => 'let me think',
      ),
      ask('go'),
    );
    final kinds = <bool>[];
    call.deltas.listen((d) => kinds.add(d.reasoning));
    final result = await call.done;
    expect(kinds, [true, true, true, false]);
    expect(call.reasoning, 'let me think');
    expect(call.text, 'ready.');
    expect(result.reasoning, 'let me think');
    final response = lines()[1];
    expect(response['type'], 'provider.response');
    expect(response['payload'], {
      'text': 'ready.',
      'finish': 'stop',
      'reasoning': 'let me think',
    });
  });

  test('long reasoning is clipped with a marker', () async {
    final long = 'y' * (maxRecordedReasoningBytes + 10);
    final call = await recorder.start(
      FakeLlmProvider(script: (_) => 'ok', reasoning: (_) => long),
      ask('go'),
    );
    await call.done;
    final payload = lines()[1]['payload']! as Map;
    expect((payload['reasoning'] as String).length, maxRecordedReasoningBytes);
    expect(payload['reasoning_truncated'], long.length);
  });
}

final class _ThrowingProvider implements LlmProvider {
  @override
  String get id => 'throwing';
  @override
  String get displayName => 'throwing';
  @override
  LlmPrivacy get privacy => LlmPrivacy.local;
  @override
  String get defaultModel => 'm';
  @override
  LlmCall start(LlmRequest request) => throw StateError('boom');
  @override
  Future<void> close() async {}
}

/// Emits one delta, then an error on the stream, then finishes normally
/// — the shape of an adapter bug the recorder must not trust.
final class _ErroringProvider implements LlmProvider {
  @override
  String get id => 'erroring';
  @override
  String get displayName => 'erroring';
  @override
  LlmPrivacy get privacy => LlmPrivacy.local;
  @override
  String get defaultModel => 'm';
  @override
  LlmCall start(LlmRequest request) => _ErroringCall();
  @override
  Future<void> close() async {}
}

final class _ErroringCall implements LlmCall {
  _ErroringCall() {
    scheduleMicrotask(() async {
      _controller.add(const LlmDelta('partial'));
      _controller.addError(StateError('bad chunk'));
      await _controller.close();
      _done.complete(
        LlmResult(
          text: 'partial',
          finish: LlmFinish.stop,
          model: const ModelRef(provider: 'erroring', id: 'm'),
        ),
      );
    });
  }
  final _controller = StreamController<LlmDelta>();
  final _done = Completer<LlmResult>();
  @override
  Stream<LlmDelta> get deltas => _controller.stream;
  @override
  Future<LlmResult> get done => _done.future;
  @override
  void cancel() {}
}

final class _SpyProvider implements LlmProvider {
  _SpyProvider(this._count);
  final int Function() _count;
  final _inner = FakeLlmProvider(id: 'spy');
  int linesAtStart = -1;
  @override
  String get id => _inner.id;
  @override
  String get displayName => _inner.displayName;
  @override
  LlmPrivacy get privacy => _inner.privacy;
  @override
  String get defaultModel => _inner.defaultModel;
  @override
  LlmCall start(LlmRequest request) {
    linesAtStart = _count();
    return _inner.start(request);
  }

  @override
  Future<void> close() => _inner.close();
}
