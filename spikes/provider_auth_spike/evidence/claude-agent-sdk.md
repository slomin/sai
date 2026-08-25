# Claude Agent SDK and Claude Code — the official contract

Claude Code itself is closed source; per the ticket owner's steer it is
covered by **official documentation only** (all pages fetched
2026-08-25; quotes in `vendor-docs.md`). The Python SDK is open and shows
exactly how a program drives the `claude` binary.

- `anthropics/claude-agent-sdk-python` at
  `15af77c68ad7d43a66439a974b0a8a42ccda33fd`, version `0.2.143`
  (`pyproject.toml:6-7`), bundles Claude CLI `2.1.238` (`CHANGELOG.md:7`).
- `anthropics/claude-agent-sdk-typescript` at
  `9d56dae01499ea975b024da307d56c5db2c4c04b`, `0.3.245` ("parity with
  Claude Code v2.1.245"). **This repository holds no source** — README,
  CHANGELOG, examples only; TS facts below are changelog-derived.
- `claude` installed here: `2.1.245`.

## 1. Who logs in, who owns the tokens

Claude Code. `/login` runs the browser flow; credentials on macOS live
"in the encrypted macOS Keychain" (docs: authentication → Credential
management), on Linux in `~/.claude/.credentials.json` mode `0600`.
`claude setup-token` mints a one-year OAuth token for CI and prints it —
"It does not save the token anywhere". Neither SDK contains a login flow
of its own; there is no `apiKeySource` type in the Python SDK source
(only in a test's fake `system/init`), and no `claude setup-token`
reference in either repo.

## 2. How the SDK launches the binary

`src/claude_agent_sdk/_internal/transport/subprocess_cli.py`:

- Binary discovery: bundled → `shutil.which("claude")` → known paths
  (`~/.local/bin/claude` among them) (`:247-331`); override
  `ClaudeAgentOptions(cli_path=…)` (`types.py:2064-2068`). No
  `CLAUDE_CODE_PATH` env var exists.
- Command always starts `[cli, "--output-format", "stream-json",
  "--verbose"]` (`:566`) and ends with `["--input-format", "stream-json"]`
  (`:781-783`); the SDK never passes `-p` — it is always bidirectional
  streaming, with large options sent through the `initialize` control
  request (`_internal/query.py:231-277`).
- Environment (`:807-815`): inherit `os.environ` minus `CLAUDECODE`, then
  `CLAUDE_CODE_ENTRYPOINT=sdk-py`, then `options.env`, then
  `CLAUDE_AGENT_SDK_VERSION`. So **`options.env` merges over the parent
  environment** in Python; the TS changelog (`CHANGELOG.md:480`) says
  `Options.env` *replaces* it there. A caller that wants a scrubbed child
  must pass a complete environment (TS) or explicitly unset (Python).
- Version gate `MINIMUM_CLAUDE_CODE_VERSION = "2.0.0"` (`:36`).

## 3. Isolation flags — how to make Claude "inference only"

| option | flag | note |
|---|---|---|
| `tools=[]` | `--tools ""` | disables every built-in tool (`:586`); `--tools default` restores them (`:591`) |
| `allowed_tools` / `disallowed_tools` | `--allowedTools` / `--disallowedTools` (`:597-607`) | `"*"` in disallowed removes every tool (cli-reference) |
| `setting_sources=[]` | `--setting-sources=` (`:719-720`) | `None` = load user/project/local as the CLI would; `[]` = "SDK isolation mode" (`types.py:2218-2228`) |
| `strict_mcp_config=True` | `--strict-mcp-config` (`:691`) | ignore project `.mcp.json`, user settings, plugin MCP servers (`types.py:1984-1989`) |
| `permission_mode` | `--permission-mode` | `default|acceptEdits|plan|bypassPermissions|dontAsk|auto` (`types.py:25-27`) |
| `system_prompt` | `--system-prompt` / `--append-system-prompt` | replace or append |
| — | `--no-session-persistence` | print mode only; "sessions are not saved to disk and cannot be resumed" (cli-reference); the SDK does not emit it, the CLI accepts it |
| — | `--bare` | skips hooks, skills, commands, subagents, plugins, MCP, auto memory, CLAUDE.md — **and "never reads OAuth credentials or the system keychain"** (headless docs) |

Trap: `_apply_skills_defaults` silently sets
`setting_sources=["user","project"]` when `skills` is given and
`setting_sources` is `None` (`:519-560`).

## 4. Auth precedence (docs: authentication → Authentication precedence)

1. cloud provider vars (`CLAUDE_CODE_USE_BEDROCK|VERTEX|FOUNDRY`)
2. `ANTHROPIC_AUTH_TOKEN`
3. `ANTHROPIC_API_KEY` — "In non-interactive mode (`-p`), the key is
   always used when present"
4. `apiKeyHelper`
5. `CLAUDE_CODE_OAUTH_TOKEN`
6. Anthropic profile / federation (`ANTHROPIC_PROFILE`, `ANTHROPIC_FEDERATION_RULE_ID`)
7. **subscription OAuth from `/login`** — the Pro/Max default

"If you have an active Claude subscription but also have
`ANTHROPIC_API_KEY` set in your environment, the API key takes
precedence once approved." Bare mode "does not read
`CLAUDE_CODE_OAUTH_TOKEN`" and "never reads OAuth credentials".

## 5. The SDK reads Claude Code's Keychain item too

`_internal/session_resume.py` materialises a `SessionStore` resume into a
temp `CLAUDE_CONFIG_DIR` and seeds it from the caller's real config dir:
`.credentials.json`, `.claude.json`, `settings.json` (`_copy_auth_files`,
`:326-394`); on macOS it reads the Keychain service `"Claude
Code-credentials"` through `/usr/bin/security` (`:55`,
`_read_keychain_credentials` `:495-511`) because a redirected
`CLAUDE_CONFIG_DIR` changes the Keychain service-name suffix — skipped
when `ANTHROPIC_API_KEY` or `CLAUDE_CODE_OAUTH_TOKEN` is set. It strips
`claudeAiOauth.refreshToken` before writing the copy
(`_write_redacted_credentials`, `:431-456`) so the child cannot consume
the single-use refresh token and revoke the parent's login. That is the
vendor's own code acknowledging both the readability of the item and
the refresh-token hazard.

## 6. Redaction, tests

- The SDK pipes stderr only when `options.stderr` is set (`:851`).
- Tests fake the transport; `tests/test_close_cancellation.py:52` builds
  a `system/init` payload with `apiKeySource` by hand. No real binary
  or credential is needed.

## 7. Portable vs macOS-specific

Spawning `claude` and parsing `stream-json` is portable Dart. The
Keychain is Claude Code's concern, not the caller's; a caller that
redirects `CLAUDE_CONFIG_DIR` loses the Keychain login (the SDK's §5
workaround exists precisely because of that) — so a client must **not**
redirect it if it wants the user's subscription login.
