/// Compiles `profile/system-prompt.md` into `lib/src/context/profile.g.dart`
/// (#14): the prompt as one const, without the file's final newline, and
/// the sha256 blobref of the file's exact bytes as another. An installed
/// sai has no repository to read, so the profile ships inside the
/// binary; the file stays the source, reviewed like any other.
///
///     dart run tool/gen_profile.dart      (in packages/sai_core)
///
/// `test/context/profile_test.dart` refuses a stale copy. No process is
/// spawned and no build system is involved: this is the one generated
/// Dart file in the tree, made by hand and committed.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';

Future<void> main() async {
  final lib = await Isolate.resolvePackageUri(
    Uri.parse('package:sai_core/sai_core.dart'),
  );
  final package = File.fromUri(lib!).parent.parent;
  final repo = package.parent.parent;
  final source = File('${repo.path}/profile/system-prompt.md');
  final target = File('${package.path}/lib/src/context/profile.g.dart');
  final bytes = source.readAsBytesSync();
  final text = utf8.decode(bytes);
  final prompt = text.endsWith('\n')
      ? text.substring(0, text.length - 1)
      : text;
  final id = 'sha256-${sha256.convert(bytes)}';
  target.writeAsStringSync(generateProfileSource(prompt: prompt, id: id));
  stdout.writeln('wrote ${target.path}');
  stdout.writeln(id);
}

/// The generated file: formatted as `dart format` leaves it, so the format
/// gate never touches it.
String generateProfileSource({required String prompt, required String id}) {
  final out = StringBuffer()
    ..writeln('// GENERATED from profile/system-prompt.md by')
    ..writeln('// `dart run tool/gen_profile.dart` (in packages/sai_core).')
    ..writeln('// Do not edit: change the profile and run it again;')
    ..writeln('// test/context/profile_test.dart refuses a stale copy.')
    ..writeln()
    ..writeln("/// The assistant's standing instructions (#14):")
    ..writeln('/// `profile/system-prompt.md`, byte for byte, without the')
    ..writeln("/// file's final newline. Provider-independent — the same text")
    ..writeln(
      '/// goes to every model — and the first message of every request,',
    )
    ..writeln(
      '/// so a change here is a new `context_hash` on every line and a',
    )
    ..writeln('/// new prefix to warm.')
    ..writeln('const assistantProfile =');
  final lines = prompt.split('\n');
  final literals = <String>[];
  for (final (i, line) in lines.indexed) {
    final tail = i == lines.length - 1 ? '' : r'\n';
    final chunks = _chunks(_escape(line));
    for (final (j, chunk) in chunks.indexed) {
      literals.add("'$chunk${j == chunks.length - 1 ? tail : ''}'");
    }
  }
  for (final (i, literal) in literals.indexed) {
    out.writeln('    $literal${i == literals.length - 1 ? ';' : ''}');
  }
  out
    ..writeln()
    ..writeln('/// The sha256 blobref of the exact bytes of')
    ..writeln('/// `profile/system-prompt.md` (`shasum -a 256` reproduces it):')
    ..writeln(
      '/// the revision in force, what a `decision.made` names and what',
    )
    ..writeln("/// a `provider.request`'s first message can be matched to.")
    ..writeln('const assistantProfileId =')
    ..writeln("    '$id';");
  return out.toString();
}

String _escape(String line) =>
    line.replaceAll(r'\', r'\\').replaceAll("'", r"\'").replaceAll(r'$', r'\$');

/// Splits an escaped line at spaces into pieces of at most [max]
/// characters (the space stays at the end of the piece), so the generated
/// literals read as prose; an empty line is one empty piece.
List<String> _chunks(String text, {int max = 66}) {
  if (text.isEmpty) return const [''];
  final out = <String>[];
  var rest = text;
  while (rest.length > max) {
    var cut = rest.lastIndexOf(' ', max - 1);
    if (cut <= 0) cut = max - 1;
    out.add(rest.substring(0, cut + 1));
    rest = rest.substring(cut + 1);
  }
  if (rest.isNotEmpty) out.add(rest);
  return out;
}
