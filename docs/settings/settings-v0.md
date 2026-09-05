# Settings, v0

Status: current · Issues: #21, #29, #22, #27, #23, #76, #40, #97, #24, #26, #62, #15 · ADRs: [0006](../decisions/0006-settings-live-in-a-file-beside-the-archive.md), [0008](../decisions/0008-secrets-live-in-the-file-keychain.md), [0009](../decisions/0009-provider-transport-is-direct-and-bounded.md), [0012](../decisions/0012-plaintext-http-is-allowed-on-the-lan.md), [0015](../decisions/0015-the-workspace-is-restored-from-settings.md), [0022](../decisions/0022-openrouter-is-its-own-kind-with-pinned-routing.md), [0024](../decisions/0024-provider-choice-is-an-order-resolved-at-send.md), [0025](../decisions/0025-the-archive-is-replicated-to-a-second-root.md)

The non-secret preferences both clients share: one JSON object in
`settings.json`, beside the default archive (`SAI_SETTINGS_FILE` moves it).
`packages/sai_core/lib/src/settings/` is the one reader and writer. This
file never holds a secret; the tests in `packages/sai_core/test/settings/`
and `test/no_secrets_test.dart` enforce that.

## Object

| key | required | value |
| --- | --- | --- |
| `version` | yes | `0` |
| `llm` | no | id of the **first choice** — a configured provider or a built-in (`fake`, `lmstudio`, `lan`; #23; `openrouter`, #24) — or `null` for none. The head of the preference order (#62, ADR 0024), and a plain string on purpose: an older sai reads this key alone and selects exactly this provider. While the file does not exist, a first run selects `lmstudio` without writing; once the file exists, its word stands |
| `llm_fallback` | no | list of ids tried after `llm`, in order, when it cannot answer (#62). Omitted while empty, so a single choice writes the file an older sai wrote. Read strictly on type — anything but a list of non-empty strings makes the file unreadable — and leniently on content: an entry repeating `llm` or itself is dropped on read and not written again, and a tail with `llm: null` is dropped whole (a tail without a head is not an order, and an older sai reading `llm` alone sees the same nothing) |
| `providers` | no | list of provider objects, ids unique; omitted when empty |
| `share_tasks_with_cloud` | no | boolean, the privacy switch (#27, ADR 0010): whether a `cloud`-tagged provider may see the task list. Off when absent, and omitted while off |
| `reasoning` | no | boolean (#34): whether a model may think before it answers. Off (absent) asks the backend not to (`reasoning_effort: none` and `chat_template_kwargs: {enable_thinking: false}` on the request) and the clients show no thinking; on lets it and shows it. Omitted while off |
| `workspace` | no | object (#76, ADR 0015): where the app's workspace was left — identifiers and UI preferences only, never task text. Omitted while empty; read leniently, see below |
| `finished_task_visibility` | no | `end_of_day` \| `immediate` (#97): when a completed or cancelled task leaves its working lists. `end_of_day` — the default, and absent while chosen — keeps a task finished on the current local day in every list and container it would be in if still open, greyed, until local midnight; `immediate` drops it into the Logbook at once. The Logbook, sidebar counts and the assistant's task context never depend on it. A word this sai does not know reads as the default and is dropped on the next write |
| `archive_backup` | no | absolute path of the archive's replica root on this Mac (#15, ADR 0025) — an external volume, a second disk, a mount; never the archive root, inside it, or above it. While set, the clients copy the log there on their own and `sai_tui archive backup` copies from outside; omitted while unset. Read strictly on type — anything but a non-empty string makes the file unreadable — and leniently on content: a relative path reads as unset and is dropped on the next write |
| `setup` | no | `"done"` once first-run setup was completed (#40, ADR 0016): the person chose to start empty or finished an import. Written on that choice and never unset; omitted before. Any other value reads as not done and is dropped on the next write |

## Workspace object

| key | required | value |
| --- | --- | --- |
| `section` | no | the selected section's key: `list:<inbox\|today\|upcoming\|anytime\|someday\|logbook>`, `trash`, `area:<id>`, `project:<id>` or `tag:<id>` |
| `task` | no | id of the task open in the inspector |
| `collapsed_areas` | no | list of area ids whose projects the sidebar folds away; omitted while empty |
| `assistant_visible` | no | boolean: whether the assistant pane is shown. Absent leaves the client's default (shown) |

## Provider object

| key | required | value |
| --- | --- | --- |
| `id` | yes | `^[a-z0-9][a-z0-9_-]*$`; what `llm` selects and the archive's `model.provider` carries |
| `kind` | yes | which implementation builds it: `fake`, `openai_compatible` (#22), `openrouter` (#24, ADR 0022), `openai` and `chatgpt_subscription` (#26, ADR 0013): OpenAI's Responses API on an API key, and a ChatGPT plan through the Codex App Server sai runs as a child — two kinds, two billings, no fall-through between them. Open: an unknown kind is kept and shown as "not available" |
| `endpoint` | no | absolute `http`/`https` URL with no userinfo, query or fragment. New entries take `http` only for this machine or the LAN — the same hosts `privacy` calls `local` below (ADR 0009, 0012); a stored one is read either way and refused at request time. `openai_compatible` needs it, and `default_model`. `openrouter` and `openai` have none — their origins are fixed in code — and `chatgpt_subscription` has none either (the App Server dials its own backend); an entry of any of the three that carries one is misconfigured |
| `default_model` | no | the model used when a request names none. `openrouter` needs it as one exact `owner/name` id: an `openrouter/*` router, a `~latest` alias or a `:nitro`/`:floor`/`:online` shortcut (judged on the lowercased id) leaves the entry misconfigured. `openai` needs it as the exact id OpenAI lists. `chatgpt_subscription` stores the exact id the App Server's `model/list` gave and may stand without one until a model is chosen; a stored id the list no longer carries is shown as unavailable and refused on every call, never swapped for another |
| `credential` | no | `^provider:[a-z0-9][a-z0-9_-]*$` — the secret-store *account* holding the key, by convention `provider:<id>`. Absent for keyless backends; `openrouter` and `openai` need it. `chatgpt_subscription` never has one — the login is the App Server's own (ADR 0013), and an entry naming a key is misconfigured |
| `privacy` | no | `local` \| `cloud` — where the inference happens (#27, ADR 0010). Absent: the fake is `local`; an `openai_compatible` endpoint is `local` for this machine and the LAN (loopback, private, link-local and unique-local addresses, `.local`/`.lan`/`.home`/`.internal` names, dotless names) and `cloud` for any other host; `openrouter`, `openai` and `chatgpt_subscription` are `cloud`, and `local` leaves any of them misconfigured. An unknown value is read as absent and dropped on write |
| `credential_origin` | no | `scheme://host[:port]` of the endpoint the key was entered for; written when the key is stored. The key is sent only while it equals the endpoint's origin (ADR 0009); one that does not match, or names no credential, is dropped on read, and an edit that moves the endpoint drops it. Not written for `openrouter`, whose origin never moves |
| `routing` | no | how a broker routes inside itself (#24, ADR 0022). For `openrouter`: `deepinfra_fp8` — the recommended preset, `deepseek/deepseek-v4-flash-0731` pinned to DeepInfra fp8 with no fallback, valid with that model only — or `exact`, one model id and OpenRouter's own choice among that model's endpoints — one of which must meet the privacy filters every request carries (zero retention above all), or every call is refused (#115). `openrouter` needs it; a word this sai does not know leaves the entry misconfigured, never re-routed. Absent for other kinds — an `openai` or `chatgpt_subscription` entry carrying one is misconfigured |
| `reasoning_effort` | no | how hard the model may think (#26), for `openai` and `chatgpt_subscription` only: the backend's own word — `none`, `minimal`, `low`, `medium`, `high`, `xhigh`, `max`, or whatever the App Server's `model/list` advertises for the chosen model — stored as written. Absent means **Model default**: no override goes on the wire and the model decides. Model and effort are two choices; changing one never changes the other. A word the chosen model does not take is shown as unavailable and refused on every call, never replaced; a word this sai does not know round-trips untouched. Another kind carrying it is misconfigured — those kinds keep the global `reasoning` switch above |

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
- **A malformed `workspace` is dropped, not quarantined.** A value that
  is not an object reads as empty, a member of the wrong type is left
  out, and an id the projection no longer knows falls back (to Today,
  with no task) at launch. It carries a view, not a configuration, so a
  bad value costs a restored view and never the file — and, being a
  known key, it is rewritten clean on the next write rather than kept.
- **The app shows `problem`.** A quarantined or refused file is said in
  the first-run welcome and in Settings, not only in the status line.
- **Removing a provider takes it out of the order**: neither `llm` nor
  `llm_fallback` ever names a provider that is gone, and the next entry
  takes a vacated head.
- **An order entry that is not a provider id is not an entry.** `llm`
  and each `llm_fallback` word must match the `id` form above; anything
  else is dropped on read and not written again — the order is held in
  memory as one space-joined word, which that form cannot contain.
- **Using a provider sets the order's first entry, never the whole
  order** (#62). An id already in the order moves to the front and
  nothing is dropped; a new one takes the head's place and the arranged
  tail behind it stands. The order grows only where a person arranges it
  — the app's Providers page or `sai_tui provider order`. Selecting none
  clears the order whole.
- **Moving an endpoint unbinds its key.** A new host, port or scheme
  drops `credential_origin`; the key stays in the Keychain but is not
  sent until entered again. A new path keeps it.
- Writes are atomic, unparseable content is quarantined, a newer
  `version` is refused and left untouched — ADR 0006.

## Example

```json
{"llm":"lan","llm_fallback":["local"],"providers":[{"credential":"provider:lan","credential_origin":"https://lan.example:8443","default_model":"qwen","endpoint":"https://lan.example:8443/v1","id":"lan","kind":"openai_compatible"},{"default_model":"qwen","endpoint":"http://127.0.0.1:8080/v1","id":"local","kind":"openai_compatible"},{"credential":"provider:openrouter","default_model":"deepseek/deepseek-v4-flash-0731","id":"openrouter","kind":"openrouter","privacy":"cloud","routing":"deepinfra_fp8"}],"version":0}
```
