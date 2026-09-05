import 'dart:convert';
import 'dart:io';

import 'package:sai_core/sai_core.dart';
import 'package:test/test.dart';

import '../package_root.dart';

/// `profile/system-prompt.md` is the assistant's profile (#14) and
/// `lib/src/context/profile.g.dart` its compiled copy: an installed sai
/// has no repository to read. The file is the source and this suite
/// refuses a stale copy — `dart run tool/gen_profile.dart` in
/// packages/sai_core regenerates it — and holds the text to what the
/// rest of the core relies on.
void main() {
  late Directory repo;
  late List<int> bytes;
  late String text;

  setUpAll(() async {
    repo = (await packageRoot()).parent.parent;
    bytes = File('${repo.path}/profile/system-prompt.md').readAsBytesSync();
    text = utf8.decode(bytes);
  });

  const stale =
      'profile.g.dart is stale; run `dart run tool/gen_profile.dart` in '
      'packages/sai_core';

  test('the compiled text is the file, without its final newline', () {
    expect(text, endsWith('\n'));
    expect(text, isNot(endsWith('\n\n')));
    expect(assistantProfile, text.substring(0, text.length - 1), reason: stale);
  });

  test('the compiled id is the sha256 blobref of the exact bytes', () {
    expect(
      assistantProfileId,
      BlobRef.sha256OfBytes(bytes).toString(),
      reason: stale,
    );
  });

  test('every revision has a changelog entry naming its id', () {
    final changelog = File('${repo.path}/profile/CHANGELOG.md')
        .readAsStringSync();
    final first = RegExp(r'sha256-[a-f0-9]{64}').firstMatch(changelog);
    expect(
      first?.group(0),
      assistantProfileId,
      reason:
          'profile/CHANGELOG.md must open with the revision in force: a '
          'changed profile is a new entry (and a decision.made, recorded by '
          'whoever keeps the sai it ships to)',
    );
  });

  test('the profile names sai and tells the model about the marker', () {
    expect(assistantProfile.split('\n').first, startsWith('You are sai'));
    // The file names the marker literally; the generator injects nothing,
    // so this is the one guard that the text and marker.dart agree.
    expect(assistantProfile, contains(proposeMarker));
    // The profile must not forbid what the marker exists to allow.
    expect(assistantProfile, isNot(contains('You cannot change the list.')));
    expect(assistantProfile, contains('never mention handles'));
    expect(assistantProfile, contains('cannot see the list right now'));
  });

  test('the text is clean: no trailing spaces, no carriage returns', () {
    expect(assistantProfile, isNot(contains('\r')));
    for (final line in assistantProfile.split('\n')) {
      expect(line, line.trimRight());
    }
    expect(assistantProfile.trim(), assistantProfile);
  });
}
