# Testing without credentials, and the human smoke

## Automated — keyless, always

Every project inspected does the same four things; sai already does
two of them (ADR 0008/0009) and #25/#26 extend the rest.

1. **A fake process runner.** `claude` and `codex app-server` are
   spawned through an injectable `ProcessRunner` in `sai_core` (the
   stub-server pattern of `test/llm/openai_compatible/`, applied to
   stdio). Tests feed canned `stream-json` / JSON-RPC lines: fragmented
   frames, `system/init` with `apiKeySource: "ANTHROPIC_API_KEY"` (must
   fail `credential` before any prompt), `account/read` reporting an API
   key (same), `account/rateLimits/read` with `spend_control_reached`,
   malformed JSON, a process that exits mid-stream, one that never emits
   `result`, cancellation mid-turn (exactly one terminal result).
2. **Environment assertions.** The runner records the argv and
   environment it was given; tests assert the scrub lists (`threat-model.md`
   row 7) and the isolation flags (`--tools ""`, `--strict-mcp-config`,
   `--setting-sources=`, `--no-session-persistence`, never `--bare`; for
   Codex `sandbox: read-only`, `approval_policy: never`,
   `environments: []`, no `dynamic_tools`) are present on every spawn.
   A test starts the fake with `ANTHROPIC_API_KEY`/`OPENAI_API_KEY` set
   in the *parent* and proves they are absent in the child.
3. **No secret in any output.** `test/no_secrets_test.dart` extends to
   the new kinds: the settings file for a `claude_subscription` or
   `chatgpt_subscription` provider has no `credential`; the archive lines
   for a failed spawn carry `kind` + fixed message, never the child's
   stderr; a `LlmFailure` for these kinds never quotes argv or env.
4. **Fixtures are synthetic.** As Codex's `ChatGptAuthFixture` and
   Hermes' `conftest`: a temp `CODEX_HOME` with a placeholder
   `auth.json` shape (no real token), never the real `~/.codex`; the
   `claude` fake never touches `~/.claude` or the Keychain. Nothing under
   `test/` may spawn the real binaries — the runner is injected, and the
   default runner is only wired in the riverpod layer.

Coding agents (#56) run only this suite. No agent-run command carries a
key, reads `~/.claude`, `~/.codex`, or the `Claude Code-credentials` /
`Codex Auth` Keychain items; `sandbox.credentials` masks the variables
listed in `followups.md`.

## Human-run — real accounts, once per route, evidence not claims

Run by Jan, never by an agent, in a scratch env
(`SAI_ARCHIVE_ROOT`/`SAI_SETTINGS_FILE`), after #25/#26 land.

**Claude subscription (C).** Preconditions: `claude` signed in with the
Max plan (`claude auth status`), no `ANTHROPIC_API_KEY` in the launching
shell. Steps: select the provider, send one prompt, observe the stream.
Evidence: the archive's `provider.request`/`provider.response` lines
(model lineage from `system/init`, `apiKeySource: none`), `claude`'s
`/usage` before and after showing the plan pool moved, and the Console
usage page showing **no** API spend for the window. Then set
`ANTHROPIC_API_KEY=not-a-real-key` in the shell, relaunch, send —
expect a `credential` failure, no request, no spend.

**ChatGPT subscription (G).** Preconditions: sai's dedicated
`CODEX_HOME` empty. Steps: "Sign in" in sai → device code or browser →
`account/read` shows ChatGPT + plan; `model/list` populates; one
prompt. Evidence: archive lines, `account/rateLimits/read` before/after,
the Platform usage page showing no API spend; `ls -la "$CODEX_HOME"`
showing no `auth.json` (keyring backend) — or, if the platform fell back
to a file, that fact recorded and the setting fixed. Set
`OPENAI_API_KEY` in the shell, relaunch — expect the child not to see it
and the turn still to be ChatGPT-authenticated.

**API keys (K).** Mint a **capped** key: OpenRouter with `limit` ≤ $1,
`limit_reset: null`, `expires_at` tomorrow; OpenAI a project with a hard
monthly limit ≤ $1. Enter it through `sai_tui secret set` (hidden
prompt) or the app's masked field — never through an agent, never in a
command line. One prompt; evidence: archive lines, the provider
dashboard showing the spend, `GET /api/v1/key` `limit_remaining`. Delete
the key afterwards. The agent-run counterpart is the fake provider and
the LAN box (`tool/smoke/lan.py`).

**Cross-mode check.** With both a subscription entry and a key entry
configured, exhaust or disable one and confirm sai reports the failure
for *that* entry and does not send through the other.

Each run's evidence goes into the PR that lands the route, as the
README's smoke rule requires.
