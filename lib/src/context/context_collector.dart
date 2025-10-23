import 'dart:io';

import '../core_contract.dart';
import 'config.dart';
import 'history.dart' as history;
import 'listing.dart' as listing;
import 'redaction.dart';

class SaiContextCollector {
  SaiContextCollector({
    SaiContextConfig? config,
    SaiRedactor? redactor,
  })  : _config = config ?? SaiContextConfig(),
        _redactor = redactor ?? SaiRedactor();

  final SaiContextConfig _config;
  final SaiRedactor _redactor;

  Future<SaiContextPayload> collect({
    required String message,
    String? shell,
    List<String> historyLines = const [],
    bool historyProvided = false,
  }) async {
    final sanitizedMessage = _redactor.redact(message);
    final shellName = _resolveShell(shell);
    final cwd = _config.noSend.contains('pwd') ? '' : Directory.current.path;

    final sanitizedHistory =
        historyProvided && !_config.noSend.contains('history')
            ? _sanitizeHistory(historyLines)
            : const <String>[];

    return SaiContextPayload(
      message: sanitizedMessage,
      shell: shellName,
      cwd: cwd,
      history: sanitizedHistory,
    );
  }

  List<String> parseRawHistory(String raw) {
    return history.parseHistoryLines(
      raw,
      limit: _config.historyCount,
    );
  }

  Future<List<String>> loadHistoryFromFile(String path) {
    return history.loadHistoryFile(
      path,
      limit: _config.historyCount,
    );
  }

  String? get historyFilePath => _config.historyFile;

  listing.DirectorySnapshot collectDirectorySnapshot() {
    if (_config.noSend.contains('listing')) {
      return listing.DirectorySnapshot(
        entries: const [],
        truncated: false,
      );
    }

    return listing.collectDirectorySnapshot(
      ignorePatterns: _config.ignoreGlobs,
      maxEntries: _config.maxListing,
    );
  }

  List<String> _sanitizeHistory(List<String> lines) {
    final sanitized = lines
        .map((line) => _redactor.redact(line.trim()))
        .where((line) => line.isNotEmpty)
        .toList();
    final limit = _config.historyCount;
    if (sanitized.length <= limit) {
      return sanitized;
    }
    return sanitized.sublist(sanitized.length - limit);
  }

  String _resolveShell(String? provided) {
    if (provided != null && provided.trim().isNotEmpty) {
      return provided.trim();
    }
    final envShell = Platform.environment['SHELL'];
    if (envShell != null && envShell.isNotEmpty) {
      return envShell.split('/').last;
    }
    if (Platform.isMacOS) {
      return 'zsh';
    }
    return 'unknown';
  }
}
