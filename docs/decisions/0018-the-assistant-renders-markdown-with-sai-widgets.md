# 18. The assistant renders Markdown with Sai widgets

Date: 2026-08-27 · Amended: 2026-08-30 (#99) · Status: accepted · Issue: #39 · Builds on: [0007](0007-provider-traffic-is-three-events-per-call.md)

## Context

Models answer in Markdown; the chat pane showed the raw markup in a
plain `Text`. #39 asks for rendered answers that stream without layout
jumps. The obvious packages are the wrong shape: `flutter_markdown` is
discontinued upstream, and the drop-in chat renderers own their widget
tree and styling, which the Sai visual system cannot share. The
workspace is deliberately dependency-lean.

## Decision

- **`package:markdown` parses; Sai widgets draw.** The Dart team's
  parser (already in the tree as a transitive dependency of nocterm)
  produces the CommonMark AST, and `lib/assistant/markdown/` maps it
  onto the band's own text styles — `Text.rich` and spans throughout,
  no HTML and no `WidgetSpan`, so the test finders keep matching plain
  text. `package:highlight` (its core plus ~20 imported language
  definitions, never the 190 of `highlight.dart`) tokenizes fenced
  code; the token classes map onto the accents the system already owns.
  It last shipped in 2021, but it is regex and data with no platform
  code; if it ever stops compiling, the registered definitions get
  vendored.
- **The feature set is CommonMark minus furniture.** Paragraphs,
  bold/italic, inline code, lists, links (named in the accent, no tap),
  fenced code with a language label, highlighting, sideways scroll and
  a copy control. Headings are stronger paragraphs, never larger ones.
  Blockquotes flatten, rules vanish, tables stay off (`extensionSet`
  is CommonMark). Untagged fences stay plain — no language guessing.
  Only the assistant's turns render; a person's words stay as typed.
  The terminal client keeps raw text.
- **Streaming may not jump.** The rules that deliver that: no inline
  span exceeds its paragraph's line box; code bodies never wrap (the
  block scrolls sideways, so its height is exactly its line count); an
  unclosed fence is a code block to EOF by the parser's own behaviour;
  a trailing line of nothing but
  backticks or tildes is held back while the answer streams (it is
  the closing fence arriving, whatever its character and length); and the cursor is
  appended to the rendered spans, never to the source, where a fence
  line followed by it would become a fence's language. A finished turn
  parses once — the AST lives in widget state.
- **The cursor is a thin bar, and the transcript is selectable** (#99).
  The streaming cursor is a hair space and a one-eighth block in the
  mono face, in the accent, at the body's line height: it stands clear
  of the last glyph and cannot change a line's height. It stays a span
  — never a `WidgetSpan` — so the finders keep matching plain text.
  The transcript sits under a `SelectionArea`: a mouse drag selects
  across a person's plain text and the rendered spans alike and ⌘C
  copies exactly that text; a fence's label and copy control are
  chrome, excluded from selection. Between a question and its first
  delta the band shows three dots that breathe in turn; under Reduce
  Motion they hold still beside the word *Thinking*.
- **What CommonMark itself reflows is accepted:** `**bo` is literal
  until the `**` closes, and a `---` under a paragraph turns it into a
  heading after the fact. Disabling setext headings would mean
  re-listing every standard block syntax; not worth it.

## Consequences

- Green and amber join red inside the band (the syntax palette); until
  now the band carried them only in the connection light.
- `encodeHtml: false` and a fresh `Document` per parse are load-bearing
  (`<` must arrive as itself; a `Document` accumulates link
  references).
- One net-new package in the lockfile (`highlight`); `markdown` was
  already there.
- The transcript's `ListView` stays non-lazy: auto-follow jumps to
  `maxScrollExtent`, which a builder only estimates.
