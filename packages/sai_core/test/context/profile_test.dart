import 'dart:convert';
import 'dart:io';

import 'package:sai_core/sai_core.dart';
import 'package:test/test.dart';

import '../../tool/gen_profile.dart';
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

  test('the committed copy is what the generator writes today', () {
    final generated = File(
      '${repo.path}/packages/sai_core/lib/src/context/profile.g.dart',
    ).readAsStringSync();
    expect(
      generated,
      generateProfileSource(
        prompt: text.substring(0, text.length - 1),
        id: assistantProfileId,
      ),
      reason: stale,
    );
  });

  test('the generator never cuts a literal inside an escape', () {
    // One word of 70 characters ending in an apostrophe, then more: the
    // old chunker cut at a fixed offset and could split the \' in two.
    final prompt = "${'x' * 69}' and a dollar \$ and a backslash \\ end";
    final source = generateProfileSource(prompt: prompt, id: 'sha256-00');
    final literal = RegExp(r"^\s*'((?:[^'\\]|\\.)*)'(?:;)?$");
    // The prompt's literals only — not the id const that follows them.
    final lines = source
        .split('\n')
        .where((l) => l.trimLeft().startsWith("'"))
        .where((l) => !l.trimLeft().startsWith("'sha256-"))
        .toList();
    expect(lines, isNotEmpty);
    for (final line in lines) {
      expect(line, matches(literal), reason: 'not one well-formed literal');
    }
    // Every escape is a whole one, and the words come back unchanged.
    final joined = lines
        .map((l) => literal.firstMatch(l)![1]!)
        .join()
        .replaceAll(r'\$', r'$')
        .replaceAll(r"\'", "'")
        .replaceAll(r'\\', r'\');
    expect(joined, prompt);
  });

  test('a control character is refused before anything is written', () {
    expect(hasControlCharacters('plain\nlines'), isFalse);
    expect(hasControlCharacters('crlf\r\n'), isTrue);
    expect(hasControlCharacters('a\ttab'), isTrue);
    expect(hasControlCharacters('nul\x00'), isTrue);
  });

  test('the text is clean: no trailing spaces, no carriage returns', () {
    expect(assistantProfile, isNot(contains('\r')));
    for (final line in assistantProfile.split('\n')) {
      expect(line, line.trimRight());
    }
    expect(assistantProfile.trim(), assistantProfile);
  });
}
