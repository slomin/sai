import 'package:sai_core/sai_core.dart';
import 'package:test/test.dart';

void main() {
  const messages = [
    LlmMessage(LlmRole.system, 'p'),
    LlmMessage(LlmRole.user, 'hi'),
  ];

  test('is the sha256 blobref of the compact message JSON, and stable', () {
    final hash = contextHash(messages);
    expect(hash.isSha256, isTrue);
    // Golden: sha256 of '[{"role":"system","text":"p"},{"role":"user","text":"hi"}]'.
    expect(
      hash.toString(),
      'sha256-479a2110e0d809557a0f4f4f0ee4ea0d7be5664d418bb416582f7c5028f94a34',
    );
  });

  test('differs when the list differs or is withheld', () {
    final request = LlmRequest(messages: messages, taskContext: 'Today: x');
    final sent = contextHash(request.sent);
    final withheld = contextHash(request.withoutTaskContext().sent);
    expect(sent, isNot(withheld));
    expect(
      contextHash(LlmRequest(messages: messages, taskContext: 'Today: y').sent),
      isNot(sent),
    );
    expect(withheld, contextHash(messages));
  });
}
