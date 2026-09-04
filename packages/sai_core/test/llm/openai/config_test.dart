import 'package:sai_core/sai_core.dart';
import 'package:test/test.dart';

void main() {
  ProviderConfig config({
    String? endpoint,
    String? model = 'gpt-5.6-sol',
    String? credential = 'provider:openai',
    LlmPrivacy? privacy,
    String? routing,
    String? effort,
  }) => ProviderConfig(
    id: 'openai',
    kind: openAiKind,
    endpoint: endpoint,
    defaultModel: model,
    credential: credential,
    privacy: privacy,
    routing: routing,
    reasoningEffort: effort,
  );

  test('the origin is fixed and the kind is its own word (#26)', () {
    expect(openAiKind, 'openai');
    expect(openAiEndpoint.toString(), 'https://api.openai.com/v1');
    expect(openAiEndpoint.scheme, 'https');
    expect(openAiEffortWords, [
      'none',
      'minimal',
      'low',
      'medium',
      'high',
      'xhigh',
      'max',
    ]);
  });

  test('openAiProblem: a bare key for what is missing, a phrase for what '
      'is wrong', () {
    expect(openAiProblem(config()), isNull);
    expect(openAiProblem(config(privacy: LlmPrivacy.cloud)), isNull);
    // Any effort word stands: the model judges it, sai does not.
    expect(openAiProblem(config(effort: 'xhigh')), isNull);
    expect(openAiProblem(config(effort: 'a-word-from-the-future')), isNull);
    expect(openAiProblem(config(model: null)), 'default_model');
    expect(openAiProblem(config(credential: null)), 'credential');
    expect(
      openAiProblem(config(endpoint: 'https://other.example/v1')),
      'carrying an endpoint, but openai has a fixed one',
    );
    expect(
      openAiProblem(config(privacy: LlmPrivacy.local)),
      'tagged local, but openai is a cloud provider',
    );
    expect(
      openAiProblem(config(routing: 'exact')),
      'carrying a routing word, which only openrouter takes',
    );
  });

  test('missingForKind routes the kind to its own judgement', () {
    expect(missingForKind(config()), isNull);
    expect(missingForKind(config(model: null)), 'default_model');
    expect(
      missingForKind(config(privacy: LlmPrivacy.local)),
      'tagged local, but openai is a cloud provider',
    );
  });

  test('a reasoning effort on any other kind is misconfigured', () {
    for (final kind in ['fake', 'openai_compatible']) {
      final entry = ProviderConfig(
        id: 'x',
        kind: kind,
        endpoint: kind == 'fake' ? null : 'http://127.0.0.1:8080/v1',
        defaultModel: 'm',
        reasoningEffort: 'high',
      );
      expect(
        missingForKind(entry),
        'carrying a reasoning effort, which only the OpenAI kinds take',
        reason: kind,
      );
    }
    final routed = ProviderConfig(
      id: 'openrouter',
      kind: openRouterKind,
      defaultModel: openRouterPresetModel,
      credential: 'provider:openrouter',
      routing: 'deepinfra_fp8',
      reasoningEffort: 'high',
    );
    // OpenRouter judges its own entry and reads the switch, not this
    // key; the stray word is a misconfiguration all the same.
    expect(
      missingForKind(routed),
      'carrying a reasoning effort, which only the OpenAI kinds take',
    );
  });
}
