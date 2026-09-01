# 22. OpenRouter is its own kind, on one origin, with the routing said

Date: 2026-09-01 · Status: accepted · Issue: #24 · Builds on: [0008](0008-secrets-live-in-the-file-keychain.md), [0009](0009-provider-transport-is-direct-and-bounded.md), [0010](0010-the-privacy-policy-is-a-switch-checked-in-the-recorder.md), [0013](0013-subscription-logins-belong-to-the-vendor-runtime.md) · Amends: [0013](0013-subscription-logins-belong-to-the-vendor-runtime.md) · Schema: [settings-v0](../settings/settings-v0.md)

## Context

sai's first cloud provider. Every shipped provider so far is local and
keyless; the bearer-key path in the transport had never carried a real
key, `provider.usage` had never carried a `cost`, and no
`policy.decision` line had been written for a real call. ADR 0013 and
the auth spike planned OpenRouter as a locked-down `openai_compatible`
entry on a fixed origin. Building it showed what that entry could not
say: which fields OpenRouter wants and which it refuses, how thinking
is switched off there, that a request must never move to another
model, host or quantization than the one chosen, and that the endpoint
is not the person's to edit. Those are properties of the kind, not of
one settings entry.

The wire contract was checked against OpenRouter's current
documentation (Context7 `/websites/openrouter_ai`) and its public
endpoint listings on 2026-09-01: the `provider` routing object and its
fields; `HTTP-Referer` plus `X-OpenRouter-Title` for attribution;
`reasoning: {enabled: false}`; usage with `cost` in the final stream
chunk without asking; DeepInfra serving
`deepseek/deepseek-v4-flash-0731` as `fp8` and that endpoint being in
the zero-data-retention list; and DeepInfra's `supported_parameters`
lacking `stream_options`, which `require_parameters` would refuse.

## Decision

- **A kind of its own, `openrouter`**, built by the common transport
  (ADR 0009) with a *dialect*: `OpenAiDialect` names what differs
  between OpenAI-compatible backends beyond the endpoint — headers,
  body fields, how reasoning is switched off, how a refusal reads, how
  the endpoint is asked about itself. `LocalDialect` is what the
  local backends had; `OpenRouterDialect` is this ADR. The transport —
  direct, bounded, redirect-free, the key read from the Keychain at
  call time — is one and unchanged.
- **One origin, not configurable.** `https://openrouter.ai/api/v1` is
  a constant in code. The settings entry carries no `endpoint`; one
  that does is misconfigured. Nothing in settings or the environment
  moves it; tests point the built-in and the factory at a loopback
  stub through a riverpod override, and that is the only way. With the
  origin fixed there is nothing to bind the key to: the dialect says
  so and the `credential_origin` check does not apply.
