/// The streaming cursor's glyph (#99), shared by the renderer that
/// draws it and the selection join that keeps it off the clipboard.
library;

/// A hair space, then a one-eighth block — a thin bar that stands clear
/// of the last glyph instead of crowding it. It is drawn as a span in
/// the mono face (which has the glyph, so no fallback font can change
/// the line's height), never a widget, so the test finders keep
/// matching plain text (ADR 0018).
const caretGlyph = '\u200a▏';
