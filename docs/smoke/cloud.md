# Cloud smoke — run by a person, never by an agent

sai's cloud routes (Claude subscription #25, ChatGPT subscription and
API keys #26) are exercised against real accounts once per route, by
Jan, after the route lands. A coding agent never runs this: it has no
key, gets none, and its own smokes are keyless (the `fake` provider,
`tool/smoke/lan.py`). The rules are in `AGENTS.md`; the reasoning is
ADR 0008, 0013 and `spikes/provider_auth_spike/testing.md`.

Every run happens in a scratch env
(`SAI_ARCHIVE_ROOT=<dir>/archive SAI_SETTINGS_FILE=<dir>/settings.json`)
and puts **evidence, not claims**, in the PR that lands the route: the
archive lines, the provider's own usage page, and a screenshot per step.

## Keys are capped and short-lived

A key used for a smoke is minted for the smoke and deleted after it:

- **OpenRouter**: create the key with `limit` ≤ $1, `limit_reset: null`
  and `expires_at` set to tomorrow; check `GET /api/v1/key`
  (`limit_remaining`) before and after.
- **OpenAI**: a dedicated project with a hard monthly limit ≤ $1; a
  project key (`sk-proj-`), never an admin key.

The smoke runs the **stable** flavor — a signed bundle from
`tool/release.sh sign`, launched with scratch `SAI_ARCHIVE_ROOT` and
`SAI_SETTINGS_FILE` overrides so the real data stays out of it; the dev
flavor holds no credentials at all (#95). The key enters sai through
`sai_tui secret set` (hidden prompt) or the app's masked field — never on a command line, in a file, in the shell
that launches an agent, or in a chat with one. When the smoke is done,
delete the key at the provider and remove the entry from the Keychain.

An alternative the spike considered — a wrapper the agent can invoke
that injects a capped key it cannot read — is **not built**: it would
still put a live key in an agent-reachable process on a machine without
the App Sandbox (ADR 0001).

## Claude subscription (route C)

Preconditions: `claude` signed in with the plan (`claude auth status`),
no `ANTHROPIC_API_KEY` in the launching shell.

1. Select the provider, send one prompt, watch the stream.
2. Evidence: the archive's `provider.request` / `provider.response`
   lines (model lineage from `system/init`, `apiKeySource: none`),
   `claude`'s `/usage` before and after showing the plan pool moved,
   and the Console usage page showing **no** API spend for the window.
3. Set `ANTHROPIC_API_KEY=not-a-real-key` in the shell, relaunch, send:
   expect a `credential` failure, no request, no spend.

## ChatGPT subscription (route G)

Preconditions: sai's own `CODEX_HOME`
(`~/Library/Application Support/sai/codex/`) empty.

1. "Sign in" in sai → device code or browser → `account/read` shows
   ChatGPT and the plan; `model/list` populates; send one prompt.
2. Evidence: archive lines, `account/rateLimits/read` before and after,
   the Platform usage page showing no API spend,
   `ls -la "$CODEX_HOME"` showing no `auth.json` (keyring backend) — or,
   if the platform fell back to a file, that fact recorded and the
   setting fixed.
3. Set `OPENAI_API_KEY` in the shell, relaunch: the child must not see
   it and the turn is still ChatGPT-authenticated.

## API keys (route K)

1. Mint a capped key as above; enter it through the hidden prompt or
   the masked field.
2. Send one prompt. Evidence: archive lines, the provider dashboard
   showing the spend, `limit_remaining` (OpenRouter) or the project
   usage (OpenAI).
3. Delete the key.

### OpenRouter, the pinned preset (#24, ADR 0022)

The stable app against scratch roots; the `openrouter` built-in is
there on every install, inactive, on its recommended preset.

1. At openrouter.ai create an ordinary **inference** key (never a
   management or provisioning key) with `limit` ≤ $1, `limit_reset:
   null`, `expires_at` tomorrow. Note `limit_remaining` from
   `GET /api/v1/key`.
2. Settings › Providers › openrouter: type the key into the masked
   field, Save. The row reads `deepseek/deepseek-v4-flash-0731 — cloud
   · pinned to DeepInfra fp8 · key set`; the health line, after
   Refresh, `ok · openrouter · no models listed · context unavailable`.
   `settings.json` now holds the entry with `"routing":"deepinfra_fp8"`
   and no key.
2a. The zero-retention list (#112). Saving the key read it: the line
   under "Exact model" reads `N models with zero retention` (the
   dashboard's activity shows no generation for it — a list costs no
   tokens). Type a letter into the model field, then delete it: the
   whole list, exact ids only, no `openrouter/*`; type a few letters,
   take one with ↓ and Enter, then Enter again (or Apply). The row reads `<id> — cloud · exact
   model · key set`; Test answers — a listed model has an endpoint that
   meets the filters. Wi-Fi off, Refresh: `Could not refresh (…);
   showing N models cached`, the suggestions still there; Wi-Fi on,
   Refresh: the count again. Tap the recommended preset before going
   on.
3. Test, then Use and send one short chat. Both stream; the archive
   holds, per call, `policy.decision` (tasks withheld — sharing is off
   by default), `provider.request`, `provider.response`,
   `provider.usage` with a `cost`.
4. On OpenRouter's activity page the two generations name the exact
   model and **DeepInfra** as the provider — success under `only` plus
   `quantizations: [fp8]` is the proof the pinned route was there. Note
   `limit_remaining` again; the difference is the two calls' cost, and
   Settings › Usage shows the same number.
5. Confirm "Allow cloud providers to see my tasks" is off and the
   requests carried no task list; confirm no key in `settings.json`,
   the archive, the screenshots or any error text (grep the scratch
   dir for the key's first characters), and nothing of the list's
   body either (grep for `provider_name` and `endpoints/zdr`).
6. Remove in sai (the Keychain item goes; the entry stays), then
   revoke the key at openrouter.ai.

The PR records counts, the routing line and the redacted dashboard
row only. A person runs this; an agent never receives, enters or sees
the key.

## Cross-mode check

With a subscription entry and a key entry both configured, exhaust or
disable one and confirm sai reports the failure for *that* entry and
does not send through the other.
