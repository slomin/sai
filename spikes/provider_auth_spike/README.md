# Provider auth spike

Evidence and decision for [#28](https://github.com/slomin/sai/issues/28):
how sai authenticates subscription-backed providers and who owns the
credentials. Research only — no code, nothing here is imported, nothing
here ran against a real account. `DECISION.md` holds the outcome.

## Layout

| file | what |
|---|---|
| `DECISION.md` | recommendation per route; the verified leading design |
| `matrix.md` | the comparison matrix, ticket questions × six columns |
| `threat-model.md` | the seven threats × routes; what an unsandboxed app cannot defend |
| `testing.md` | keyless automated strategy; human-run real-account smoke |
| `followups.md` | the exact edits applied to #25, #26, #56 |
| `evidence/codex.md`, `codex-app-server.md`, `opencode.md`, `openclaw.md`, `hermes.md`, `claude-agent-sdk.md` | per-project findings, `path:lines` at a pinned SHA |
| `evidence/vendor-docs.md` | Anthropic, OpenAI, OpenRouter primary pages, verbatim, dated |
| `evidence/incidents.md` | GitHub issues, press, HN: the public record |

## How the evidence was gathered

- Source: shallow clones under `references/other_repos/` (gitignored),
  read locally at the SHAs in the table below. Line numbers were
  spot-checked against the clone after writing; where a function moved,
  the number was corrected to the clone.
- Docs: fetched 2026-08-25 with WebFetch, WebSearch and the Context7 MCP
  (`/websites/openrouter_ai`, `/openai/codex`); a page that refused
  automated fetch is marked so and not quoted.
- Claude Code itself is closed source and covered by its official
  documentation only; the Python Agent SDK shows how a program drives
  it.

| project | SHA | version |
|---|---|---|
| openai/codex | `ba6cf9c69277` (2026-08-25) | tree `0.0.0`; release `rust-v0.149.1` = `ff29a44391de` installed here |
| anomalyco/opencode (was sst/) | `ac1c048e6420` (2026-08-26) | 1.18.23 |
| openclaw/openclaw | `1d526c5c0ef6` (2026-08-25) | 2026.8.1 |
| NousResearch/hermes-agent | `02c7ae956e42` (2026-08-25) | 0.20.5 |
| anthropics/claude-agent-sdk-python | `15af77c68ad7` (2026-08-25) | 0.2.143 |
| anthropics/claude-agent-sdk-typescript | `9d56dae01499` (2026-08-25) | 0.3.245, changelog only |

## Safety rules honoured

No file under `~/.claude`, `~/.codex`, `~/.hermes` or any Keychain item
was read. No account was authenticated, no model invoked, no token
pasted. No credential-shaped string appears in this directory
(`grep -rEn 'sk-(ant|proj|or|svcacct)-[A-Za-z0-9]{6,}|eyJ[A-Za-z0-9_-]{20,}'`
is empty). Storage schemas are described, not copied.
