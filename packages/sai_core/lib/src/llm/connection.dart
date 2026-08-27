/// The assistant header's light (#40): how the active provider stands,
/// as a level a client colours and a word it prints — never colour
/// alone.
library;

/// Green, amber, red.
enum ConnectionLevel {
  /// Connected and ready to answer.
  ready,

  /// Being asked, still loading, or degraded — worth a glance.
  attention,

  /// Unavailable or misconfigured — nothing will answer.
  down,
}

/// One reading of the connection: the level and the word for it.
final class ConnectionState {
  const ConnectionState(this.level, this.text);

  const ConnectionState.ready(this.text) : level = ConnectionLevel.ready;
  const ConnectionState.attention(this.text)
    : level = ConnectionLevel.attention;
  const ConnectionState.down(this.text) : level = ConnectionLevel.down;

  final ConnectionLevel level;

  /// A short lowercase phrase: `ready`, `probing…`, `loading`,
  /// `unreachable`, `no provider`, `misconfigured`, `no key`.
  final String text;

  /// The phrase a screen reader gets, e.g. `connected and ready`.
  String get spoken => switch (level) {
    ConnectionLevel.ready => 'connected and ready',
    ConnectionLevel.attention => 'not ready yet: $text',
    ConnectionLevel.down => 'unavailable: $text',
  };

  @override
  bool operator ==(Object other) =>
      other is ConnectionState && other.level == level && other.text == text;

  @override
  int get hashCode => Object.hash(level, text);

  @override
  String toString() => 'ConnectionState(${level.name}, $text)';
}
