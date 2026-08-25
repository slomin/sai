# 13. Subscription logins belong to the vendor runtime

Date: 2026-08-25 · Status: accepted · Issue: #28 · Spike: [provider_auth_spike](../../spikes/provider_auth_spike/DECISION.md) · Builds on: [0008](0008-secrets-live-in-the-file-keychain.md), [0009](0009-provider-transport-is-direct-and-bounded.md), [0010](0010-the-privacy-policy-is-a-switch-checked-in-the-recorder.md)

## Context

sai wants three kinds of cloud access: Claude from a Max plan (#25),
ChatGPT from a Plus/Pro plan (#26), and pay-per-token API keys (OpenAI,
OpenRouter). ADR 0008 settled where a key lives. A subscription is not a
key: it is an OAuth login with a single-use refresh token, owned by a
vendor, with the vendor's rules about who may hold it.

The spike (#28) read four open-source clients and both vendors' own
contracts. Three facts decide this ADR:

- The clients that ran their own OAuth flow and held the vendor's
  tokens were the ones blocked, sued or driven to impersonation
  (OpenCode removed its Anthropic OAuth "per legal requests"; Hermes
  spoofs Claude Code's user-agent and rewrites tool names). Anthropic's
  page permits the other shape in so many words: "an end user … signing
  in to the unmodified Claude Code binary with their own Claude
  subscription", and `claude -p` "still draw[s] from your subscription's
  usage limits". OpenAI open-sourced the App Server for third-party
  clients.
- Single-use refresh tokens plus two processes equal logouts
  (openai/codex#10332, closed not-planned; openclaw#26322). The Codex
  CLI has no cross-process refresh lock.
- Real money was lost not to theft but to precedence: an API-key
  environment variable outranks a subscription login in both vendors'
  tools ($52, $152, $1,122 in anthropics/claude-code#58083, #39903,
  #86723).

## Decision

**sai never holds a subscription credential.** Each subscription route
is served by the vendor's own runtime as a child process that owns
login, refresh, storage and logout; sai talks to it over stdio and
stores nothing but the provider entry.

- **Claude**: the unmodified `claude` binary, `-p` with
  `--output-format stream-json`; Claude Code's `/login` and Keychain
  item are the credential. Never `--bare` (it does not read the login).
  Isolated with `--setting-sources=`, `--strict-mcp-config`,
  `--tools ""`, `--no-session-persistence`, `--max-turns 1`,
  `--permission-mode dontAsk`, sai's `--system-prompt`. `CLAUDE_CONFIG_DIR`
  is never redirected.
- **ChatGPT**: `codex app-server` with a sai-owned `CODEX_HOME`
  (`~/Library/Application Support/sai/codex/`) whose `config.toml` sets
  `cli_auth_credentials_store = "keyring"`; login through
  `account/login/start`, models from `model/list`, plan state from
  `account/rateLimits/read`; threads at `sandbox: read-only`,
  `approval_policy: never`, `environments: []`, `ephemeral: true`.
  A separate home is a separate token family: no refresh race with the
  user's Codex CLI, no plaintext `auth.json`, and sai's logout cannot
  touch the user's login.
- **API keys** stay under ADR 0008 unchanged: `openai_compatible`
  `cloud` entries on fixed origins for OpenAI and OpenRouter, the key
  in the file Keychain, bound to the origin. Claude by key goes through
  OpenRouter; Anthropic's OpenAI-compatibility layer is documented as
  not production-ready.
- **The child environment is scrubbed**, not inherited. Claude:
  `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `CLAUDE_CODE_OAUTH_TOKEN`,
  `ANTHROPIC_PROFILE`, `ANTHROPIC_FEDERATION_*`, `CLAUDE_CODE_USE_*`,
  `ANTHROPIC_BASE_URL`, `CLAUDE_CODE_SIMPLE`, `CLAUDE_CONFIG_DIR`,
  `CLAUDECODE`. Codex: everything starting `OPENAI_` or `CODEX_` except
  the `CODEX_HOME` sai sets.
- **Fail closed before the first prompt.** Claude: `system/init` must
  report `apiKeySource: none`. Codex: `account/read` must report ChatGPT
  authentication. Anything else — missing binary, wrong version, signed
  out, an API key that leaked through — is `LlmFailureKind.credential`;
  nothing is sent.
- **No fall-through.** Subscription and key routes are distinct
  provider kinds and entries; a failure on one is never retried on
  another. Switching billing is a user selecting a different entry.
- **What the archive records** for these kinds is what ADR 0007/0009
  already fix: kind, fixed message, model lineage from the vendor's
  stream — never a child's stderr, argv or environment.

## What this defends, honestly

The same list as ADR 0008 — files, backups, settings, archive, logs,
exception text, process listings — plus the two failures that cost
others money: there is no sai-held token to race or leak, and a leaked
`ANTHROPIC_API_KEY` in the shell cannot bill a subscription call. It is
**not** a boundary against a process running as the user: that process
can read Claude Code's Keychain item (its ACL trusts `/usr/bin/security`)
or run either vendor binary itself. #56 is the compensating control.

## Consequences

- Two new provider kinds (`claude_subscription`, `chatgpt_subscription`)
  with no `credential` field; settings-v0 grows them in #25/#26.
- `sai_core` gains an injectable process runner; every test spawns a
  fake. No test, and no coding agent, runs the real binaries or reads
  `~/.claude`, `~/.codex`, or the `Claude Code-credentials` / `Codex
  Auth` Keychain items (#56).
- The user signs in to ChatGPT once inside sai (device code or
  browser), separately from the Codex CLI. Claude needs no sai-side
  sign-in: the existing `claude` login is the credential.
- Two dated vendor facts are re-check triggers: Anthropic's paused
  Agent SDK credit (support 15036540) and "`--bare` … will become the
  default for `-p`". Either landing means re-reading the two pages and
  confirming `-p` still reaches the `/login` credential.
- This app is one person's. Handing it to others with "sign in with
  Claude" is a different product under a different clause; not planned,
  noted so the boundary is visible.

## Rejected

- **sai's own OAuth flow with a vendor's public client id** — the shape
  every enforcement action landed on; it makes sai a token store and a
  refresh-race participant.
- **Reading Claude Code's or Codex's stored tokens** (Hermes, and even
  the Agent SDK's resume path) — technically trivial, and exactly what
  "may not collect, store, or intermediate" forbids.
- **Reusing the user's `~/.codex`** — no setup, but a shared single-use
  refresh token with a CLI that has no lock.
- **Anthropic's OpenAI-compatibility endpoint** as the API-key route —
  "not … production-ready", no thinking output.
- **An "auto" provider that falls back to a key** — the precedence
  incidents, deliberately built.
