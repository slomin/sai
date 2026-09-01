/// What the archive follower (#118) has done for this process: how many
/// times another process's lines made it replay the log, and the failure
/// its last check ended in, when one stands — cleared by the next check
/// that succeeds. The clients show [failure] as their reload notice.
final class FollowerState {
  const FollowerState({this.reloads = 0, this.failure});

  /// Replays another writer's lines caused since the process started.
  final int reloads;

  /// Why the last check or reload failed, or null while all is well.
  final String? failure;

  @override
  String toString() =>
      'FollowerState(reloads: $reloads'
      '${failure == null ? '' : ', failure: $failure'})';
}
