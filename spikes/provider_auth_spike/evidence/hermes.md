# NousResearch/hermes-agent — credential handling

Inspected at `02c7ae956e42891d5e337a921b45de0a6067146d` (2026-08-25,
`main`). `pyproject.toml:4-5` `hermes-agent 0.20.5`. This **is** the
current upstream: README and every localisation name
`github.com/NousResearch/hermes-agent`; no move/rename notice. Not
installed on this Mac. Hermes is the counter-example in this spike: it
borrows another client's credential and impersonates that client.

## 1. Who logs in, who owns the tokens

- Its own PKCE flow reusing Claude Code's public client id and the
  `console.anthropic.com` callback, scopes `org:create_api_key
  user:profile user:inference` (`agent/anthropic_adapter.py:1553-1558`);
  tokens to `$HERMES_HOME/.anthropic_oauth.json` (`:1555-1557`).
- `run_oauth_setup_token()` shells `claude setup-token` interactively and
  harvests the result (`agent/anthropic_adapter.py:1486-1526`).
- **Reads Claude Code's credential**, two ways, then reconciles:
  - macOS Keychain: `security find-generic-password -s "Claude
    Code-credentials" -w` (`agent/anthropic_adapter.py:1025-1078`, call at
    `:1043`), parsing `claudeAiOauth.{accessToken, refreshToken, expiresAt}`.
  - File: `~/.claude/.credentials.json` (`:1083-1108`).
  - `read_claude_code_credentials()` prefers the non-expired one, else
    the later `expiresAt` (`:1111-1148`).
- **Writes back** into `~/.claude/.credentials.json` after its own
  refresh, re-persisting `scopes` so Claude Code ≥2.1.81 still accepts
  the file (`_write_claude_code_credentials`, `:1271-1348`; called from the
  refresh path `:1270` and `agent/credential_pool.py:1448-1457, 1532-1541`).
  Never writes the Keychain, so the two sources can diverge.
- **Reads Codex's** `$CODEX_HOME/auth.json` (default `~/.codex`) but never
  writes it: `_import_codex_cli_tokens` (`hermes_cli/auth.py:4175-4207`),
  and on `invalid_grant`/`refresh_token_reused` re-imports the CLI's
  current token (`_recover_codex_tokens_from_cli`, `:3981-4174`). Header
  comment: tokens kept in `~/.hermes/auth.json` "to prevent refresh token
  rotation conflicts" (`:3796-3800`).
