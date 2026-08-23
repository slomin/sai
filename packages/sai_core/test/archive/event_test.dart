import 'dart:convert';

import 'package:sai_core/sai_core.dart';
import 'package:test/test.dart';

void main() {
  final ts = DateTime.utc(2026, 8, 23, 9, 14, 2, 123, 456);
  final aRef = BlobRef.sha256OfBytes(utf8.encode('a'));
  final bRef = BlobRef.sha256OfBytes(utf8.encode('b'));

  EventDraft chatDraft() => EventDraft(
    type: EventTypes.chatMessage,
    actor: Actor.assistant,
    source: 'sai/tui',
    payload: {'text': 'hello'},
    model: const ModelRef(
      provider: 'anthropic',
      id: 'claude-fable-5',
      version: 'claude-fable-5',
      requestId: 'req_123',
    ),
  );

  group('formatTs', () {
    test('always writes exactly six fractional digits, UTC, Z', () {
      expect(
        formatTs(DateTime.utc(2026, 1, 2, 3, 4, 5)),
        '2026-01-02T03:04:05.000000Z',
      );
      expect(formatTs(ts), '2026-08-23T09:14:02.123456Z');
      expect(
        formatTs(DateTime.utc(2026, 1, 2, 3, 4, 5, 7)),
        '2026-01-02T03:04:05.007000Z',
      );
    });

    test('converts local times to UTC rather than dropping the zone', () {
      final local = DateTime.fromMicrosecondsSinceEpoch(
        ts.microsecondsSinceEpoch,
      );
      expect(formatTs(local), '2026-08-23T09:14:02.123456Z');
    });
  });

  group('Event.seal and encode', () {
    test('is deterministic and sorts keys', () {
      final e1 = Event.seal(chatDraft(), prev: aRef, ts: ts);
      final e2 = Event.seal(chatDraft(), prev: aRef, ts: ts);
      expect(e1.encode(), e2.encode());
      expect(e1.encode(), startsWith('{"actor":"assistant",'));
      expect(e1.encode(), isNot(contains('\n')));
    });

    test('genesis events carry prev null', () {
      final line = Event.seal(chatDraft(), prev: null, ts: ts).encode();
      expect(line, contains('"prev":null'));
    });

    test('an assistant event without a model block is refused', () {
      final draft = EventDraft(
        type: EventTypes.chatMessage,
        actor: Actor.assistant,
        source: 'sai/tui',
        payload: {'text': 'hi'},
      );
      expect(() => Event.seal(draft, prev: null, ts: ts), throwsArgumentError);
    });

    test('lines above 1 MiB are refused', () {
      final draft = EventDraft(
        type: EventTypes.toolResult,
        actor: Actor.system,
        source: 'sai/tui',
        payload: {'out': 'x' * (1 << 20)},
      );
      expect(() => Event.seal(draft, prev: null, ts: ts), throwsArgumentError);
    });
  });

  group('Event.decodeLine', () {
    test('round-trips every field, model lineage included', () {
      for (final draft in [
        chatDraft(),
        EventDraft(
          type: EventTypes.providerResponse,
          actor: Actor.assistant,
          source: 'sai/app',
          payload: {'raw': '…'},
          model: const ModelRef(provider: 'anthropic', id: 'claude-fable-5'),
          refs: [aRef],
        ),
        EventDraft(
          type: EventTypes.toolCall,
          actor: Actor.assistant,
          source: 'sai/tui',
          payload: {
            'name': 'search',
            'arguments': {'q': 'x'},
          },
          model: const ModelRef(provider: 'anthropic', id: 'claude-fable-5'),
        ),
        EventDraft(
          type: EventTypes.toolResult,
          actor: Actor.system,
          source: 'sai/tui',
          payload: {'ok': true},
          refs: [aRef, bRef],
        ),
      ]) {
        final sealed = Event.seal(draft, prev: aRef, ts: ts);
        final decoded = Event.decodeLine(sealed.encode());
        expect(decoded.encode(), sealed.encode());
        expect(decoded.type, draft.type);
        expect(decoded.actor, draft.actor);
        expect(decoded.source, draft.source);
        expect(decoded.payload, draft.payload);
        expect(decoded.model?.provider, draft.model?.provider);
        expect(decoded.model?.id, draft.model?.id);
        expect(decoded.model?.version, draft.model?.version);
        expect(decoded.model?.requestId, draft.model?.requestId);
        expect(decoded.refs, draft.refs ?? const <BlobRef>[]);
        expect(decoded.prev, aRef);
        expect(decoded.ts, ts);
        expect(decoded.tsText, formatTs(ts));
      }
    });

    test('rejects malformed lines', () {
      final good = jsonDecode(
        Event.seal(chatDraft(), prev: aRef, ts: ts).encode(),
      ) as Map<String, Object?>;

      String mutate(void Function(Map<String, Object?> m) change) {
        final m = Map<String, Object?>.from(good);
        change(m);
        return jsonEncode(m);
      }

      final badLines = <String, String>{
        'not JSON': 'nope',
        'JSON array': '[1,2]',
        'missing v': mutate((m) => m.remove('v')),
        'wrong v': mutate((m) => m['v'] = 1),
        'missing ts': mutate((m) => m.remove('ts')),
        'ts with offset': mutate(
          (m) => m['ts'] = '2026-08-23T09:14:02.123456+00:00',
        ),
        'ts with three digits': mutate(
          (m) => m['ts'] = '2026-08-23T09:14:02.123Z',
        ),
        'ts not a date': mutate((m) => m['ts'] = '2026-13-99T99:99:99.000000Z'),
        'missing type': mutate((m) => m.remove('type')),
        'uppercase type': mutate((m) => m['type'] = 'Chat.Message'),
        'unknown actor': mutate((m) => m['actor'] = 'robot'),
        'empty source': mutate((m) => m['source'] = ''),
        'payload not an object': mutate((m) => m['payload'] = 7),
        'missing prev': mutate((m) => m.remove('prev')),
        'prev in OCI form': mutate((m) => m['prev'] = 'sha256:${'0' * 64}'),
        'assistant without model': mutate((m) => m.remove('model')),
        'model missing provider': mutate(
          (m) => m['model'] = {'id': 'claude-fable-5'},
        ),
        'model with unknown key': mutate(
          (m) => m['model'] = {
            'provider': 'anthropic',
            'id': 'claude-fable-5',
            'temperature': 1,
          },
        ),
        'refs not a list': mutate((m) => m['refs'] = 'sha256-00'),
        'refs with a bad ref': mutate((m) => m['refs'] = ['nope']),
        'refs empty': mutate((m) => m['refs'] = <String>[]),
        'unknown top-level key': mutate((m) => m['extra'] = 1),
      };
      badLines.forEach((reason, line) {
        expect(
          () => Event.decodeLine(line),
          throwsFormatException,
          reason: reason,
        );
      });
    });

    test('a system event needs no model, and may carry one', () {
      final line = mutateModelOntoSystem();
      expect(Event.decodeLine(line).model?.provider, 'anthropic');
    });
  });
}

String mutateModelOntoSystem() {
  final ts = DateTime.utc(2026, 8, 23);
  final sealed = Event.seal(
    EventDraft(
      type: EventTypes.providerRequest,
      actor: Actor.system,
      source: 'sai/tui',
      payload: {'messages': []},
      model: const ModelRef(provider: 'anthropic', id: 'claude-fable-5'),
    ),
    prev: null,
    ts: ts,
  );
  return sealed.encode();
}
