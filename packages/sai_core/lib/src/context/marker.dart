/// The model-initiated proposal trigger (#35): a fixed line an answer
/// may end with to ask sai for a proposal turn. Detection and display
/// stripping live in core so both clients show the same text.
library;

/// The exact marker; it counts only as the answer's final line.
const proposeMarker = '<sai:propose/>';

/// Whether [text], trailing whitespace ignored, ends with the marker on
/// a line of its own. A mid-text occurrence is ordinary text.
bool endsWithMarker(String text) {
  final trimmed = text.trimRight();
  if (!trimmed.endsWith(proposeMarker)) return false;
  final cut = trimmed.length - proposeMarker.length;
  return cut == 0 || trimmed.codeUnitAt(cut - 1) == 0x0A;
}

/// [raw] as a client shows it: the final marker line stripped. While
/// [streaming], a trailing line that is a prefix of the marker is held
/// back too — it is the marker arriving, and drawing it would add a
/// line its completion takes away (the ADR 0018 fence hold-back,
/// generalised).
String shownText(String raw, {bool streaming = false}) {
  if (endsWithMarker(raw)) {
    final trimmed = raw.trimRight();
    return trimmed
        .substring(0, trimmed.length - proposeMarker.length)
        .trimRight();
  }
  if (streaming) {
    final at = raw.lastIndexOf('\n');
    final lastLine = raw.substring(at + 1);
    if (lastLine.isNotEmpty && proposeMarker.startsWith(lastLine)) {
      return at < 0 ? '' : raw.substring(0, at);
    }
  }
  return raw;
}
