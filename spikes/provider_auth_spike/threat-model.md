# Threat model

The ticket lists seven threats. Each is scored against the three routes
the decision keeps — **C** Claude subscription via the unmodified
`claude` binary, **G** ChatGPT subscription via `codex app-server`, **K**
API keys (OpenAI, OpenRouter, Anthropic) in `SecretStore` — and against
the rejected alternative **O**: sai running its own OAuth flow and
holding vendor tokens. Ground truth throughout: the app runs without the
App Sandbox (ADR 0001), so **there is no boundary between processes of
the same user**; ADR 0008 already says so for keys.

| # | threat | C | G | K | O (rejected) |
|---|---|---|---|---|---|
| 1 | Coding agent / same-user process with shell | Can read the Keychain item with `security find-generic-password` (Silverfort) or run `claude -p` itself. sai adds nothing to steal: it holds no token. Defence is #56 (keyless agents), not storage | Can run `codex app-server` against sai's `CODEX_HOME` or read its `auth.json`; keyring backend makes the file disappear and the item prompt-gated. sai holds nothing | Can prompt for or, after one "Always Allow", read the item (ADR 0008). Damage cap is the key's: OpenRouter per-key `limit`/`expires_at`, OpenAI project limits | Same as K, but the stolen thing is a refresh token: full account, no per-key cap, and revocation is a vendor login reset |
| 2 | Compromised / buggy sai process | Nothing to leak; worst case it mis-drives `claude` (mitigated by `--tools ""`, `--strict-mcp-config`, `--setting-sources=`, `--no-session-persistence`) | Nothing to leak; worst case it starts a turn with a wider sandbox — fixed at `sandbox: read-only`, `approval_policy: never`, no `dynamic_tools`, `environments: []` | Reads the key at call time only (factory hands the store, not the key); recorder normalises failures; `no_secrets_test` | Token in process memory for its lifetime, plus refresh logic to get wrong |
| 3 | Compromised child provider process | `claude` is the vendor's binary with the vendor's own credential; the child cannot reach sai's Keychain items (different account names, prompt-gated) | `codex app-server` likewise; a dedicated `CODEX_HOME` means it cannot touch the user's own `~/.codex` | not applicable (HTTP, no child) | not applicable |
| 4 | Backups, support bundles | Claude Code's Keychain item is in the login keychain (backed up by Time Machine as the keychain file, encrypted at rest by the login password); nothing sai-side | dedicated `CODEX_HOME` with `keyring` → no plaintext `auth.json`; sai's own settings carry no secret (settings-v0) | Keychain, same as ADR 0008 | a plaintext token store of sai's own, in every backup |
| 5 | Leaks into settings, archive, logs, exceptions, `ps`, env dumps | settings: no credential field for this kind; archive: recorder writes failure kind + fixed text (ADR 0009); `ps`: no token on the command line — Claude Code reads its own store; env: scrubbed (below) | same; the child's stdout is JSON-RPC, never a token; `ps` shows `codex app-server` only | ADR 0008/0009 already tested from the outside | the failure text of an OAuth exchange, refresh error bodies (Codex logs them verbatim) |
| 6 | Refresh race invalidating another login | Claude Code owns refresh; sai never refreshes. The Agent SDK's own `refreshToken` strip shows the hazard of copying the credential — sai copies nothing | **Real risk if `~/.codex` is shared** with the user's Codex CLI (codex#10332, no cross-process lock). Dedicated `CODEX_HOME` = own token family = no race | none | sai would have to implement the lock OpenClaw wrote |
| 7 | Surprise API charges via precedence / fallback | `-p` "always uses" `ANTHROPIC_API_KEY` when present → sai **removes** `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `CLAUDE_CODE_OAUTH_TOKEN`, `ANTHROPIC_PROFILE`, `ANTHROPIC_FEDERATION_*`, `CLAUDE_CODE_USE_*`, `CLAUDE_CODE_SIMPLE` from the child and checks `system/init.apiKeySource == "none"` before sending the prompt | `auth_mode` in the file decides; sai removes `OPENAI_API_KEY`, `CODEX_API_KEY`, `CODEX_ACCESS_TOKEN`, `CODEX_*_OVERRIDE`, `CODEX_APP_SERVER_LOGIN_CLIENT_ID` and checks `account/read` reports ChatGPT before a turn | a key route is explicit by provider entry; never selected as a fallback for a subscription route | the flip Hermes documents in its own code |

## What cannot be defended without the App Sandbox

Stated plainly, so nobody reads a Keychain item as a boundary:

- A process running as Jan can read Claude Code's Keychain item (the
  item's ACL trusts `/usr/bin/security`), can read or copy a
  `CODEX_HOME`, can present a Keychain prompt and wait for a careless
  "Always Allow", can attach a debugger to sai or its children, and can
  read a child's environment (`ps -E`) or file descriptors.
- Therefore the controls are **what exists to be stolen** (sai holds no
  OAuth token; keys are per-provider, scoped and capped) and **who gets
  a shell as this user** (#56: coding agents never receive a real key,
  never read `~/.claude`, `~/.codex`, or the two Keychain items).
- The one thing a dedicated `CODEX_HOME` buys against a same-user
  attacker is *isolation of blast radius*: sai's ChatGPT login is a
  separate token family from the user's Codex CLI, so revoking one does
  not log the other out.

## What the design does defend

Files, backups, the repository, `settings.json`, the archive, logs,
exception text, process listings and child environments — the same list
ADR 0008 defends for keys — plus the two failure modes that cost real
money elsewhere: the refresh race (no shared token) and the precedence
flip (scrubbed child env + a positive auth check before the first
prompt).
