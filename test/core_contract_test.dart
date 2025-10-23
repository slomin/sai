import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sai/src/core_contract.dart';
import 'package:test/test.dart';

void main() {
  group('SaiContextPayload', () {
    test('toJson preserves fields', () {
      final payload = SaiContextPayload(
        message: 'run tests',
        shell: 'zsh',
        cwd: '/tmp/project',
        history: const ['ls', 'dart test'],
      );

      expect(
        payload.toJson(),
        equals(<String, Object?>{
          'message': 'run tests',
          'shell': 'zsh',
          'cwd': '/tmp/project',
          'history': const ['ls', 'dart test'],
        }),
      );
    });

    test('fromJson fills defaults', () {
      final payload = SaiContextPayload.fromJson(<String, Object?>{
        'history': ['git status'],
      });
      expect(payload.message, isEmpty);
      expect(payload.shell, 'unknown');
      expect(payload.cwd, '.');
      expect(payload.history, equals(const ['git status']));
    });

    test('writePayloadJson and readPayloadJson roundtrip', () async {
      final payload = SaiContextPayload(
        message: 'build',
        shell: 'zsh',
        cwd: '/Users/test',
        history: const ['ls -la'],
      );

      final buffer = StringBuffer();
      final sink = IOSink(_StringBufferConsumer(buffer));
      await writePayloadJson(payload, sink: sink);
      await sink.close();

      final source = Stream<List<int>>.value(
        utf8.encode(buffer.toString()),
      );

      final result = await readPayloadJson(source);
      expect(result.message, 'build');
      expect(result.shell, 'zsh');
      expect(result.cwd, '/Users/test');
      expect(result.history, equals(const ['ls -la']));
    });

    test('readPayloadJson throws with invalid json', () {
      final source = Stream<List<int>>.value(utf8.encode('not json'));
      expect(
        () => readPayloadJson(source),
        throwsA(
          isA<SaiPayloadFormatException>().having(
            (e) => e.message,
            'message',
            contains('Invalid JSON payload'),
          ),
        ),
      );
    });

    test('readPayloadJson throws with empty payload', () {
      final source = Stream<List<int>>.value(utf8.encode('   '));
      expect(
        () => readPayloadJson(source),
        throwsA(
          isA<SaiPayloadFormatException>().having(
            (e) => e.message,
            'message',
            'Empty JSON payload',
          ),
        ),
      );
    });
  });
}

class _StringBufferConsumer implements StreamConsumer<List<int>> {
  _StringBufferConsumer(this._buffer);

  final StringBuffer _buffer;

  @override
  Future addStream(Stream<List<int>> stream) async {
    await for (final chunk in stream) {
      _buffer.write(utf8.decode(chunk));
    }
  }

  @override
  Future close() async {}
}
