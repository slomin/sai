import 'dart:io';

import 'package:nocterm/nocterm.dart';
import 'package:riverpod/misc.dart' show Override;
import 'package:riverpod/riverpod.dart';
import 'package:sai_core/sai_core.dart';
import 'package:test/test.dart';

/// A per-test container over a temp archive root — TUI tests must never
/// touch the real archive under Application Support.
ProviderContainer testContainer({
  List<Override> overrides = const [],
  List<LlmProvider Function()> builtins = const [FakeLlmProvider.new],
  FinishedTaskVisibility? finishedTasks = FinishedTaskVisibility.endOfDay,
  SecretStore? secrets,
}) {
  // Archive and settings both go under one temp dir, whatever the
  // developer's environment says.
  final tmp = Directory.systemTemp.createTempSync('sai_tui_test');
  addTearDown(() => tmp.deleteSync(recursive: true));
  final root = Directory('${tmp.path}/archive');
  return ProviderContainer.test(
    overrides: [
      archiveRootProvider.overrideWithValue(root),
      settingsFileProvider.overrideWithValue(File('${tmp.path}/settings.json')),
      eventSourceProvider.overrideWithValue(EventSources.tui),
      // Never the login keychain from a test. A test whose built-ins
      // take a key hands in the store they were built over.
      secretStoreProvider.overrideWithValue(secrets ?? InMemorySecretStore()),
      // The fake alone, nothing selected: a test never reaches LM Studio
      // or the LAN box unless it asks for them.
      builtinLlmsProvider.overrideWithValue(builtins),
      defaultLlmIdProvider.overrideWithValue(null),
      // The status row watches the warmer; a test provider must never
      // be sent a background inference (#105).
      warmEnabledProvider.overrideWithValue(false),
      // The product default (#97) unless a test is about the row leaving;
      // null reads the setting through, for the CLI that sets it.
      if (finishedTasks != null)
        finishedTaskVisibilityProvider.overrideWithValue(finishedTasks),
      ...overrides,
    ],
  );
}

/// Every event line under the container's archive root, oldest first.
List<String> archiveLines(ProviderContainer container) {
  final dir = Directory('${container.read(archiveRootProvider).path}/events');
  if (!dir.existsSync()) return const [];
  final lines = <String>[];
  final files = dir.listSync().whereType<File>().toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  for (final file in files) {
    lines.addAll(
      file.readAsStringSync().split('\n').where((l) => l.isNotEmpty),
    );
  }
  return lines;
}

/// Pumps frames for [total] in [step]s. `pumpAndSettle` never settles
/// under the nocterm tester (it counts the frame it just pumped as a
/// change), so tests drive time explicitly instead.
Future<void> pumpFor(
  NoctermTester tester,
  Duration total, {
  Duration step = const Duration(milliseconds: 20),
}) async {
  var elapsed = Duration.zero;
  while (elapsed < total) {
    await tester.pump(step);
    elapsed += step;
  }
}

/// Pumps until [text] shows on the terminal, failing after [timeout]
/// with the current screen for diagnosis.
Future<void> pumpUntilText(
  NoctermTester tester,
  String text, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!tester.terminalState.containsText(text)) {
    if (DateTime.now().isAfter(deadline)) {
      fail(
        'timed out waiting for "$text" — screen:\n${tester.renderToString()}',
      );
    }
    await tester.pump(const Duration(milliseconds: 20));
  }
}
