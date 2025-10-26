# Streaming UI Progress – 2024-11-18

## What We Changed
- Reworked the chat model’s streaming lifecycle by introducing a pluggable `streamLauncher` and a safe default implementation that manages goroutines and channel closure.
- Hardened state transitions (`sending`, `streamCh`, `pendingRequest`) and refreshed the viewport after each chunk/done event so the UI reflects streaming progress immediately.
- Added `TestStreamingLifecycleAllowsMultipleMessages` plus helper utilities to simulate consecutive streams via TDD. This guards the regression where the second prompt froze the UI.
- Defaulted the CLI to the remote llama.cpp endpoint; `-l/--local` now switches to LM Studio. Updated docs (`AGENTS.md`) accordingly.

## What Works Now
- Two consecutive streaming turns complete without freezing; `sending` resets to false and input becomes available again.
- The viewport appends streamed content in real time and scrolls to the latest assistant reply.
- The new tests pass, ensuring future changes keep the multi-turn streaming path healthy.

## Remaining Issues / Next Steps
- The second streamed response still repeats or reflows whole lines; investigate trimming logic in `appendStreamChunk` or the LM delta merge strategy.
- Review Bubble Tea rendering guidance (Context7 `/charmbracelet/bubbletea`) for handling multi-line chunks without duplication.
- Consider adding integration coverage for chunk segmentation (e.g., newline-delimited deltas).
- Once formatting quirks are addressed, rerun manual tests (`go run ./cmd/sai`) against remote and local endpoints to confirm UX is smooth.
