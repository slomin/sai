# Codex App Server — the contract a client programs against

Same commit as `codex.md` (`ba6cf9c69277`, 2026-08-25). Official page:
learn.chatgpt.com/docs/app-server (fetched 2026-08-25) — *"the interface
Codex uses to power rich clients (for example, the Codex VS Code
extension)"*, *"open source in the Codex GitHub repository
(openai/codex/codex-rs/app-server)"*.

## Transport

- `codex app-server` (`codex-rs/cli/src/main.rs:159,546-594`). Default
  `--listen stdio://`: newline-delimited JSON-RPC 2.0 with the `jsonrpc`
  field omitted on the wire; also `ws://` (experimental) and `unix://`
  (`codex-rs/app-server/README.md:24-30`). Backpressure error `-32001`
  "Server overloaded; retry later." (`README.md:55-57`).
- Schema: `codex-rs/app-server-protocol/schema/json/codex_app_server_protocol.v2.schemas.json`
  and `schema/typescript/v2/*.ts`; Rust source of truth
  `codex-rs/app-server-protocol/src/protocol/common.rs` and `protocol/v2/*.rs`.
  Regenerate with `codex app-server generate-ts | generate-json-schema`
  (`README.md:60`).

## Account methods (v2)

`codex-rs/app-server/README.md:2287-2330`; types in
`codex-rs/app-server-protocol/src/protocol/v2/account.rs`:

| method | purpose |
|---|---|
| `account/login/start` | `LoginAccountParams` variants `apiKey`, `chatgpt` (browser), `chatgptDeviceCode`, `chatgptAuthTokens` (OpenAI-internal), Bedrock variants (`account.rs:64-120`). Device code returns `{loginId, verificationUrl, userCode}` (`README.md:2477-2478`) |
| `account/login/cancel` | abort a pending login |
| `account/login/completed` | notification |
| `account/logout` | clears every store |
| `account/read`, `account/updated` | who is signed in; `planType` flows here |
| `account/rateLimits/read`, `account/rateLimits/updated` | `RateLimitSnapshot { limit_id, limit_name, primary, secondary, credits, individual_limit, spend_control_reached }` (`account.rs:560-567`); requires a ChatGPT-backed auth, otherwise `invalid_request` "chatgpt authentication required to read rate limits" (`codex-rs/app-server/src/request_processors/account_processor.rs`, `get_account_rate_limits_response`) |
| `account/usage/read` | usage |

The v1 names `loginChatGpt` etc. are gone; the only legacy auth method
kept is `getAuthStatus` (`common.rs:1378`, listed at
`codex-rs/app-server-protocol/src/export.rs:66`).

## Models and turns

- `model/list` with `ModelListParams { cursor, limit, include_hidden }`
  (`protocol/v2/model.rs:53-63`).
- `ThreadStartParams` (`protocol/v2/thread.rs:62-152`): `approval_policy`,
  `sandbox` (`SandboxMode`: `read-only` default | `workspace-write` |
  `danger-full-access`, `codex-rs/protocol/src/config_types.rs:104-114`),
  `permissions` (named profile), `config` (arbitrary `config.toml`
  overrides), `cwd`, `environments` (`[]` disables environment access),
  `dynamic_tools`, `ephemeral`, `base_instructions`, `developer_instructions`.
- `TurnStartParams` (`protocol/v2/turn.rs:71-141`): per-turn
  `approval_policy`, `sandbox_policy`, `model`, `effort`, `service_tier`.
- `AskForApproval`: `untrusted | on-request | granular | never`
  (`codex-rs/protocol/src/protocol.rs:924-954`).
- There is no per-thread "disable MCP/tools" boolean. The levers are
  `config` overrides (`tools.web_search`, `mcp_servers`), `dynamic_tools`,
  and admin `requirements.toml` allow-lists (`README.md:295`, `:1356-1361`).

## What a client must not assume

- The server reads `CODEX_HOME` from its environment — that is the whole
  identity of "which login" (see `codex.md` §2, §3).
- Login state is per `CODEX_HOME`, one account, no switch RPC.
- `account/rateLimits/read` is a snapshot; refetch after a reset credit is
  consumed (README, `account/rateLimits/read`).
