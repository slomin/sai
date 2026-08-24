/// What went wrong, at the granularity a client acts on.
enum LlmFailureKind {
  /// Nothing answered at the endpoint — connection refused, DNS, no route.
  unreachable,

  /// The backend accepted the connection and then did not answer in time.
  timeout,

  /// The backend answered with an error; [LlmFailure.status] where HTTP.
  rejected,

  /// The answer was not something this provider can read — a truncated
  /// stream, an unparseable chunk, streaming refused.
  protocol,

  /// The provider adapter itself broke: a synchronous throw, an error on
  /// the deltas stream. A bug, recorded rather than swallowed.
  internal,

  /// The answer arrived but the archive refused to record it (disk full,
  /// a log pulled out from under the process). Never written to the log
  /// — the log is what failed; `RecordedCall.archiveError` has the cause.
  archive,
}

/// A call that did not produce an answer. Carried as data on
/// `LlmResult.failure` (hence not `…Error`); written to the archive, so
/// it never holds a key, a header or a request body.
final class LlmFailure implements Exception {
  const LlmFailure(this.kind, this.message, {this.endpoint, this.status});

  final LlmFailureKind kind;
  final String message;

  /// Which endpoint failed — connection errors must name it (#22).
  final String? endpoint;

  /// The HTTP status where the backend answered with one.
  final int? status;

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'message': message,
    if (endpoint != null) 'endpoint': endpoint,
    if (status != null) 'status': status,
  };

  @override
  String toString() =>
      'LlmFailure(${kind.name}): $message'
      '${status == null ? '' : ' [$status]'}'
      '${endpoint == null ? '' : ' ($endpoint)'}';
}
