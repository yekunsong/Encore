# Encore

Reopen the Claude Code sessions a reboot cut off — in one command.

`encore restore` puts every closed session back the way you left it: same folder,
same conversation, one terminal tab each. No daemon, no service, no dependencies
beyond PowerShell 5.1 and the `claude` CLI you already have.

```
$ encore list
  1  closed  12m  D:\work\api      api-refactor
  2  closed   3h  D:\work\web      web-3
  3    open  41m  D:\work\infra    infra

$ encore restore
2 session(s) to reopen:
  1  12m  D:\work\api  api-refactor
  2   3h  D:\work\web  web-3
reopened 2 session(s)
```

## Why

Claude Code resumes one session at a time: `--resume <id>`, or the `/resume`
picker. It has no "reopen everything" command, and nothing restores the windows
you had open. Background sessions don't survive a reboot either, and
`claude respawn --all` only restarts sessions that are still running — after a
reboot, none are.

If you keep a dozen sessions across several projects, every restart is a manual
round of `cd` and `--resume`. Encore is the missing batch verb.

## Requirements

- Windows 10/11
- Windows PowerShell 5.1 (built in) — PowerShell 7 also works
- Claude Code with `claude` on `PATH`
- Each folder you restore from must be trusted once (Claude Code's normal
  workspace-trust prompt). Encore cannot accept that dialog for you.

## Install

```powershell
git clone <this repo> C:\Tools\Encore
cd C:\Tools\Encore
.\encore.ps1 install
```

`install` copies the script to `%LOCALAPPDATA%\Encore\bin`, puts that folder on
your user `PATH`, and registers an autosave task that snapshots your open
sessions every 15 minutes. Open a new terminal afterwards.

`install --no-task` skips the scheduled task.

## Use

| Command | What it does |
| --- | --- |
| `encore list` | Show restorable sessions (last 7 days by default) |
| `encore restore` | Reopen every closed session, one tab each |
| `encore restore --only 1,3` | Reopen selected rows from the list |
| `encore restore --dry-run` | Print the commands, launch nothing |
| `encore restore --project D:\work\api` | Only that tree |
| `encore restore --since 2d --limit 10` | Narrow the window |
| `encore save` | Snapshot what is open right now |
| `encore doctor` | Check the installation |
| `encore uninstall` | Remove PATH entry and task |

Sessions that are **still running are skipped**, so running `encore restore`
from inside a live Claude Code session never forks the conversation out from
under you. Use `--include-open` to override.

Encored sessions resume with a one-line prompt, `Continue from where you left
off.`, because Claude Code's interactive `--resume` currently refuses to load a
session whose transcript ends on an unresolved tool marker. Change or drop the
prompt with `--prompt "text"` / `--no-prompt`.

## Options

```
--since 30m|12h|2d|7d|1w    how far back to look (default 7d)
--project <dir>             restrict to a folder and its subfolders
--limit <n>                 cap the number of sessions
--only 1,3 / --only 3fa9c1  pick by row number or session-id prefix
--dry-run                   print, do not launch
--prompt <text>             prompt sent on resume
--no-prompt                 resume without sending a turn
--include-open              also reopen sessions that are still running
--yolo                      add --dangerously-skip-permissions
--wt                        force Windows Terminal instead of a new console
--window                    new window rather than tab (with --wt)
--kinds interactive,bg      session kinds to consider
```

## How it works

Two sources feed the candidate list:

1. `%LOCALAPPDATA%\Encore\snapshots\*.json` — written by `encore save` and by
   the autosave task from `claude agents --json`. Snapshots protect the record
   from Claude Code's startup cleanup, which prunes its own session registry.
2. `~/.claude/sessions\*.json` — Claude Code's own per-process records, which
   survive a reboot and carry folder and session id.

Each candidate resumes with a plain `claude --resume <id>` in its original
folder, in a new console (which Windows 11 opens as a Windows Terminal tab) or
a Windows Terminal tab with `--wt`. Surviving sessions are detected by session
id, PID and start time. Nothing is written to your transcripts; nothing leaves
the machine.

## Limitations

- Interactive CLI sessions only. `claude -p`, SDK, IDE, Desktop and background
  sessions are tracked separately and hidden by default.
- Session order and window geometry are not preserved — new tabs appear in a
  sensible but arbitrary order.
- `claude agents --json` is used for liveness. Sessions started by another
  process may not appear there on some builds; `--include-open` is the escape
  hatch if a restore ever skips one session too many.
- Flags that were not stored with the session (`--mcp-config`, `--add-dir`,
  `--settings`, `--plugin-dir`, `--fallback-model`) are not re-applied.
- Sessions older than `cleanupPeriodDays` (default 30) may already be deleted.

## Testing

`tests\smoke.ps1` runs the whole loop against a throwaway session with a cheap
model: real model call, real snapshot, real resume, real tab, real cleanup.

```powershell
git clone <this repo> C:\Tools\Encore
cd C:\Tools\Encore
.\tests\smoke.ps1
```

It creates `.test\smoke` inside the repo. That folder has to be trusted once;
the script says so and stops if it is not.

## Uninstall

```powershell
encore uninstall
```

Snapshots stay in `%LOCALAPPDATA%\Encore` — delete the folder to remove them.

## License

MIT
