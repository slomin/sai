import 'package:sai_core/sai_core.dart';
import 'package:test/test.dart';

void main() {
  ProviderConfig config({
    String? endpoint,
    String? model = 'gpt-5.6-sol',
    String? credential,
    LlmPrivacy? privacy,
    String? routing,
    String? effort,
  }) => ProviderConfig(
    id: 'chatgpt',
    kind: chatGptKind,
    endpoint: endpoint,
    defaultModel: model,
    credential: credential,
    privacy: privacy,
    routing: routing,
    reasoningEffort: effort,
  );

  test('the kind is its own word and names no credential (#26)', () {
    expect(chatGptKind, 'chatgpt_subscription');
    expect(chatGptProblem(config()), isNull);
    expect(chatGptProblem(config(privacy: LlmPrivacy.cloud)), isNull);
    // The model is chosen from the live list: an entry may wait for it.
    expect(chatGptProblem(config(model: null)), isNull);
    expect(chatGptProblem(config(effort: 'xhigh')), isNull);
    expect(chatGptProblem(config(effort: 'unheard-of')), isNull);
  });

  test('chatGptProblem says what is wrong as a phrase', () {
    expect(
      chatGptProblem(config(endpoint: 'https://other.example/v1')),
      'carrying an endpoint, but chatgpt_subscription has none',
    );
    expect(
      chatGptProblem(config(privacy: LlmPrivacy.local)),
      'tagged local, but chatgpt_subscription is a cloud provider',
    );
    expect(
      chatGptProblem(config(routing: 'exact')),
      'carrying a routing word, which only openrouter takes',
    );
    expect(
      chatGptProblem(config(credential: 'provider:chatgpt')),
      'naming a key, but the ChatGPT login lives in the App Server, '
      'not the Keychain',
    );
    expect(
      missingForKind(config(credential: 'provider:chatgpt')),
      startsWith('naming a key'),
    );
  });

  test('both OpenAI kinds coexist as two entries with two billings', () {
    final settings = Settings(
      providers: [
        config(),
        ProviderConfig(
          id: 'openai',
          kind: openAiKind,
          defaultModel: 'gpt-5.6-sol',
          credential: 'provider:openai',
          reasoningEffort: 'high',
        ),
      ],
    );
    final decoded = Settings.decode(settings.encode());
    expect(
      decoded.providers.map((p) => p.kind),
      unorderedEquals([openAiKind, chatGptKind]),
    );
    expect(decoded.provider('chatgpt')?.credential, isNull);
    expect(decoded.provider('openai')?.credential, 'provider:openai');
    expect(decoded.provider('openai')?.reasoningEffort, 'high');
    expect(decoded.provider('chatgpt')?.reasoningEffort, isNull);
    for (final p in decoded.providers) {
      expect(missingForKind(p), isNull, reason: p.id);
    }
  });
}
