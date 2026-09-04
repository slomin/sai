import 'package:sai_core/sai_core.dart';
import 'package:test/test.dart';

/// A provider that is installed and can be asked for its tag.
LlmProvider provider(String id, {LlmPrivacy privacy = LlmPrivacy.local}) =>
    FakeLlmProvider(id: id, displayName: id, privacy: privacy);

const ok = EndpointInfo(health: EndpointHealth.ok);
const loading = EndpointInfo(health: EndpointHealth.loading);
const down = EndpointInfo(
  health: EndpointHealth.unavailable,
  failure: LlmFailure(LlmFailureKind.unreachable, 'nope'),
);
const timedOut = EndpointInfo(
  health: EndpointHealth.unavailable,
  failure: LlmFailure(LlmFailureKind.timeout, 'nope'),
);

LlmResolution resolve(
  List<String> order, {
  Map<String, LlmProvider> registry = const {},
  Map<String, String> misconfigured = const {},
  Map<String, String> credentials = const {},
  Map<String, EndpointInfo> health = const {},
  bool shareTasksWithCloud = false,
}) => resolveLlm(
  order: order,
  registry: registry,
  misconfigured: misconfigured,
  credentialProblem: (id) => credentials[id],
  health: health,
  policy: PrivacyPolicy(shareTasksWithCloud: shareTasksWithCloud),
);

