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

Every provider here is `cloud`-tagged, so the preference order passes it
over until **Allow cloud providers to see my tasks** is on (#62, ADR
0024): turn the switch on before any step that sends a chat, and while
it is off expect the row to read `· cloud not allowed` and a send to be
refused with `no provider can answer — <id> cloud not allowed`, writing
nothing. Test is not a send — it names the provider itself and streams
either way.

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

The stable app and `sai_tui`, built by `tool/release.sh prepare stable`
and signed, so the bundled App Server (#26, ADR 0023) is the one that
runs. Preconditions: the credential home empty — for the smoke, point
`SAI_CODEX_HOME=<dir>/codex` beside the scratch archive and settings so
your daily login is untouched (never `~/.codex`, which the override
refuses); `provider add chatgpt --kind chatgpt_subscription` in the
scratch settings.

1. **Sign in, both ways.** Settings › Providers › chatgpt: *Sign in with
   ChatGPT* opens the browser; finish there and the block reads *Signed
   in as … · <plan> plan*. Sign out. *Use device code*: the URL and the
   one-time code show; open the URL, type the code; signed in again.
   Start a device-code sign-in and *Cancel*: the block says it was
   cancelled and nothing else changed. Evidence: a shot of each state,
   with the email redacted. sai printed and stored no token.
2. **Models and efforts.** The Model menu lists what `model/list`
   returned by display name; switch among Sol, Terra and Luna where the
   plan offers them and confirm `settings.json` holds the exact id each
   time. The Reasoning effort menu reads *Model default (<advertised>)*
   first and then that model's advertised words; choose one the model
   takes, then switch to a model that does not take it and confirm it
   shows as *unavailable* and Test refuses in the fixed words with both
   choices left as they were. `sai_tui provider models chatgpt` prints
   the same list.
3. **Wire selection.** With Model default, Test and one chat; then with
   an explicit `high` and `xhigh`. The archive's `provider.request`
   lines carry no `reasoning_effort` for the first and the exact word
   for the others; the answers stream; a reasoning summary shows only
   when the model sent one.
4. **Cancel.** Send a long prompt and press Esc: the turn stops, the
   partial text stands, `provider.response` says `cancelled`, and no
   second answer arrives.
5. **Plan state.** The block's *Plan usage* line and `sai_tui provider
   account chatgpt` show a percentage and a reset, never money, and move
   after the calls.
6. **One owner.** With the app signed in and idle, run `sai_tui provider
   account chatgpt` from the scratch env: it must answer *ChatGPT is in
   use by another sai client* and spawn nothing while the app holds the
   home; quit the app and it answers.
7. **Sign out, sign in again.** Sign out in Settings: the account line,
   the model list and the plan line clear; sign in again and they return.
8. **The environment.** Set `OPENAI_API_KEY=not-a-real-key` in the
   launching shell, relaunch, send: the turn is still
   ChatGPT-authenticated (`ps -E` on the child shows no `OPENAI_*` but
   `CODEX_HOME`, and no `HTTP_PROXY`).
9. **Safety canaries.** Put a sentinel task in the scratch archive and a
   sentinel file in your home. After the calls, `grep -r <sentinel>
   "$SAI_CODEX_HOME"` finds nothing (ephemeral threads, no history), and
   `ls -la "$SAI_CODEX_HOME"` shows `config.toml` and `lock`, no
   `auth.json`. Ask the assistant to run a shell command and to read the
   sentinel file: each answer is the fixed safety failure, the sentinel is
   never quoted, and nothing changed on disk.
10. Evidence: the archive lines, the Platform usage page showing **no**
    API spend for the window, the shots, the canary results. Counts and
    fixed text only — never the email, the device code, a token or the
    task text.

## API keys (route K)

1. Mint a capped key as above; enter it through the hidden prompt or
   the masked field.
2. Send one prompt. Evidence: archive lines, the provider dashboard
   showing the spend, `limit_remaining` (OpenRouter) or the project
   usage (OpenAI).
3. Delete the key.

### OpenAI, the Responses API (#26, ADR 0023)

The stable app against scratch roots; `provider add openai --kind openai
--model <exact id>` in the scratch settings.

1. At platform.openai.com create a **project** with a hard monthly limit
   ≤ $1 and a project key (`sk-proj-`), never an admin key. Settings ›
   Providers › openai: the row reads `<id> — cloud · OpenAI API, billed
   separately · no key`; the block says the billing. Type the key into
   the masked field, Save. The line under the model field reads `N
   models this key can reach — guidance only …`; type a few letters and
   pick one, or type an exact id; Apply.
2. Reasoning effort: with Model default, Test; the request line carries
   no `reasoning_effort`, the body `"store":false`, `"tools":[]`,
   `"tool_choice":"none"`. Choose one explicit effort the model takes
   (`high`); Test streams and the line carries `"reasoning_effort":"high"`.
3. Choose a deliberately incompatible pair (a non-reasoning model with
   `xhigh`, say) and Test: one bounded failure in the fixed words, one
   request on the project's usage page, the model and the effort
   unchanged in Settings and in `settings.json`.
4. One streamed chat, then Esc mid-answer: the partial text stands,
   `provider.response` says `cancelled`.
5. Remove the key in sai (the entry stays, the Keychain item goes), type
   it again, Test once more. Then delete the key at platform.openai.com.
6. Evidence: archive lines, the project usage page, `grep` of the scratch
   dir for the key's first characters finding nothing, the shots.

### Cross-mode (#26)

With `chatgpt` and `openai` both configured: sign out of ChatGPT and
send with `chatgpt` selected — the failure names the sign-in, and the
project usage page shows no request; remove the OpenAI key and send with
`openai` selected — the failure names the key, and no App Server is
spawned (`pgrep codex-app-server` finds none). Switching billing is
choosing the other row; nothing ever falls through.

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
   tokens). Type a few letters into the model field: exact ids only,
   no `openrouter/*`, the highlight following ↓ down a list taller than
   its box; take one with Enter, then Enter again (or Apply). Escape
   closes the list and keeps the field — Enter then applies what was
   typed, even an id a listed one begins with. The row reads `<id> — cloud · exact
   model · key set`; Test answers — a listed model has an endpoint that
   meets the filters. Wi-Fi off, Refresh: `Could not refresh (…);
   showing N models cached`, the suggestions still there; Wi-Fi on,
   Refresh: the count again. Tap the recommended preset before going
   on.
3. Test, then Use. Test names the provider itself, so it streams while
   the sharing switch is still off; the send does not — a cloud provider
   is passed over entirely until the switch is on (#62, ADR 0024), the
   row reads `· cloud not allowed` and the send is refused with `no
   provider can answer — <id> cloud not allowed`, writing nothing. Turn
   "Allow cloud providers to see my tasks" on and send one short chat.
   Both stream; the archive holds, per call, `policy.decision`
   (`task_context: none` for Test, `sent` for the chat),
   `provider.request`, `provider.response`, `provider.usage` with a
   `cost`.
4. On OpenRouter's activity page the two generations name the exact
   model and **DeepInfra** as the provider — success under `only` plus
   `quantizations: [fp8]` is the proof the pinned route was there. Note
   `limit_remaining` again; the difference is the two calls' cost, and
   Settings › Usage shows the same number.
5. Turn the switch back off and send again: refused, and nothing
   written. Confirm the chat's request carried the compact lists only —
   Today and Upcoming, never the catalog; confirm no key in
   `settings.json`,
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
