# Settings, v0

Status: current · Issues: #21, #29, #22, #27 · ADRs: [0006](../decisions/0006-settings-live-in-a-file-beside-the-archive.md), [0008](../decisions/0008-secrets-live-in-the-file-keychain.md), [0009](../decisions/0009-provider-transport-is-direct-and-bounded.md)

The non-secret preferences both clients share: one JSON object in
`settings.json`, beside the default archive (`SAI_SETTINGS_FILE` moves it).
`packages/sai_core/lib/src/settings/` is the one reader and writer. This
file never holds a secret; the tests in `packages/sai_core/test/settings/`
and `test/no_secrets_test.dart` enforce that.

## Object

| key | required | value |
| --- | --- | --- |
| `version` | yes | `0` |
| `llm` | no | id of the selected provider — a configured one or the built-in `fake` — or `null` for none |
| `providers` | no | list of provider objects, ids unique; omitted when empty |
| `share_tasks_with_cloud` | no | boolean, the privacy switch (#27, ADR 0010): whether a `cloud`-tagged provider may see the task list. Off when absent, and omitted while off |
| `show_reasoning` | no | boolean (#34): whether the clients show a model's reasoning beside its answer. Off when absent, and omitted while off; the archive records reasoning either way |

## Provider object

| key | required | value |
| --- | --- | --- |
| `id` | yes | `^[a-z0-9][a-z0-9_-]*$`; what `llm` selects and the archive's `model.provider` carries |
| `kind` | yes | which implementation builds it: `fake`, `openai_compatible` (#22). Open: an unknown kind is kept and shown as "not available" |
| `endpoint` | no | absolute `http`/`https` URL with no userinfo, query or fragment. New entries take `http` only for `localhost` or a loopback address (ADR 0009); a stored one is read either way and refused at request time. `openai_compatible` needs it, and `default_model` |
| `default_model` | no | the model used when a request names none |
| `credential` | no | `^provider:[a-z0-9][a-z0-9_-]*$` — the secret-store *account* holding the key, by convention `provider:<id>`. Absent for keyless backends |
| `privacy` | no | `local` \| `cloud` — where the inference happens (#27, ADR 0010). Absent: the fake is `local`; an `openai_compatible` endpoint is `local` for this machine and the LAN (loopback, private, link-local and unique-local addresses, `.local`/`.lan`/`.home`/`.internal` names, dotless names) and `cloud` for any other host. An unknown value is read as absent and dropped on write |
| `credential_origin` | no | `scheme://host[:port]` of the endpoint the key was entered for; written when the key is stored. The key is sent only while it equals the endpoint's origin (ADR 0009); one that does not match, or names no credential, is dropped on read, and an edit that moves the endpoint drops it |

## Rules

- **What sai writes, sai reads back.** The writer applies the same
  secret-looking guard as the reader, so a provider id or model that
  merely looks like a key (`sk-…`) is refused at entry rather than
  quarantined on the next start; `none` is reserved as a provider id.
- **No secret, ever.** A secret-looking key (`api_key`, `key`, `token`,
  `secret`, `password`, `authorization`, any case, at any depth) or a
  secret-looking value (`sk-…`, `Bearer …`) makes the file unreadable:
  it is quarantined like malformed JSON, and the error names the key,
  never the value. Keys live in the Keychain (ADR 0008) and the file
  names their accounts.
- **Unknown keys survive a write**, at the top and inside a provider
  object, so two binaries of different versions share one file.
- **Removing a provider clears its selection**: `llm` never names a
  provider that is gone.
- **Moving an endpoint unbinds its key.** A new host, port or scheme
  drops `credential_origin`; the key stays in the Keychain but is not
  sent until entered again. A new path keeps it.
- Writes are atomic, unparseable content is quarantined, a newer
  `version` is refused and left untouched — ADR 0006.

## Example

```json
{"llm":"lan","providers":[{"credential":"provider:lan","credential_origin":"https://lan.example:8443","default_model":"qwen","endpoint":"https://lan.example:8443/v1","id":"lan","kind":"openai_compatible"},{"default_model":"qwen","endpoint":"http://127.0.0.1:8080/v1","id":"local","kind":"openai_compatible"}],"version":0}
```
