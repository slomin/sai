import 'dart:io';

import 'package:riverpod/riverpod.dart';
import 'package:sai_core/sai_core.dart';
import 'package:sai_tui/bootstrap.dart';
import 'package:test/test.dart';

/// A local provider that answers a scripted probe, so the keep-alive can
/// be seen to start the connection's probing without a socket.
final class _Probed implements LlmProvider, LlmEndpointProbe {
  var probes = 0;

  @override
  String get id => 'probed';
  @override
  String get displayName => 'probed';
  @override
  LlmPrivacy get privacy => LlmPrivacy.local;
  @override
  String get defaultModel => 'm';
  @override
  LlmCall start(LlmRequest request) => throw UnimplementedError();
  @override
  Future<void> close() async {}
  @override
  Future<EndpointInfo> probe() async {
    probes++;
    return const EndpointInfo(health: EndpointHealth.ok, contextWindow: 262144);
  }
}

void main() {
  test(
    'the interactive client keeps the connection probe alive (#105)',
    () async {
      final tmp = Directory.systemTemp.createTempSync('sai_bootstrap');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final probed = _Probed();
      final container = ProviderContainer.test(
        overrides: [
          archiveRootProvider.overrideWithValue(
            Directory('${tmp.path}/archive'),
          ),
          settingsFileProvider.overrideWithValue(File('${tmp.path}/s.json')),
          eventSourceProvider.overrideWithValue('sai/test'),
          secretStoreProvider.overrideWithValue(InMemorySecretStore()),
          builtinLlmsProvider.overrideWithValue([() => probed]),
          defaultLlmIdProvider.overrideWithValue(null),
          connectionProbeEveryProvider.overrideWithValue(null),
        ],
      );
      container.read(settingsProvider.notifier).selectLlm('probed');
      // Nothing the TUI renders watches the connection; without the
      // keep-alive no probe would ever run and the chat budget would stay
      // on the conservative default.
      keepConnectionAlive(container);
      await Future<void>.delayed(Duration.zero);
      expect(probed.probes, 1);
      expect(container.read(contextWindowsProvider), {'probed': 262144});
      expect(container.read(chatBudgetProvider).maxTokens, 262144);
    },
  );
}
