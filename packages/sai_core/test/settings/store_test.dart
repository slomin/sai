import 'dart:io';

import 'package:sai_core/sai_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late File file;
  late SettingsStore store;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('sai_settings_store_test');
    file = File('${tmp.path}/settings.json');
    store = SettingsStore(file, clock: () => DateTime.utc(2026, 8, 24, 10));
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  List<String> names() =>
      tmp.listSync().map((e) => e.uri.pathSegments.last).toList()..sort();

  test('a missing file loads empty and writes nothing', () {
    final settings = store.load();
    expect(settings.llm, isNull);
    expect(settings.problem, isNull);
    expect(file.existsSync(), isFalse);
  });

  test('save then load round-trips, leaving no temp file', () {
    store.save(const Settings(llm: 'fake'));
    expect(names(), ['settings.json']);
    expect(file.readAsStringSync(), '{"llm":"fake","version":0}');
    expect(store.load().llm, 'fake');
  });

  test('the temp file name carries the pid', () {
    expect(store.tempFile.path, '${file.path}.$pid.tmp');
  });

  test('a missing parent directory is created', () {
    final nested = SettingsStore(File('${tmp.path}/a/b/settings.json'));
    nested.save(const Settings(llm: 'fake'));
    expect(nested.load().llm, 'fake');
  });

  test('unparseable content is quarantined once and reported', () {
    file.writeAsStringSync('not json');
    final settings = store.load();
    expect(settings.llm, isNull);
    expect(settings.problem, contains('moved aside'));
    expect(names(), ['settings.json.bad-20260824T100000Z']);
    // Loading again finds nothing to quarantine.
    expect(store.load().problem, isNull);
    // And the next write starts fresh.
    store.save(settings.withLlm('fake'));
    expect(store.load().llm, 'fake');
  });

  test('a newer version is reported, kept, and never overwritten', () {
    file.writeAsStringSync('{"version":7,"llm":"future","x":1}');
    final settings = store.load();
    expect(settings.llm, isNull);
    expect(settings.problem, contains('version 7'));
    expect(() => store.save(settings.withLlm('fake')), throwsStateError);
    expect(file.readAsStringSync(), '{"version":7,"llm":"future","x":1}');
    expect(names(), ['settings.json']);
  });

  test('a fresh store over the same file is not read-only', () {
    file.writeAsStringSync('{"version":7}');
    store.load();
    file.writeAsStringSync('{"version":0,"llm":"fake"}');
    final again = SettingsStore(file);
    expect(again.load().llm, 'fake');
    again.save(const Settings(llm: 'other'));
    expect(again.load().llm, 'other');
  });
}
