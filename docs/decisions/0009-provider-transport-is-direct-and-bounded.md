# 9. Provider transport is direct and bounded

Date: 2026-08-25 · Status: accepted · Issue: #22 · Amended by: [0012](0012-plaintext-http-is-allowed-on-the-lan.md), [0022](0022-openrouter-is-its-own-kind-with-pinned-routing.md) · Schema: [settings-v0](../settings/settings-v0.md)

## Context

The first real provider (#22) speaks to OpenAI-compatible `/v1`
endpoints: `llama-server` and LM Studio on this Mac, the Ubuntu box on
the LAN (#23), and later the cloud kinds (#24–#26). The endpoint is
user-configured, the key comes from the Keychain (ADR
[0008](0008-secrets-live-in-the-file-keychain.md)), and every call is
archived for life (ADR
[0007](0007-provider-traffic-is-three-events-per-call.md)). Each of
those is a way for a key to end up somewhere it does not belong:

- `dart:io` follows redirects by default. It strips `Authorization` on
  a cross-origin redirect but not `x-api-key`-style headers, so a
  redirect from a configured base URL forwards the key to wherever the
  redirect points. A base URL is also the SSRF surface of this class of
  client (cf. axios CVE-2025-27152).
- `dart:io` honours `HTTP(S)_PROXY` from the environment by default.
- A URL can carry userinfo, a query or a fragment, and an exception's
  text quotes the URL.
- `dart:io` has no total request timeout. A hung endpoint leaves a
  `provider.request` line with no outcome, which ADR 0007 forbids.
- A key entered for one endpoint keeps being sent after the endpoint is
  edited to point elsewhere.

## Decision

Every outbound provider request goes through one transport, in
`packages/sai_core/lib/src/llm/openai_compatible/`, with this policy:

- **No redirects.** `followRedirects = false` on every request; a 3xx is
  a `rejected` failure carrying the status. Nothing is re-sent.
- **Direct connections.** `findProxy` answers `DIRECT`; the environment's
  proxy variables are ignored. No `badCertificateCallback`, no TLS
  pinning: the system trust store decides, and a certificate it does not
  trust is an `unreachable` failure (`TLS handshake failed`).
- **Plaintext only to this machine.** `http://` is accepted only for
  `localhost` and loopback addresses; anything else must be `https://`.
  (Widened to the LAN by ADR
  [0012](0012-plaintext-http-is-allowed-on-the-lan.md).)
  Refused at entry (the CLI and the dialogs, `checkEndpointForEntry`)
  and at request time (no socket is opened) — never on the read path, so
  a rule tightened later cannot make a stored file unreadable.
- **Clean URLs.** An endpoint carries no userinfo, query or fragment
  (settings v0), and no key is ever put in one.
- **Keys are bound to an origin.** Storing a key records the endpoint's
  `scheme://host[:port]` as `credential_origin` beside the account name.
  The key is sent, as `Authorization: Bearer`, only while the endpoint
  still has that origin; after the endpoint moves, the call fails with
  kind `credential` until the key is entered again. A path change is
  not a move.
- **Four deadlines.** Connect (10 s), first response headers (30 s),
  first token (5 min — prompt evaluation on a large context), and
  between later stream events (30 s); an SSE comment (`: ping`) resets
  the clock. There is no total deadline: a long answer that keeps
  arriving is fine. Every deadline aborts the request. Discovery answers
  are capped at 1 MiB.
- **Cancellation** finishes the call first (the controller's rule), then
  aborts the socket, so the recorder's three lines are always written.
  Cancellation is client-side only: OpenAI-compatible servers expose no
  cancel endpoint, so a server may keep ingesting the prompt bytes it
  already received until it notices the disconnect — a cancelled warm
  can look busy on the old endpoint for a while after a provider switch.
  Intended (#109); the transport's whole obligation is that the abort
  reaches the wire promptly.
- **Fixed failure text.** A failure names its kind, a message from a
  fixed set (`policy.dart`), the endpoint's *origin*, and an HTTP status
  where there was one — never an exception's text, a response body, a
  header, or a URL path. An OpenAI-style `error` object inside the
  stream is a `rejected` failure, not an empty answer. The recorder
  normalises `endpoint` to an origin again before writing, as a second
  guard.
- **Discovery is not a call.** `GET /v1/models`, llama.cpp `/health` and
  `/props`, LM Studio `/api/v1/models` go through the same transport and
  policy but are not recorded: they carry no user content, and what an
  endpoint did not say stays "unavailable" rather than guessed.

`LlmFailureKind` gains `credential` for the three ways a key stops a
call before a socket opens: none stored where the endpoint takes one,
bound to another origin, the store unreadable. A binding on disk that
does not match its endpoint is simply not a binding — dropped on read,
not a format error. Storing a key writes the binding first and the
secret second, so a half-failed store leaves "no key", never a key that
can never be sent; and the binding is pushed into the live provider
rather than rebuilding it, so a running call is never cut.

## Consequences

- A LAN endpoint needs TLS. `llama-server` serves it natively
  (`--ssl-key-file`, `--ssl-cert-file`, built with `LLAMA_OPENSSL=ON`);
  the certificate must be one this Mac trusts, since nothing here
  bypasses trust. #23 owns that setup. (Superseded: ADR 0012 admits
  plaintext on the LAN.)
- Corporate proxies are not supported, and there is no setting to add
  one. If that changes, it is a visible setting, not an environment
  variable.
- A key entered before this decision (no `credential_origin` on record)
  is not sent until entered again; both clients say so.
- The stub-server tests (`test/llm/openai_compatible/`) pin each rule:
  redirect refusal, proxy bypass (a child process with `HTTP_PROXY`
  set), an untrusted self-signed certificate (generated at test time,
  nothing committed), each deadline, origin binding, and that no failure
  text ever quotes what was sent or received.

## Rejected

- **TLS pinning** — a client that controls neither end would break on
  every certificate rotation; trust-store validation is the right level.
- **UNIX-socket transport** — `llama-server` supports it, but it does
  not reach the LAN and adds a second transport to police.
- **Honouring the proxy environment with a UI indicator** — a proxy is a
  place a LAN key goes; not sending is simpler than warning.
- **A total request deadline** — would cut long legitimate answers; the
  inter-token deadline catches a hung stream just as well.
