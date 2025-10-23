import 'dart:io';

class SaiContextConfig {
  SaiContextConfig({
    Map<String, String>? environment,
  }) : _env = environment ?? Platform.environment {
    historyCount = _parseHistoryCount(_env['SAI_HISTORY_COUNT']);
    noSend = _parseNoSend(_env['SAI_NO_SEND']);
    ignoreGlobs = _parseIgnoreGlobs(_env['SAI_IGNORE_GLOBS']);
    maxListing = _parseMaxListing(_env['SAI_MAX_LISTING']);
    historyFile = _parseHistoryFile(_env['SAI_HISTORY_FILE']);
  }

  final Map<String, String> _env;

  late final int historyCount;
  late final Set<String> noSend;
  late final List<String> ignoreGlobs;
  late final int maxListing;
  late final String? historyFile;

  static int _parseHistoryCount(String? value) {
    final parsed = int.tryParse(value ?? '');
    if (parsed == null) {
      return 10;
    }
    return parsed.clamp(1, 500);
  }

  static Set<String> _parseNoSend(String? value) {
    if (value == null || value.trim().isEmpty) {
      return <String>{};
    }
    return value
        .split(',')
        .map((item) => item.trim().toLowerCase())
        .where((item) => item.isNotEmpty)
        .toSet();
  }

  static List<String> _parseIgnoreGlobs(String? value) {
    if (value == null || value.trim().isEmpty) {
      return const [];
    }
    return value
        .split(',')
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toList(growable: false);
  }

  static int _parseMaxListing(String? value) {
    final parsed = int.tryParse(value ?? '');
    if (parsed == null) {
      return 5000;
    }
    return parsed.clamp(100, 20000);
  }

  static String? _parseHistoryFile(String? value) {
    if (value == null || value.trim().isEmpty) {
      return null;
    }
    return value.trim();
  }
}
