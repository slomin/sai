/// The LLM provider layer: one [LlmProvider] interface, the call machinery
/// behind it, a deterministic fake, and the recorder that puts every call
/// into the archive. Pure Dart; the HTTP providers (#22) implement the
/// interface, the clients only read the riverpod layer.
///
/// Naming: `LlmProvider` is the model backend; riverpod providers in
/// `providers.dart` say "Provider" once (`activeLlmProvider`,
/// `llmStatusProvider`). On the wire the archive keeps the spec's
/// `provider.*` types and `model.provider` key.
library;

export 'llm/call.dart';
export 'llm/failure.dart';
export 'llm/factory.dart';
export 'llm/fake.dart';
export 'llm/provider.dart';
export 'llm/recorder.dart';
export 'llm/status.dart';
