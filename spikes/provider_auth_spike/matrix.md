# Comparison matrix

Rows are the ticket's questions; columns are the four clients and the
two official contracts. Each cell is a summary — the `path:lines @ SHA`
and URL citations are in `evidence/`. Pins: Codex `ba6cf9c69277`,
OpenCode `ac1c048e6420` (1.18.23), OpenClaw `1d526c5c0ef6` (2026.8.1),
Hermes `02c7ae956e42` (0.20.5), Agent SDK py `15af77c68ad7` (0.2.143),
docs 2026-08-25.

| question | Codex CLI | OpenCode | OpenClaw | Hermes | Claude Code / Agent SDK (docs + py SDK) | Codex App Server |
|---|---|---|---|---|---|---|
| **Who performs login, owns tokens** | The app: own PKCE + device code; app-server exposes login to clients | The app: own PKCE/device code for ChatGPT with Codex's client id; Anthropic OAuth removed 2026-03 | The app: own PKCE for Anthropic (Claude Code's client id) and ChatGPT (Codex's); gateway owns the store | The app: own PKCE with Claude Code's client id **and** borrows Claude Code's + Codex's stored tokens | Claude Code (`/login`); the SDK never logs in | Codex; the client drives `account/login/start` and never sees a token |
| **Where stored** | `$CODEX_HOME/auth.json`, or OS keyring (`Codex Auth`), or age-encrypted; `auto` falls back silently | `auth.json` (XDG) + SQLite `Credential` table; plaintext | SQLite `openclaw.sqlite` blobs; plaintext; SecretRef indirection | `~/.hermes/auth.json`, `.env`; plaintext | macOS Keychain (`Claude Code-credentials`); Linux `~/.claude/.credentials.json` | same as Codex, per `CODEX_HOME` |
| **File modes / at-rest / backup** | `0600` on create only; keyring optional; no dir mode | `0600` after write (umask window); DB not chmod'd; dir default | `0700`/`0600` incl. WAL/SHM; best-effort | `0600` via `O_EXCL`, dir `0700`; skipped in containers | Keychain item ACL trusts `/usr/bin/security` (Silverfort); file `0600` | inherits Codex |
| **Refresh / locking / expiry** | 5 min before `exp` or 8 days; in-process semaphore + reload-compare; **no cross-process lock** | 0 ms margin; in-process promise; no lock | 5 min margin; cross-process file lock + queue + CAS; documented "token sink" | 120 s skew; `fcntl` lock; adopts Claude Code's rotated token before refreshing | Claude Code refreshes; renewal warning 3 days out | inherits Codex |
| **Logout / switching / multi-account** | logout clears all stores; one account per `CODEX_HOME`, no switch RPC | local delete; single slot per provider | ordered profiles, cooldowns, session pinning; logout aborts runs | profiles = separate homes; cannot clear a borrowed credential | `/logout`; one login | `account/logout`; one account |
| **Crossing process boundaries** | stdio JSON-RPC; `CODEX_HOME` env; external-auth bridge is OpenAI-internal | whole store to workspaces via `OPENCODE_AUTH_CONTENT`; plugins via thunk + local HTTP | sentinels + egress proxy; Claude CLI child on **fd 3**; RPC env allow-list, "exactly one Claude credential" | child env blocklist, except `CLAUDE_CODE_OAUTH_TOKEN` kept on purpose; docker volume | env merge (py) vs replace (TS); SDK copies `.credentials.json` + Keychain into a temp `CLAUDE_CONFIG_DIR`, strips `refreshToken` | stdio; nothing crosses |
| **Precedence → silent API billing?** | `CODEX_API_KEY` inert; `OPENAI_API_KEY` not in chain; `auth_mode` in file decides; historic auto-minted key (codex#2000) | env → stored key → OAuth plugin → config; no auto fallback | profile-first by default; env only if `env-first`; rotation on 429 across keys/profiles | env → Claude Code store → pool; guard against OAuth↔key flip; docs: "bills as extra usage" | **`ANTHROPIC_API_KEY` outranks `/login`; in `-p` "always used when present"**; $52/$152/$1,122 incidents | `auth_mode` |
| **Logs / errors / telemetry** | `RedactedString`, header `Debug` hidden; `AuthDotJson` derives `Debug`; error body logged verbatim | none at runtime; cassette recorder only | value registry + patterns + support-bundle layer; metadata-only audit | `redact.py` on every handler, default on | stderr only if requested; SDK strips refresh token | inherits Codex |
| **Keyless tests** | temp `CODEX_HOME`, synthetic `auth.json`, wiremock, URL overrides | temp XDG, env vars deleted, `OPENCODE_AUTH_CONTENT={}`, `alg:none` JWT | hermetic env by default, live shard opt-in, staged copies | `conftest` unsets by suffix, autouse Keychain neutraliser, seat-belt raise | SDK tests fake the transport | fixtures + mock model server |
| **Portable vs macOS** | keyring = Keychain on macOS; else portable | portable, no keychain | portable; reads Codex Keychain item on Darwin | portable; reads Claude Code Keychain item on Darwin | Keychain is Claude Code's; caller must not redirect `CLAUDE_CONFIG_DIR` | portable |

## What the columns agree on

1. Nobody encrypts a provider credential at rest with their own key; the
   only real protections are the OS keychain (Codex, opt-in) and file
   modes. Everyone accepts that a same-user process can read the store.
2. Single-use refresh tokens plus more than one process equal logouts.
   The clients that survived it added a cross-process lock (OpenClaw,
   Hermes) or adopt the other process's rotation (Hermes); Codex did not.
3. An API-key environment variable outranks a subscription login in
   both vendors' own tools, and that — not theft — is where real money
   was lost.
4. The clients that hold a vendor's OAuth token themselves are the ones
   that were blocked, sued or forced to impersonate. The vendor runtime
   holding it is the shape that stayed supported.
5. Every project keeps tests keyless the same way: a temp home, env vars
   removed, a fake transport, live runs behind an explicit opt-in.
