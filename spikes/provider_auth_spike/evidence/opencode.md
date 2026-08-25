# anomalyco/opencode — credential handling

Inspected at `ac1c048e6420eb4c728fd3e343a1ba7b076cba92` (2026-08-26,
`main`; the repository moved from `sst/opencode`). Workspace packages are
`1.18.23` (`packages/opencode/package.json`); the CLI installed here is
`opencode 1.18.23`. Shallow clone — no history. Two credential systems
coexist at this commit: the v1 JSON store (used by the CLI and plugins)
and a newer SQLite `Credential` table.

## 1. Who logs in, who owns the tokens

- OpenCode itself, in-tree, for ChatGPT/Codex: `packages/opencode/src/plugin/openai/codex.ts`
  — Codex's public client id, issuer `https://auth.openai.com`, loopback
  port 1455, `codex_cli_simplified_flow: "true"`, `originator: "opencode"`
  (`:10-16`, `:97-99`, `:166`); PKCE S256 (`:23-36`); device-code fallback
  (`:471-549`). Requests to `/v1/responses` are rewritten to
  `https://chatgpt.com/backend-api/codex/responses` (`:12`, `:415-424`)
  with `authorization: Bearer` + `ChatGPT-Account-Id` (`:410-413`);
  `User-Agent: opencode/<version>` (`:556-565`). A v2 copy lives in
  `packages/core/src/plugin/provider/openai.ts` (same id `:14`, port `:16`,
  methods `chatgpt-browser` / `chatgpt-headless` `:18-19`).
- **Anthropic Pro/Max OAuth is not in the tree.** `packages/core/src/plugin/provider/anthropic.ts`
  (27 lines) only adds beta headers; grep for `claude.ai/oauth`,
  `platform.claude.com`, `oauth-2025-04-20`, `claude-code-20250219` is
  empty. The UI still renders an "Anthropic Pro/Max" label when a *plugin*
  registers such a method (`packages/app/src/components/dialog-connect-provider.tsx:1122-1124`).
  Removed by PR anomalyco/opencode#18186 "anthropic legal requests"
  (merged 2026-03-19; see `incidents.md`). Neither
  `opencode-anthropic-auth` nor `opencode-openai-auth` is in `packages/`
  or `bun.lock`.

## 2. Where credentials live

- v1: `$XDG_DATA_HOME/opencode/auth.json` (`packages/opencode/src/auth/index.ts:10`),
  discriminated union `oauth {refresh, access, expires}` | `api {key}` |
  `wellknown {key, token}` (`:14-35`); `OAUTH_DUMMY_KEY` sentinel handed to
  the AI SDK when the real auth is OAuth (`:8`).
- Write is `fsys.writeJson(file, data, 0o600)` (`:73-89`, mode at `:79`),
  and `writeJson` is *write then chmod* (`packages/core/src/fs-util.ts:110-114`,
  chmod at `:113`) — the file exists under the umask for a moment on first
  write. Data dir created with no `mode` (`packages/core/src/global.ts:35-43`).
- **`OPENCODE_AUTH_CONTENT`**: when set, the whole store is parsed from
  that environment variable instead of the file (`auth/index.ts:59-63`).
- v2: `packages/core/src/credential.ts` over `CredentialTable`
  (`packages/core/src/credential/sql.ts`); DB at
  `$XDG_DATA_HOME/opencode/opencode.db`, override `OPENCODE_DB`
  (`packages/core/src/database/database.ts:44-54`); **no chmod on the DB**.
  `create` deletes sibling rows for the same integration — one credential
  per integration.
- No keychain, no encryption at rest (repo-wide grep for
  `keychain|keytar|libsecret|safeStorage|find-generic-password` empty).
- Asymmetry: MCP tokens in `mcp-auth.json` are written at `0o600` **under a
  file lock** (`packages/opencode/src/mcp/auth.ts:7,37,63,80`); provider
  tokens are not locked.

## 3. Refresh, locking, expiry, logout, accounts

