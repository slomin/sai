import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sai_app/assistant/assistant_band.dart';
import 'package:sai_app/theme/sai_tokens.dart';
import 'package:sai_core/sai_core.dart';

import 'harness.dart';

/// A provider whose endpoint answers as the test says.
final class _Probed implements LlmProvider, LlmEndpointProbe {
  _Probed();

  EndpointInfo answer = const EndpointInfo(health: EndpointHealth.loading);

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
  Future<EndpointInfo> probe() async => answer;
}

Color dot(WidgetTester tester) =>
    (tester.widget<Container>(find.byKey(connectionDotKey)).decoration
            as BoxDecoration)
        .color!;

String word(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(connectionTextKey)).data!;

String spoken(WidgetTester tester) =>
    tester.getSemantics(find.byKey(assistantHeaderKey)).label;

void main() {
  group('the connection light (#40)', () {
    testWidgets('no provider is red and says so; the fake is green', (
      tester,
    ) async {
      final container = await pumpApp(tester);
      expect(dot(tester), SaiColors.red);
      expect(word(tester), 'NO PROVIDER');
      expect(spoken(tester), contains('unavailable: no provider'));
      expect(spoken(tester), contains(noProviderStatus));
      container.read(settingsProvider.notifier).selectLlm('fake');
      await tester.pump();
      expect(dot(tester), SaiColors.green);
      expect(word(tester), 'READY');
      expect(spoken(tester), contains('connected and ready'));
    });

    testWidgets('probing, loading, ready, down — each a colour and a word', (
      tester,
    ) async {
      final probed = _Probed();
      final container = await pumpApp(tester, builtins: [() => probed]);
      container.read(settingsProvider.notifier).selectLlm('probed');
      await tester.pump();
      expect(dot(tester), SaiColors.amber);
      expect(word(tester), 'PROBING…');
      await tester.pump();
      expect(dot(tester), SaiColors.amber);
      expect(word(tester), 'LOADING');
      expect(spoken(tester), contains('not ready yet: loading'));
      probed.answer = const EndpointInfo(health: EndpointHealth.ok);
      container.read(connectionProvider.notifier).refresh();
      await tester.pump();
      await tester.pump();
      expect(dot(tester), SaiColors.green);
      expect(word(tester), 'READY');
      // A call that failed lights it red without waiting for the timer.
      probed.answer = const EndpointInfo(
        health: EndpointHealth.unavailable,
        failure: LlmFailure(LlmFailureKind.unreachable, 'refused'),
      );
      container
          .read(connectionProvider.notifier)
          .callFailed(const LlmFailure(LlmFailureKind.unreachable, 'refused'));
      await tester.pump();
      await tester.pump();
      expect(dot(tester), SaiColors.red);
      expect(word(tester), 'UNREACHABLE');
      expect(spoken(tester), contains('unavailable: unreachable'));
      // And recovers.
      probed.answer = const EndpointInfo(health: EndpointHealth.ok);
      container.read(connectionProvider.notifier).refresh();
      await tester.pump();
      await tester.pump();
      expect(dot(tester), SaiColors.green);
    });

    testWidgets('a credentialed provider in dev is red: no credentials', (
      tester,
    ) async {
      final container = await pumpApp(tester, identity: SaiIdentity.dev);
      final settings = container.read(settingsProvider.notifier);
      settings.upsertProvider(
        ProviderConfig(
          id: 'lan',
          kind: 'fake',
          defaultModel: 'qwen',
          credential: 'provider:lan',
        ),
      );
      settings.selectLlm('lan');
      await tester.pump();
      expect(dot(tester), SaiColors.red);
      expect(word(tester), 'NO CREDENTIALS IN DEV');
    });

    testWidgets('a misconfigured provider is red: misconfigured', (
      tester,
    ) async {
      final container = await pumpApp(tester);
      final settings = container.read(settingsProvider.notifier);
      settings.upsertProvider(
        ProviderConfig(id: 'half', kind: 'openai_compatible'),
      );
      settings.selectLlm('half');
      await tester.pump();
      expect(dot(tester), SaiColors.red);
      expect(word(tester), 'MISCONFIGURED');
    });
  });
}
