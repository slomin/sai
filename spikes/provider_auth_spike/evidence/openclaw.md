# openclaw/openclaw — credential handling

Inspected at `1d526c5c0ef635b4b7fda952c2b26da0c0290652` (2026-08-25,
`main`). Root `package.json` version `2026.8.1`. Shallow clone. Not
installed on this Mac. The most developed credential design of the four
clients — and the one that runs its own Claude OAuth flow.

## 1. Who logs in, who owns the tokens

- OpenClaw itself, for both vendors:
  - Anthropic: `src/llm/utils/oauth/anthropic.ts` — Claude Code's public
    client id (`:38`), `AUTHORIZE_URL = https://claude.ai/oauth/authorize`
    (`:39`), `TOKEN_URL = https://platform.claude.com/v1/oauth/token`
    (`:40`), loopback port 53692 (`:43-45`), scopes including
    `user:inference` and `user:sessions:claude_code` (`:56`), PKCE S256
    (`:232-256`), 5-minute refresh skew baked into `expires` (`:108-113`),
    refresh at the same token URL (`:336-354`).
  - OpenAI/Codex: Codex's client id, port 1455,
    `codex_cli_simplified_flow=true`, `originator: "openclaw"`
    (`extensions/openai/openai-chatgpt-oauth-authorization.runtime.ts:4-6,45-54`;
    device code in `extensions/openai/openai-chatgpt-device-code.ts:17-34`,
    `User-Agent: openclaw/<version>`).
- On the wire the Anthropic OAuth path adds the Claude Code beta headers
  `claude-code-20250219`, `oauth-2025-04-20` (`extensions/anthropic/stream-wrappers.ts:40-42`,
  merged `:62-74`) and sends `sk-ant-oat…` tokens as `Authorization:
  Bearer`, API keys as `x-api-key` (`extensions/anthropic/register.runtime.ts:146-154`).
  No system-prompt spoofing (grep `You are Claude Code` empty).
- Separate "Claude CLI reuse" path: only `claude auth status --json` →
  `loggedIn` (`extensions/anthropic/cli-auth-seam.ts:26`); the docs say
  "OpenClaw never reads, stores, refreshes, or forwards the native login
  tokens" (`docs/gateway/authentication.md:60`).
- Policy commentary is explicit: `docs/concepts/oauth.md:17-18` —
  "Anthropic staff told us this usage is allowed again, so OpenClaw treats
  Claude CLI reuse and `claude -p` usage as sanctioned … unless Anthropic
  publishes a new policy"; `docs/providers/claude-max-api-proxy.md:15-30`
  warns "Anthropic has blocked some subscription usage outside Claude Code
  in the past".

## 2. Where credentials live

- SQLite, not JSON: `state/openclaw.sqlite` or the legacy per-agent
  `openclaw-agent.sqlite` (`src/agents/auth-profiles/path-resolve.ts:16-83`),
  two JSON blobs per row (`src/agents/auth-profiles/sqlite.ts:57-62`).
- Modes: `0o700` dir / `0o600` file, applied to the DB **and** its
  `-wal`/`-shm`/journal sidecars (`src/state/openclaw-state-db-permissions.ts:12-54`);
  best-effort with a one-time warning on chmod-less filesystems.
  `openclaw.json` written `0o600` in a `0o700` dir
  (`src/config/io.write.ts:396,554,588-589`).
- Schema (`src/agents/auth-profiles/types.ts:13-74`): `oauth {access,
  refresh, expires, accountId?, chatgptPlanType?, …}`, `api_key {key |
  keyRef}`, `token {token | tokenRef}` (static, never refreshed).
  `AUTH_STORE_VERSION = 1` (`constants.ts:8`).
- No encryption at rest; indirection through `SecretRef`
  (`env`/`file`/`exec`/shared store — `src/config/types.secrets.ts`,
  `docs/gateway/secrets.md`); OAuth-mode profiles reject SecretRefs
  (`src/agents/auth-profiles/policy.ts`).