- Consent gate: pool seeding of `claude_code`/`hermes_pkce` entries only
  when Anthropic is explicitly configured
  (`agent/credential_pool.py:2583-2587`, referencing PR #4210:
  "auxiliary client fallback chains silently read
  ~/.claude/.credentials.json without user consent");
  `is_provider_explicitly_configured` (`hermes_cli/auth.py:1942-2020`)
  deliberately ignores `CLAUDE_CODE_OAUTH_TOKEN` because Claude Code sets
  it itself. The gate covers pool seeding only: `resolve_anthropic_token()`
  (`anthropic_adapter.py:1428-1483`, source #4) and the `/model` picker,
  inventory and dashboard read the Keychain item ungated.
- **Impersonation on the wire** when the token is OAuth-shaped:
  `user-agent: claude-code/<detected version> (external, cli)` and
  `x-app: cli` (`anthropic_adapter.py:947-954`; the version is read by
  running `claude --version`, `:414-441`); the system prompt is prefixed
  with `_CLAUDE_CODE_SYSTEM_PREFIX` = "You are Claude Code, Anthropic's
  official CLI for Claude." (`:439`, `:2989`) and product names rewritten
  (`Nous Research → Anthropic`, `:3005`); tool names rewritten to a
  `mcp__` prefix because — quoting the code comment at `:3012-3020` —
  Anthropic's classifier answers single-underscore names with 400
  "Third-party apps now draw from extra usage, not plan limits". The
  token endpoint deliberately uses an `axios/…` UA because a
  `claude-code/` UA is 429'd there (`:1546-1553`).
- Explicitly *not* borrowed: `hermes import-agent` copies skills/config
  from `~/.claude` and `~/.codex` but "Secrets are NEVER imported"
  (`hermes_cli/agent_import.py:33,82`, `_CREDENTIAL_FILENAMES`).

## 2. Where credentials live

- `$HERMES_HOME/auth.json` (default `~/.hermes/auth.json`) holding
  `providers.*`, `credential_pool.*`, `active_provider`,
  `suppressed_sources` (`hermes_cli/auth.py:1114-1133`); secrets env file
  `~/.hermes/.env` (`hermes_cli/config.py:730-732`); MCP OAuth state
  `tools/mcp_oauth.py:415-440`.
- Atomic create at `0600`: `os.open(O_WRONLY|O_CREAT|O_EXCL, 0600)` +
  `fsync` + `os.replace`, parent dir `0700` (`hermes_cli/auth.py:1417-1470`;
  `hermes_constants.py:1017-1056` `secure_parent_dir` refuses to chmod
  `/`, top-level dirs or `$HOME`). Skipped under `HERMES_CONTAINER` /
  `HERMES_SKIP_CHMOD` (`hermes_cli/config.py:838`).
- No keyring/keychain dependency, no encryption at rest for provider
  credentials. The Electron desktop stores its *own* session token via
  `safeStorage` (`apps/desktop/electron/hardening.ts:156-227`).
- External secret sources (Bitwarden, 1Password, `secrets.command`,
  `providers.<x>.key_cmd`) resolve at startup (`agent/secret_sources/`,
  `website/docs/integrations/providers.md:1298-1304`).

## 3. Refresh, locking, expiry, logout, accounts

- Cross-process advisory lock on the store (`fcntl`/`msvcrt`, 15 s
  timeout, documented lock ordering; `hermes_cli/auth.py:1320-1345`);
  per-credential leases in the pool (`agent/credential_pool.py:2281-2337`).
- Skews: 120 s (`hermes_cli/auth.py:113-115`); Claude Code `expiresAt`
  in ms with a 60 s buffer, missing/zero = "managed key, valid"
  (`anthropic_adapter.py:1151-1163`).
- Before refreshing it re-reads the live Claude Code sources and adopts
  an already-rotated token rather than racing (`:1230-1281`).
- Unreadable store (EACCES/EIO) re-raises rather than degrading to `{}`;
  an unparseable one is copied to `auth.json.corrupt` (`hermes_cli/auth.py:1348-1414`).
- Logout: `logout_command` clears Hermes' own entry
  (`hermes_cli/auth.py:9491-9521`). A *borrowed* Claude Code credential
  cannot be cleared by Hermes; the dashboard hands the user a shell
  command that deletes the Keychain item and the file
  (`hermes_cli/web_server.py:11020-11040`).
- Profiles = independent `HERMES_HOME`s (`hermes_cli/profiles.py:1-20,219-220`)
  with read-only fallback to the global store (`hermes_cli/auth.py:1136-1215`).
  Multiplex gateway: an unscoped secret read **raises** rather than
  falling back to `os.environ` (`agent/secret_scope.py:1-90`).
- Rotation ladder documented in
  `website/docs/user-guide/features/credential-pools.md:24-41`: plan-limit
  429 → rotate; generic 429 → retry once then rotate; 402 → 1 h cooldown;
  401 → refresh then rotate; all exhausted → `fallback_model`.

## 4. Precedence

- Anthropic token chain (`anthropic_adapter.py:1428-1441`):
  `ANTHROPIC_TOKEN` → `CLAUDE_CODE_OAUTH_TOKEN` → `ANTHROPIC_API_KEY` →
  **Claude Code's credential store** → Hermes pool entry. Inversions: a
  static env OAuth token is overridden by the Claude Code file when that
  has a `refreshToken` (`:1366-1387`); `~/.hermes/.env` is preferred over
  `os.environ` for the key-vs-OAuth decision (`agent/credential_pool.py:2941`).
- The billing-lane flip is named in code: seeding OAuth entries while the
  user chose an API key would mean "rotation on a 401/429 silently flips
  the session onto an OAuth credential, which forces the Claude Code
  identity injection, `mcp_` tool-name rewrite, and claude-cli User-Agent
  header" (`agent/credential_pool.py:2589-2600`); guard: with
  `ANTHROPIC_API_KEY` set and no OAuth env var, OAuth entries are pruned
  (`:2616-2628`). Docs: OAuth path "routes as Claude Code against your
  Anthropic account", requires Max + extra-usage credits, "All Hermes
  usage bills as 'extra usage'" (`website/docs/integrations/providers.md:120-145`).

## 5. Process boundaries

- Registry-driven blocklist strips every provider credential var from
  terminal subprocesses (`tools/environments/local.py:226-334`) — with
  one deliberate exception: `blocked.discard("CLAUDE_CODE_OAUTH_TOKEN")`
  (`:325-334`), because stripping it made agent-spawned `claude` CLIs
  fall through to the shared Keychain and, on failure, clear it (issue
  #55878). Pattern-based strip of dynamically named secrets
  (`:363-484`); two-tier `hermes_subprocess_env(inherit_credentials=False)`
  (`:620-680`); code-execution child scrub (`tools/code_execution_tool.py:136-299`);
  passthrough registration rejects blocklisted names
  (`tools/env_passthrough.py:50-165`).
- Docker mounts `~/.hermes` as a volume (`docker-compose.yml:36-42`), so
  `auth.json` and `.env` are inside the container by file, not env.

## 6. Redaction

- `agent/redact.py` (1427 lines): key prefixes, env-assignment forms,
  config-key names, `Authorization`, PEM, JWTs, URL userinfo/query,
  control-char normalisation (`:80-485`); on by default
  (`HERMES_REDACT_SECRETS`, `:70-78`), opt-out logged at startup; wired into
  every log handler (`hermes_logging.py:316-395`) and tool stdout
  (`tools/code_execution_tool.py:1228-1230`). Pool metadata persists
  fingerprints, never values (`agent/credential_persistence.py:20-108`).
  No telemetry SDK.

## 7. Tests without credentials

- `tests/conftest.py:1-21` invariants: no credential env vars, isolated
  `HERMES_HOME` (set at import time, `:38-80`), deterministic runtime;
  `_looks_like_credential` unsets by suffix (`:139-186`); **autouse**
  `_neutralize_macos_keychain_creds` patches the Keychain read to `None`
  (`:628-644`); `tests/test_hermetic_side_effect_guards.py:34-66`
  booby-traps `subprocess.run` so reaching the real `security` binary
  fails. Production seat belt: under `PYTEST_CURRENT_TEST`,
  `_auth_file_path()` raises if it resolves to the real store
  (`hermes_cli/auth.py:1118-1132`).

## 8. Portable vs macOS-specific

The Keychain read is Darwin-only; everything else is plain files.
