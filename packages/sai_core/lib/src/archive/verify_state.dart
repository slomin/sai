/// Where an on-demand integrity pass stands (#40).
library;

sealed class VerifyState {
  const VerifyState();
}

/// Not asked.
final class VerifyIdle extends VerifyState {
  const VerifyIdle();

  @override
  bool operator ==(Object other) => other is VerifyIdle;

  @override
  int get hashCode => (VerifyIdle).hashCode;

  @override
  String toString() => 'VerifyIdle()';
}

/// Walking the log.
final class VerifyRunning extends VerifyState {
  const VerifyRunning();

  @override
  bool operator ==(Object other) => other is VerifyRunning;

  @override
  int get hashCode => (VerifyRunning).hashCode;

  @override
  String toString() => 'VerifyRunning()';
}

/// Every line hashed to its id and HEAD agreed: [count] events.
final class Verified extends VerifyState {
  const Verified(this.count);

  final int count;

  @override
  bool operator ==(Object other) => other is Verified && other.count == count;

  @override
  int get hashCode => Object.hash(Verified, count);

  @override
  String toString() => 'Verified($count)';
}

/// The log refused: [message] names the file and the reason, never a
/// line's content.
final class VerifyFailed extends VerifyState {
  const VerifyFailed(this.message);

  final String message;

  @override
  String toString() => 'VerifyFailed($message)';
}

/// What the archive holds, for a settings screen: events and bytes.
final class ArchiveStats {
  const ArchiveStats({required this.count, required this.bytes});

  final int count;
  final int bytes;

  @override
  bool operator ==(Object other) =>
      other is ArchiveStats && other.count == count && other.bytes == bytes;

  @override
  int get hashCode => Object.hash(count, bytes);

  @override
  String toString() => 'ArchiveStats($count events, $bytes bytes)';
}
