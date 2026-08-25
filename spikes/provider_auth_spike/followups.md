# Follow-ups applied to #25, #26, #56

Applied to the issue bodies at delivery (Jan's call: bodies, not
comments), each with a comment linking the spike PR. Old → new.

## #25 Claude subscription provider

**Keep** the whole design. The spike verified it (`DECISION.md`).

**Replace** the paragraph "Anthropic currently states that Claude Agent
SDK, `claude -p`, and third-party app usage draw from Claude
subscription limits. Reconfirm that guidance when implementation
starts: <support 15036540>" with:

> Verified 2026-08-25 (#28): Anthropic's legal-and-compliance page
> permits "an end user … signing in to the unmodified Claude Code binary
> with their own Claude subscription", and support article 15036540
> (2026-06-15) says "Claude Agent SDK, `claude -p`, and third-party app
> usage still draw from your subscription's usage limits". Two dated
> facts to re-check when implementation starts: that article's paused
> Agent SDK credit, and the headless docs' "`--bare` … will become the
> default for `-p`". ADR 0013 records the boundary.

**Amend** Runtime boundary bullets:

- "Invoke Claude in non-interactive streaming mode" → add: `-p
  --output-format stream-json --verbose --include-partial-messages`,
  **never `--bare`** (bare mode does not read the `/login` credential).
- "Disable Claude session persistence" → `--no-session-persistence`.
- "Disable native tools, MCP, browser access, skills, hooks, project
  instructions…" → `--tools ""`, `--disallowedTools "*"`,
  `--strict-mcp-config`, `--setting-sources=`, `--max-turns 1`,
  `--permission-mode dontAsk`, `--system-prompt` with sai's prompt.
- "Scrub Anthropic API-key and provider-override environment variables"
  → the list: `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`,
  `CLAUDE_CODE_OAUTH_TOKEN`, `ANTHROPIC_PROFILE`,
  `ANTHROPIC_FEDERATION_RULE_ID`, `ANTHROPIC_ORGANIZATION_ID`,
  `CLAUDE_CODE_USE_BEDROCK`, `CLAUDE_CODE_USE_VERTEX`,
  `CLAUDE_CODE_USE_FOUNDRY`, `CLAUDE_CODE_USE_ANTHROPIC_AWS`,
  `ANTHROPIC_BASE_URL`, `CLAUDE_CODE_SIMPLE`, `CLAUDE_CONFIG_DIR`,
  `CLAUDECODE`. Never redirect `CLAUDE_CONFIG_DIR`.
- "verify the active Claude login is subscription-backed before sending
  a prompt" → concretely: `system/init.apiKeySource == "none"`; also
  `claude auth status --json` `loggedIn` before spawn; else
  `LlmFailureKind.credential`, nothing sent.
- Add: minimum `claude` version pinned at implementation (the SDK
  bundles 2.1.238; 2.1.245 installed).

**Amend** Done-when: "Tests use a fake process runner…" → add "the
runner records argv and environment; a test sets `ANTHROPIC_API_KEY` in
the parent and proves it is absent in the child". Human smoke per
`spikes/provider_auth_spike/testing.md`.

## #26 OpenAI provider: subscription and API key

**Replace** "OpenAI documents ChatGPT subscription access and API-key
usage as separate Codex sign-in modes…" links: `learn.chatgpt.com/docs/auth`
and `/docs/app-server` (the developers.openai.com URLs redirect there).

**Amend** Configuration and runtime boundary:

- "launches the official `codex app-server`, uses its existing ChatGPT
  login or its documented browser or device-code flow" → **sai owns
  `CODEX_HOME`** (`~/Library/Application Support/sai/codex/`) with a
  sai-written `config.toml` setting `cli_auth_credentials_store =
  "keyring"`; login through `account/login/start` (`chatgpt` or
  `chatgptDeviceCode`), `account/login/cancel`, `account/logout`. The
  user's own `~/.codex` is never used (refresh race, codex#10332).
- "verifies that App Server reports ChatGPT authentication before
  inference" → `account/read` before every thread; otherwise
  `credential`.
- Scrub list → `OPENAI_API_KEY`, `CODEX_API_KEY`, `CODEX_ACCESS_TOKEN`,
  `CODEX_APP_SERVER_LOGIN_CLIENT_ID`, `CODEX_REFRESH_TOKEN_URL_OVERRIDE`,
  `CODEX_REVOKE_TOKEN_URL_OVERRIDE`, `OPENAI_BASE_URL`, and anything
  else starting `OPENAI_`/`CODEX_`; set `CODEX_HOME`, `RUST_LOG=warn`.
- "Discover subscription models … through App Server `model/list`" →
  keep; add `account/rateLimits/read` (+ `account/rateLimits/updated`)
  as the plan-limit surface, shown as availability.
- "Run subscription turns in an isolated, restrictive, inference-only
  context" → `thread/start` with `sandbox: "read-only"`,
  `approval_policy: "never"`, `environments: []`, no `dynamic_tools`,
  `ephemeral: true`, sai's prompt as `base_instructions`; `turn/start`
  per request. Note: no per-thread "disable MCP" flag exists; pass
  `config` overrides that empty `mcp_servers` and disable
  `tools.web_search`.
- Remove any mention of `preferred_auth_method` / `loginChatGpt`: they
  do not exist in current Codex (`forced_login_method` and
  `account/login/start` do).
- Add a sibling **OpenRouter** `api_key` entry: `openai_compatible`,
  `https://openrouter.ai/api/v1`, `cloud`, key via `SecretStore`;
  Claude-by-key is served through it (ADR 0013).

**Amend** Done-when: human smoke per `testing.md`, with a capped key
(OpenRouter per-key `limit`/`expires_at`, OpenAI project limit).

## #56 Keep credentials out of coding agents' reach

**Amend** "Claude Code's sandbox is configured … to deny or mask the
provider-key variables (`sandbox.credentials`)" → the list:
`ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `CLAUDE_CODE_OAUTH_TOKEN`,
`OPENAI_API_KEY`, `CODEX_API_KEY`, `CODEX_ACCESS_TOKEN`,
`OPENROUTER_API_KEY`, `OPENCODE_AUTH_CONTENT`, `OPENAI_ADMIN_KEY`.

**Amend** secret-scanning patterns → add `sk-ant-oat` (Claude OAuth
access tokens), `sk-ant-api`, `sk-admin-` (OpenAI admin keys); keep
`sk-proj-`, `sk-svcacct-`, `sk-or-v1-`, bare `Authorization: Bearer`.

**Amend** the `AGENTS.md` rule → agents never read `~/.claude`,
`~/.codex`, `~/.hermes`, `~/.local/share/opencode`, nor the
`Claude Code-credentials` or `Codex Auth` Keychain items, nor run
`security find-generic-password`; never spawn `claude` or `codex
app-server` against a real home; all provider tests go through the
fake process runner.

**Add** a Done-when: "an agent-run test proves the fake runner is the
only spawn path under `test/` (no `Process.start` of `claude`/`codex`
outside the injected default)".