void main() {
  group('resolveLlm', () {
    test('an empty order resolves to nothing at all', () {
      final resolution = resolve(const []);
      expect(resolution.provider, isNull);
      expect(resolution.first, isNull);
      expect(resolution.skipped, isEmpty);
      expect(resolution.isFallback, isFalse);
      expect(resolution, LlmResolution.none);
    });

    test('the first entry answers when nothing is wrong with it', () {
      final lan = provider('lan');
      final resolution = resolve(
        ['lan', 'local'],
        registry: {'lan': lan, 'local': provider('local')},
        health: const {'lan': ok, 'local': ok},
      );
      expect(resolution.provider, same(lan));
      expect(resolution.first, 'lan');
      expect(resolution.skipped, isEmpty);
      expect(resolution.isFallback, isFalse);
    });

    test('an unprobed provider answers: a send never waits for a probe', () {
      final resolution = resolve(['lan'], registry: {'lan': provider('lan')});
      expect(resolution.provider?.id, 'lan');
      expect(resolution.skipped, isEmpty);
    });

    test('an unreachable head falls through, naming what it skipped', () {
      final local = provider('local');
      final resolution = resolve(
        ['lan', 'local'],
        registry: {'lan': provider('lan'), 'local': local},
        health: const {'lan': down, 'local': ok},
      );
      expect(resolution.provider, same(local));
      expect(resolution.first, 'lan');
      expect(resolution.isFallback, isTrue);
      expect(resolution.skipped, hasLength(1));
      expect(resolution.skipped.single.id, 'lan');
      expect(resolution.skipped.single.reason, SkipReason.unreachable);
      expect(resolution.skipped.single.word, 'unreachable');
    });

    test('the failure kind is the word, when the endpoint gave one', () {
      final resolution = resolve(
        ['lan', 'local'],
        registry: {'lan': provider('lan'), 'local': provider('local')},
        health: const {'lan': timedOut},
      );
      expect(resolution.skipped.single.word, 'timeout');
      expect(resolution.skipped.single.reason, SkipReason.unreachable);
    });

    test('a loading endpoint is skipped, not waited for', () {
      final resolution = resolve(
        ['lan', 'local'],
        registry: {'lan': provider('lan'), 'local': provider('local')},
        health: const {'lan': loading},
      );
      expect(resolution.provider?.id, 'local');
      expect(resolution.skipped.single.reason, SkipReason.loading);
      expect(resolution.skipped.single.word, 'loading');
    });

    test('an id nothing installed answers is skipped as unavailable', () {
      final resolution = resolve(
        ['gone', 'local'],
        registry: {'local': provider('local')},
      );
      expect(resolution.provider?.id, 'local');
      expect(resolution.skipped.single.reason, SkipReason.unavailable);
      expect(resolution.skipped.single.word, 'not available');
    });

    test('a configuration its kind refused is skipped as misconfigured', () {
      final resolution = resolve(
        ['half', 'local'],
        registry: {'local': provider('local')},
        misconfigured: const {'half': 'endpoint'},
      );
      expect(resolution.provider?.id, 'local');
      expect(resolution.skipped.single.reason, SkipReason.misconfigured);
      expect(resolution.skipped.single.word, 'misconfigured');
    });

    test('a provider whose key is not there is skipped in its own words', () {
      final resolution = resolve(
        ['keyed', 'local'],
        registry: {'keyed': provider('keyed'), 'local': provider('local')},
        credentials: const {'keyed': 'no key'},
      );
      expect(resolution.provider?.id, 'local');
      expect(resolution.skipped.single.reason, SkipReason.noKey);
      expect(resolution.skipped.single.word, 'no key');
      expect(
        resolve(
          ['keyed', 'local'],
          registry: {'keyed': provider('keyed'), 'local': provider('local')},
          credentials: const {'keyed': 'no credentials in dev'},
        ).skipped.single.word,
        'no credentials in dev',
      );
    });

    test('a cloud provider is skipped while sharing is off, first choice or '
        'not', () {
      final cloudy = provider('cloudy', privacy: LlmPrivacy.cloud);
      final registry = {'cloudy': cloudy, 'local': provider('local')};
      final off = resolve(['cloudy', 'local'], registry: registry);
      expect(off.provider?.id, 'local');
      expect(off.skipped.single.reason, SkipReason.cloudDisallowed);
      expect(off.skipped.single.word, 'cloud not allowed');
      // Its own first choice, and still skipped: a chat never goes to a
      // cloud provider while the switch is off.
      final alone = resolve(['cloudy'], registry: registry);
      expect(alone.provider, isNull);
      expect(alone.skipped.single.reason, SkipReason.cloudDisallowed);
      // With the switch on it answers, and nothing was skipped.
      final on = resolve(
        ['cloudy', 'local'],
        registry: registry,
        shareTasksWithCloud: true,
      );
      expect(on.provider, same(cloudy));
      expect(on.skipped, isEmpty);
    });

    test('a health failure still bites a cloud provider sharing allows', () {
      final resolution = resolve(
        ['cloudy', 'local'],
        registry: {
          'cloudy': provider('cloudy', privacy: LlmPrivacy.cloud),
          'local': provider('local'),
        },
        health: const {'cloudy': down},
        shareTasksWithCloud: true,
      );
      expect(resolution.provider?.id, 'local');
      expect(resolution.skipped.single.reason, SkipReason.unreachable);
    });

    test('every entry passed over is named, in order', () {
      final resolution = resolve(
        ['gone', 'lan', 'cloudy', 'local'],
        registry: {
          'lan': provider('lan'),
          'cloudy': provider('cloudy', privacy: LlmPrivacy.cloud),
          'local': provider('local'),
        },
        health: const {'lan': down},
      );
      expect(resolution.provider?.id, 'local');
      expect(resolution.skipped.map((s) => '${s.id} ${s.word}'), [
        'gone not available',
        'lan unreachable',
        'cloudy cloud not allowed',
      ]);
    });

    test('nothing after the answer is judged', () {
      final resolution = resolve(
        ['lan', 'gone'],
        registry: {'lan': provider('lan')},
        health: const {'lan': ok},
      );
      expect(resolution.provider?.id, 'lan');
      expect(resolution.skipped, isEmpty);
    });

    test('an order where nothing can answer keeps every reason', () {
      final resolution = resolve(
        ['lan', 'cloudy'],
        registry: {
          'lan': provider('lan'),
          'cloudy': provider('cloudy', privacy: LlmPrivacy.cloud),
        },
        health: const {'lan': down},
      );
      expect(resolution.provider, isNull);
      expect(resolution.first, 'lan');
      expect(resolution.isFallback, isFalse);
      expect(resolution.skipped, hasLength(2));
    });

    test('what is not installed is not asked about its key, its tag or its '
        'health', () {
      final resolution = resolve(
        ['gone'],
        credentials: const {'gone': 'no key'},
        health: const {'gone': down},
      );
      expect(resolution.skipped.single.reason, SkipReason.unavailable);
      // Its kind refusing the configuration is the more precise word, and
      // the one the status line already uses.
      expect(
        resolve(
          ['half'],
          misconfigured: const {'half': 'endpoint'},
          credentials: const {'half': 'no key'},
        ).skipped.single.reason,
        SkipReason.misconfigured,
      );
    });

    test('two resolutions of the same outcome are equal', () {
      final lan = provider('lan');
      final registry = {'lan': lan, 'local': provider('local')};
      const health = {'lan': down};
      expect(
        resolve(['lan', 'local'], registry: registry, health: health),
        resolve(['lan', 'local'], registry: registry, health: health),
      );
      expect(
        resolve(['lan', 'local'], registry: registry, health: health).hashCode,
        resolve(['lan', 'local'], registry: registry, health: health).hashCode,
      );
      expect(
        resolve(['lan', 'local'], registry: registry, health: health),
        isNot(resolve(['lan', 'local'], registry: registry)),
      );
    });
  });

  group('the fallback line', () {
    test('names the first choice, what answered, and every skip', () {
      final resolution = resolve(
        ['lan', 'cloudy', 'local'],
        registry: {
          'lan': provider('lan'),
          'cloudy': provider('cloudy', privacy: LlmPrivacy.cloud),
          'local': provider('local'),
        },
        health: const {'lan': timedOut},
      );
      expect(fallbackPayload(resolution), {
        'first': 'lan',
        'chosen': 'local',
        'skipped': [
          {'provider': 'lan', 'reason': 'unreachable', 'detail': 'timeout'},
          {'provider': 'cloudy', 'reason': 'cloud_disallowed'},
        ],
      });
    });
  });
}
