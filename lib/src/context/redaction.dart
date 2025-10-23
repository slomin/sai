class SaiRedactor {
  SaiRedactor();

  String redact(String input) {
    var output = input;
    for (final rule in _rules) {
      output = rule.apply(output);
    }
    return output;
  }
}

class _RedactionRule {
  _RedactionRule(
    String pattern, {
    this.replacement = 'REDACTED',
    bool caseSensitive = false,
  }) : regex = RegExp(pattern, caseSensitive: caseSensitive);

  final RegExp regex;
  final String replacement;

  String apply(String input) {
    return input.replaceAllMapped(regex, (match) {
      if (match.groupCount >= 2) {
        final prefix = match.group(1) ?? '';
        return '$prefix$replacement';
      }
      return replacement;
    });
  }
}

final List<_RedactionRule> _rules = <_RedactionRule>[
  _RedactionRule(r'\b(AWS[_-]?SECRET[_-]?(?:ACCESS)?KEY\s*[:=]\s*)(\S+)'),
  _RedactionRule(r'\b(password|passwd|pwd)\s*[:=]\s*(\S+)'),
  _RedactionRule(r'\b(token|api[_-]?key|auth[_-]?token)\s*[:=]\s*(\S+)'),
  _RedactionRule(r'\b(aws_session_token\s*[:=]\s*)(\S+)'),
  _RedactionRule(r'\b(secret|client_secret)\s*[:=]\s*(\S+)'),
  _RedactionRule(r'(?<!\w)(ghp_[A-Za-z0-9]{20,})(?!\w)'),
  _RedactionRule(r'(?<!\w)(sk-[A-Za-z0-9]{20,})(?!\w)'),
];
