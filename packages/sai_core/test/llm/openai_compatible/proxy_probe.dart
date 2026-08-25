// Run by provider_test.dart in a child process whose environment names a
// proxy that does not exist; prints `<finish> <text>` of one call.
import 'package:sai_core/sai_core.dart';

Future<void> main(List<String> args) async {
  final provider = OpenAiCompatibleProvider(
    id: 'p',
    endpoint: Uri.parse(args.single),
    defaultModel: 'm',
    secrets: InMemorySecretStore(),
    deadlines: const OpenAiDeadlines(
      connect: Duration(seconds: 5),
      firstResponse: Duration(seconds: 5),
      interToken: Duration(seconds: 5),
    ),
  );
  final result = await provider
      .start(LlmRequest(messages: const [LlmMessage(LlmRole.user, 'hi')]))
      .done;
  print('${result.finish.name} ${result.text}');
  await provider.close();
}
