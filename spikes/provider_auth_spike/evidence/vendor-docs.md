# Vendor documentation — primary sources, as read on 2026-08-25

Every quote below was fetched on 2026-08-25 (UTC afternoon). Pages
change; the date is part of the citation. Where a page 403'd to
automated fetch it is marked so and not quoted.

## Anthropic

### code.claude.com/docs/en/legal-and-compliance — "Authentication and credential use"

Confirmed by two fetches (rendered HTML and the `.md` variant, Cloudflare
`age: 280`):

> **OAuth authentication** is intended exclusively for purchasers of
> Claude Free, Pro, Max, Team, and Enterprise subscription plans and is
> designed to support ordinary use of Claude Code and other native
> Anthropic applications.

> **Developers** building products or services that interact with
> Claude's capabilities, including those using the Agent SDK, should use
> API key authentication through Claude Console or a supported cloud
> provider. Anthropic does not permit third-party developers to offer
> Claude.ai login into their own applications, or to route requests
> through Free, Pro, or Max plan credentials on behalf of their users.
> Moreover, developers may not collect, store, or intermediate Claude.ai
> credentials or session tokens — sign-in to a Claude account must
> complete through Anthropic's own flow.

> This does not restrict how customers provision and manage their own
> API keys … Nor does it prevent an end user from signing in to the
> unmodified Claude Code binary with their own Claude subscription,
> including where a platform hosts Claude Code …

> Advertised usage limits for Pro and Max plans assume ordinary,
> individual usage of Claude Code and the Agent SDK.

Reading for sai: the developer and the end user are the same person,
the binary is unmodified, sai never touches a credential. That is the
"end user signing in to the unmodified Claude Code binary with their own
Claude subscription" sentence, not the "third-party developers … on
behalf of their users" one.

### code.claude.com/docs/en/agent-sdk/overview

> Unless previously approved, Anthropic does not allow third party
> developers to offer claude.ai login or rate limits for their products,
> including agents built on the Claude Agent SDK.

Also: "To drive the same agent loop from another language, run the CLI
as a subprocess with the `-p` flag and `--output-format json`."

### support.claude.com/en/articles/15036540 — "Use the Claude Agent SDK with your Claude plan"

> Update (June 15, 2026): We're pausing the changes to Claude Agent SDK
> usage described below. For now, nothing has changed: Claude Agent SDK,
> `claude -p`, and third-party app usage still draw from your
> subscription's usage limits.

> We're working to update the plan to better support how users build
> with Claude subscriptions. When we have an update, we'll share it
> before anything takes effect.

The paused plan (announced 2026-05-13/14, see `incidents.md`): a
separate monthly "Agent SDK credit" — Pro $20, Max 5x $100, Max 20x $200
— billed at API rates, for Agent SDK, `claude -p`, GitHub Actions and
third-party apps; the ordinary subscription limits reserved for
interactive Claude Code, Cowork and claude.ai.

### support.claude.com/en/articles/11145838 — "Use Claude Code with your Pro or Max plan"

> If you have an ANTHROPIC_API_KEY environment variable set on your
> system, Claude Code will use this API key for authentication instead of
> your Claude subscription … resulting in API usage charges.

Claude and Claude Code share one usage pool on Pro/Max; past the limit,
usage credits bill at standard API rates.

### support.claude.com/en/articles/11049741 — "What is the Max plan?"

Max 5x $100 / Max 20x $200 per month, "5x or 20x more usage than the
Pro plan"; includes Claude Code and Cowork; session and weekly resets;
Anthropic "may limit your usage in other ways, such as weekly and
monthly caps". Nothing about the Agent SDK, automation or third parties.

### support.claude.com/en/articles/12429409 — usage credits

> Usage credits allow individuals subscribed to paid Claude plans (Pro,
> Max 5x, and Max 20x) to continue using Claude seamlessly after reaching
> their included usage limits.