- Codex refresh triggers only when `expires < Date.now()` — zero margin
  (`codex.ts:336-394`); concurrency control is one in-process
  `refreshPromise` (`:338-344`, cleared `:386-388`); no file lock; rotation
  persisted through the local HTTP API `client.auth.set` (`:371-380`). No
  retry/backoff; a failed refresh throws.
- OpenCode's *own* console account (client id `opencode-cli`, device
  flow) has a 5-minute eager-refresh threshold and an in-process dedupe
  cache (`packages/opencode/src/account/account.ts:123-141`, `:248-263`).
- Provider credentials are single-slot per provider id; multi-account
  exists only for the console account (`packages/opencode/src/account/repo.ts:13,58-70`).
- Logout is a local delete (`packages/opencode/src/cli/cmd/providers.ts:491-498`);
  no provider-side revoke.

## 4. Precedence

`packages/opencode/src/provider/provider.ts` merges in order: env-derived
key (`:1577-1588`, e.g. `OPENAI_API_KEY`) → stored API key from `auth.json`
(`:1590-1601`, overwrites env) → plugin OAuth loader (`:1603-1622`, sets the
dummy key + custom fetch, wins) → per-provider custom resolvers
(`:1625-1641`, some read env first — inconsistent) → config `options`
(`:1643-1650`, last). Final: explicit config `options.apiKey` beats all
(`:1777`). **No automatic subscription↔API-key fallback** and no cooldown
rotation found. OAuth-authenticated Codex models get cost zeroed and
context capped (`codex.ts:290-323`).

## 5. Process boundaries

- Remote/container workspaces receive **the entire credential store** as
  `OPENCODE_AUTH_CONTENT: JSON.stringify(auth.all())`
  (`packages/opencode/src/control-plane/workspace.ts:528-535`; asserted by
  `packages/opencode/test/control-plane/workspace.test.ts:442,501`).
- Plugins get a `getAuth()` thunk and write back via the local HTTP API
  (`provider/auth.ts:163-221`, `provider.ts:1613-1618`), which is protected
  by HTTP Basic (`packages/opencode/src/server/auth.ts:19-45`).
- Shell/PTY children get `{}` unless a plugin's `shell.env` hook adds
  something (`packages/opencode/src/plugin/pty-environment.ts:14-22`).
- The proxy helper strips hop-by-hop and `proxy-authorization` but
  forwards `authorization` (`packages/opencode/src/server/proxy-util.ts:1-29`).
- AWS/SAP resolvers mutate `process.env` from stored auth
  (`provider.ts:318-325,577-585`) — inherited by any later child.

## 6. Redaction

- No runtime log redaction (`packages/core/src/observability/logging.ts`
  has none). Redaction exists only in the test cassette recorder
  (`packages/http-recorder/src/redaction.ts:5-49`: headers, query params,
  `sk-…`, `sk-ant-…`, bearer, PEM, plus any env var whose name matches
  `API|AUTH|BEARER|CREDENTIAL|KEY|PASSWORD|SECRET|TOKEN`).

## 7. Tests without credentials

- `packages/opencode/test/preload.ts`: per-test temp XDG dirs (`:9-11`,
  `:34-38`), explicit `delete process.env[...]` for `ANTHROPIC_API_KEY`,
  `OPENAI_API_KEY`, `OPENROUTER_API_KEY` and friends (`:58-83`),
  `OPENCODE_DB=":memory:"` (`:86`).
- `OPENCODE_AUTH_CONTENT: "{}"` for CLI subprocess tests
  (`packages/opencode/test/lib/cli-process.ts:76`); a leak regression test
  asserts a JSON-RPC error never echoes the env store
  (`packages/opencode/test/cli/acp/initialize-auth.test.ts:44`).
- Codex plugin tests mint an `alg:none` JWT locally
  (`packages/opencode/test/plugin/codex.test.ts:15-19`).
- Live suites are opt-in via `requires: ["OPENAI_API_KEY"]` with
  cassette fallback (`packages/llm/test/provider/*.recorded.test.ts`).

## 8. Portable vs macOS-specific

Nothing platform-specific: plaintext JSON/SQLite under XDG dirs, no OS
keychain.
