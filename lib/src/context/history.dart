import 'dart:async';
import 'dart:convert';
import 'dart:io';

List<String> parseHistoryLines(
  String raw, {
  required int limit,
}) {
  if (raw.trim().isEmpty) {
    return const [];
  }

  final lines = const LineSplitter().convert(raw);
  final cleaned = lines
      .map((line) => _stripHistoryPrefix(line.trimRight()))
      .where((line) => line.isNotEmpty)
      .toList(growable: false);
  if (cleaned.length <= limit) {
    return cleaned;
  }
  return cleaned.sublist(cleaned.length - limit);
}

Future<List<String>> loadHistoryFile(
  String path, {
  required int limit,
}) async {
  final file = File(path);
  if (!await file.exists()) {
    return const [];
  }
  try {
    final raw = await file.readAsString();
    return parseHistoryLines(raw, limit: limit);
  } on IOException {
    return const [];
  }
}

String _stripHistoryPrefix(String line) {
  final match = RegExp(r'^\s*\d+\s+(.*)$').firstMatch(line);
  if (match != null && match.groupCount >= 1) {
    return match.group(1)!.trimLeft();
  }
  return line;
}