Billed at standard API rates; monthly spend cap; "apply to both Claude
conversations and Claude Code terminal usage".

### support.claude.com/en/articles/14552983 — "Models, usage, and limits in Claude Code" (updated 2026-04-15)

How you signed in decides metering: a subscription draws from the plan's
pool; an API key is "Pay-as-you-go, billed per token to that cloud or
Console account", no hard cap, `/cost` shows session spend.

### code.claude.com/docs/en/authentication

Storage: macOS "encrypted macOS Keychain"; Linux
`~/.claude/.credentials.json` mode `0600`; `CLAUDE_CONFIG_DIR` moves the
file on Linux/Windows. Precedence 1–7 reproduced in
`claude-agent-sdk.md` §4. Key sentences:

> In non-interactive mode (`-p`), the key is always used when present.

> If you have an active Claude subscription but also have
> `ANTHROPIC_API_KEY` set in your environment, the API key takes
> precedence once approved.

> Bare mode does not read `CLAUDE_CODE_OAUTH_TOKEN`. If your script
> passes `--bare`, authenticate with `ANTHROPIC_API_KEY` or an
> `apiKeyHelper` instead.

`claude setup-token`: one-year token, "It does not save the token
anywhere", "can only make model requests".

### code.claude.com/docs/en/headless — "Run Claude Code programmatically"

> In bare mode, Claude Code never reads OAuth credentials or the system
> keychain. For the Anthropic API, set `ANTHROPIC_API_KEY` …

> `--bare` is the recommended mode for scripted and SDK calls, and will
> become the default for `-p` in a future release.

> Without `--bare`, a `-p` session runs the hooks in a project's
> `.claude/settings.json` and connects the servers in its `.mcp.json`,
> even in a folder you've never trusted.

Streaming: `--output-format stream-json --verbose
--include-partial-messages`; the last line is a `result` message; the
first is `system/init` (model, tools, MCP servers, `capabilities`);
`system/api_retry` carries `error` categories including
`authentication_failed`, `oauth_org_not_allowed`, `billing_error`,
`rate_limit`. `--json-schema` for structured output. `/login` is not
available in `-p` mode.

### code.claude.com/docs/en/cli-reference (relevant flags)

