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

  var nowMicros = DateTime.utc(2026, 8, 24, 10).microsecondsSinceEpoch;
  DateTime clock() {
    nowMicros += 1000000;
    return DateTime.fromMicrosecondsSinceEpoch(nowMicros, isUtc: true);
  }

  setUp(() async {
    nowMicros = DateTime.utc(2026, 8, 24, 10).microsecondsSinceEpoch;
    tmp = Directory.systemTemp.createTempSync('sai_llm_recorder_test');
    archive = await Archive.open(tmp, clock: clock);
    recorder = LlmRecorder(archive: archive, source: 'sai/test', clock: clock);
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
    });
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

  test('the request line exists before the provider is started', () async {
    final fake = _SpyProvider(() => lines().length);
    final call = await recorder.start(fake, ask('x'));
    expect(fake.linesAtStart, 1);
    await call.done;
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
