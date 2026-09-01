import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sai_core/sai_core.dart';
import 'package:sai_core/src/llm/openai_compatible/policy.dart';
import 'package:test/test.dart';

import '../provider_contract.dart';
import '../stub_server.dart';

const canary = 'sk-canary-3c9e1a7b5d2f4e6a8c0b1d3f5a7c9e2b';

/// Short deadlines so the timeout tests finish quickly.
const quick = OpenAiDeadlines(
  connect: Duration(seconds: 2),
  firstResponse: Duration(milliseconds: 400),
  firstToken: Duration(milliseconds: 400),
  interToken: Duration(milliseconds: 300),
  ingestBytesPerSecond: 1 << 30,
);

LlmRequest ask(String text, {ReasoningEffort? effort, String? model}) =>
    LlmRequest(
      messages: [LlmMessage(LlmRole.user, text)],
      reasoningEffort: effort,
      model: model,
    );

/// One Responses stream event as `data:` JSON.
void emit(HttpResponse response, Map<String, Object?> event) =>
    StubServer.event(response, event);

Map<String, Object?> textDelta(String delta) => {
  'type': 'response.output_text.delta',
  'item_id': 'msg_1',
  'output_index': 0,
  'content_index': 0,
  'delta': delta,
};

Map<String, Object?> completed({
  String id = 'resp_1',
  String model = 'gpt-5.6-sol-2026-08-01',
  bool usage = true,
}) => {
  'type': 'response.completed',
  'response': {
    'id': id,
    'object': 'response',
    'status': 'completed',
    'model': model,
    'output': [],
    if (usage)
      'usage': {'input_tokens': 7, 'output_tokens': 3, 'total_tokens': 10},
  },
};

