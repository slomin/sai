# 23. OpenAI is two kinds: a Responses dialect on the one transport, and a bundled runtime

Date: 2026-09-01 · Status: accepted · Issue: #26 · Builds on: [0008](0008-secrets-live-in-the-file-keychain.md), [0009](0009-provider-transport-is-direct-and-bounded.md), [0010](0010-the-privacy-policy-is-a-switch-checked-in-the-recorder.md), [0013](0013-subscription-logins-belong-to-the-vendor-runtime.md), [0022](0022-openrouter-is-its-own-kind-with-pinned-routing.md) · Amends: [0009](0009-provider-transport-is-direct-and-bounded.md), [0013](0013-subscription-logins-belong-to-the-vendor-runtime.md) · Schema: [settings-v0](../settings/settings-v0.md), [event-log-v0](../archive/event-log-v0.md)

## Context

A ChatGPT plan and an OpenAI API key are different products with
different authentication, limits and billing (#26). ADR 0013 settled who
holds each credential — the vendor's own runtime for the plan, the
Keychain for the key — and that nothing falls from one to the other.
Building both showed what the transport of ADR 0009 could not say and
what the runtime boundary needed to be exact about:

- The Responses API is not chat completions: another path, another body
  (`input` items, `max_output_tokens`, `reasoning.effort`, `text.format`),
  another stream (`type`-tagged events, a terminal `response.completed`
  carrying the usage), other refusals. An `openai_compatible` entry could
  carry none of that, and an edit could move its endpoint.
- Reasoning is not a boolean. OpenAI's models advertise which efforts
  they take, per model; the App Server lists them; the Responses API
  reads a word. sai's `reasoning` switch was on/off for local models.
- The App Server is an agent runtime with shell, file, web and tool
  surfaces. sai wants one thing from it — a streamed answer to its
  governed messages — and must be unable to get anything else.
- Which App Server runs matters: its protocol, its config keys, its
  Keychain account (derived from the home path), its login flow.

Wire contracts were checked on 2026-09-01: the Responses API reference
(Context7 `/websites/developers_openai_api`) for the body, the effort
vocabulary and the stream events; the Codex `rust-v0.152.0` App Server
README and v2 JSON schema for every method, notification and item type
sai touches (copied verbatim under
`packages/sai_core/test/llm/codex_app_server/fixtures/`); the pinned
`config_toml.rs` for the config keys sai writes; GitHub's release asset
digests for the two macOS slices.

## Decision

**One transport, two dialects.** The socket rules of ADR 0009 — direct
connections, no redirects, no certificate bypass, plaintext only on this
machine or the LAN, a deadline on every stage, capped bodies, fixed
failure words naming only the origin, the key read at call time and
never held — move out of `OpenAiCompatibleProvider` into `BoundedHttp`
(`lib/src/llm/openai_compatible/transport.dart`). The chat-completions
provider and the new Responses provider both compose it; the 400
negotiation ladder, the probe and the fetch of the former stay where they
were. This amends ADR 0009's "one transport, in
`openai_compatible/`": the transport is one class, the dialects are two
directories.

**`openai` is its own kind on the Responses API.** Fixed origin
`https://api.openai.com`, always `cloud`, always keyed under
`provider:<id>` (ADR 0008; no `credential_origin`, the origin never
moves). `POST /v1/responses` with every sai message as one `input` item
in order (`system` as `developer`), `stream: true`, `store: false`,
`background: false`, `tools: []`, `tool_choice: "none"`, no conversation
or `previous_response_id`, no metadata; `maxTokens` as
`max_output_tokens`; a temperature only when the caller set one; a schema
as the strict `text.format`. The stream is read by event type; any output
item sai did not ask for fails the call closed. A refusal is one bounded
failure read from `error.param`/`error.code` alone — the model does not
take the effort, the model is not this key's, the schema was refused, no
credit — and nothing is re-sent. `store: false` is a request-storage
choice, not a retention promise: the clients point at OpenAI's data
controls and claim nothing about ZDR.

**`chatgpt_subscription` is its own kind on a bundled App Server.** The
runtime is one exact stable release (`tool/vendor/codex-app-server.pin`,
today `rust-v0.152.0`), its two official macOS slices fetched at release
preparation into the build cache, each verified against its pinned
SHA-256 before extraction, joined into one universal helper at
`Contents/Helpers/codex-app-server` and placed as the host slice at
`bundle/libexec/codex-app-server`, with upstream's Apache-2.0 LICENSE and
NOTICE shipped with each (under the app's `Contents/Resources`, beside
the client's slice), signed inside out with the rest and sealed in the
manifest. Nothing is downloaded at run time; nothing on the machine — a
Homebrew or npm Codex, the person's own installation, `PATH` — is ever
used; a dev release carries none and `verify-release.sh` refuses one
that does. The digest is the version: no downloaded binary is executed
during preparation. Moving the pin is its own pull request, re-diffing
the protocol fixtures and rerunning the suite.

**One owner, one home, one child.** The runtime owns
`~/Library/Application Support/sai/codex` (`SAI_CODEX_HOME` moves it for
a scratch smoke; never onto `~/.codex`), created 0700 with sai's own
`config.toml` 0600 — `cli_auth_credentials_store = "keyring"`,
`forced_login_method = "chatgpt"`, `web_search = "disabled"`,
`[history] persistence = "none"`, `[mcp_servers]` empty,
`check_for_update_on_startup = false` — compared to the byte before every
spawn. An exclusive file lock on the home is taken before the spawn and
released after the exit, so the app and the terminal client cannot run
two runtimes on one login (a second sees "ChatGPT is in use by another
sai client", fixed text, no spawn). The child gets exactly six
environment variables (`CODEX_HOME`, `HOME` = the home, `TMPDIR`, `LANG`,
`RUST_LOG`, `PATH`) — no `OPENAI_*`, no `CODEX_*` but the home, no proxy
— through the one `ProcessRunner` implementation in `lib/src/process/`,
the only `Process.start` under `lib/` (`no_spawn_test`); every test
drives a scripted fake. `initialize` must report the home sai gave.

**The runtime is a text-inference bridge and nothing else.** It runs
under a checked-in Seatbelt profile passed inline to `sandbox-exec`
with the roots as parameters: closed by default; `process-exec` of its
own binary alone; the system runtime read-only; its home, the per-call
scratch directory, a private temp root and the user's `~/Library/Keychains`
read-write; the Keychain, trust and network services; the network out,
and loopback in for the browser sign-in callback. The repository, the
archive, settings and the rest of the home directory are dark to it, and
a shell a model asks for fails at exec. Inside that, every turn is a
fresh `ephemeral` thread in a scratch directory at `sandbox: "read-only"`,
`approvalPolicy: "never"`, with sai's leading system message as
`baseInstructions`, the prior messages injected as role-correct Responses
items, and the last user message as the turn; `effort` goes only when
explicit. sai sends eleven methods and no other; every server-initiated
request is declined with a JSON-RPC error and the turn interrupted; any
item that is not passive text — a command, a file change, a tool call,
a plan, a type sai has never heard of — interrupts the turn and fails it
closed. Before any prompt goes, `account/read` must say `chatgpt`, and
the chosen model and effort must be in the live `model/list`.

**Model and effort are two choices.** `LlmRequest.reasoning` (a
boolean) becomes `ReasoningEffort`, the backend's own word or null for
the model's default; `provider.request` records it as `reasoning_effort`
(older lines' `reasoning: false` stand as written). The two OpenAI kinds
carry `reasoning_effort` in their entry — chosen from the model's
advertised list for the plan, from the Responses vocabulary labelled
model-dependent for the key — and Model default sends no override. Every
other kind keeps the global switch, translated as before (on → default,
off → `none`); the App menu says *Set Reasoning Effort…* while an OpenAI
kind is active and opens the provider's setting instead of flipping a
switch that is not its. A saved model or effort the list no longer
carries stays visible as unavailable and is refused on every call; nothing
is swapped, upgraded or downgraded on sai's initiative. Lineage is the
exact id asked for; what upstream says answered rides as the version.

## What this defends, honestly

The two failure modes ADR 0013 named — a shared refresh token and a key
that outranks a login — cannot happen here: sai holds no ChatGPT token,
the runtime's home is its own token family, and the child inherits no
key. A model that reaches for a shell, a file or a tool is stopped at
three layers: sai interrupts the turn, the App Server's own sandbox is
read-only with approvals off, and the Seatbelt profile lets it exec
nothing but itself. The key of the API route is in the Keychain and goes
out as one header to one origin. What it does not defend: the child must
reach the Keychain for its own `Codex Auth` item, and a process running as
the user can in principle reach other user-granted items through that
service — the OS sandbox is a file-system and process boundary, not a
credential one (ADR 0013). `sandbox-exec` is deprecated by Apple and
present on every macOS; the human smoke is where it is proven against the
real binary, and the fallback is a narrower profile amendment, never a
run without one.

## Consequences

- Settings v0 gains the two kinds and `reasoning_effort`; event log v0's
  `provider.request` gains `reasoning_effort`.
- `TransportText` grows the Responses refusals; `CodexText` is the
  ChatGPT route's fixed vocabulary. Neither ever quotes the runtime's
  stderr, a URL with a path, an email, a token or a prompt.
- Both clients gain the sign-in, model and effort journeys
  (`docs/smoke/cloud.md`, routes G and K); the terminal client's
  `provider login/account/models/reasoning/logout`.
- The release carries a third-party binary for the first time:
  `docs/release/README.md` documents the pin, the fetch, the
  verification, the notices and the upgrade procedure.
- The dev flavor runs no runtime and refuses in fixed words before any
  spawn (#95, ADR 0019); the keyless smoke an agent runs never spawns
  it, never reaches api.openai.com and never touches a Keychain.

## Rejected

- **A locked-down `openai_compatible` entry for the API** — cannot say
  the Responses body or stream, and an edit could move it (as ADR 0022
  found for OpenRouter).
- **Widening `OpenAiDialect` to serve both APIs** — the dialect is a
  chat-completions vocabulary; threading path, body and decoder through
  it would put the 400 ladder every local model depends on in the blast
  radius of a cloud change.
- **Discovering or downloading the App Server at run time** — a floating
  version is a floating protocol and a floating Keychain account.
- **Running the App Server without the outer sandbox** — its own
  read-only mode is a policy the model is asked to respect; the profile
  is one it cannot.
- **Reusing the person's `~/.codex`** — ADR 0013's refresh race.
- **Estimating a per-call price for the plan** — plan windows are
  availability, not money; only what upstream reports is recorded.