`--bare` (sets `CLAUDE_CODE_SIMPLE`), `--print/-p`, `--output-format
text|json|stream-json`, `--include-partial-messages`, `--setting-sources
user,project,local`, `--strict-mcp-config`, `--tools ""|default|names`,
`--allowedTools`, `--disallowedTools` (`"*"` removes every tool),
`--no-session-persistence` ("Disable session persistence so sessions are
not saved to disk and cannot be resumed. Print mode only."),
`--system-prompt`, `--append-system-prompt`, `--model`, `--max-turns`,
`--permission-mode`.

### code.claude.com/docs/en/feature-availability

"CLI and Agent SDK" work on every provider; the plan-only features are
web/mobile/Slack, Desktop, Routines, Remote Control, computer use,
artifacts. Nothing there restricts `-p` on a subscription.

### anthropic.com/legal/consumer-terms (effective 2025-10-08), §3

Prohibited: "Except when you are accessing our Services via an Anthropic
API Key or where we otherwise explicitly permit it, to access the
Services through automated or non-human means, whether through a bot,
script, or otherwise." The legal-and-compliance page above is the
"explicitly permit" for Claude Code and the Agent SDK on a plan.

### anthropic.com/legal/aup

No clause on automated access, personal tooling or credential use;
content-based prohibitions only.

## OpenAI

### learn.chatgpt.com/docs/auth (moved from developers.openai.com/codex/auth)

Two methods: "Sign in with ChatGPT for subscription access" and "Sign in
with an API key for usage-based access". Storage switch
`cli_auth_credentials_store = file | keyring | auto` ("Auto: prefers OS
storage, falls back to `auth.json`").

> Treat `~/.codex/auth.json` like a password: it contains access tokens.
> Don't commit it, paste it into tickets, or share it in chat.

> Codex refreshes tokens automatically during use before they expire, so
> active sessions usually continue without requiring another browser
> login.

Device-code auth (beta) for headless; enterprise `forced_login_method`,
`forced_chatgpt_workspace_id`. **No third-party restriction on the page.**

### learn.chatgpt.com/docs/app-server

> the interface Codex uses to power rich clients (for example, the Codex
> VS Code extension)

> The app-server implementation is open source in the Codex GitHub
> repository (openai/codex/codex-rs/app-server).

Start `codex app-server` (stdio default; `--listen ws://…` experimental
with `--ws-auth capability-token …`; `unix://`). `model/list`;
`sandboxPolicy` `dangerFullAccess | readOnly | workspaceWrite |
externalSandbox`; `approvalPolicy` `never | onRequest | unlessTrusted`.
"No subscription or account requirements are explicitly mentioned for
using app-server itself."

### help.openai.com/en/articles/11369540 — "Using Codex with your ChatGPT plan"

403 to automated fetch; not quoted. Search snippets: ChatGPT sign-in is
governed by the plan's limits; API-key sign-in bills at Platform rates
and "included ChatGPT plan credits do not apply".

### openai.com/policies/terms-of-use

403 to automated fetch; not quoted. The maintainers' reply in
openai/codex#8338 points at it for forks; the direct OAuth question was
never answered there (see `incidents.md`).

### developers.openai.com/api/reference/overview

`Authorization: Bearer OPENAI_API_KEY_OR_ACCESS_TOKEN`; "Remember that
your API key is a secret. Don't share it with others or expose it in any
client-side code"; `OpenAI-Organization` / `OpenAI-Project` headers;
Admin API keys for administration; "Revocations of an API key take
effect within a few seconds."

### Statement by OpenAI staff (secondary, dated)

Romain Huet, 2026-03-30, quoted by simonwillison.net (2026-04-23): "We
want people to be able to use Codex, and their ChatGPT subscription,
wherever they like! That means in the app, in the terminal, but also in
JetBrains, Xcode, OpenCode, Pi, and now Claude Code. That's why Codex CLI
and Codex app server are open source too!"

## OpenRouter (docs fetched 2026-08-25; Context7 `/websites/openrouter_ai`)

- Authentication: Bearer tokens; "You must protect your API keys and
  never commit them to public repositories"; "OpenRouter is a GitHub
  secret scanning partner" — exposed keys trigger an email
  (`openrouter.ai/docs/api-reference/authentication`).
- Per-key controls (`/docs/features/provisioning-api-keys`,
  `/docs/api-reference/api-keys/create-api-key`): `limit` (USD),
  `limit_reset` `daily|weekly|monthly` ("Resets happen automatically at
  midnight UTC"), `expires_at` (ISO 8601 UTC), `disabled`,
  `include_byok_in_limit`; response carries `limit_remaining`. "The
  plaintext `key` is returned only in this response … it cannot be
  retrieved later." Management keys "cannot be used to make API calls to
  OpenRouter's completion endpoints".
- Limits (`/docs/api-reference/limits`): per-key cap or empty balance →
  `402`; request caps → `429` with `Retry-After`; `GET /api/v1/key`
  returns `limit_remaining`, `usage`, `is_free_tier`; a mid-stream 429
  arrives as an SSE event with `finish_reason: "error"`.
- OAuth PKCE (`/docs/use-cases/oauth-pkce`): the exchange at
  `POST /api/v1/auth/keys` returns "a user-controlled API key"; codes
  expire after 10 minutes; headless mode shows the code on screen and
  requires a `code_challenge`. Relevant to sai only as a way to *obtain*
  a key; the key then lives in `SecretStore` like any other.
- Key prefix `sk-or-v1-` (from the create-key example).
