# Encore

**English** · [简体中文](README.zh-CN.md)

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Platform: Windows](https://img.shields.io/badge/platform-Windows%2010%2F11-0078D4.svg)](#requirements)
[![PowerShell 5.1](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE.svg)](#requirements)

Reopen the Claude Code sessions a reboot cut off — in one command.

```console
$ encore restore
2 session(s) to reopen [window mode]:
  1  12m  D:\work\api  api-refactor
  2   3h  D:\work\web  web-3

Restore 2 session(s)? [Y/n] y
reopened 2 session(s) in one new window
```

Each session comes back in its own folder with its conversation intact. Sessions
that are still running are skipped, so nothing gets forked out from under you.

---

## Contents

- [Why this exists](#why-this-exists)
- [Requirements](#requirements)
- [Install](#install)
- [Quick start](#quick-start)
- [Daily workflow](#daily-workflow)
- [Commands](#commands)
- [Filters and options](#filters-and-options)
- [Restore modes](#restore-modes)
- [Configuration](#configuration)
- [How it works](#how-it-works)
- [Privacy and safety](#privacy-and-safety)
- [Troubleshooting](#troubleshooting)
- [FAQ](#faq)
- [Limitations](#limitations)
- [Development](#development)
- [Uninstall](#uninstall)
- [License](#license)

## Why this exists

Claude Code resumes one session at a time: `--resume <id>`, or the `/resume`
picker. There is no "reopen everything" verb, and nothing restores the windows
you had open.

The other obvious candidates don't cover it either:

| Attempt | Why it falls short |
| --- | --- |
| `claude --continue` | only the newest conversation in the *current* folder |
| `claude respawn --all` | restarts background sessions that are *still running* — after a reboot, none are |
| `/resume` picker | one session per invocation, one folder at a time |
| Windows "restore previous session" | restores shells, not the Claude conversations inside them |

If you keep a dozen sessions across several projects, every restart is a manual
round of `cd` and `--resume`. Encore is the missing batch verb.

## Requirements

- Windows 10 or 11
- Windows PowerShell 5.1 (built into Windows)
- Claude Code with `claude` on `PATH`
- Each folder you restore from must be trusted once — Claude Code's normal
  workspace-trust prompt. Encore cannot answer that dialog for you.

## Install

Pick one:

**Git (recommended)**

```powershell
git clone https://github.com/yekunsong/Encore.git C:\Tools\Encore
cd C:\Tools\Encore
.\encore.ps1 install
```

**Zip** — download and extract the archive, then from the extracted folder:

```powershell
powershell -ExecutionPolicy Bypass -File .\encore.ps1 install
```

`install` does four things:

1. copies `encore.ps1` and `encore-hook.ps1` to `%LOCALAPPDATA%\Encore\bin`
2. puts that folder on your **user** `PATH`
3. registers a `SessionStart` hook in `~/.claude/settings.json`
4. seeds the index with the sessions you already have open

Open a **new terminal** afterwards so the `PATH` change applies.

> **Note**
> The scripts are unsigned. If PowerShell blocks them, run
> `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` once, or prefix a call
> with `powershell -ExecutionPolicy Bypass -File ...`.

## Quick start

```powershell
encore doctor              # 1. confirm claude, PowerShell and the hook are in place
encore list                # 2. see what is restorable (closed sessions only)
encore restore --dry-run   # 3. read the commands before running them
encore restore             # 4. review the plan, confirm, reopen
```

`encore list` marks each row `open` or `closed`. `restore` acts on `closed` rows
only and **asks before launching** — `--yes` skips the question. It shows at most
30 sessions by default and tells you how many more matched; add `--all` for
everything. `--dry-run` prints the exact commands instead.

## Daily workflow

The intended loop is short:

1. **Work.** Open as many sessions in as many folders as you like. The hook
   records each one the moment it starts; nothing else is needed from you.
2. **Shut down, crash, or reboot.** The sessions die, but their ids and folders
   stay in `%LOCALAPPDATA%\Encore\index.jsonl`.
3. **Come back.** Open one terminal and run:

   ```powershell
   encore list      # what was cut off
   encore restore   # put it back
   ```

4. **Trim what you don't need.** `encore restore --only 1,3` reopens just those
   rows; `--since 2d` or `--project D:\work\api` narrows the set; `--limit 5`
   caps it.

Restored sessions get a one-line prompt, `Continue from where you left off.`, so
they pick up immediately. Send none with `--prompt ""`.

## Commands

| Command | What it does |
| --- | --- |
| `encore list` | Show restorable sessions (last 7 days by default) |
| `encore list --ids` | Same, with session ids for use with `--only` |
| `encore restore` | Reopen every closed session |
| `encore restore --only 1,3` | Reopen selected rows |
| `encore restore --only 3fa9c1` | Reopen the session whose id starts like that |
| `encore restore --dry-run` | Print the commands, launch nothing |
| `encore config` | Show the persisted configuration |
| `encore config mode windows` | Persist a default restore mode |
| `encore doctor` | Check install state: `claude`, PowerShell, index, mode |
| `encore install` | Install or refresh scripts, `PATH` entry and hook |
| `encore uninstall` | Remove `PATH` entry and hook (the index is kept) |
| `encore version` | Print the version |

## Filters and options

| Option | Meaning |
| --- | --- |
| `--since 30m\|12h\|2d\|1w` | how far back to look (default `7d`) |
| `--project <dir>` | restrict to a folder and its subfolders |
| `--limit <n>` | cap the number of sessions |
| `--only 1,3` / `--only 3fa9c1` | pick by row number or id prefix |
| `--yes` | skip the confirmation prompt |
| `--all` | lift the 30-session default cap |
| `--include-open` | also reopen sessions that are still running |
| `--kinds interactive,background` | session kinds to consider (default `interactive`) |
| `--prompt "text"` | prompt sent on resume; `""` resumes with no turn |
| `--yolo` | add `--dangerously-skip-permissions` |
| `--dry-run` | print, do not launch |

## Restore modes

| Mode | Result |
| --- | --- |
| `window` (default) | one **new** terminal window, a tab per session inside it |
| `tabs` | a tab per session in your current terminal window |
| `windows` | one window per session |
| `background` | no terminal at all; sessions run headless and are reached with `claude attach <id>` |

Choose per run with `--mode <mode>` or the shorthands `--tabs` / `--windows` /
`--background`. `window` is the default: one new window, nothing else disturbed. Resuming a session that is already running in the background
starts a *copy* instead of stealing the original — the same rule the CLI applies.

`window` and `windows` go through Windows Terminal's command line. Some Terminal builds
ignore the trailing command and open an empty tab; Encore notices within a few
seconds and falls back to a plain console window, warning once per run.

## Configuration

One persisted key today (default `window`):

```powershell
encore config                # -> mode = window
encore config mode windows   # persist a default
```

Precedence: `--mode` / shorthand flag, then `config`, then `tabs`. The file is
plain JSON at `%LOCALAPPDATA%\Encore\config.json`.

## How it works

Claude Code deletes a session's live record once its process is dead, so a copy
has to exist *before* the machine goes down. Encore keeps that copy itself: a
`SessionStart` hook appends `session id + folder + kind + time` to
`%LOCALAPPDATA%\Encore\index.jsonl` the instant a session starts. No polling, no
timer, no window in which a session can vanish.

`restore` reads the index plus the still-live `~/.claude/sessions\*.json`
records, drops entries whose transcript file is gone, drops entries whose folder
no longer exists, and drops entries whose session is still running. Each survivor
launches as:

```powershell
Set-Location -LiteralPath '<folder>'; claude --resume <id> "<prompt>"
```

`install` seeds the index from the sessions open at that moment, which is why
sessions that predate the hook still survive a reboot.

## Privacy and safety

- Everything stays local: no network call, no telemetry, no account.
- The index stores only session id, folder, kind and a timestamp — no prompt
  text, no file contents.
- Transcripts are read, never rewritten.
- Running sessions are never stolen; a live session is skipped unless you pass
  `--include-open`.
- `--yolo` is opt-in; by default your normal permission prompts stay.

## Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| `Workspace not trusted` on a restored session | Accept the trust prompt once in that folder — Encore cannot click it for you |
| `encore` is not recognized | Open a new terminal; check that `PATH` contains `%LOCALAPPDATA%\Encore\bin` |
| The script is blocked | `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`, or call `powershell -File ...` |
| `encore list` is empty after a reboot | The hook was never installed, or those sessions predate it. Run `encore install` |
| A window opens but stays empty | Your Windows Terminal build ignores the CLI command; the fallback handles it — or use `--mode tabs` |
| A session is listed but will not reopen | Folder or transcript is gone; `encore doctor` shows whether the index is populated |

## FAQ

**Does it reopen sessions that are still running?**
Not by default — they would be forked into a second conversation.

**Does it touch my conversations?**
No. It reads transcripts only to check they still exist, then calls
`claude --resume`.

**What about worktrees and other machines?**
Any folder works, worktrees included. Sessions from another machine restore only
if their transcript exists locally.

**Does it cost tokens?**
Restoring sends one short turn per session on your configured model — the same
cost as typing "continue" yourself.

**Can I exclude some sessions?**
Yes: start them with hooks disabled (`claude --bare`), or leave them out at
restore time with `--project` / `--only`.

**Where is the data?**
`%LOCALAPPDATA%\Encore\`. Delete the folder to forget everything.

## Limitations

- Interactive CLI sessions only by default (`--kinds background` to include
  background ones).
- Tab order and window geometry are not preserved.
- Flags not stored with a session (`--add-dir`, `--mcp-config`, `--settings`,
  `--plugin-dir`, `--fallback-model`) are not re-applied.
- Sessions started with hooks disabled are recorded only by the live record and
  are lost after a reboot.
- Sessions older than Claude Code's `cleanupPeriodDays` (default 30) may already
  be gone.

## Development

```
encore.ps1        main CLI
encore-hook.ps1   SessionStart hook (index writer)
tests/smoke.ps1   end-to-end test with real model calls; cleans up after itself
```

`tests\smoke.ps1` drives the whole loop against a throwaway session on a cheap
model — real session start, real hook record, real resume, real terminal, real
cleanup. It needs the hook installed.

```powershell
.\tests\smoke.ps1
```

## Uninstall

```powershell
encore uninstall
```

Removes the `PATH` entry, the hook and the deployed scripts. The index stays in
`%LOCALAPPDATA%\Encore`; delete that folder for a full wipe.

## License

MIT — see [LICENSE](LICENSE).
