# Incidents and public record — what actually went wrong for people

Collected by web search and fetch on 2026-08-25. **[fetched]** = the page
was read; **[listed]** = URL and title from search results only, not
opened — treat as weaker.

## A. The Claude subscription timeline for third-party clients

| date | event | source |
|---|---|---|
| 2025-11-20 | `This credential is only authorized for use with Claude Code and cannot be used for other API requests` appears inside Claude Code itself (false positive on model switch) | anthropics/claude-code#12021 **[fetched]** |
| 2026-01-05 | OpenCode user reports an account ban after OAuth login through OpenCode | anomalyco/opencode#6930 **[fetched]** |
| 2026-01-09 | Same rejection string hits OpenClaw's own OAuth store | openclaw/openclaw#559 **[fetched]** |
| 2026-02-19 | "Authentication and credential use" section added to legal-and-compliance | HN 47063384 **[fetched]**; agentclientprotocol/claude-agent-acp#337 **[fetched]** |
| 2026-02-20 | Anthropic engineer Thariq Shihipar: "Third-party harnesses using Claude subscriptions create problems for users and are prohibited by our Terms of Service" | The Register **[fetched]** |
| 2026-03-19 | OpenCode PR "anthropic legal requests" removes its Anthropic OAuth plugin, prompt file and `claude-code-20250219` header | anomalyco/opencode#18186 **[fetched]**; HN 47444748 (483 points) **[fetched]** |
| 2026-04-03/04 | Boris Cherny: "Starting tomorrow at 12pm PT, Claude subscriptions will no longer cover usage on third-party tools like OpenClaw" | threads.com/@boris_cherny **[fetched]**; TechCrunch, VentureBeat 2026-04-03/04 **[fetched]** |
| 2026-05-13/14 | Reinstated with a catch: a separate monthly Agent SDK credit (Pro $20 / Max 5x $100 / Max 20x $200) at API rates from 2026-06-15; Lydia Hallie: "you don't pay extra. It's the same subscription, same price per month" | VentureBeat **[fetched]**; zed.dev/blog **[fetched]** |
| 2026-06-15/16 | Change **paused**: "nothing has changed: Claude Agent SDK, `claude -p`, and third-party app usage still draw from your subscription's usage limits"; Zed: "continue to work with Claude subscriptions exactly as they did before" | support 15036540 **[fetched]**; zed.dev/blog **[fetched]** |

What the enforcement targeted: clients running their own OAuth flow
with Claude Code's client id and holding the tokens (OpenCode's removed
plugin, OpenClaw's `anthropic.ts`, Hermes). What every Anthropic page
keeps permitting: the end user signing in to the unmodified binary. sai
is the latter.

## B. Refresh races — the bug class every client hit

- openai/codex#10332 (2026-02-01, closed not-planned) **[fetched]**:
  several app-server instances refresh the same single-use token at the
  ~8-day mark; "Your access token could not be refreshed because your
  refresh token was already used. Please log out and sign in again."
- openclaw/openclaw#26322 (2026-02-25) **[fetched]**: 18 agents on one
  profile; losers fail over to pricier models. Fixed by the per-profile
  file lock now in `openclaw.md` §3.
- Related **[listed]**: openai/codex#14144, #13956, #17265, #28201 (MCP
  OAuth stale refresh tokens); openclaw#62247; decolua/9router#1663.
- Anthropic's own SDK strips `refreshToken` before handing a copied
  credential to a child for the same reason (`claude-agent-sdk.md` §5).

## C. Credential storage

- openai/codex#14704 (2026-03-14, open) **[fetched]**: keyring → plaintext
  fallback is silent; deletion of the stale file swallows errors;
  `mode(0o600)` only at create — "If the file already exists with wider
  permissions (e.g. `0o644`), the credentials get written to a
  world-readable file."
- openai/codex#5212 (2025-10-15, closed not-planned) **[fetched]**: request
  to use `OPENAI_API_KEY` directly instead of writing it into `auth.json`.
- Silverfort, 2026-07-28 **[fetched]**: the `Claude Code-credentials`
  Keychain item is created via `/usr/bin/security add-generic-password`
  with no access-control arguments, so `security find-generic-password
  -s "Claude Code-credentials" -w` works from any same-user process;
  Anthropic: same-user processes are trusted under its threat model,
  tightening tracked as hardening. This is the mechanism Hermes and the
  Agent SDK both use.
- anthropics/claude-code#81707 (2026-07-27) **[fetched]**: the opposite
  failure — a partition list that excludes Claude Code's own team id
  causes endless Keychain prompts. ADR 0008's "update in place, never
  delete-and-recreate" is the sai-side lesson.

## D. Surprise API billing from precedence

- anthropics/claude-code#58083 (2026-05-11) **[fetched]**: `.env`
  auto-loaded by direnv put `ANTHROPIC_API_KEY` in the shell; ~$52 to the
  API instead of Max, including ~1,400 unmocked calls from a test run.
- anthropics/claude-code#39903 (2026-03-27) **[fetched]**: subagents
  inherited the env key; $152.04 on a $200 Max plan.
- anthropics/claude-code#86723 (open) **[fetched]**: scheduled Routines
  billed to API credits, $1,122.83 over two months, plan headroom unused.
- openai/codex#2000 (2025-08-08) **[fetched]**: "Sign in with ChatGPT"
  on Windows auto-generated a billable API key into `auth.json`.
- openai/openai-python#2951 (2026-03-10, open, unanswered) **[fetched]**:
  ChatGPT Plus OAuth succeeds but third-party Codex calls 429.

## E. OpenAI's stance on third-party subscription clients

- openai/codex discussions#8338 (2025-12-19) **[fetched]**: maintainer
  `etraut-openai` — forking Codex CLI is "welcome"; the direct question
  whether "Sign in with ChatGPT" is approved for a fork received no
  answer through July 2026.
- Romain Huet 2026-03-30 (see `vendor-docs.md`): "wherever they like …
  OpenCode, Pi, and now Claude Code".
- Community plugins that reuse the Codex OAuth flow self-limit to
  "personal development use with your own ChatGPT Plus/Pro subscription"
  (numman-ali/opencode-openai-codex-auth **[fetched]**).
- No ban or block report for ChatGPT-subscription use through third
  parties was found.

## F. OpenRouter

- No named incident of an OpenRouter-side leak. GitHub secret-scanning
  partnership (docs); scanners for exposed `sk-or-v1` keys exist
  (Thereallo1026/OpenRouter-API-Scanner **[listed]**); GitGuardian
  2026-04-14: 1.2M AI-service secrets leaked on GitHub in 2025 **[listed]**.
