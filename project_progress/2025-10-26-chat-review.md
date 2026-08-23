# Chat UX Review – 2025-10-26

## Status Summary
- Clipboard copy failures now keep the chat open, show the snippet inline in the transcript, and surface a clear fallback message.
- Footer shortcut hints are contextual; the Tab hint appears only when a selectable fence exists.
- Glamour markdown rendering respects `GLAMOUR_STYLE` (and other env overrides) without the OSC background probe, removing the multi-second pause when chat starts and falling back to the dark preset otherwise.
- Selecting a snippet highlights the corresponding fence inside the viewport so users can confirm the exact block that will be copied.
- Streaming uses llama.cpp’s `timings.predicted_per_second` when available, falling back to local cadence measurement otherwise.

## Follow-ups
- Document the need to set `GLAMOUR_STYLE=light` (or other presets) explicitly now that we skip auto-detection for faster startup.
- Monitor highlight formatting on extremely narrow terminals (alignment padding can wrap the header glyph).
- Consider persisting the fallback snippet even after exiting so shell history captures it when desired.
