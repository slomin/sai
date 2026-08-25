# openai/codex — credential handling

Inspected at `ba6cf9c69277caec51a4c12c5b7401a9920930e0` (2026-08-25, `main`).
The workspace version in the tree is `0.0.0` (`codex-rs/Cargo.toml:143-144`;
stamped at release). The release installed on this Mac is `codex-cli
0.149.1`, tag `rust-v0.149.1` = `ff29a44391de`; between the tag and the
inspected commit the auth crate changed by 39 insertions / 290 deletions
across 13 files (`git diff --stat rust-v0.149.1 -- codex-rs/login/src …`),
none of which moves the facts below. Paths are relative to the repository;
line numbers are at the inspected commit. No credential-shaped value from the
source is reproduced here.

## 1. Who logs in, who owns the tokens

- The Codex process itself. PKCE authorization-code flow against
  `https://auth.openai.com` (`codex-rs/login/src/server.rs:59-62`: issuer,
  loopback port 1455, fallback 1457; `:160-182` PKCE + `state`; `:350-370`
  state mismatch rejected). PKCE S256 in `codex-rs/login/src/pkce.rs:12-27`.
- A public client id constant with an env override
  (`codex-rs/login/src/auth/manager.rs:201`, `CODEX_APP_SERVER_LOGIN_CLIENT_ID`).
- Device-code flow: `codex-rs/login/src/device_code_auth.rs`.
- The app-server exposes login to a client (see `codex-app-server.md`); the
  client never sees a token.

## 2. Where credentials live

- Schema `AuthDotJson` — `auth_mode`, `OPENAI_API_KEY`, `tokens`,
  `last_refresh`, plus personal-access-token / Bedrock variants
  (`codex-rs/login/src/auth/storage.rs:39-65`); file `$CODEX_HOME/auth.json`
  (`:154-156`); `CODEX_HOME` defaults to `~/.codex` and must be an existing
  directory when set (`codex-rs/core/src/config/mod.rs:4695-4702`).
