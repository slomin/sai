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

/// Where the replica stands (#15): what the last replication did, or that
/// none is configured.
sealed class BackupState {
  const BackupState();
}

/// No backup destination is configured.
final class BackupIdle extends BackupState {
  const BackupIdle();

  @override
  bool operator ==(Object other) => other is BackupIdle;

  @override
  int get hashCode => (BackupIdle).hashCode;

  @override
  String toString() => 'BackupIdle()';
}

/// Copying, then walking the replica.
final class BackupRunning extends BackupState {
  const BackupRunning();

  @override
  bool operator ==(Object other) => other is BackupRunning;

  @override
  int get hashCode => (BackupRunning).hashCode;

  @override
  String toString() => 'BackupRunning()';
}

/// The replica holds [count] events, every hash checked, as of [at].
final class BackedUp extends BackupState {
  const BackedUp({required this.count, required this.at});

  final int count;
  final DateTime at;

  @override
  bool operator ==(Object other) =>
      other is BackedUp && other.count == count && other.at == at;

  @override
  int get hashCode => Object.hash(BackedUp, count, at);

  @override
  String toString() => 'BackedUp($count, $at)';
}

/// The destination was not there this time — an unmounted volume; the
/// next run tries again. [reason] names the condition, never a path.
final class BackupSkipped extends BackupState {
  const BackupSkipped(this.reason);

  final String reason;

  @override
  bool operator ==(Object other) =>
      other is BackupSkipped && other.reason == reason;

  @override
  int get hashCode => Object.hash(BackupSkipped, reason);

  @override
  String toString() => 'BackupSkipped($reason)';
}

/// The replication was refused or the replica did not verify: [message]
/// names the reason and a file's name at most — never a path or a line.
final class BackupFailed extends BackupState {
  const BackupFailed(this.message);

  final String message;

  @override
  bool operator ==(Object other) =>
      other is BackupFailed && other.message == message;

  @override
  int get hashCode => Object.hash(BackupFailed, message);

  @override
  String toString() => 'BackupFailed($message)';
}
