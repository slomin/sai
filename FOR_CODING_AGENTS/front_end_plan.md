# Shell Assistant (“sai”) – Front-End Plan

## Goal

A dead-simple CLI entrypoint that lets users type plain English (no quoting, no flags) and sends the query plus local context (last 10 commands, current working directory, and a directory listing) to a single cross-platform core binary (`sai-core`).

---

## What the user does

```bash
# Works the same on macOS/Linux (bash/zsh) and Windows (PowerShell)
$ sai I'm not sure how to build this project?
$ sai run python -m http.server on a free port
$ sai -- this text should be treated as natural language, not flags
```

---

## Terminology (quick)

- **Shell wrapper / wrapper function**: Tiny per-shell function that forwards text + context to the real program.
- **Shim**: Small executable or alias on `PATH` that delegates to the real binary.
- **Shell hook / shell integration**: One-liners added to shell startup files (e.g., `eval "$(tool init zsh)"`).
- **Prompt hooks**: `preexec`/`precmd` (zsh) or `PROMPT_COMMAND` (bash) run around each prompt. Useful later, not required for v1.
- **PowerShell profile function**: A function added to the user’s PS profile that behaves like a command.

---

## Chosen approach

**Lightweight per-shell wrappers → single **``** binary.**\
Rationale: simple UX, fresh session history access, minimal shell-specific code, one portable core.

---

## High-level flow

1. User types `sai …` with any free-form text.
2. Shell wrapper captures the full message (including `-`/`--` tokens) **without** parsing options.
3. Wrapper collects context:
   - Last 10 commands (session history).
   - `pwd`.
   - (Option) the core will collect the directory listing for portability.
4. Wrapper sends a JSON payload to `sai-core` via stdin (or `--json @-`).
5. `sai-core` calls the LLM (local), prints a response, returns an exit code.

---

## Cross-platform wrapper snippets (minimal)

### bash/zsh

```sh
# Put this in what `sai init zsh` / `sai init bash` outputs.
sai() {
  # Join all args as one NL string without trying to parse flags
  local message="$*"

  # Last 10 commands (session)
  local history_10
  history_10=$(fc -ln -10 2>/dev/null || history 10 2>/dev/null)

  # Current directory
  local cwd="$PWD"

  # Build JSON and call core
  command sai-core --json @- <<'JSON'
{
  "message": "__MESSAGE__",
  "shell": "__SHELL__",
  "cwd": "__CWD__",
  "history": __HISTORY__
}
JSON
}
# Note: the init generator will replace placeholders with escaped values.
```

**Notes**

- `"$*"` treats everything after `sai` as natural language. It collapses multiple spaces—OK for NL input. If you need perfect spacing, the init generator can instead do: `printf '%s\n' "$@" | paste -sd' ' -`.
- Prefer sending **history & cwd** from the wrapper; let `` gather the directory listing using its own filesystem API for portability.

### PowerShell (Windows)

```powershell
function sai {
  param([Parameter(ValueFromRemainingArguments = $true)] [string[]] $MessageParts)
  $message = $MessageParts -join ' '

  # Session history (best-effort)
  $history10 = (Get-History -Count 10 | Select-Object -ExpandProperty CommandLine)

  $payload = [pscustomobject]@{
    message = $message
    shell   = "powershell"
    cwd     = (Get-Location).Path
    history = $history10
  } | ConvertTo-Json -Depth 4

  $payload | & sai-core --json @-
}
```

**Notes**

- Works in Windows PowerShell and PowerShell (Core). If `Get-History` is empty, you can fall back to PSReadLine’s persisted file (later enhancement).

---

## JSON payload (v1)

```json
{
  "message": "run pytest -q and show only failures",
  "shell": "zsh|bash|powershell|fish|other",
  "cwd": "/absolute/path",
  "history": [
    "git status",
    "python -m venv .venv",
    "pip install -r requirements.txt"
  ]
}
```

### Directory listing is gathered by the core

