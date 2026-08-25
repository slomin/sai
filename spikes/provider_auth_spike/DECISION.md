# Decision: subscription authentication and credential ownership

Issue: [#28](https://github.com/slomin/sai/issues/28) · 2026-08-25 ·
evidence pinned in `evidence/` (Codex `ba6cf9c69277`, OpenCode
`ac1c048e6420`, OpenClaw `1d526c5c0ef6`, Hermes `02c7ae956e42`, Agent
SDK `15af77c68ad7`; docs fetched 2026-08-25) · ADR
[0013](../../docs/decisions/0013-subscription-logins-belong-to-the-vendor-runtime.md)

sai is one person's app on one Mac, with one Claude Max plan and one
ChatGPT plan. Every decision below is for that shape.

## Recommendation, per route

### Claude subscription — build it as #25 describes: verified

sai spawns the **unmodified `claude` binary** in `-p` stream-json mode;
Claude Code owns `/login`, refresh and the Keychain item; sai stores,
reads and forwards no token. The docs permit exactly this — "an end
user … signing in to the unmodified Claude Code binary with their own
Claude subscription" — and say the usage draws from the plan ("Claude
Agent SDK, `claude -p`, and third-party app usage still draw from your
subscription's usage limits", 2026-06-15). The enforcement of 2026
landed on clients that ran their own OAuth with Claude Code's client id
and held the tokens (`evidence/incidents.md` §A); sai does neither.

Binding details, all from the vendor's pages (`evidence/vendor-docs.md`):

- **Never `--bare`.** Bare mode "never reads OAuth credentials or the
  system keychain". Isolation comes from `--setting-sources=`,
  `--strict-mcp-config`, `--tools ""` (`--disallowedTools "*"` as belt
  and braces), `--no-session-persistence`, `--max-turns 1`,
  `--permission-mode dontAsk`, and sai's own system prompt via
  `--system-prompt`.
- **Scrub the child.** In `-p` "the key is always used when present":
  remove `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`,
  `CLAUDE_CODE_OAUTH_TOKEN`, `ANTHROPIC_PROFILE`,
  `ANTHROPIC_FEDERATION_RULE_ID`, `ANTHROPIC_ORGANIZATION_ID`,
  `CLAUDE_CODE_USE_BEDROCK|VERTEX|FOUNDRY|ANTHROPIC_AWS`,
  `ANTHROPIC_BASE_URL`, `CLAUDE_CODE_SIMPLE`, `CLAUDE_CONFIG_DIR`,
  `CLAUDECODE` from the environment sai passes. Do not redirect
  `CLAUDE_CONFIG_DIR`: that changes the Keychain service name and loses
  the login (the Agent SDK carries a workaround for precisely this).
- **Fail closed before the prompt.** Read `system/init`; unless
  `apiKeySource` is `none` (subscription login) the call ends with
  `LlmFailureKind.credential` and nothing is sent. A missing or
  incompatible binary (`claude --version` < 2.1.x pinned at
  implementation) and a signed-out state (`claude auth status --json`
  `loggedIn: false`, the same probe OpenClaw uses) are `credential` too.
- **Re-check trigger.** Two dated facts can move: the paused Agent SDK
  credit (support 15036540 — Anthropic promised to announce before it
  takes effect) and the headless page's "`--bare` … will become the
  default for `-p` in a future release". When either lands, re-read the
  two pages and confirm `-p` still reaches the `/login` credential
  without `--bare`; if a flag is needed to opt out of bare, add it.

### ChatGPT subscription — Codex App Server owns the login: verified

sai spawns `codex app-server` over stdio and speaks JSON-RPC v2:
`account/login/start` (`chatgpt` browser or `chatgptDeviceCode`),
`account/read` (must report ChatGPT auth before any turn),
`account/rateLimits/read` (plan state, surfaced as availability, not
quota), `model/list` (the only model catalogue), `thread/start` with
`sandbox: read-only`, `approval_policy: never`, `environments: []`, no
`dynamic_tools`, `ephemeral: true`, sai's prompt as `base_instructions`;
`turn/start` per request. OpenAI's public position is that this is
wanted ("wherever they like … OpenCode, Pi"); no ToS text or ban says
otherwise, and the app-server page is written for third-party clients.
The `ExternalAuth`/`chatgptAuthTokens` bridge is marked OpenAI-internal
and is not used.

**`CODEX_HOME` is sai's own**, `~/Library/Application Support/sai/codex/`,
with a sai-written `config.toml` setting
`cli_auth_credentials_store = "keyring"`. Reasons: the user's `~/.codex`
is refreshed by the Codex CLI with no cross-process lock (codex#10332,
closed not-planned) — a shared home means one of the two gets logged
out; a separate home is a separate token family; `keyring` keeps
`auth.json` off disk (the `auto` mode falls back silently, so the
explicit value is required); and `account/logout` in sai then cannot
touch the user's Codex login. Cost: one sign-in inside sai.
Rejected: reusing `~/.codex` (zero setup, shared race, plaintext by the
user's setting, not sai's).

Scrub for the child: `OPENAI_API_KEY`, `CODEX_API_KEY`,
`CODEX_ACCESS_TOKEN`, `CODEX_APP_SERVER_LOGIN_CLIENT_ID`,
`CODEX_REFRESH_TOKEN_URL_OVERRIDE`, `CODEX_REVOKE_TOKEN_URL_OVERRIDE`,
`OPENAI_BASE_URL`; set `CODEX_HOME` and `RUST_LOG=warn`; nothing else
from the parent that starts with `OPENAI_` or `CODEX_`.

### API keys — OpenAI, OpenRouter, Anthropic: ADR 0008 stands

No flaw found that needs a new storage decision. The keys stay in the
file Keychain through `SecretStore`, named in settings, bound to an
origin (ADR 0009). OpenAI (`https://api.openai.com/v1`) and OpenRouter
(`https://openrouter.ai/api/v1`) are `openai_compatible` `cloud`
entries on fixed origins. **Claude by API key goes through OpenRouter**
for now: Anthropic's OpenAI-compatibility layer is documented as "not
considered a long-term or production-ready solution" and hides
thinking; a native Messages-API kind is a later ticket if OpenRouter's
Claude routing proves insufficient. The human smoke uses OpenRouter's
per-key `limit`/`expires_at` and OpenAI project limits (`testing.md`).

### No silent fall-through

Each route is its own provider entry with its own `kind`
(`claude_subscription`, `chatgpt_subscription`, `openai_compatible`).
A subscription entry has no `credential`; a key entry has no vendor
runtime. Failure on one entry is reported for that entry; sai never
retries a request through another. The privacy switch (ADR 0010)
applies to all three as `cloud`.

## Threat model verdict

`threat-model.md`. Without the App Sandbox nothing sai does stops a
same-user process; what the design changes is that there is **nothing
sai-owned to steal for the two subscription routes**, keys are
per-provider and capped, and the two money-losing failures seen in the
wild — the refresh race and the API-key precedence flip — are
structurally absent (no shared token; scrubbed child + positive auth
check).

## Deliverable checklist (from #28)

- [x] matrix, four clients + two contracts — `matrix.md`
- [x] every observation pinned — `evidence/*.md` (SHA or URL + date)
- [x] frozen under `spikes/provider_auth_spike/`, nothing imports it
- [x] separate recommendation for Claude subscription, ChatGPT
      subscription, OpenAI API key (+ OpenRouter, Anthropic key)
- [x] leading design verified: Claude Code owns the Claude login, Codex
      App Server owns the ChatGPT login, sai stores neither token
- [x] `SecretStore`/ADR 0008 unchanged
- [x] login, refresh ownership, logout, switching, env scrub, model
      discovery, plan-limit reporting, fail-closed — above and in
      `followups.md`
- [x] no silent fall-through — above
- [x] ADR 0013
- [x] follow-ups applied to #25, #26, #56 — `followups.md`
- [x] keyless test strategy + human smoke — `testing.md`
