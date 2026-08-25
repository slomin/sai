# 12. Plaintext HTTP is allowed on the LAN

Date: 2026-08-25 · Status: accepted · Issue: #23 · Amends: [0009](0009-provider-transport-is-direct-and-bounded.md) · Schema: [settings-v0](../settings/settings-v0.md)

## Context

ADR [0009](0009-provider-transport-is-direct-and-bounded.md) accepted
`http://` only for `localhost` and loopback addresses, and left the LAN
box (#23) to serve TLS with a certificate this Mac trusts. #23 turned
out differently: the box is sai's default brain now, it speaks plain
HTTP on the LAN, and it is read-only for sai — provisioning TLS, a
stable name and a key on it is not this project's work at this stage.
The rule as written refused the one endpoint sai is for, at entry and
at request time.

What the rule protected against on the LAN path is a key on the wire.
The LAN provider has no key; a key entered for a plaintext LAN endpoint
is bound to that origin (0009) and never leaves the LAN, since nothing
follows a redirect or honours a proxy. What is left is a neighbour on
the same network reading the conversation — accepted for a home LAN,
the same trust the archive on a shared disk already assumes.

## Decision

- **Plaintext to this machine or the LAN.** `http://` is accepted when
  the host is local as `isPrivateHost` (`settings/endpoint.dart`)
  already defines it for the privacy tag (ADR
  [0010](0010-the-privacy-policy-is-a-switch-checked-in-the-recorder.md)):
  loopback, a private (RFC 1918), link-local, CGNAT or unique-local
  address, a `.local`/`.lan`/`.home`/`.internal`/`.home.arpa` name, or a
  name without a dot. Any other host over `http://` is refused as
  before — at entry (`checkEndpointForEntry`) and at request time (no
  socket), never on the read path.
- **One predicate.** Where plaintext may go and what counts as `local`
  are the same question answered once; the privacy override in the
  configuration does not widen the plaintext rule.
- Everything else in 0009 stands: no redirects, no proxy, no
  certificate bypass, keys bound to an origin, the deadlines, the fixed
  failure text (`plaintext http is allowed only on this machine or the
  LAN; use https`).

## Consequences

- A LAN endpoint no longer needs TLS; a public host still needs a
  certificate the system trusts.
- Traffic to a LAN endpoint can be read on the LAN path. A key sent to
  one is exposed the same way — the README says so where keys are
  entered.
- A dotless name or a `.local` name is trusted by its shape, not by
  where it resolves. A search domain that maps a bare name to a public
  host would get plaintext; the key binding still refuses to send a
  key anywhere but the origin it was entered for.

## Rejected

- **An allow-list of one address** — a second rule beside the privacy
  predicate, and the box's address is not a contract.
- **TLS on the box** — 0009's plan; the server is not sai's to change
  now. When it is, `https://` on a LAN name needs no rule change.
