import 'package:sai_core/sai_core.dart';
import 'package:test/test.dart';

void main() {
  group('SaiIdentity', () {
    test('stable is exactly what sai was before flavors', () {
      const s = SaiIdentity.stable;
      expect(s.displayName, 'sai');
      expect(s.name, 'stable');
      expect(s.slug, 'sai');
      expect(s.bundleId, 'me.slominski.sai');
      expect(s.keychainService, saiKeychainService);
      expect(s.dataDirName, 'sai');
      expect(s.tuiCommand, 'sai_tui');
      expect(s.appBundle, 'sai.app');
      expect(s.appExecutable, 'sai');
      expect(s.flavor, 'stable');
      expect(s.isDev, isFalse);
    });

    test('dev differs in every location-bearing value', () {
      const d = SaiIdentity.dev;
      expect(d.displayName, 'sai dev');
      expect(d.name, 'dev');
      expect(d.slug, 'sai-dev');
      expect(d.bundleId, 'me.slominski.sai.dev');
      // Dev holds no credentials (#95): no service, nothing to file under.
      expect(d.keychainService, isNull);
      expect(d.dataDirName, 'sai-dev');
      expect(d.tuiCommand, 'sai_tui-dev');
      expect(d.appBundle, 'sai-dev.app');
      expect(d.appExecutable, 'sai-dev');
      expect(d.flavor, 'dev');
      expect(d.isDev, isTrue);
      for (final field in [
        (SaiIdentity s) => s.slug,
        (SaiIdentity s) => s.bundleId,
        (SaiIdentity s) => s.keychainService ?? '',
        (SaiIdentity s) => s.dataDirName,
        (SaiIdentity s) => s.tuiCommand,
        (SaiIdentity s) => s.appBundle,
      ]) {
        expect(field(SaiIdentity.stable), isNot(field(SaiIdentity.dev)));
      }
    });

    test('an unflavored Flutter build is dev, never stable', () {
      expect(SaiIdentity.fromFlavor(null), SaiIdentity.dev);
      expect(SaiIdentity.fromFlavor(''), SaiIdentity.dev);
      expect(SaiIdentity.fromFlavor('dev'), SaiIdentity.dev);
      expect(SaiIdentity.fromFlavor('stable'), SaiIdentity.stable);
    });

    test('there is no third flavor', () {
      expect(() => SaiIdentity.fromFlavor('qa'), throwsStateError);
      expect(() => SaiIdentity.values.byName('qa'), throwsArgumentError);
    });

    test('the flavor word round-trips through the enum name', () {
      for (final identity in SaiIdentity.values) {
        expect(identity.flavor, identity.name);
        expect(SaiIdentity.values.byName(identity.flavor), identity);
        expect(SaiIdentity.fromFlavor(identity.flavor), identity);
      }
    });
  });
}