- **Always `cloud`, always keyed.** The privacy tag is forced; a
  `privacy: local` entry is misconfigured. The key lives under
  `provider:openrouter` (ADR 0008); no environment variable, no file,
  no command-line argument. The dev flavor holds none (#95). Removing
  the key in sai removes the Keychain item only; revoking it is done
  at OpenRouter, and both clients say so.
- **Built in, inactive.** The provider ships like `lmstudio` and `lan`
  — a constructed object, never written to `settings.json` — so it is
  on every install with no migration, and a first run still selects
  LM Studio. The first key stored for it, or the first model chosen,
  writes the entry it would have had (`configFor`), and that entry
  hides the built-in as any configured id does.
- **The routing is said, never inferred.** `routing` is a settings
  key with two words. `deepinfra_fp8` — the recommended preset — sends
  `provider: {only: [deepinfra], quantizations: [fp8], allow_fallbacks:
  false, require_parameters: true, data_collection: "deny", zdr: true}`
  with `deepseek/deepseek-v4-flash-0731` and nothing else; `exact`
  sends `{require_parameters: true, data_collection: "deny", zdr: true}`
  with one model id. A route that is not there is a 404 with fixed
  text, never a retry without the pin — and under exact routing a 404 is
  the privacy filters alone: a model with no zero-retention endpoint
  (`qwen/qwen3-8b` at the time of writing) is refused on every call, in
  words that say so (#115). The same model chosen by hand is `exact`,
  because the person did not say "pinned". Every id under the
  `openrouter/` owner (`auto`, `auto-beta`, `free`, …) is a router,
  `~latest` is an alias and `:nitro` / `:floor` / `:online` are
  shortcuts — all refused at entry, judged on the lowercased id: each
  hands routing, or a web search, back to the router.
- **OpenRouter's request shape.** `reasoning: {enabled: false}` when
  thinking is off — never llama.cpp's `chat_template_kwargs`, never
  negotiated (a 400 is a refusal). No `stream_options`: usage with the
  cost comes in the final chunk regardless, and DeepInfra does not list
  the field under `require_parameters` (it does list `reasoning`,
  `max_tokens` and `temperature`, the three the preset sends — checked
  on the same day; the human smoke runs with thinking off, the
  default, and so proves it live). Fixed attribution headers. Two chat
  statuses get their own words: 404 — worded by the routing: the pin
  missed, or no endpoint answers for that model — and 402 (no credit);
  discovery keeps the common ones. The probe is `GET /key`:
  zero tokens, says whether the key is good — and, from
  `limit_remaining`, whether a capped key has anything left — and
  reports no model list and no context window.
- **What does not change.** The cloud budget stays the conservative
  one (`chatBudgetProvider`); catalog context never reaches a cloud
  provider and proposals are refused (ADR 0011, 0021); every call is
  recorded by `LlmRecorder` as four lines (ADR 0007, 0010); the
  reported `cost` rides `provider.usage` (#30). OpenRouter's own
  routing metadata is not persisted; the human smoke reads the route
  off OpenRouter's activity page.

## What this defends, honestly

The key is in the Keychain and goes out as one header to one origin;
a redirect, a proxy or a moved endpoint cannot carry it elsewhere, and
`no_secrets_test` scans every byte sai writes. The pin cannot be
relaxed by a setting, a retry or a router alias. What it does not
defend: the key is as safe as this Mac's login Keychain and the
process reading it (ADR 0001, no App Sandbox), so the smoke guide asks
for a dedicated key with a spending cap and an expiry, and an agent
never holds one (#56). `zdr` and `data_collection` are OpenRouter's
filters over providers' stated policies; sai asks, it cannot verify.

## Consequences

- Settings v0 gains the `openrouter` kind and the `routing` key; the
  kind's own validator (`openRouterProblem`) names an absent key bare,
  as `llmKindNeeds` would, and a present-but-wrong value as a phrase,
  so the clients never say "missing" about something that is there.
  An entry changed to this kind from the CLI drops the endpoint and
  the local tag it had, and choosing a model in the app rewrites the
  whole shape — either repairs an entry the factory refused.
- Both clients gain the model choice — preset or one exact id — and
  the key field works on the unconfigured built-in. The TUI does it
  through `provider add openrouter [--model …] [--routing …]` and
  `secret set openrouter`; there is still no in-terminal settings
  screen.
- The model list (#112, amending what first deferred it here): the
  app's exact-model field suggests the ids from
  `GET /api/v1/endpoints/zdr` — every endpoint OpenRouter would route
  to under `zdr: true`, one row per endpoint; ~0.7 MB for 816 rows and
  294 models on 2026-09-01 (Context7 `/websites/openrouter_ai` and a
  live read). That list, not `GET /models` (~2 MB, every model whether
  or not any endpoint keeps nothing): a model with no zero-retention
  endpoint is one sai refuses on every call, so it is never offered.
  Read on demand only — the first time the block shows with a key
  stored, and on its own Refresh — never on the connection watcher's
  timer, never on a task or chat change. The list is public; the
  request still goes down the provider's prepared path, key and all,
  because that path is the one rule set that already says "no key, no
  request" and keeps the dev copy off the network — a keyless second
  path would be more code for no privacy gained. Its own body cap (8
  MiB; the probe's stays 1 MiB); only `data[].model_id` is kept,
  filtered as a typed id is, deduplicated, sorted; one list for the
  session, a failed refresh keeping the last one beside its failure in
  the transport's fixed words; nothing of it in settings, the archive
  or the usage totals. Guidance, not a gate: a typed id that is not
  listed still applies, and a listed one may still be refused later —
  the list is the moment's.
- Rejected: a locked-down `openai_compatible` entry (cannot say the
  dialect, the pin or the fixed origin, and an edit could move it);
  OpenRouter's OAuth PKCE "connect" flow (a browser round-trip and a
  code exchange for a one-person app that has a Keychain); an
  environment or `.env` fallback (#56); inferring the pin from the
  model id (the person would not have said it); persisting router
  metadata (arbitrary, and a second place a body could land).
