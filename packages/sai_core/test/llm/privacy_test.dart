import 'package:sai_core/sai_core.dart';
import 'package:test/test.dart';

void main() {
  LlmRequest ask({String? context, List<LlmMessage>? messages}) => LlmRequest(
    messages: messages ?? [const LlmMessage(LlmRole.user, 'what is due?')],
    taskContext: context,
  );

  group('PrivacyPolicy.decide', () {
    const off = PrivacyPolicy();
    const on = PrivacyPolicy(shareTasksWithCloud: true);

    test('a local provider gets no decision, whatever the switch', () {
      expect(off.decide(LlmPrivacy.local, ask(context: 'Today: x')), isNull);
      expect(on.decide(LlmPrivacy.local, ask(context: 'Today: x')), isNull);
      expect(off.decide(LlmPrivacy.local, ask()), isNull);
    });

    test('cloud with sharing off withholds the context', () {
      final decision = off.decide(LlmPrivacy.cloud, ask(context: 'Today: x'))!;
      expect(decision.withheld, isTrue);
      expect(decision.toJson(), {
        'privacy': 'cloud',
        'share_tasks': false,
        'task_context': 'withheld',
      });
    });

    test('cloud with sharing on sends it', () {
      final decision = on.decide(LlmPrivacy.cloud, ask(context: 'Today: x'))!;
      expect(decision.withheld, isFalse);
      expect(decision.toJson(), {
        'privacy': 'cloud',
        'share_tasks': true,
        'task_context': 'sent',
      });
    });

    test('a catalog context to cloud is withheld even with sharing on', () {
      final catalog = LlmRequest(
        messages: [const LlmMessage(LlmRole.user, 'what is due?')],
        taskContext: 'the whole collection',
        taskContextProvenance: TaskProvenance.catalog,
      );
      for (final policy in [off, on]) {
        final decision = policy.decide(LlmPrivacy.cloud, catalog)!;
        expect(decision.withheld, isTrue);
        expect(decision.taskContext, TaskContextOutcome.withheld);
      }
    });

    test('cloud without context has nothing to withhold', () {
      for (final policy in [off, on]) {
        final decision = policy.decide(LlmPrivacy.cloud, ask())!;
        expect(decision.withheld, isFalse);
        expect(decision.taskContext, TaskContextOutcome.none);
        expect(decision.shareTasks, policy.shareTasksWithCloud);
      }
    });

    test('withholdsFrom is the status-line question', () {
      expect(off.withholdsFrom(LlmPrivacy.cloud), isTrue);
      expect(off.withholdsFrom(LlmPrivacy.local), isFalse);
      expect(on.withholdsFrom(LlmPrivacy.cloud), isFalse);
    });

    test('off by default, value-equal', () {
      expect(const PrivacyPolicy().shareTasksWithCloud, isFalse);
      expect(off, const PrivacyPolicy(shareTasksWithCloud: false));
      expect(off, isNot(on));
    });
  });

  group('LlmRequest task context', () {
    test('is refused when empty', () {
      expect(() => ask(context: ''), throwsArgumentError);
    });

    test('goes on the wire as a system message after the instructions', () {
      final request = ask(
        context: 'Today: x',
        messages: const [
          LlmMessage(LlmRole.system, 'be brief'),
          LlmMessage(LlmRole.user, 'hi'),
          LlmMessage(LlmRole.assistant, 'hello'),
          LlmMessage(LlmRole.user, 'what is due?'),
        ],
      );
      expect(request.sent.map((m) => (m.role.name, m.text)), [
        ('system', 'be brief'),
        ('system', 'Today: x'),
        ('user', 'hi'),
        ('assistant', 'hello'),
        ('user', 'what is due?'),
      ]);
      final assembled = request.assembled();
      expect(assembled.taskContext, isNull);
      expect(
        assembled.messages.map((m) => m.toJson()),
        request.sent.map((m) => m.toJson()),
      );
      expect(assembled.model, request.model);
    });

    test('leads when there is no system message', () {
      expect(ask(context: 'Today: x').sent.first.role, LlmRole.system);
      expect(ask(context: 'Today: x').sent.first.text, 'Today: x');
    });

    test('without it, the messages go as they are', () {
      final request = ask();
      expect(request.sent, same(request.messages));
    });

    test('carries its provenance: compact by default, none without', () {
      expect(ask(context: 'x').taskContextProvenance, TaskProvenance.compact);
      expect(ask().taskContextProvenance, TaskProvenance.none);
      expect(
        () => LlmRequest(
          messages: const [LlmMessage(LlmRole.user, 'q')],
          taskContextProvenance: TaskProvenance.compact,
        ),
        throwsArgumentError,
      );
      expect(
        () => LlmRequest(
          messages: const [LlmMessage(LlmRole.user, 'q')],
          taskContext: 'x',
          taskContextProvenance: TaskProvenance.none,
        ),
        throwsArgumentError,
      );
    });

    test('the provenance never reaches the wire or the hash', () {
      const flagged = LlmMessage(
        LlmRole.assistant,
        'Call mom @today',
        provenance: TaskProvenance.catalog,
      );
      expect(flagged.toJson(), {
        'role': 'assistant',
        'text': 'Call mom @today',
      });
    });
  });

  group('LlmRequest.forCloud', () {
    LlmRequest conversation({String? context, TaskProvenance? provenance}) =>
        LlmRequest(
          messages: const [
            LlmMessage(LlmRole.user, 'due?'),
            LlmMessage(
              LlmRole.assistant,
              'Call mom @today',
              provenance: TaskProvenance.compact,
            ),
            LlmMessage(LlmRole.user, 'and the trash?'),
            LlmMessage(
              LlmRole.assistant,
              'Old secret plan',
              provenance: TaskProvenance.catalog,
            ),
            LlmMessage(LlmRole.user, 'now?'),
          ],
          taskContext: context,
          taskContextProvenance: provenance,
        );

    test('always drops catalog-flagged history', () {
      final kept = conversation(context: 'Today: x')
          .forCloud(sendTaskContext: true, keepCompactHistory: true);
      expect(kept.messages.map((m) => m.text), [
        'due?',
        'Call mom @today',
        'and the trash?',
        'now?',
      ]);
      expect(kept.taskContext, 'Today: x');
    });

    test('withholding drops the context and compact history too', () {
      final bare = conversation(context: 'Today: x')
          .forCloud(sendTaskContext: false, keepCompactHistory: false);
      expect(bare.messages.map((m) => m.text), [
        'due?',
        'and the trash?',
        'now?',
      ]);
      expect(bare.taskContext, isNull);
      expect(bare.taskContextProvenance, TaskProvenance.none);
    });

    test('never sends a catalog context, whatever the switch says', () {
      final governed = conversation(
        context: 'the whole collection',
        provenance: TaskProvenance.catalog,
      ).forCloud(sendTaskContext: true, keepCompactHistory: true);
      expect(governed.taskContext, isNull);
      expect(
        governed.messages.map((m) => m.text),
        isNot(contains('Old secret plan')),
      );
    });
  });

  group('the words', () {
    test(
      'selectionWarning names the provider, only for cloud without sharing',
      () {
        final cloud = FakeLlmProvider(id: 'cloudy', privacy: LlmPrivacy.cloud);
        final local = FakeLlmProvider();
        expect(
          selectionWarning(cloud, const PrivacyPolicy()),
          "cloud provider 'cloudy' will not see your tasks until sharing is on",
        );
        expect(
          selectionWarning(
            cloud,
            const PrivacyPolicy(shareTasksWithCloud: true),
          ),
          isNull,
        );
        expect(selectionWarning(local, const PrivacyPolicy()), isNull);
      },
    );

    test('the status line carries the suffix while tasks are withheld', () {
      final cloud = FakeLlmProvider(
        id: 'cloudy',
        displayName: 'cloudy',
        privacy: LlmPrivacy.cloud,
      );
      expect(
        llmStatusLine(cloud, policy: const PrivacyPolicy()),
        'cloudy (fake-1) — cloud · tasks withheld',
      );
      expect(
        llmStatusLine(
          cloud,
          policy: const PrivacyPolicy(shareTasksWithCloud: true),
        ),
        'cloudy (fake-1) — cloud',
      );
      expect(
        llmStatusLine(FakeLlmProvider(), policy: const PrivacyPolicy()),
        'fake (fake-1) — local',
      );
    });
  });

  group('the default tag of an endpoint', () {
    test('this machine and the LAN are local', () {
      for (final host in [
        'localhost',
        '127.0.0.1',
        '::1',
        '10.0.0.5',
        '172.16.4.4',
        '172.31.255.1',
        '192.168.1.20',
        '169.254.1.1',
        '100.64.0.1',
        'fd12::1',
        'fe80::1',
        'potato',
        'potato.local',
        'nas.lan',
        'box.home',
        'srv.internal',
        'srv.home.arpa',
      ]) {
        expect(isPrivateHost(host), isTrue, reason: host);
        expect(
          defaultPrivacyFor(
            Uri.parse(
              'https://${host.contains(':') ? '[$host]' : host}:8443/v1',
            ),
          ),
          LlmPrivacy.local,
          reason: host,
        );
      }
    });

    test('anything else is cloud', () {
      for (final host in [
        'api.openai.com',
        'openrouter.ai',
        '8.8.8.8',
        '172.32.0.1',
        '2001:db8::1',
        'lan.example',
      ]) {
        expect(isPrivateHost(host), isFalse, reason: host);
        expect(
          defaultPrivacyFor(
            Uri.parse('https://${host.contains(':') ? '[$host]' : host}/v1'),
          ),
          LlmPrivacy.cloud,
          reason: host,
        );
      }
    });
  });
}
