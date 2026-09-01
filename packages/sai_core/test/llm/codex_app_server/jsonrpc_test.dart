import 'dart:async';
import 'dart:io';

import 'package:sai_core/sai_core.dart';
import 'package:sai_core/src/llm/codex_app_server/jsonrpc.dart';
import 'package:test/test.dart';

import 'package:sai_core/process_testing.dart';

void main() {
  late ScriptedProcess process;
  late JsonRpcClient client;

  setUp(() {
    process = ScriptedProcess(spawn: Spawn('x', const [], const {}, '/tmp'));
    client = JsonRpcClient(
      process,
      maxLineBytes: 200,
      maxPending: 2,
      requestTimeout: const Duration(milliseconds: 300),
    );
  });

  tearDown(() async {
    await client.close();
  });

  test('requests carry sai\'s ids, no jsonrpc field, and correlate', () async {
    process.onLine = (p, line) {
      if (line['method'] == 'b') p.reply(line['id'], 'B');
      if (line['method'] == 'a') p.reply(line['id'], 'A');
    };
    final a = client.request('a', {'x': 1});
    final b = client.request('b', null);
    expect(await a, 'A');
    expect(await b, 'B');
    expect(process.written, [
      {
        'id': 1,
        'method': 'a',
        'params': {'x': 1},
      },
      {'id': 2, 'method': 'b'},
    ]);
    for (final w in process.written) {
      expect(w, isNot(contains('jsonrpc')));
    }
    expect(process.malformed, isEmpty);
  });

  test(
    'a fragmented line and several lines in one chunk both read whole',
    () async {
      process.onLine = (p, line) {
        final id = line['id'];
        final text = '{"id":$id,"result":{"ok":true}}\n';
        p.emitRaw(text.substring(0, 5));
        p.emitRaw(text.substring(5));
      };
      expect(await client.request('m', null), {'ok': true});
      final seen = <String>[];
      client.notifications.listen((n) => seen.add(n.method));
      process.emitRaw(
        '{"method":"n1","params":{}}\n{"method":"n2","params":{}}\n',
      );
      await Future<void>.delayed(Duration.zero);
      expect(seen, ['n1', 'n2']);
    },
  );

  test(
    'an error answer is a fixed word; the server\'s text is dropped',
    () async {
      process.onLine = (p, line) => p.fail(line['id'], -32600, 'bad sk-canary');
      final error = await client
          .request('m', null)
          .then<Object?>((_) => null, onError: (Object e) => e);
      expect(error, isA<JsonRpcException>());
      final e = error as JsonRpcException;
      expect(e.text, CodexText.rejected);
      expect(e.code, -32600);
      expect(e.method, 'm');
      expect('$e', isNot(contains('sk-canary')));
      process.onLine = (p, line) =>
          p.fail(line['id'], -32001, 'Server overloaded');
      final busy = await client
          .request('m', null)
          .then<Object?>((_) => null, onError: (Object e) => e);
      expect((busy as JsonRpcException).text, CodexText.overloaded);
      expect(busy.isOverloaded, isTrue);
    },
  );

  test('a request outlives its deadline as a timeout', () async {
    final error = await client
        .request('m', null)
        .then<Object?>((_) => null, onError: (Object e) => e);
    expect((error as JsonRpcException).text, CodexText.timeout);
    // A late answer is ignored, not a crash.
    process.reply(1, 'late');
    await Future<void>.delayed(Duration.zero);
    expect(client.isClosed, isFalse);
  });

  test('too many pending requests are refused, not queued', () async {
    final a = client.request('a', null);
    final b = client.request('b', null);
    final c = await client
        .request('c', null)
        .then<Object?>((_) => null, onError: (Object e) => e);
    expect((c as JsonRpcException).text, CodexText.tooManyPending);
    process.reply(1, 1);
    process.reply(2, 2);
    expect(await a, 1);
    expect(await b, 2);
  });

  test('a server request is declined at once and reported', () async {
    final reported = <JsonRpcServerRequest>[];
    client.serverRequests.listen(reported.add);
    process.ask(77, 'item/commandExecution/requestApproval', {
      'threadId': 't',
      'command': 'rm -rf /',
    });
    await Future<void>.delayed(Duration.zero);
    expect(process.written, [
      {
        'id': 77,
        'error': {'code': -32601, 'message': 'declined'},
      },
    ]);
    expect(reported.single.method, 'item/commandExecution/requestApproval');
    expect(reported.single.params['command'], 'rm -rf /');
  });

  test('a line that is not a JSON object ends the connection', () async {
    final pending = client
        .request('m', null)
        .then<Object?>((_) => null, onError: (Object e) => e);
    process.emitRaw('not json at all\n');
    expect(await client.closed, CodexText.badLine);
    expect(((await pending) as JsonRpcException).text, CodexText.badLine);
    expect(client.isClosed, isTrue);
    final after = await client
        .request('m', null)
        .then<Object?>((_) => null, onError: (Object e) => e);
    expect((after as JsonRpcException).text, CodexText.childExited);
  });

  test('a line past the bound ends the connection before it is read', () async {
    process.emitRaw('{"method":"n","params":{"x":"${'a' * 500}"}}\n');
    expect(await client.closed, CodexText.lineTooLong);
  });

  test('a response to an id sai never sent is ignored — a late answer '
      'after a timeout is one', () async {
    process.reply(999, 'x');
    await Future<void>.delayed(Duration.zero);
    expect(client.isClosed, isFalse);
  });

  test('the child exiting fails what was pending', () async {
    final pending = client
        .request('m', null)
        .then<Object?>((_) => null, onError: (Object e) => e);
    process.exit(1);
    expect(await client.closed, CodexText.childExited);
    expect(((await pending) as JsonRpcException).text, CodexText.childExited);
  });

  test('stdin breaking — the child gone mid-write — ends the connection as '
      'the child exited, never as an uncaught error', () async {
    final pending = client.request('m', null);
    process.breakStdin(const SocketException('Broken pipe'));
    final error = await pending.then<Object?>(
      (_) => null,
      onError: (Object e) => e,
    );
    expect((error as JsonRpcException).text, CodexText.childExited);
    expect(await client.closed, CodexText.childExited);
  });

  test('stderr is counted, kept bounded, never surfaced', () async {
    process.emitStderr('warning sk-canary ' * 5000);
    await Future<void>.delayed(Duration.zero);
    expect(client.stderrBytes, greaterThan(JsonRpcClient.maxStderrBytes));
    expect(client.isClosed, isFalse);
  });

  test('close from sai\'s side fails pending with closed', () async {
    final pending = client
        .request('m', null)
        .then<Object?>((_) => null, onError: (Object e) => e);
    await client.close();
    expect(((await pending) as JsonRpcException).text, CodexText.closed);
    expect(await client.closed, CodexText.closed);
  });
}
