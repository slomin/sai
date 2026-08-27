/// Syntax colour for fenced code (#39): `package:highlight` tokenizes,
/// and the token classes map onto the accents the Sai system already
/// owns — a restrained palette, not a rainbow.
library;

import 'package:flutter/painting.dart';
import 'package:highlight/highlight_core.dart';
import 'package:highlight/languages/bash.dart' as lang_bash;
import 'package:highlight/languages/cs.dart' as lang_cs;
import 'package:highlight/languages/css.dart' as lang_css;
import 'package:highlight/languages/dart.dart' as lang_dart;
import 'package:highlight/languages/diff.dart' as lang_diff;
import 'package:highlight/languages/dockerfile.dart' as lang_dockerfile;
import 'package:highlight/languages/go.dart' as lang_go;
import 'package:highlight/languages/ini.dart' as lang_ini;
import 'package:highlight/languages/java.dart' as lang_java;
import 'package:highlight/languages/javascript.dart' as lang_javascript;
import 'package:highlight/languages/json.dart' as lang_json;
import 'package:highlight/languages/kotlin.dart' as lang_kotlin;
import 'package:highlight/languages/makefile.dart' as lang_makefile;
import 'package:highlight/languages/markdown.dart' as lang_markdown;
import 'package:highlight/languages/python.dart' as lang_python;
import 'package:highlight/languages/ruby.dart' as lang_ruby;
import 'package:highlight/languages/rust.dart' as lang_rust;
import 'package:highlight/languages/shell.dart' as lang_shell;
import 'package:highlight/languages/sql.dart' as lang_sql;
import 'package:highlight/languages/swift.dart' as lang_swift;
import 'package:highlight/languages/typescript.dart' as lang_typescript;
import 'package:highlight/languages/xml.dart' as lang_xml;
import 'package:highlight/languages/yaml.dart' as lang_yaml;

import '../../theme/sai_tokens.dart';

/// The languages the assistant is likely to speak. One import per
/// definition — `package:highlight/highlight.dart` would pull in all
/// 190 of them.
final Map<String, Mode> _languages = {
  'bash': lang_bash.bash,
  'cs': lang_cs.cs,
  'css': lang_css.css,
  'dart': lang_dart.dart,
  'diff': lang_diff.diff,
  'dockerfile': lang_dockerfile.dockerfile,
  'go': lang_go.go,
  'ini': lang_ini.ini,
  'java': lang_java.java,
  'javascript': lang_javascript.javascript,
  'json': lang_json.json,
  'kotlin': lang_kotlin.kotlin,
  'makefile': lang_makefile.makefile,
  'markdown': lang_markdown.markdown,
  'python': lang_python.python,
  'ruby': lang_ruby.ruby,
  'rust': lang_rust.rust,
  'shell': lang_shell.shell,
  'sql': lang_sql.sql,
  'swift': lang_swift.swift,
  'typescript': lang_typescript.typescript,
  'xml': lang_xml.xml,
  'yaml': lang_yaml.yaml,
};

final Highlight _highlight = Highlight()..registerLanguages(_languages);

/// Fence names models write that are not registry keys.
const _aliases = {
  'c#': 'cs',
  'cjs': 'javascript',
  'csharp': 'cs',
  'golang': 'go',
  'html': 'xml',
  'js': 'javascript',
  'jsonc': 'json',
  'jsx': 'javascript',
  'kt': 'kotlin',
  'md': 'markdown',
  'mjs': 'javascript',
  'py': 'python',
  'rb': 'ruby',
  'rs': 'rust',
  'sh': 'bash',
  'toml': 'ini',
  'ts': 'typescript',
  'tsx': 'typescript',
  'yml': 'yaml',
  'zsh': 'bash',
};

/// Fences that name plain text stay plain by decision, as does any
/// name nobody registered — no language-guessing.
String? _resolve(String? language) {
  if (language == null) return null;
  final name = language.toLowerCase();
  final canonical = _aliases[name] ?? name;
  return _languages.containsKey(canonical) ? canonical : null;
}

/// The spans for [code]: highlighted when the fence names a language
/// this registry knows, plain mono otherwise. The caller owns the
/// base style; these carry only colour and weight deltas.
List<TextSpan> codeSpans(String code, String? language) {
  final name = _resolve(language);
  if (name == null) return [TextSpan(text: code)];
  final nodes = _highlight.parse(code, language: name).nodes;
  if (nodes == null) return [TextSpan(text: code)];
  return [for (final node in nodes) _span(node)];
}

TextSpan _span(Node node) {
  final children = node.children;
  if (children == null) {
    return TextSpan(text: node.value ?? '', style: _styleFor(node.className));
  }
  return TextSpan(
    style: _styleFor(node.className),
    children: [for (final child in children) _span(child)],
  );
}

/// highlight.js token classes onto the Sai accents. JetBrains Mono
/// ships a static 700, so weight needs no variation axis here.
TextStyle? _styleFor(String? className) => switch (className) {
  null => null,
  'keyword' ||
  'built_in' ||
  'literal' ||
  'type' ||
  'meta-keyword' => const TextStyle(color: SaiColors.red),
  'string' ||
  'regexp' ||
  'addition' ||
  'attr' ||
  'attribute' ||
  'template-tag' => const TextStyle(color: SaiColors.green),
  'number' ||
  'symbol' ||
  'bullet' ||
  'link' ||
  'variable' ||
  'template-variable' => const TextStyle(color: SaiColors.amber),
  'comment' || 'quote' => const TextStyle(
    color: SaiColors.sheetDim,
    fontStyle: FontStyle.italic,
  ),
  'meta' || 'deletion' => const TextStyle(color: SaiColors.sheetDim),
  'title' ||
  'class' ||
  'function' ||
  'name' ||
  'section' ||
  'selector-tag' ||
  'tag' => const TextStyle(fontWeight: FontWeight.w700),
  _ => null,
};
