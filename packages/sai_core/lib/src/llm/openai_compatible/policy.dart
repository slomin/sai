import 'dart:async';

import '../../secrets/secret_store.dart';

import 'dart:io';

import '../failure.dart';

/// Every word an OpenAI-compatible transport can put in a failure. Fixed
/// text only: a failure line is permanent, and an exception's own text can
/// quote a URL, a header or a body. Tests check that nothing else is ever
/// written.
abstract final class TransportText {
  static const redirected =
      'the endpoint redirected; redirects are not followed';
  static const plaintext =
      'plaintext http is allowed only on this machine or the LAN; '
      'use https';
  static const noKey = 'no key stored for this endpoint';
  static const keyElsewhere =
      'the key was entered for another endpoint; enter it again';
  static const keychainUnavailable = 'the keychain could not be read';
  static const connectTimeout = 'connection timed out';
  static const noResponse = 'no response before the deadline';
  static const stalled = 'the stream stalled';
  static const couldNotConnect = 'could not connect';
  static const tls = 'TLS handshake failed';
  static const dns = 'DNS lookup failed';
  static const rejectedKey = 'the endpoint rejected the key';
  static const schemaRefused = 'the endpoint refused the response schema';
  static String answered(int status) => 'the endpoint answered $status';
  static const notAStream = 'the endpoint did not answer with a stream';
  static const badChunk = 'a chunk could not be read';
  static const endedEarly = 'the stream ended early';
  static const closed = 'the provider is closed';
  static const notJson = 'the answer was not JSON';
  static const errorPayload = 'the endpoint answered with an error';
  static const tooLarge = 'the answer was too large';
  static const noRoute = 'no endpoint matched the pinned route';
  static const noPrivateEndpoint =
      'no endpoint for this model meets the privacy filters '
      '(zero retention, no data collection, every parameter)';
  static const noCredit = 'the account has no credit left';

  /// The one non-constant: an unexpected exception's type, never its text.
  static String threw(Object error) => 'transport threw: ${error.runtimeType}';

  /// Everything above that is a constant, for the tests that assert a
  /// message is one of these.
  static const all = {
    redirected,
    plaintext,
    noKey,
    keyElsewhere,
    keychainUnavailable,
    devSecretsMessage,
    connectTimeout,
    noResponse,
    stalled,
    couldNotConnect,
    tls,
    dns,
    rejectedKey,
    schemaRefused,
    notAStream,
    badChunk,
    endedEarly,
    closed,
    notJson,
    errorPayload,
    tooLarge,
    noRoute,
    noPrivateEndpoint,
    noCredit,
  };
}

/// How long a call may take at each stage before it is a failure. There
/// is no total deadline: a long answer that keeps arriving is fine.
final class OpenAiDeadlines {
  const OpenAiDeadlines({
    this.connect = const Duration(seconds: 10),
    this.firstResponse = const Duration(seconds: 30),
    this.firstToken = const Duration(minutes: 5),
    this.interToken = const Duration(seconds: 30),
    this.ingestBytesPerSecond = 64,
  });

  /// TCP connect and TLS handshake.
  final Duration connect;

  /// From the request being sent to the response headers arriving.
  final Duration firstResponse;

  /// From the response headers to the first data event: prompt
  /// evaluation, which on a large context takes minutes on a laptop. An
  /// SSE comment (`: ping`) resets the clock without ending the wait.
  /// The floor — [firstTokenFor] grows it with the request.
  final Duration firstToken;

  /// Between two later events on the stream.
  final Duration interToken;

  /// The slowest prompt ingestion still treated as work in progress,
  /// in encoded request bytes per second. A 2-bit 27B on an M-series
  /// laptop measured ~154 B/s over a 34 KB catalog prompt (#105); 64
  /// waits for a machine well over twice as slow before calling it
  /// hung.
  final int ingestBytesPerSecond;

  /// The first-token deadline for a request whose encoded body is
  /// [bodyBytes] long: the flat [firstToken] plus one second per
  /// [ingestBytesPerSecond] bytes. Prompt evaluation scales with the
  /// prompt, and a first turn carrying the whole catalog must never be
  /// cut down mid-ingestion (#105) — a generous wait only delays the
  /// report of a genuinely hung server, which Esc can end at any time.
  Duration firstTokenFor(int bodyBytes) =>
      firstToken + Duration(seconds: bodyBytes ~/ ingestBytesPerSecond);
}

/// The failure for a transport exception raised before the response
/// arrived. [origin] is all the failure says about where.
LlmFailure connectFailure(Object error, String origin) {
  final (kind, message) = switch (error) {
    HandshakeException() => (LlmFailureKind.unreachable, TransportText.tls),
    TlsException() => (LlmFailureKind.unreachable, TransportText.tls),
    SocketException(:final osError, :final message) =>
      _isDnsFailure(osError)
          ? (LlmFailureKind.unreachable, TransportText.dns)
          : message.toLowerCase().contains('timed out')
          ? (LlmFailureKind.unreachable, TransportText.connectTimeout)
          : (LlmFailureKind.unreachable, TransportText.couldNotConnect),
    TimeoutException() => (LlmFailureKind.timeout, TransportText.noResponse),
    HttpException() => (
      LlmFailureKind.unreachable,
      TransportText.couldNotConnect,
    ),
    _ => (LlmFailureKind.internal, TransportText.threw(error)),
  };
  return LlmFailure(kind, message, endpoint: origin);
}

bool _isDnsFailure(OSError? error) {
  if (error == null) return false;
  // EAI_NONAME on Darwin (8) and glibc (-2); the messages match too.
  if (error.errorCode == 8 || error.errorCode == -2) return true;
  final text = error.message.toLowerCase();
  return text.contains('nodename nor servname') ||
      text.contains('name or service not known') ||
      text.contains('failed host lookup');
}

/// The failure for a response the backend refused to serve.
LlmFailure statusFailure(int status, String origin) => LlmFailure(
  LlmFailureKind.rejected,
  status == HttpStatus.unauthorized || status == HttpStatus.forbidden
      ? TransportText.rejectedKey
      : TransportText.answered(status),
  endpoint: origin,
  status: status,
);
