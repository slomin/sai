/// Simulated token stream: emits [text] in word-sized chunks, one every
/// [gap] (plus scheduling drift, so ~35-40 chunks/s at the default).
/// Real tokens are sub-word, so this understates the chunk rate a little
/// and overstates the bytes per chunk.
Stream<String> fakeTokens(
  String text, {
  Duration gap = const Duration(milliseconds: 25),
}) async* {
  final words = text.split(' ');
  for (var i = 0; i < words.length; i++) {
    await Future<void>.delayed(gap);
    yield i == words.length - 1 ? words[i] : '${words[i]} ';
  }
}

const cannedReply =
    'Sure. Looking at your list, three of these are blocked on the same '
    'thing: nobody has provisioned the LAN inference box yet. If you do '
    '"Provision the LAN inference server" first, the three model-layer '
    'tasks unblock at once. The Things import can wait until the event '
    'log exists, otherwise you would be importing into a store you will '
    'throw away. Want me to reorder the list that way?';

List<String> fakeTasks() => List.generate(
      30,
      (i) => const [
        'Bootstrap the Dart monorepo for macOS',
        'Define the append-only event log',
        'Import tasks from Things 3',
        'Provision the LAN inference server',
        'Add the OpenAI-compatible provider',
        'Write the identity pack',
        'Build the Flutter task list view',
        'Wire the TUI to shared state',
        'Back up the archive nightly',
        'Sign and notarize the macOS build',
      ][i % 10],
    );