- Four backends behind `AuthStorageBackend` (`storage.rs:167-171`), chosen
  by `create_auth_storage(codex_home, mode, keyring_backend)` (`:502-544`):
  - `File` — `OpenOptions::mode(0o600)` on create only (`:206-223`, mode at
    `:217`). An existing wider-mode file is truncated and rewritten without
    a `chmod` (reported as openai/codex#14704).
  - `Keyring` — OS credential store, service `"Codex Auth"`, entry key
    `cli|<first 16 hex of SHA-256(canonical codex_home)>` (`:235-323`,
    key derivation `:238-249`); on save it deletes the on-disk fallback.
  - `Secrets` — the blob age-encrypted under `codex_auth.age`
    (`codex-rs/secrets/src/local.rs:42,157`).
  - `Auto` — keyring first, **silent** fallback to the plaintext file on any
    keyring error, `warn!` only (`storage.rs:409-457`).
  - `Ephemeral` — process-global in-memory map for externally supplied
    tokens (`:459-500`).
- The documented user-facing switch is `cli_auth_credentials_store =
  file | keyring | auto` in `config.toml` (learn.chatgpt.com/docs/auth,
  see `vendor-docs.md`).

## 3. Refresh, locking, expiry, logout, accounts

- Proactive refresh when the access-token JWT `exp` is within 5 minutes;
  if `exp` is unparseable, when `last_refresh` is older than 8 days
  (`manager.rs:188-189` constants, `:2924-2946`).
- `refresh_token()` (`manager.rs:2768-2802`) takes an **in-process**
  `tokio::sync::Semaphore(1)` (`:2045`, `:2181`), then reloads the store:
  if the file changed under it, it assumes another process refreshed and
  skips; if the account id differs it fails permanently with
  `REFRESH_TOKEN_ACCOUNT_MISMATCH_MESSAGE` (`:196`, `:2798`).
- **No cross-process file lock** — no `flock`/`fs2`/`LockFile` in
  `codex-rs/login` or `codex-rs/secrets`. Two Codex processes refreshing the
  same single-use refresh token race; the loser is logged out
  (openai/codex#10332, closed not-planned; see `incidents.md`).
- Rotation honoured: `persist_tokens` writes back id/access/refresh and
  stamps `last_refresh` (`:1556-1579`). Refresh POST to
  `https://auth.openai.com/oauth/token`, override `CODEX_REFRESH_TOKEN_URL_OVERRIDE`
  (`:197`, `:1583-1634`).
- Failure classes `refresh_token_expired` / `_reused` / `_invalidated`
  and RFC 6749 `invalid_grant` are terminal (`:1636-1665`); permanent
  failures are cached per auth snapshot so later attempts fail fast
  (`:1787-1798`, `:2331-2339`).
- Logout: `logout` and `logout_with_revoke` (`:2862-2897`; revoke URL
  `:198`) clear file, keyring, secrets and ephemeral stores.
- **One account per `CODEX_HOME`**; no multi-account store and no
  switch RPC ("Account switches require a restart",
  `codex-rs/core-plugins/src/manager.rs:727`).

## 4. Precedence — what decides ChatGPT vs API billing

`load_auth()` (`manager.rs:1445-1552`), in order:

1. `CODEX_API_KEY` env, only when `enable_codex_api_key_env` is true
   (`:1456-1462`) — and that flag is `false` at every shipped call site
   found (`codex-rs/tui/src/lib.rs:585,891`, `codex-rs/core/src/connectors.rs:123`,
   `codex-rs/mcp-server/src/message_processor.rs:61`,
   `codex-rs/cli/src/login.rs:447,461`). Effectively inert.
2. Ephemeral store (externally supplied ChatGPT tokens) — "external auth
   takes precedence over any persisted credentials" (`:1464-1491`).
3. `CODEX_ACCESS_TOKEN` env — personal access token or agent-identity JWT
   (`:1493-1515`).
4. The persisted store (`:1522-1552`).

`OPENAI_API_KEY` is **not** in that chain: `read_openai_api_key_from_env`
(`:914-919`) only prefills the onboarding field
(`codex-rs/tui/src/onboarding/auth.rs:783`) and the realtime path
(`codex-rs/core/src/realtime_conversation.rs:1699`). The ChatGPT-vs-API
decision is `auth.json`'s own `auth_mode`, read by `resolved_mode()` (`manager.rs:1754-1771`, field `storage.rs:44-49`); absent
that, an `OPENAI_API_KEY` field present in the file resolves to ApiKey,
otherwise ChatGPT. `preferred_auth_method` no longer exists; the knobs are
`forced_login_method` (`codex-rs/config/src/config_toml.rs:257`) and
`allowed_login_methods` (`codex-rs/config/src/config_requirements.rs:160,907`),
evaluated in `codex-rs/config/src/auth_policy.rs:11-36`. A disallowed stored
mode makes `load_auth` return `Ok(None)` — "not logged in", not an error
(`manager.rs:1532-1534`).

## 5. Process boundaries

- The app-server is started as a child with stdio pipes and `CODEX_HOME`
  in the environment (reference spawn:
  `codex-rs/app-server/tests/common/test_app_server.rs:237-259`, which also
  `env_remove`s originator overrides). The token never leaves the child.
- An in-process client exists for embedding (`codex-rs/app-server-client/README.md`).
- Externally managed auth: `ExternalAuth` trait (`manager.rs:257-277`),
  bridged in `codex-rs/app-server/src/external_auth.rs:20-96` and wired in
  `request_processors/account_processor.rs:826-880`; the client-supplied
  token login variant is marked *"[UNSTABLE] FOR OPENAI INTERNAL USE ONLY -
  DO NOT USE"* (`app-server-protocol/src/protocol/v2/account.rs:86-103`).
  There is no `CODEX_AUTH` env var; that name is only the keyring secret
  (`storage.rs:230-234`).

## 6. Redaction

- `RedactedString` newtype, `Debug` prints `<redacted>`
  (`codex-rs/utils/redacted-string/src/lib.rs:9-48`).
- Best-effort regex scrub `redact_secrets()` for `sk-…`, `AKIA…`,
  bearer tokens and `api_key|token|secret|password` assignments
  (`codex-rs/secrets/src/sanitizer.rs:15-23`).
- `AuthHeaders` and `CachedAuth` have manual `Debug` impls that hide
  values (`auth_headers.rs:27-32`, `manager.rs:1800-1816`).
- Gap: `AuthDotJson` (`storage.rs:40`) and `TokenData`
  (`codex-rs/login/src/token_data.rs:10-25`) `#[derive(Debug)]` over plain
  `String` token fields; no site was found that logs them, but the types
  do not protect themselves. A refresh failure logs the OAuth error body
  verbatim at `error` level (`manager.rs:1612`).

## 7. Tests without credentials

- `ChatGptAuthFixture` writes a synthetic `auth.json` (locally minted
  JWT, literal placeholder refresh token, settable `last_refresh`)
  through the real `save_auth` (`codex-rs/app-server/tests/common/auth_fixtures.rs:20-77`).
- Every test gets a temporary `CODEX_HOME`
  (`codex-rs/test-binary-support/lib.rs:49-63`).
- `wiremock` mock servers for refresh, device code, logout and login
  (`codex-rs/login/tests/suite/*.rs`); `CODEX_REFRESH_TOKEN_URL_OVERRIDE`,
  `CODEX_REVOKE_TOKEN_URL_OVERRIDE`, `CODEX_APP_SERVER_LOGIN_CLIENT_ID`
  exist for exactly this (`manager.rs:197-201`).
- `CodexAuth::create_dummy_chatgpt_auth_for_testing()` (`manager.rs:774`)
  and `StaticExternalAuth` (`codex-rs/core-plugins/src/test_support.rs:133-142`).

## 8. Portable vs macOS-specific

Everything above is the vendor's; a client only needs to spawn a process
and speak newline-delimited JSON-RPC. The keyring backend maps to the
macOS Keychain on this platform; a client that wants it sets
`cli_auth_credentials_store = "keyring"` in the `config.toml` of the
`CODEX_HOME` it launches with.
