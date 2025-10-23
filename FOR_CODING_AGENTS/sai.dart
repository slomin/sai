// bin/sai.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

void main(List<String> args) async {
  // --- parse args: optional --history - on stdin, and optional free-form prompt after `--`
  final env = Platform.environment;
  final start = DateTime.now();
  bool expectHistoryFromStdin = false;
  bool loadHistoryFromFile = false;
  bool loadHistoryLive = false;
  bool historyRequested = false;
  String? historyFileArg;
  int historyLimit =
      int.tryParse(env['SAI_HISTORY_COUNT'] ?? '')?.clamp(1, 500).toInt() ?? 20;
  bool widgetMode = _isTruthy(env['SAI_WIDGET_MODE']);
  final defaultHistorySource = env['SAI_HISTORY_SOURCE']?.toLowerCase();
  if (defaultHistorySource == 'live') {
    loadHistoryLive = true;
  } else if (defaultHistorySource == 'file') {
    loadHistoryFromFile = true;
  }
  String userLine = '';
  bool debugMode = _isTruthy(env['SAI_DEBUG']);
  for (int i = 0; i < args.length; i++) {
    final a = args[i];
    if (a == '--history') {
      historyRequested = true;
      if (i + 1 < args.length && args[i + 1] == '-') {
        expectHistoryFromStdin = true;
        i++;
      } else {
        if (i + 1 < args.length) {
          final next = args[i + 1];
          if (_isHistorySource(next)) {
            final mode = next.toLowerCase();
            loadHistoryLive = mode == 'live';
            loadHistoryFromFile = mode == 'file';
            i++;
          } else {
            final parsedLimit = int.tryParse(next);
            if (parsedLimit != null) {
              historyLimit = parsedLimit.clamp(1, 500).toInt();
              loadHistoryFromFile = true;
              i++;
            } else if (!next.startsWith('--')) {
              loadHistoryFromFile = true;
              historyFileArg = next;
              i++;
            } else {
              loadHistoryFromFile = true;
            }
          }
        } else {
          loadHistoryFromFile = true;
        }
      }
    } else if (a.startsWith('--history=')) {
      historyRequested = true;
      final value = a.substring('--history='.length);
      if (value == '-') {
        expectHistoryFromStdin = true;
      } else if (_isHistorySource(value)) {
        final mode = value.toLowerCase();
        loadHistoryLive = mode == 'live';
        loadHistoryFromFile = mode == 'file';
      } else {
        final parsedLimit = int.tryParse(value);
        if (parsedLimit != null) {
          loadHistoryFromFile = true;
          historyLimit = parsedLimit.clamp(1, 500).toInt();
        } else {
          loadHistoryFromFile = true;
          historyFileArg = value;
        }
      }
    } else if (a == '--history-file' && i + 1 < args.length) {
      historyRequested = true;
      loadHistoryFromFile = true;
      historyFileArg = args[++i];
    } else if (a.startsWith('--history-file=')) {
      historyRequested = true;
      loadHistoryFromFile = true;
      historyFileArg = a.substring('--history-file='.length);
    } else if (a == '--widget') {
      widgetMode = true;
    } else if (a == '--no-widget') {
      widgetMode = false;
    } else if (a == '--debug' || a == '-d') {
      debugMode = true;
    } else if (a == '--') {
      userLine = args.sublist(i + 1).join(' ').trim();
      break;
    } else {
      // treat positional args as a prompt fragment if no `--`
      userLine = [userLine, a].where((s) => s.isNotEmpty).join(' ');
    }
  }

  if (historyRequested && !expectHistoryFromStdin) {
    if (!loadHistoryLive && !loadHistoryFromFile) {
      if (defaultHistorySource == 'live') {
        loadHistoryLive = true;
      } else if (defaultHistorySource == 'file') {
        loadHistoryFromFile = true;
      } else if (defaultHistorySource == 'none') {
        // explicit opt-out
      } else {
        loadHistoryFromFile = true;
      }
    }
  } else {
    loadHistoryLive = false;
    loadHistoryFromFile = false;
  }

  // --- read history if piped
  List<String> history = const [];
  if (expectHistoryFromStdin) {
    final data = await utf8.decoder.bind(stdin).join();
    history = const LineSplitter().convert(data);
  } else if (historyRequested) {
    if (loadHistoryLive) {
      history = await _loadHistoryLive(
        limit: historyLimit,
        shellCandidates: _shellCandidates(env),
      );
    }
    if (history.isEmpty && loadHistoryFromFile) {
      history = await _loadHistory(
        explicitPath: historyFileArg,
        limit: historyLimit,
      );
    }
  } else if (!stdin.hasTerminal && userLine.isEmpty) {
    // if no flags but something is piped, treat it as "prompt"
    userLine = (await utf8.decoder.bind(stdin).join()).trim();
  }

  // --- gather cwd + file names (skip hidden & bulky dirs)
  final cwd = Directory.current.path;
  final entries = Directory.current
      .listSync(followLinks: false)
      .where((e) => !_isHidden(e))
      .where((e) => !_skipDir(e))
      .take(200)
      .toList();
  final fileNames = entries.map((e) => _basename(e.path)).toList();
  final fileSample = fileNames.take(20).toList();

  final historyTailLimit = historyLimit.clamp(1, 500).toInt();
  final historyTail = history.length <= historyTailLimit
      ? history
      : history.sublist(history.length - historyTailLimit);

  final lmEndpointRaw =
      env['SAI_LM_ENDPOINT'] ?? 'http://localhost:1234/v1/chat/completions';
  final lmEndpoint = Uri.tryParse(lmEndpointRaw);
  final lmModel = env['SAI_LM_MODEL'] ?? 'qwen3-vl-4b-instruct-mlx';
  final lmSystemPrompt = env['SAI_LM_SYSTEM_PROMPT'] ??
      'You are a command line helper, your job is purely to reply questions about command line in zsh, you reply in super short sentences.';
  final lmTemperature = double.tryParse(env['SAI_LM_TEMPERATURE'] ?? '');

  final userPromptForModel =
      userLine.isEmpty ? '(no direct prompt provided)' : userLine;
  final historyForModel = historyTail.isEmpty
      ? '  (none)'
      : historyTail.map((line) => '  - $line').join('\n');
  final filesForModel = fileSample.isEmpty
      ? '  (none)'
      : fileSample.map((name) => '  - $name').join('\n');

  final modelUserMessage = 'User prompt: ' +
      userPromptForModel +
      '\n\nContext for you (zsh session):\n' +
      '- Working directory to run commands from: ' +
      cwd +
      '\n' +
      '- Recent zsh commands (oldest -> newest):\n' +
      historyForModel +
      '\n' +
      '- Visible files/folders in this directory (sample):\n' +
      filesForModel +
      '\n\nReply with the shortest helpful zsh command or tip (max two short sentences, no code fences).\n';

  // quick helpers for presence detection
  bool has(String name) =>
      File(name).existsSync() || Directory(name).existsSync();
  bool anyOf(Iterable<String> names) => names.any((n) => has(n));

  // --- build six suggestion candidates that "make sense" in terminals
  final candidates = <String>[
    if (has('package.json'))
      'npm run dev'
    else if (has('pnpm-lock.yaml'))
      'pnpm dev'
    else
      'git status',

    if (has('pubspec.yaml')) 'dart pub get && dart run' else 'ls -la',

    if (has('Cargo.toml'))
      'cargo build && cargo test'
    else
      'make -n || true', // harmless if no Makefile

    if (has('go.mod'))
      'go test ./... && go run ./...'
    else
      'grep -R \"TODO\" -n . | head -20',

    if (anyOf(['gradlew', 'gradlew.bat', 'build.gradle', 'build.gradle.kts']))
      './gradlew build'
    else
      'git log --oneline -n 10',

    if (anyOf(['docker-compose.yml', 'compose.yaml', 'compose.yml']))
      'docker compose up --build'
    else
      'rg -n \"main\\(|fn\\s+main|int\\s+main\" || true', // ripgrep if present
  ];

  // always exactly six (above ensures it)
  final rand = Random();
  final delayMs = 300 + rand.nextInt(1700); // 300..2000 ms
  final fallbackSuggestion = candidates[rand.nextInt(candidates.length)];

  final useColor = _shouldUseColor(env);
  final spinner = _Spinner(
    enabled: _shouldSpin(env, widgetMode),
    useColor: useColor,
  );
  String? aiSuggestion;
  await spinner.run(() async {
    if (lmEndpoint != null && lmEndpoint.hasScheme) {
      aiSuggestion = await _fetchLMSuggestion(
        endpoint: lmEndpoint,
        model: lmModel,
        systemPrompt: lmSystemPrompt,
        userMessage: modelUserMessage,
        temperature: lmTemperature,
      );
    }

    await Future.delayed(Duration(milliseconds: delayMs));
  });

  final trimmedSuggestion = aiSuggestion?.trim();
  final usedLmSuggestion = (trimmedSuggestion?.isNotEmpty ?? false);
  final suggestionText =
      usedLmSuggestion ? trimmedSuggestion! : fallbackSuggestion;
  final elapsed = DateTime.now().difference(start);

  // If you ever need the context, keep it handy (not printed):
  final _ = {
    'pwd': cwd,
    'files': fileNames.take(50).toList(),
    'historyTail': historyTail,
    'userLine': userLine,
  };

  if (widgetMode) {
    final widgetLine = suggestionText.split('\n').first.trim();
    stdout.write(widgetLine.isEmpty ? fallbackSuggestion : widgetLine);
    return;
  }

  if (!debugMode) {
    final compactLine = suggestionText
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .join(' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final prefix = _paint('SAI:', useColor ? _ansiCyanBold : null, useColor);
    final body = _paint(compactLine, useColor ? _ansiGreen : null, useColor);
    stdout.writeln('$prefix $body');
    final timingLine = '[Total Response Time] ${elapsed.inMilliseconds} ms';
    stdout.writeln(_paint(timingLine, useColor ? _ansiDim : null, useColor));
    return;
  }

  _emitBlock(
    'Input text',
    userLine.isEmpty ? ['(none)'] : [userLine],
    useColor: useColor,
    labelAnsi: _ansiCyanBold,
  );
  _emitBlock(
    'Working dir',
    [cwd],
    useColor: useColor,
    labelAnsi: _ansiCyanBold,
    lineAnsi: _ansiDim,
  );
  final historyLines = historyTail
      .asMap()
      .entries
      .map((entry) => '${entry.key + 1}. ${entry.value}')
      .toList();
  _emitBlock(
    'History tail',
    historyLines.isEmpty ? ['(none)'] : historyLines,
    useColor: useColor,
    labelAnsi: _ansiCyanBold,
    lineAnsi: _ansiYellow,
  );
  final suggestionLines = suggestionText
      .split('\n')
      .map((line) => line.trimRight())
      .where((line) => line.isNotEmpty)
      .toList();
  final responseLines = <String>[
    'Question: ${userLine.isEmpty ? '(none)' : userLine}',
    ...suggestionLines,
  ];
  final outputLabel =
      usedLmSuggestion ? 'Sai output (LM Studio)' : 'Sai output (fallback)';
  _emitBlock(
    outputLabel,
    responseLines.isEmpty ? ['(none)'] : responseLines,
    useColor: useColor,
    labelAnsi: usedLmSuggestion ? _ansiGreenBold : _ansiMagentaBold,
    lineAnsi: usedLmSuggestion ? _ansiGreen : _ansiMagenta,
  );
  final crawlLines = fileNames.take(50).map((name) => '- $name').toList();
  _emitBlock(
    'Folder crawl',
    crawlLines.isEmpty ? ['(empty directory)'] : crawlLines,
    useColor: useColor,
    labelAnsi: _ansiCyanBold,
    lineAnsi: _ansiBlue,
    trailingBlankLine: false,
  );
  _emitBlock(
    'Timing',
    ['Total response time: ${elapsed.inMilliseconds} ms'],
    useColor: useColor,
    labelAnsi: _ansiCyanBold,
    lineAnsi: _ansiDim,
    trailingBlankLine: false,
  );
}

Future<List<String>> _loadHistory({
  String? explicitPath,
  int limit = 20,
}) async {
  final candidates = <String>[];
  void addCandidate(String? path) {
    if (path == null || path.isEmpty || candidates.contains(path)) {
      return;
    }
    candidates.add(path);
  }

  addCandidate(explicitPath);
  final env = Platform.environment;
  addCandidate(env['SAI_HISTORY_FILE']);
  addCandidate(env['HISTFILE']);
  final home = env['HOME'];
  if (home != null && home.isNotEmpty) {
    addCandidate('$home/.zsh_history');
    addCandidate('$home/.zhistory');
    addCandidate('$home/.bash_history');
  }

  for (final path in candidates) {
    final file = File(path);
    if (!await file.exists()) {
      continue;
    }
    try {
      final lines = await file.readAsLines();
      final cleaned = lines
          .map(_cleanHistoryLine)
          .where((line) => line.isNotEmpty)
          .toList();
      if (cleaned.isEmpty) {
        continue;
      }
      if (cleaned.length > limit) {
        return cleaned.sublist(cleaned.length - limit);
      }
      return cleaned;
    } catch (_) {
      // ignore read issues and try next candidate
    }
  }

  return const [];
}

Future<List<String>> _loadHistoryLive({
  required int limit,
  required List<String> shellCandidates,
}) async {
  final cappedLimit = limit.clamp(1, 500).toInt();
  for (final shell in shellCandidates) {
    if (shell.isEmpty) {
      continue;
    }
    try {
      final result = await Process.run(shell, ['-c', 'fc -ln -$cappedLimit']);
      if (result.exitCode != 0) {
        continue;
      }
      final output = (result.stdout ?? '').toString();
      if (output.trim().isEmpty) {
        continue;
      }
      final lines = output
          .split('\n')
          .map(_cleanHistoryLine)
          .where((line) => line.isNotEmpty)
          .toList();
      if (lines.isEmpty) {
        continue;
      }
      if (lines.length > cappedLimit) {
        return lines.sublist(lines.length - cappedLimit);
      }
      return lines;
    } on ProcessException {
      // ignore and try next candidate
    } catch (_) {
      // ignore and try next candidate
    }
  }
  return const [];
}

Future<String?> _fetchLMSuggestion({
  required Uri endpoint,
  required String model,
  required String systemPrompt,
  required String userMessage,
  double? temperature,
}) async {
  final client = HttpClient();
  client.connectionTimeout = const Duration(seconds: 5);
  try {
    final request = await client.postUrl(endpoint);
    request.headers.contentType = ContentType.json;
    final payload = <String, dynamic>{
      'model': model,
      'messages': [
        {'role': 'system', 'content': systemPrompt},
        {'role': 'user', 'content': userMessage},
      ],
    };
    if (temperature != null) {
      payload['temperature'] = temperature;
    }
    request.write(jsonEncode(payload));
    final response = await request.close().timeout(const Duration(seconds: 8));
    if (response.statusCode != 200) {
      return null;
    }
    final body = await response.transform(utf8.decoder).join();
    final data = jsonDecode(body);
    final choices = data['choices'];
    if (choices is List && choices.isNotEmpty) {
      final first = choices.first;
      if (first is Map) {
        final message = first['message'];
        if (message is Map) {
          final content = message['content'];
          if (content is String && content.trim().isNotEmpty) {
            return content.trim();
          }
        }
      }
    }
  } on TimeoutException {
    return null;
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
  return null;
}

String _cleanHistoryLine(String line) {
  final trimmed = line.trim();
  if (trimmed.startsWith(': ')) {
    final idx = trimmed.indexOf(';');
    if (idx != -1 && idx + 1 < trimmed.length) {
      return trimmed.substring(idx + 1).trimLeft();
    }
  }
  return trimmed;
}

bool _isTruthy(String? value) {
  if (value == null) {
    return false;
  }
  final normalized = value.trim().toLowerCase();
  return const {'1', 'true', 'yes', 'on'}.contains(normalized);
}

bool _isHistorySource(String value) {
  final normalized = value.toLowerCase();
  return normalized == 'live' || normalized == 'file';
}

List<String> _shellCandidates(Map<String, String> env) {
  final seen = <String>{};
  final list = <String>[];
  void add(String? path) {
    if (path == null || path.isEmpty) {
      return;
    }
    if (seen.add(path)) {
      list.add(path);
    }
  }

  add(env['SAI_ZSH_BIN']);
  add(env['SAI_LIVE_SHELL']);
  add(env['SAI_SHELL']);
  add(env['ZSH']);
  final shell = env['SHELL'];
  if (shell != null && shell.contains('zsh')) {
    add(shell);
  }
  add('/bin/zsh');
  add('/usr/bin/zsh');
  return list;
}

const _ansiReset = '\x1B[0m';
const _ansiCyanBold = '\x1B[1;36m';
const _ansiGreenBold = '\x1B[1;32m';
const _ansiMagentaBold = '\x1B[1;35m';
const _ansiGreen = '\x1B[32m';
const _ansiMagenta = '\x1B[35m';
const _ansiYellow = '\x1B[33m';
const _ansiBlue = '\x1B[34m';
const _ansiDim = '\x1B[2m';
const _spinnerFrames = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'];

bool _shouldUseColor(Map<String, String> env) {
  if (!stdout.hasTerminal) {
    return false;
  }
  if (env.containsKey('NO_COLOR')) {
    return false;
  }
  if (_isTruthy(env['SAI_NO_COLOR'])) {
    return false;
  }
  final pref = env['SAI_COLOR'];
  if (pref == null) {
    return true;
  }
  return _isTruthy(pref);
}

String _paint(String text, String? ansi, bool enabled) {
  if (!enabled || ansi == null || ansi.isEmpty) {
    return text;
  }
  return '$ansi$text$_ansiReset';
}

bool _shouldSpin(Map<String, String> env, bool widgetMode) {
  if (widgetMode) {
    return false;
  }
  if (!stderr.hasTerminal) {
    return false;
  }
  if (_isTruthy(env['SAI_NO_SPINNER'])) {
    return false;
  }
  final term = env['TERM'] ?? '';
  if (term.toLowerCase() == 'dumb') {
    return false;
  }
  return true;
}

class _Spinner {
  _Spinner({required this.enabled, required this.useColor});

  final bool enabled;
  final bool useColor;

  Timer? _timer;
  int _index = 0;
  static const _message = 'Sai thinking…';

  Future<T> run<T>(Future<T> Function() action) async {
    if (!enabled) {
      return await action();
    }

    final coloredMessage = _paint(
      _message,
      useColor ? _ansiCyanBold : null,
      useColor,
    );
    final clearLength = _message.length + 2; // frame + space + message

    _timer = Timer.periodic(const Duration(milliseconds: 120), (_) {
      final frame = _spinnerFrames[_index];
      _index = (_index + 1) % _spinnerFrames.length;
      stderr.write('\r$frame $coloredMessage');
    });

    try {
      return await action();
    } finally {
      _timer?.cancel();
      stderr.write('\r');
      stderr.write(' ' * (clearLength + 2));
      stderr.write('\r');
      await stderr.flush();
    }
  }
}

void _emitBlock(
  String label,
  List<String> lines, {
  bool trailingBlankLine = true,
  bool useColor = false,
  String? labelAnsi,
  String? lineAnsi,
}) {
  stdout.writeln(_paint('$label:', useColor ? labelAnsi : null, useColor));
  for (final line in lines) {
    stdout.writeln(_paint('  $line', useColor ? lineAnsi : null, useColor));
  }
  if (trailingBlankLine) {
    stdout.writeln();
  }
}

bool _isHidden(FileSystemEntity e) {
  final name = _basename(e.path);
  return name.startsWith('.');
}

bool _skipDir(FileSystemEntity e) {
  final name = _basename(e.path);
  if (e is Directory) {
    return const {
      'node_modules',
      '.git',
      '.dart_tool',
      'build',
      '.gradle',
      '.idea',
    }.contains(name);
  }
  return false;
}

String _basename(String path) {
  final sep = Platform.pathSeparator;
  final idx = path.lastIndexOf(sep);
  return idx == -1 ? path : path.substring(idx + 1);
}
