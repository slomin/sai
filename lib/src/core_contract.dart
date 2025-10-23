import 'dart:convert';
import 'dart:io';

/// Exit codes returned by `sai-core`.
class SaiExitCode {
  SaiExitCode._();

  static const success = 0;
  static const badInput = 2;
  static const contextFailure = 3;
  static const modelFailure = 4;
}

/// JSON payload sent to `sai-core`.
class SaiContextPayload {
  SaiContextPayload({
    required this.message,
    required this.shell,
    required this.cwd,
    required List<String> history,
  }) : history = List.unmodifiable(history);

  factory SaiContextPayload.fromJson(Map<String, Object?> json) {
    List<String> _stringList(Object? maybeList) {
      if (maybeList is List) {
        return maybeList
            .where((element) => element is String)
            .cast<String>()
            .toList(growable: false);
      }
      return const <String>[];
    }

    return SaiContextPayload(
      message: (json['message'] as String?)?.trim() ?? '',
      shell: (json['shell'] as String?)?.trim() ?? 'unknown',
      cwd: (json['cwd'] as String?)?.trim() ?? '.',
      history: _stringList(json['history']),
    );
  }

  final String message;
  final String shell;
  final String cwd;
  final List<String> history;

  Map<String, Object?> toJson() => <String, Object?>{
        'message': message,
        'shell': shell,
        'cwd': cwd,
        'history': history,
      };
}

/// Encodes the payload as UTF-8 JSON on an IOSink.
Future<void> writePayloadJson(
  SaiContextPayload payload, {
  required IOSink sink,
}) async {
  final encoder = JsonEncoder.withIndent('  ');
  sink
    ..writeln(encoder.convert(payload.toJson()))
    ..flush();
}

/// Reads JSON payload from stdin.
Future<SaiContextPayload> readPayloadJson(Stream<List<int>> source) async {
  final buffer = await utf8.decoder.bind(source).join();
  if (buffer.trim().isEmpty) {
    throw const SaiPayloadFormatException('Empty JSON payload');
  }
  try {
    final jsonMap = jsonDecode(buffer) as Map<String, Object?>;
    return SaiContextPayload.fromJson(jsonMap);
  } on FormatException catch (err) {
    throw SaiPayloadFormatException(
      'Invalid JSON payload: ${err.message}',
    );
  }
}

class SaiPayloadFormatException implements Exception {
  const SaiPayloadFormatException(this.message);
  final String message;

  @override
  String toString() => 'SaiPayloadFormatException: $message';
}