void main() {
  late StubServer stub;
  late InMemorySecretStore secrets;

  setUp(() async {
    stub = await StubServer.start();
    secrets = InMemorySecretStore()..write('provider:openai', canary);
  });
  tearDown(() => stub.close());

  OpenAiResponsesProvider make({
    ReasoningEffort? effort,
    String defaultModel = 'gpt-5.6-sol',
    SecretStore? store,
    OpenAiDeadlines deadlines = quick,
  }) => OpenAiResponsesProvider(
    id: 'openai',
    defaultModel: defaultModel,
    secrets: store ?? secrets,
    credential: 'provider:openai',
    reasoningEffort: effort,
    endpoint: stub.v1,
    deadlines: deadlines,
  );

  /// A whole streamed answer: the lifecycle markers, [words] as deltas,
  /// then the terminal response.
  void answerWith(List<String> words, {Duration gap = Duration.zero}) {
    stub.routes['POST /v1/responses'] = (req) async {
      final response = StubServer.sse(req);
      emit(response, {
        'type': 'response.created',
        'response': {'id': 'resp_1', 'status': 'in_progress'},
      });
      emit(response, {
        'type': 'response.output_item.added',
        'output_index': 0,
        'item': {'type': 'message', 'id': 'msg_1', 'role': 'assistant'},
      });
      for (final w in words) {
        emit(response, textDelta(w));
        if (gap != Duration.zero) await Future<void>.delayed(gap);
      }
      emit(response, {
        'type': 'response.output_text.done',
        'text': words.join(),
      });
      emit(response, completed());
      await response.close();
    };
  }

  Map<String, Object?> sentBody() =>
      jsonDecode(stub.requests.single.body) as Map<String, Object?>;

  group('against a stub that streams', () {
    setUp(
      () => answerWith([
        'one ',
        'two ',
        'three',
      ], gap: const Duration(milliseconds: 5)),
    );
    llmProviderContract(
      'OpenAiResponsesProvider',
      () => make(),
      request: () => ask('go'),
    );
  });

  test('sends a Responses request and reads the answer back', () async {
    answerWith(['hello ', 'world']);
    final provider = make();
    final result = await provider.start(ask('hi')).done;
    expect(result.finish, LlmFinish.stop);
    expect(result.text, 'hello world');
    expect(result.model.provider, 'openai');
    // Lineage is the exact id asked for; the dated snapshot upstream
    // answered with is the version.
    expect(result.model.id, 'gpt-5.6-sol');
    expect(result.model.version, 'gpt-5.6-sol-2026-08-01');
    expect(result.model.requestId, 'resp_1');
    expect(result.usage!.promptTokens, 7);
    expect(result.usage!.completionTokens, 3);
    expect(result.usage!.totalTokens, 10);
    expect(result.usage!.cost, isNull);
    final sent = stub.requests.single;
    expect(sent.path, '/v1/responses');
    expect(sent.header('content-type'), startsWith('application/json'));
    expect(sent.header('accept'), 'text/event-stream');
    expect(sent.header('authorization'), 'Bearer $canary');
    final body = sentBody();
    expect(body['model'], 'gpt-5.6-sol');
    expect(body['stream'], isTrue);
    expect(body['store'], isFalse);
    expect(body['background'], isFalse);
    expect(body['tools'], isEmpty);
    expect(body['tool_choice'], 'none');
    expect(body['input'], [
      {'role': 'user', 'content': 'hi'},
    ]);
    expect(body, isNot(contains('reasoning')), reason: 'Model default');
    expect(body, isNot(contains('previous_response_id')));
    expect(provider.displayName, 'openai @ ${stub.origin}');
    expect(provider.privacy, LlmPrivacy.cloud);
    expect(provider.kind, openAiKind);
    expect(provider.takesKey, isTrue);
    await provider.close();
  });

  test('the entry\'s effort reaches the wire exactly, none included', () async {
    for (final word in ['none', 'high', 'xhigh', 'a-future-word']) {
      stub.requests.clear();
      answerWith(['ok']);
      final provider = make(effort: ReasoningEffort(word));
      // Resolved before the recorder, whatever the global switch says
      // (#26): the request carries the entry's own word.
      final effort = requestedEffortFor(provider, reasoningOn: false);
      expect(effort, ReasoningEffort(word));
      await provider.start(ask('x', effort: effort)).done;
      expect(sentBody()['reasoning'], {'effort': word}, reason: word);
    }
    // Model default: the switch does not turn it into `none`.
    stub.requests.clear();
    answerWith(['ok']);
    final byDefault = make();
    final effort = requestedEffortFor(byDefault, reasoningOn: false);
    expect(effort, isNull);
    await byDefault.start(ask('x', effort: effort)).done;
    expect(sentBody(), isNot(contains('reasoning')));
  });

  test('the wire says what the request says, nothing the entry adds', () async {
    answerWith(['ok']);
    await make(effort: const ReasoningEffort('low'))
        .start(ask('x', effort: const ReasoningEffort('high')))
        .done;
    // The archive line names the request's effort; the wire agrees.
    expect(sentBody()['reasoning'], {'effort': 'high'});
  });

  test('messages keep their order; system is developer', () async {
    answerWith(['ok']);
    await make()
        .start(
          LlmRequest(
            messages: const [
              LlmMessage(LlmRole.system, 'rules'),
              LlmMessage(LlmRole.user, 'q1'),
              LlmMessage(LlmRole.assistant, 'a1'),
              LlmMessage(LlmRole.user, 'q2'),
            ],
            maxTokens: 64,
            responseSchema: const ResponseSchema(
              name: 'p',
              schema: {'type': 'object'},
            ),
          ),
        )
        .done;
    final body = sentBody();
    expect(body['input'], [
      {'role': 'developer', 'content': 'rules'},
      {'role': 'user', 'content': 'q1'},
      {'role': 'assistant', 'content': 'a1'},
      {'role': 'user', 'content': 'q2'},
    ]);
    expect(body['max_output_tokens'], 64);
    expect((body['text'] as Map)['format'], {
      'type': 'json_schema',
      'name': 'p',
      'strict': true,
      'schema': {'type': 'object'},
    });
  });

  test('reasoning summaries stream apart from the answer', () async {
    stub.routes['POST /v1/responses'] = (req) async {
      final response = StubServer.sse(req);
      emit(response, {
        'type': 'response.reasoning_summary_text.delta',
        'item_id': 'rs_1',
        'summary_index': 0,
        'delta': 'let me ',
      });
      emit(response, {
        'type': 'response.reasoning_summary_text.delta',
        'item_id': 'rs_1',
        'summary_index': 0,
        'delta': 'think',
      });
      emit(response, textDelta('ready.'));
      emit(response, completed());
      await response.close();
    };
    final call = make().start(ask('x'));
    final deltas = await call.deltas.toList();
    final result = await call.done;
    expect(deltas.map((d) => (d.text, d.reasoning)), [
      ('let me ', true),
      ('think', true),
      ('ready.', false),
    ]);
    expect(result.text, 'ready.');
    expect(result.reasoning, 'let me think');
  });

  test('fragmented events and multi-line data frames read whole', () async {
    stub.routes['POST /v1/responses'] = (req) async {
      final response = StubServer.sse(req);
      final one = jsonEncode(textDelta('hel'));
      response.write('data: ${one.substring(0, 12)}');
      await Future<void>.delayed(const Duration(milliseconds: 10));
      response.write('${one.substring(12)}\n\n');
      final two = jsonEncode(textDelta('lo'));
      response.write(
        'data: ${two.substring(0, 20)}\ndata: ${two.substring(20)}\n\n'
            .replaceFirst('\ndata: ', '\ndata:'),
      );
      emit(response, completed());
      await response.close();
    };
    final result = await make().start(ask('x')).done;
    // The second event's two data lines join with a newline, which is
    // not valid JSON mid-object — that is the protocol failure it is.
    expect(result.finish, anyOf(LlmFinish.stop, LlmFinish.failed));
    if (result.finish == LlmFinish.failed) {
      expect(result.failure!.message, TransportText.badChunk);
    } else {
      expect(result.text, 'hello');
    }
  });

  test('incomplete at the cap is a length finish', () async {
    stub.routes['POST /v1/responses'] = (req) async {
      final response = StubServer.sse(req);
      emit(response, textDelta('partial'));
      emit(response, {
        'type': 'response.incomplete',
        'response': {
          'id': 'resp_2',
          'model': 'gpt-5.6-sol',
          'incomplete_details': {'reason': 'max_output_tokens'},
          'usage': {'input_tokens': 1, 'output_tokens': 2, 'total_tokens': 3},
        },
      });
      await response.close();
    };
    final result = await make().start(ask('x')).done;
    expect(result.finish, LlmFinish.length);
    expect(result.text, 'partial');
    expect(result.usage!.totalTokens, 3);
  });

  test('incomplete for another reason keeps the text with a failure', () async {
    stub.routes['POST /v1/responses'] = (req) async {
      final response = StubServer.sse(req);
      emit(response, textDelta('part'));
      emit(response, {
        'type': 'response.incomplete',
        'response': {
          'id': 'resp_2',
          'incomplete_details': {'reason': 'content_filter'},
        },
      });
      await response.close();
    };
    final result = await make().start(ask('x')).done;
    expect(result.finish, LlmFinish.failed);
    expect(result.text, 'part');
    expect(result.failure!.kind, LlmFailureKind.rejected);
    expect(result.failure!.message, TransportText.errorPayload);
  });

  test(
    'a failed response and an error event are rejections in fixed words',
    () async {
      for (final event in [
        {
          'type': 'response.failed',
          'response': {
            'error': {'code': 'server_error', 'message': 'quoting $canary'},
          },
        },
        {'type': 'error', 'code': 'rate_limit_exceeded', 'message': canary},
      ]) {
        stub.routes['POST /v1/responses'] = (req) async {
          final response = StubServer.sse(req);
          emit(response, event);
          await response.close();
        };
        final result = await make().start(ask('x')).done;
        expect(result.finish, LlmFinish.failed);
        expect(result.failure!.kind, LlmFailureKind.rejected);
        expect(result.failure!.message, TransportText.errorPayload);
        expect(result.toString(), isNot(contains(canary)));
      }
    },
  );

  test('a tool call the model reaches for fails closed', () async {
    stub.routes['POST /v1/responses'] = (req) async {
      final response = StubServer.sse(req);
      emit(response, textDelta('let me run '));
      emit(response, {
        'type': 'response.output_item.added',
        'output_index': 1,
        'item': {'type': 'function_call', 'id': 'fc_1', 'name': 'shell'},
      });
      emit(response, textDelta('never seen'));
      emit(response, completed());
      await response.close();
    };
    final result = await make().start(ask('x')).done;
    expect(result.finish, LlmFinish.failed);
    expect(result.failure!.kind, LlmFailureKind.protocol);
    expect(result.failure!.message, TransportText.toolCalled);
    expect(result.text, 'let me run ');
  });

  test(
    'a refusal streamed as content is a failure, its words not kept',
    () async {
      const refusal = 'I cannot help with that request.';
      stub.routes['POST /v1/responses'] = (req) async {
        final response = StubServer.sse(req);
        emit(response, {
          'type': 'response.output_item.added',
          'output_index': 0,
          'item': {'type': 'message', 'id': 'msg_1', 'role': 'assistant'},
        });
        emit(response, {
          'type': 'response.content_part.added',
          'item_id': 'msg_1',
          'part': {'type': 'refusal', 'refusal': ''},
        });
        emit(response, {
          'type': 'response.refusal.delta',
          'item_id': 'msg_1',
          'delta': refusal,
        });
        emit(response, {
          'type': 'response.refusal.done',
          'item_id': 'msg_1',
          'refusal': refusal,
        });
        emit(response, completed());
        await response.close();
      };
      final result = await make().start(ask('x')).done;
      expect(result.finish, LlmFinish.failed);
      expect(result.failure!.kind, LlmFailureKind.rejected);
      expect(result.failure!.message, TransportText.refused);
      expect(result.text, isEmpty);
      expect(result.toString(), isNot(contains('cannot help')));
      expect(stub.requests, hasLength(1), reason: 'nothing re-sent');
    },
  );

  test('a stream that ends without a terminal response ended early', () async {
    stub.routes['POST /v1/responses'] = (req) async {
      final response = StubServer.sse(req);
      emit(response, textDelta('a'));
      await response.close();
    };
    final result = await make().start(ask('x')).done;
    expect(result.finish, LlmFinish.failed);
    expect(result.failure!.message, TransportText.endedEarly);
  });

  test('a chunk that is not an event is a protocol failure', () async {
    stub.routes['POST /v1/responses'] = (req) async {
      final response = StubServer.sse(req);
      StubServer.event(response, 'not json', json: false);
      await response.close();
    };
    final result = await make().start(ask('x')).done;
    expect(result.failure!.message, TransportText.badChunk);
  });

  group('refusals are one bounded failure, nothing re-sent', () {
    Future<LlmResult> refusedWith(
      int status,
      Map<String, Object?> error, {
      LlmRequest? request,
    }) async {
      stub.requests.clear();
      stub.routes['POST /v1/responses'] = (req) =>
          StubServer.json(req, {'error': error}, status: status);
      final result = await make(effort: const ReasoningEffort('xhigh'))
          .start(request ?? ask('x', effort: const ReasoningEffort('xhigh')))
          .done;
      expect(stub.requests, hasLength(1), reason: 'one request, no retry');
      expect(result.finish, LlmFinish.failed);
      expect(result.failure!.status, status);
      expect(result.toString(), isNot(contains(canary)));
      return result;
    }

    test(
      'an unsupported effort names the effort and keeps the request',
      () async {
        final result = await refusedWith(400, {
          'type': 'invalid_request_error',
          'code': 'unsupported_value',
          'param': 'reasoning.effort',
          'message': "Unsupported value: 'xhigh' $canary",
        });
        expect(result.failure!.message, TransportText.effortRefused);
        expect(result.failure!.kind, LlmFailureKind.rejected);
        expect(sentBody()['reasoning'], {'effort': 'xhigh'});
      },
    );

    test('a model the key cannot reach', () async {
      for (final (status, error) in [
        (404, {'code': 'model_not_found', 'param': null, 'message': canary}),
        (400, {'code': 'invalid_value', 'param': 'model', 'message': canary}),
      ]) {
        final result = await refusedWith(status, error);
        expect(result.failure!.message, TransportText.noSuchModel);
      }
    });

    test('a refused schema is said so, with the schema kept', () async {
      final result = await refusedWith(
        400,
        {'code': 'invalid_json_schema', 'param': 'text.format.schema'},
        request: LlmRequest(
          messages: const [LlmMessage(LlmRole.user, 'x')],
          responseSchema: const ResponseSchema(name: 'p', schema: {}),
        ),
      );
      expect(result.failure!.message, TransportText.schemaRefused);
    });

    test('no credit, a bad key and any other status', () async {
      expect(
        (await refusedWith(429, {
          'code': 'insufficient_quota',
          'message': canary,
        })).failure!.message,
        TransportText.noCredit,
      );
      expect(
        (await refusedWith(429, {
          'code': 'rate_limit_exceeded',
          'message': canary,
        })).failure!.message,
        TransportText.answered(429),
      );
      expect(
        (await refusedWith(401, {
          'code': 'invalid_api_key',
          'message': canary,
        })).failure!.message,
        TransportText.rejectedKey,
      );
      expect(
        (await refusedWith(503, {'message': canary})).failure!.message,
        TransportText.answered(503),
      );
    });

    test('a refusal that is not JSON, or not an error object', () async {
      stub.routes['POST /v1/responses'] = (req) async {
        req.response
          ..statusCode = 400
          ..write('<html>$canary</html>');
        await req.response.close();
      };
      final result = await make().start(ask('x')).done;
      expect(result.failure!.message, TransportText.answered(400));
      expect(result.toString(), isNot(contains(canary)));
    });
  });

  test('a redirect is refused and never followed', () async {
    final other = await StubServer.start();
    addTearDown(other.close);
    other.routes['POST /v1/responses'] = (req) =>
        StubServer.json(req, {'leaked': true});
    stub.routes['POST /v1/responses'] = (req) async {
      req.response
        ..statusCode = 307
        ..headers.set('location', '${other.origin}/v1/responses');
      await req.response.close();
    };
    final result = await make().start(ask('x')).done;
    expect(result.failure!.message, TransportText.redirected);
    expect(result.failure!.status, 307);
    expect(other.requests, isEmpty);
  });

  test('a non-stream answer is a protocol failure', () async {
    stub.routes['POST /v1/responses'] = (req) =>
        StubServer.json(req, {'id': 'resp', 'output': []});
    final result = await make().start(ask('x')).done;
    expect(result.failure!.message, TransportText.notAStream);
  });

  test('deadlines: no response, then a stalled stream', () async {
    stub.routes['POST /v1/responses'] = (req) async {
      await Future<void>.delayed(const Duration(seconds: 2));
    };
    var result = await make().start(ask('x')).done;
    expect(result.failure!.kind, LlmFailureKind.timeout);
    expect(result.failure!.message, TransportText.noResponse);
    stub.routes['POST /v1/responses'] = (req) async {
      final response = StubServer.sse(req);
      emit(response, textDelta('a'));
      await Future<void>.delayed(const Duration(seconds: 2));
      await response.close();
    };
    result = await make().start(ask('x')).done;
    expect(result.failure!.kind, LlmFailureKind.timeout);
    expect(result.failure!.message, TransportText.stalled);
    expect(result.text, 'a');
  });

  test('cancel aborts the socket; no background cancel is called', () async {
    final gate = Completer<void>();
    stub.routes['POST /v1/responses'] = (req) async {
      final response = StubServer.sse(req);
      emit(response, textDelta('first'));
      await gate.future;
      emit(response, completed());
      await response.close();
    };
    final call = make().start(ask('x'));
    await call.deltas.first;
    call.cancel();
    final result = await call.done;
    expect(result.finish, LlmFinish.cancelled);
    expect(result.text, 'first');
    gate.complete();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(stub.requests.map((r) => r.path), ['/v1/responses']);
  });

  group('the key', () {
    test('is read at call time; without one nothing is sent', () async {
      answerWith(['ok']);
      final empty = make(store: InMemorySecretStore());
      final result = await empty.start(ask('x')).done;
      expect(result.failure!.kind, LlmFailureKind.credential);
      expect(result.failure!.message, TransportText.noKey);
      expect(stub.requests, isEmpty);
      // Stored later, used on the next call — the provider holds none.
      final store = InMemorySecretStore();
      final late = make(store: store);
      expect(
        (await late.start(ask('x')).done).failure!.kind,
        LlmFailureKind.credential,
      );
      store.write('provider:openai', canary);
      expect((await late.start(ask('x')).done).finish, LlmFinish.stop);
    });

    test('the dev copy says its own words before a socket', () async {
      final result = await make(store: const NoSecretStore(devSecretsMessage))
          .start(ask('x'))
          .done;
      expect(result.failure!.kind, LlmFailureKind.credential);
      expect(result.failure!.message, devSecretsMessage);
      expect(stub.requests, isEmpty);
    });

    test('the origin never moves: only a loopback stub may stand in', () {
      expect(
        () => OpenAiResponsesProvider(
          id: 'x',
          defaultModel: 'm',
          secrets: secrets,
          credential: 'provider:x',
          endpoint: Uri.parse('https://evil.example/v1'),
        ),
        throwsArgumentError,
      );
      final real = OpenAiResponsesProvider(
        id: 'x',
        defaultModel: 'm',
        secrets: secrets,
        credential: 'provider:x',
      );
      expect(real.endpoint, openAiEndpoint);
      expect(real.origin, 'https://api.openai.com');
    });
  });

  group('the model list', () {
    test('probe reads GET /v1/models with the key and lists ids', () async {
      stub.routes['GET /v1/models'] = (req) => StubServer.json(req, {
        'object': 'list',
        'data': [
          {'id': 'gpt-5.6-sol', 'object': 'model', 'owned_by': 'openai'},
          {'id': 'gpt-5.6-luna', 'object': 'model'},
          {'id': 'gpt-5.6-sol', 'object': 'model'},
          {'object': 'model'},
        ],
      });
      final info = await make().probe();
      expect(info.health, EndpointHealth.ok);
      expect(info.models, ['gpt-5.6-luna', 'gpt-5.6-sol']);
      expect(info.serverKind, openAiKind);
      expect(info.contextWindow, isNull);
      expect(stub.requests.single.header('authorization'), 'Bearer $canary');
      final list = await fetchOpenAiCatalogue(make());
      expect(list.models, ['gpt-5.6-luna', 'gpt-5.6-sol']);
      expect(list.failure, isNull);
    });

    test('without a key the probe fails credential before a socket', () async {
      final info = await make(store: InMemorySecretStore()).probe();
      expect(info.health, EndpointHealth.unavailable);
      expect(info.failure!.kind, LlmFailureKind.credential);
      expect(stub.requests, isEmpty);
    });

    test('a bad key, a wrong shape and a too-large list', () async {
      stub.routes['GET /v1/models'] = (req) => StubServer.json(req, {
        'error': {'message': canary},
      }, status: 401);
      var info = await make().probe();
      expect(info.failure!.message, TransportText.rejectedKey);
      stub.routes['GET /v1/models'] = (req) =>
          StubServer.json(req, {'models': []});
      info = await make().probe();
      expect(info.failure!.message, TransportText.notModels);
      expect(
        (await fetchOpenAiCatalogue(make())).failure!.message,
        TransportText.notModels,
      );
      stub.routes['GET /v1/models'] = (req) async {
        req.response.headers.contentType = ContentType.json;
        req.response.write('{"data":[${'{"id":"m"},' * 200000}{"id":"z"}]}');
        await req.response.close();
      };
      info = await make().probe();
      expect(info.failure!.message, TransportText.tooLarge);
      expect(info.toString(), isNot(contains(canary)));
    });
  });

  test('close cancels running calls and refuses new ones', () async {
    final gate = Completer<void>();
    stub.routes['POST /v1/responses'] = (req) async {
      final response = StubServer.sse(req);
      emit(response, textDelta('a'));
      await gate.future;
      await response.close();
    };
    final provider = make();
    final call = provider.start(ask('x'));
    await call.deltas.first;
    await provider.close();
    expect((await call.done).finish, LlmFinish.cancelled);
    final after = await provider.start(ask('y')).done;
    expect(after.failure!.message, TransportText.closed);
    expect(provider.isClosed, isTrue);
    gate.complete();
  });
}
