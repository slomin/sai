import 'dart:async';
import 'dart:io';

import 'package:sai_core/sai_core.dart';
import 'package:sai_core/src/llm/openai_compatible/policy.dart';
import 'package:test/test.dart';

void main() {
  test('loopback is localhost and loopback addresses only', () {
    for (final ok in ['localhost', '127.0.0.1', '127.5.5.5', '::1']) {
      expect(isLoopbackHost(ok), isTrue, reason: ok);
    }
    for (final no in ['lan', '0.0.0.0', '192.168.1.20', 'fe80::1', '']) {
      expect(isLoopbackHost(no), isFalse, reason: no);
    }
  });

  test('connect failures map to fixed text naming only the origin', () {
    const origin = 'https://lan.example:8443';
    final cases = <Object, (LlmFailureKind, String)>{
      const HandshakeException('bad cert for https://u:sk-x@lan/v1'): (
        LlmFailureKind.unreachable,
        TransportText.tls,
      ),
      const SocketException(
        'Failed host lookup: sk-x',
        osError: OSError('nodename nor servname provided', 8),
      ): (
        LlmFailureKind.unreachable,
        TransportText.dns,
      ),
      const SocketException('HTTP connection timed out after 0:00:00.200000'): (
        LlmFailureKind.unreachable,
        TransportText.connectTimeout,
      ),
      const SocketException(
        'Connection refused',
        osError: OSError('Connection refused', 61),
      ): (
        LlmFailureKind.unreachable,
        TransportText.couldNotConnect,
      ),
      TimeoutException('sk-x'): (
        LlmFailureKind.timeout,
        TransportText.noResponse,
      ),
      const HttpException('Connection closed before full header was received'):
          (LlmFailureKind.unreachable, TransportText.couldNotConnect),
      StateError('sk-x'): (
        LlmFailureKind.internal,
        'transport threw: StateError',
      ),
    };
    for (final e in cases.entries) {
      final f = connectFailure(e.key, origin);
      expect((f.kind, f.message), e.value, reason: '${e.key}');
      expect(f.endpoint, origin);
      expect(f.toString(), isNot(contains('sk-x')));
    }
  });

  test('status failures name the status; 401 and 403 blame the key', () {
    expect(statusFailure(401, 'o').message, TransportText.rejectedKey);
    expect(statusFailure(403, 'o').message, TransportText.rejectedKey);
    final f = statusFailure(503, 'o');
    expect(f.message, 'the endpoint answered 503');
    expect(f.status, 503);
    expect(f.kind, LlmFailureKind.rejected);
  });
}