- The OS keychain is **read, never written**, and only for the *Codex CLI's*
  item: `security find-generic-password -s "Codex Auth" -a <cli|sha16>`
  (`src/agents/cli-credentials.ts:165-168`, `:237`), gated by
  `allowKeychainPrompt` which every runtime caller passes as `false`.

## 3. Refresh, locking, expiry, logout, accounts

- Constants (`src/agents/auth-profiles/constants.ts:20-46`):
  `OAUTH_REFRESH_LOCK_OPTIONS = { retries: 20, factor 2, 100 ms → 10 s,
  randomize, stale 180 s }`, `OAUTH_REFRESH_CALL_TIMEOUT_MS = 120 s` (must
  stay `< stale`), `EXTERNAL_CLI_SYNC_TTL_MS = 15 min`.
- **Cross-process file lock** per `(provider, profileId)` under
  `<stateDir>/locks/oauth-refresh/` (`src/agents/auth-profiles/path-resolve.ts:103-120`);
  the comment names the bug it fixes: "prevents the `refresh_token_reused`
  storm when N agents share one OAuth profile (see issue #26322)".
- `doRefreshOAuthTokenWithLock` (`src/agents/auth-profiles/oauth-manager.ts:498-703`):
  re-read inside the lock, early-return if another holder refreshed
  (`:512-528`), adopt a fresher credential from the shared store only on
  identity match (`:530-573`), timeout-wrapped refresh (`:628-644`), CAS
  persist with a single-pass conflict resolver (`:649-676`, `:468-494`),
  mirror to the main store (`:677-685`); plus an in-process queue keyed by
  `provider|profileId` (`:704-713`).
- Expiry margin `DEFAULT_OAUTH_REFRESH_MARGIN_MS = 5 min`
  (`src/agents/auth-profiles/credential-state.ts:20`, used `:68`).
- Profiles are first-class and ordered (`anthropic:claude-cli`,
  `openai:codex-cli`, `openai:default` — `constants.ts:11-18`;
  `src/agents/auth-profiles/order.ts:284,446`), session-pinnable
  (`session-override.ts`), with cooldown classes 15 s / 30 s / 5 min /
  12 h / 24 h (`src/agents/auth-profiles/usage.ts:106-110`) and
  model-scoped blocks (`types.ts:102-120`). Profile→profile then
  model→model failover (`src/agents/model-fallback-runner.ts:197`,
  `docs/concepts/model-failover.md`).
- Logout (`openclaw models auth logout`, gateway `models.authLogout`)
  removes the profile across stores and aborts in-flight runs with
  `stopReason: "auth-revoked"` (`src/gateway/server-methods/models-auth-status.ts:430-520`);
  docs say it does **not** revoke provider-side (`docs/gateway/authentication.md:142`).

## 4. Precedence

`resolveApiKeyForProviderCore` (`src/agents/model-auth-provider.ts`):
explicit `profileId` (`:143-219`) → configured `auth.profiles`/`auth.order`
(`:221-240`) → `aws-sdk` (`:242-249`) → env **only if
`credentialPrecedence === "env-first"`** (`:252-297`; type at `:38`,
default `profile-first` — only two call sites pass `env-first`) → config
`apiKey` as a profile reference, then literal/SecretRef (`:301-400`).
So a stored profile beats `ANTHROPIC_API_KEY`/`OPENAI_API_KEY` for model
runs. Env vars per provider: `src/secrets/provider-env-vars.ts:23`
(`anthropic: ["ANTHROPIC_OAUTH_TOKEN", "ANTHROPIC_API_KEY"]`); `.env`
allow-list `src/infra/dotenv.ts:14-17`. API-key rotation on 429 across
`<PROVIDER>_API_KEYS` lists (`src/agents/live-auth-keys.ts:82-165`).

## 5. Process boundaries — the strongest design seen

- **Sentinels**: secrets are replaced in child/tool payloads by
  `oc-sent-v2.<base64url>.end` tokens sealed with a process-global
  AES-256-GCM key (`src/secrets/sentinel.ts:5-31`, mint `:52-54`,
  resolve `:74`); a local CONNECT proxy with its own CA substitutes real
  values only for registered `allowedHosts` and audits
  `forwarded|refused` (`src/secrets/egress-proxy/proxy-server.ts:21-59`).
- **Claude CLI child gets the secret on fd 3, not env**:
  `prepareClaudeNodeSecretInput` deletes `ANTHROPIC_API_KEY`,
  `CLAUDE_CODE_OAUTH_TOKEN`, `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB` from the
  child env, sets `CLAUDE_CODE_{OAUTH_TOKEN,API_KEY}_FILE_DESCRIPTOR=3`,
  passes the value on that descriptor and zeroes the buffer afterwards
  (`src/node-host/invoke-agent-cli-claude-handler.ts:72-105`).
- Gateway → node RPC accepts only an allow-list of env keys (`ENV_ALLOWLIST`,
  `src/node-host/invoke-agent-cli-claude-params.ts:54-65`), refuses more
  than one Claude credential ("exactly one Claude credential may be
  provided", `:288`), and bounds every value.
- The gateway holds the store; agents resolve profiles read-through at
  request time without copying secret material
  (`docs/auth-credential-semantics.md`); status RPCs return provenance only
  (`src/gateway/server-methods/models-auth-status-api-keys.ts:53-101`);
  UI round-trips use `__OPENCLAW_REDACTED__` (`src/config/redact-snapshot.ts:86-92`).
- External CLI stores are read-only, scoped to configured providers
  (`src/agents/auth-profiles/external-cli-scope.ts`), resolved against the
  OS home, never `OPENCLAW_HOME` (`src/agents/cli-credentials.ts:80-90`).

## 6. Redaction

- Exact-value registry (raw + URL-encoded + JSON-escaped forms, LRU 512,
  min length 6; `src/logging/secret-redaction-registry.ts:4-85`), auto-fed
  by every sentinel mint.
- Pattern layer: assignment keys, structured-JSON keys, `Authorization`/
  bearer, `sk-[A-Za-z0-9_-]{8,}` (`src/logging/redact-patterns.ts:17,75,104-112,158`);
  defaults keep 6 leading / 4 trailing chars (`src/logging/redact.ts:36-39`).
- Support bundles have their own layer
  (`src/logging/diagnostic-support-*redaction.ts`); audit history is
  metadata-only (`docs/gateway/audit.md`); docs standardise non-secret
  placeholders (`docs/reference/secret-placeholder-conventions.md`).

## 7. Tests without credentials

- Hermetic by default: `test/setup.env.ts:22` installs
  `installTestEnv({ mode: "hermetic" })` — "prevents real or staged
  credentials/config from entering the worker"; `test/test-env.ts:18-25`
  deletes live triggers and `OPENCLAW_HOME`, `:192-265` repoints `HOME`,
  `XDG_*`, `OPENCLAW_STATE_DIR` into a per-worker temp home.
- Live lane opt-in only (`OPENCLAW_LIVE_TEST=1` + provider key), staging
  *copies* of foreign-CLI stores into the temp home via a subprocess
  (`test/test-env.ts:26-34`, `:397-417`); `test/vitest/vitest.live.config.ts`
  is a separate shard.
- Fixtures: `src/agents/auth-profiles/oauth-test-utils.ts:26-50`;
  dedicated suites `oauth.concurrent-agents.test.ts`,
  `oauth-refresh-queue.test.ts`, `oauth.mirror-refresh.test.ts`,
  `upsert-with-lock.sqlite.test.ts`.

## 8. Portable vs macOS-specific

Everything is Node and portable; the only macOS-specific code is the
read of the Codex CLI's Keychain item via `/usr/bin/security`.
