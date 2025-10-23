String generateShellInitSnippet({required String shell}) {
  final normalized = shell.toLowerCase();
  if (normalized != 'zsh' && normalized != 'bash') {
    throw UnsupportedError('Unsupported shell `$shell`. Use zsh or bash.');
  }

  const template = r'''
# sai shell wrapper for {shell}
sai() {
  local _sai_shell='{shell}'
  local _sai_history_capture=""
  if command -v fc >/dev/null 2>&1; then
    _sai_history_capture="$(fc -ln -10 2>/dev/null)"
  fi
  if [ -z "$_sai_history_capture" ]; then
    _sai_history_capture="$(history 10 2>/dev/null | sed 's/^ *[0-9][0-9]* *//')"
  fi
  command sai --shell "$_sai_shell" --history-stdin -- "$@" <<< "$_sai_history_capture"
}
''';

  return template.replaceAll('{shell}', normalized);
}
