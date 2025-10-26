# Chat UX Review – 2025-10-26

## Current Issues
- **Quit after copy failure**: When snippet copying fails (e.g., clipboard disabled on the host), the chat quits immediately with no fallback, so the generated code is lost. 
- **Static shortcut hint**: The footer always advertises “Tab select snippet” even when the current transcript has no code fences, which can mislead first-time users.
- **Glamour styling locked to dark**: We force the dark preset; light terminals or custom Glamour styles (e.g., `GLAMOUR_STYLE`) are ignored.
- **No in-viewport highlight**: The snippet drawer appears, but the actual fence content is not visually distinguished in the transcript, making it harder to confirm the selection.
- **Residual console output**: After pressing Enter, we still echo the code to stdout even though the intent is to copy silently.

## Suggested Fixes
- **Handle copy errors gracefully**: Retry or keep the UI open when clipboard writes fail, and show the snippet inline as a fallback before quitting.
- **Conditional footer hints**: Toggle the footer text based on whether we have a selectable snippet (mirrors Opencode’s contextual shortcut behaviour).
- **Respect Glamour environment**: Initialize the markdown renderer with `glamour.WithEnvironmentConfig()` or auto-detect dark/light mode so theming follows terminal preferences.
- **Viewport highlight**: Apply a temporary lipgloss style around the selected fence, similar to Opencode’s selection glow, so users can confirm what will be copied.
- **Suppress redundant printing**: Only write the snippet to stdout when clipboard access is disabled or copying fails; otherwise exit silently.

These refinements keep the MVP lean while aligning the chat experience with Bubble Tea best practices and Opencode’s reference implementation.
