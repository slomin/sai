import 'package:sai_core/sai_core.dart';
import 'package:test/test.dart';

/// A provider with an effort of its own (#26), the way the OpenAI kinds
/// carry one in their entry.
final class _Configured implements LlmProvider, ConfiguredEffort {
  _Configured(this.reasoningEffort);

  @override
  final ReasoningEffort? reasoningEffort;

  @override
  String get id => 'configured';

  @override
  String get displayName => id;

  @override
  LlmPrivacy get privacy => LlmPrivacy.cloud;

  @override
  String get defaultModel => 'm';

  @override
  LlmCall start(LlmRequest request) => throw UnimplementedError();

  @override
  void releaseIdle() {}

  @override
  Future<void> close() async {}
}

void main() {
  group('ReasoningEffort', () {
    test('is the upstream word, compared by value', () {
      expect(const ReasoningEffort('xhigh'), const ReasoningEffort('xhigh'));
      expect(const ReasoningEffort('xhigh').hashCode, 'xhigh'.hashCode);
      expect(const ReasoningEffort('high'), isNot(ReasoningEffort.none));
      expect(ReasoningEffort.none.isNone, isTrue);
      expect(const ReasoningEffort('low').isNone, isFalse);
      expect('${const ReasoningEffort('medium')}', 'medium');
    });

    test('parses an absent or empty word as the default', () {
      expect(ReasoningEffort.parse(null), isNull);
      expect(ReasoningEffort.parse(''), isNull);
      expect(ReasoningEffort.parse('none'), ReasoningEffort.none);
      // A word this sai has never heard of survives untouched: the
      // provider judges it, not the parser.
      expect(ReasoningEffort.parse('ultra'), const ReasoningEffort('ultra'));
    });
  });

  group('requestedEffortFor', () {
    test('translates the switch for a provider without an effort', () {
      final fake = FakeLlmProvider();
      expect(requestedEffortFor(fake, reasoningOn: true), isNull);
      expect(
        requestedEffortFor(fake, reasoningOn: false),
        ReasoningEffort.none,
      );
    });

    test('a configured effort stands whatever the switch says', () {
      final high = _Configured(const ReasoningEffort('high'));
      expect(
        requestedEffortFor(high, reasoningOn: false),
        const ReasoningEffort('high'),
      );
      expect(
        requestedEffortFor(high, reasoningOn: true),
        const ReasoningEffort('high'),
      );
      // Model default is a choice too: the switch does not turn it off.
      final byDefault = _Configured(null);
      expect(requestedEffortFor(byDefault, reasoningOn: false), isNull);
      expect(requestedEffortFor(byDefault, reasoningOn: true), isNull);
    });
  });
}
