import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

class SaiLmConfig {
  SaiLmConfig({
    required this.endpoint,
    required this.model,
    required this.systemPrompt,
    required this.timeout,
    this.temperature,
    this.enabled = true,
  });

  factory SaiLmConfig.fromEnvironment([
    Map<String, String>? environment,
  ]) {
    final env = environment ?? const <String, String>{};

    final disabledValue = env[_disabledKey] ?? env[_disabledKeyLegacy];
    final enabled = !_isTruthy(disabledValue);

    final endpointRaw =
        env['SAI_LM_ENDPOINT'] ?? 'http://localhost:1234/v1/chat/completions';
    final endpoint = Uri.tryParse(endpointRaw) ??
        Uri.parse('http://localhost:1234/v1/chat/completions');

    final model = env['SAI_LM_MODEL'] ?? 'qwen3-vl-4b-instruct-mlx';
    final systemPrompt = env['SAI_LM_SYSTEM_PROMPT'] ??
        'You are a command line helper. Reply with concise instructions or commands that align with macOS zsh usage.';
    final temperature = double.tryParse(env['SAI_LM_TEMPERATURE'] ?? '');

    final timeoutSeconds =
        int.tryParse(env['SAI_LM_TIMEOUT_SECONDS'] ?? '') ?? 15;
    final timeout = Duration(seconds: timeoutSeconds.clamp(5, 120));

    return SaiLmConfig(
      endpoint: endpoint,
      model: model,
      systemPrompt: systemPrompt,
      temperature: temperature,
      timeout: timeout,
      enabled: enabled,
    );
  }

  static const _disabledKey = 'SAI_LM_DISABLED';
  static const _disabledKeyLegacy = 'SAI_NO_LM';

  final Uri endpoint;
  final String model;
  final String systemPrompt;
  final double? temperature;
  final Duration timeout;
  final bool enabled;

  static bool _isTruthy(String? value) {
    if (value == null) {
      return false;
    }
    final normalized = value.trim().toLowerCase();
    return normalized == '1' ||
        normalized == 'true' ||
        normalized == 'yes' ||
        normalized == 'on';
  }
}

class SaiModelResponse {
  SaiModelResponse({
    this.explanation,
    this.recommendedCommand,
    this.rawText,
  });

  factory SaiModelResponse.fromContent(String content) {
    final cleaned = _stripCodeFence(content.trim());
    try {
      final decoded = jsonDecode(cleaned);
      if (decoded is Map<String, Object?>) {
        final explanation = decoded['explanation'];
        final command = decoded['recommended_command'];
        if (explanation is String && command is String) {
          return SaiModelResponse(
            explanation: explanation.trim(),
            recommendedCommand: command.trim(),
            rawText: content.trim(),
          );
        }
      }
    } catch (_) {
      // fall through to raw text
    }
    return SaiModelResponse(rawText: content.trim());
  }

  final String? explanation;
  final String? recommendedCommand;
  final String? rawText;

  bool get hasStructured =>
      explanation != null &&
      explanation!.isNotEmpty &&
      recommendedCommand != null &&
      recommendedCommand!.isNotEmpty;

  String get displayText =>
      rawText?.isNotEmpty == true ? rawText! : (explanation ?? '');

  static String _stripCodeFence(String text) {
    final trimmed = text.trim();
    if (trimmed.startsWith('```') && trimmed.endsWith('```')) {
      final withoutFence = trimmed.substring(3, trimmed.length - 3);
      final newlineIndex = withoutFence.indexOf('\n');
      if (newlineIndex >= 0) {
        return withoutFence.substring(newlineIndex + 1).trim();
      }
      return withoutFence.trim();
    }
    return trimmed;
  }
}

class SaiLmClient {
  SaiLmClient({
    required this.config,
    http.Client? httpClient,
  }) : _httpClient = httpClient;

  final SaiLmConfig config;
  final http.Client? _httpClient;

  Future<SaiModelResponse?> complete({
    required String userPrompt,
  }) async {
    final client = _httpClient ?? http.Client();
    try {
      final payload = <String, Object?>{
        'model': config.model,
        'messages': [
          {
            'role': 'system',
            'content': config.systemPrompt,
          },
          {
            'role': 'user',
            'content': userPrompt,
          },
        ],
      };
      if (config.temperature != null) {
        payload['temperature'] = config.temperature;
      }

      final response = await client
          .post(
            config.endpoint,
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode(payload),
          )
          .timeout(config.timeout);

      if (response.statusCode != 200) {
        return null;
      }

      final data = jsonDecode(response.body);
      final content = _extractMessage(data);
      if (content == null || content.trim().isEmpty) {
        return null;
      }
      return SaiModelResponse.fromContent(content);
    } on TimeoutException {
      return null;
    } on http.ClientException {
      return null;
    } on FormatException {
      return null;
    } catch (_) {
      return null;
    } finally {
      if (_httpClient == null) {
        client.close();
      }
    }
  }

  String? _extractMessage(Object? data) {
    if (data is Map<String, Object?>) {
      final choices = data['choices'];
      if (choices is List && choices.isNotEmpty) {
        final first = choices.first;
        if (first is Map<String, Object?>) {
          final message = first['message'];
          if (message is Map<String, Object?>) {
            final content = message['content'];
            final text = _normalizeContent(content);
            if (text != null && text.trim().isNotEmpty) {
              return text.trim();
            }
          }

          final textValue = first['text'];
          if (textValue is String && textValue.trim().isNotEmpty) {
            return textValue.trim();
          }
        }
      }
    }
    return null;
  }

  String? _normalizeContent(Object? content) {
    if (content is String) {
      return content;
    }
    if (content is List) {
      final buffer = StringBuffer();
      for (final item in content) {
        if (item is String) {
          buffer.write(item);
        } else if (item is Map<String, Object?>) {
          final text = item['text'];
          if (text is String) {
            buffer.write(text);
          }
        }
      }
      if (buffer.isEmpty) {
        return null;
      }
      return buffer.toString();
    }
    return null;
  }
}
