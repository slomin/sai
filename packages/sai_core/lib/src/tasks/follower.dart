/// What the archive follower (#118) has done for this process: how many
/// times another process's lines made it replay the log, and the failure
/// its last check ended in, when one stands — cleared by the next check
/// that succeeds. The clients show [notice] in their notice row whenever
/// no notice of the person's own action holds it.
final class FollowerState {
  const FollowerState({this.reloads = 0, this.failure});

  /// Replays another writer's lines caused since the process started.
  final int reloads;

  /// Why the last check or reload failed, or null while all is well.
  /// The reason and a file's name at most — never a path or a line.
  final String? failure;

  /// The sentence both clients show while [failure] stands.
  String? get notice => failure == null ? null : 'reload failed: $failure';

  @override
  bool operator ==(Object other) =>
      other is FollowerState &&
      other.reloads == reloads &&
      other.failure == failure;

  @override
  int get hashCode => Object.hash(reloads, failure);

  @override
  String toString() =>
      'FollowerState(reloads: $reloads'
      '${failure == null ? '' : ', failure: $failure'})';
}
