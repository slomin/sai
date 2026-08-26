import 'dart:io';

import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  test('the bundled sqlite opens a file database', () {
    final tmp = Directory.systemTemp.createTempSync('sai_sqlite_smoke');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final db = sqlite3.open('${tmp.path}/t.sqlite');
    db.execute('create table t (x integer)');
    db.execute('insert into t values (1)');
    expect(db.select('select x from t').single['x'], 1);
    db.close();
    expect(sqlite3.version.versionNumber, greaterThan(3040000));
  });
}