- Cross-platform, no reliance on `ls`/`dir` nuances.
- Honor ignores: `.git`, `node_modules`, `venv/.venv`, hidden files (configurable).

---

## `sai-core` CLI contract

- **Input**: `--json @-` (read JSON from stdin) or `--json <file>`.
- **Output**: human-readable text to stdout (LLM answer); machine-readable JSON with `--out-json` (optional).
- **Exit codes**: `0` success, `2` bad input, `3` context collection error, `4` LLM error.
- **Env opts** (optional):
  - `SAI_IGNORE_GLOBS="node_modules,.git,*.log"`
  - `SAI_HISTORY_COUNT=10`
  - `SAI_MAX_LISTING=5000` (cap to avoid huge dirs)

---

## Install / init UX

- Ship `sai init <shell>` that prints the wrapper snippet tailored to the shell.
- Users add to their shell startup:

**zsh**

```sh
eval "$(sai init zsh)"
```

**bash**

```sh
eval "$(sai init bash)"
```

**PowerShell**

```powershell
# In a profile script, e.g.:
# New-Item -ItemType File -Path $PROFILE -Force | Out-Null
# Then add:
& { (sai init powershell | Out-String) } | Invoke-Expression
```

- Provide `sai doctor` to verify wrapper + core connectivity.

---

## Examples we’re cribbing from (why they help)

- **zoxide** – emits per-shell init that defines small functions calling a single binary. *Pattern for **`sai init <shell>`*.
- **The Fuck** – alias/function captures **last command** and forwards to a Python core. *Good reference for session-fresh history capture*.
- **fzf** – installs keybindings/functions via `eval "$(fzf --<shell>)"`. *Clean bootstrap and shell-agnostic core*.
- **direnv** – `hook` integrates via prompt lifecycle. *Model for future prompt hooks if we add richer context*.
- **Atuin** – cross-shell history, sync, fast lookup. *Ideas for history unification and metadata*.
- **McFly** – Rust core + shell glue for better history search. *Design for efficient history storage/indexing*.
- **pyenv / rbenv / asdf** – shim design and PATH delegation. *Clear explanation of shims and rehashing; informs naming and docs*.

---

## Guardrails & privacy

- **Never** read more than needed (default: last 10 commands).
- Redact obvious secrets before sending to the model: tokens, `AWS_SECRET_*`, `.npmrc` auth lines, `password=` patterns.
- Respect `.gitignore`-style globs for directory listing.
- Provide `SAI_NO_SEND=[history|listing|pwd]` toggles.

---

## Edge cases to handle

- Messages beginning with `-` or `--` (must be treated as text, not flags).
- Very large directories (cap and summarize: counts per type, sample of names).
- Non-UTF8 filenames; emoji and CJK in paths.
- Shells without recent history (empty arrays okay).
- Spaces/newlines in arguments; Unicode punctuation (smart quotes).

---

## Minimal testing matrix

- **Shells**: zsh (mac default), bash (Linux/mac), PowerShell (Windows & mac/Linux).
- **History**: with/without recent commands; long pipelines; multi-line.
- **CWD**: repo roots, deep nested, Windows UNC paths.
- **Dir listing**: tiny (≤100), huge (>10k), binary-heavy, nested.
- **Messages**: starts with `--`, contains quotes/backticks, Unicode.

---

## Roadmap (front-end)

- **v1**: wrappers + session history + PWD + core-collected listing; `sai init`, `sai doctor`.
- **v1.1**: optional prompt hooks for richer context (duration, exit status), PSReadLine fallback on Windows.
- **v1.2**: config file (`~/.config/sai/config.toml`), per-project overrides, ignores.
- **v1.3**: plugin points for extra context (git status, active venv, language toolchains) behind flags.

---

## Reference naming for README

> *“**`sai`** installs a small ****shell wrapper**** (zsh/bash) or ****profile function**** (PowerShell) that forwards your free-form query and local context to the **`sai-core`** binary.”*

That’s it—no quoting, no flags required by the user; wrappers keep the UX simple while `sai-core` stays portable and testable.

