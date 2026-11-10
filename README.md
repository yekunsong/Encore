# Encore

Reopen the Claude Code sessions a reboot cut off — in one command.

```
$ encore restore
2 session(s) to reopen [tabs mode]:
  1  12m  D:\work\api  api-refactor
  2   3h  D:\work\web  web-3
reopened 2 session(s)
```

Each session comes back in its own folder with its conversation intact. Sessions
that are still running are skipped, so nothing gets forked out from under you.

## Why

Claude Code resumes one session at a time (`--resume <id>`, or the `/resume`
picker), has no "reopen everything" verb, and restores nothing about the windows
you had open. Background sessions don't survive a reboot, and
`claude respawn --all` only restarts sessions that are still running — after a
reboot, none are. If you keep a dozen sessions open, every restart is a manual
round of `cd` and `--resume`.

## Requirements

Windows 10/11, Windows PowerShell 5.1 (built in), `claude` on `PATH`. Each folder
must be trusted once — Encore can't accept that dialog for you.

## Install

```powershell
git clone <this repo> C:\Tools\Encore
cd C:\Tools\Encore
.\encore.ps1 install
```

Copies the script to `%LOCALAPPDATA%\Encore\bin`, adds it to your user `PATH`,
and registers a 15-minute autosave task (`--no-task` to skip). Open a new
terminal afterwards.

## Use

| Command | What it does |
| --- | --- |
| `encore list` | Show restorable sessions (last 7 days) |
| `encore restore` | Reopen every closed session |
| `encore restore --only 1,3` | Reopen selected rows |
| `encore restore --dry-run` | Print the commands, launch nothing |
| `encore save` | Snapshot what is open right now |
| `encore config mode windows` | Persist a default restore mode |
| `encore doctor` | Check the installation |
| `encore uninstall` | Remove PATH entry and task |

Filters: `--since 30m|2d|1w`, `--project <dir>`, `--limit N`, `--include-open`,
`--ids`, `--kinds`.

### Modes

| Mode | Result |
| --- | --- |
| `tabs` (default) | a tab per session in your current terminal window |
| `windows` | one window per session |
| `background` | no terminal; sessions run headless, reached with `claude attach <id>` |

Set per run with `--mode`/`--tabs`/`--windows`/`--background`, persist with
`encore config mode ...`. Resuming a session that is already running in the
background starts a copy rather than stealing the original.

`windows` uses Windows Terminal's CLI; if your build ignores the trailing
command, Encore detects the empty tab and falls back to a plain window.

### Resume prompt

Encored sessions send `Continue from where you left off.`, because interactive
`--resume` refuses to load a session whose transcript ends on an unresolved tool
marker. Change it with `--prompt "text"`, drop it with `--prompt ""`.

## How it works

Candidates come from the newest snapshot in `%LOCALAPPDATA%\Encore\snapshots`
(protects the record from Claude Code's own startup cleanup) and from
`~/.claude/sessions\*.json`, which survives a reboot. Each one resumes with
`claude --resume <id>` in its own folder; liveness is checked per session id and
PID. Nothing leaves the machine and no transcript is written.

## Limitations

- Interactive CLI sessions only (`--kinds bg` to include background ones).
- Tab order and window geometry are not preserved.
- Flags not stored with a session (`--add-dir`, `--mcp-config`, `--settings`,
  `--plugin-dir`, `--fallback-model`) are not re-applied.
- `claude stop` deletes the session record, so a stopped session only restores
  from an older snapshot.

## Testing

`tests\smoke.ps1` exercises the whole loop against a throwaway session with a
cheap model — real model call, real snapshot, real resume, real cleanup. Run it
after changes:

```powershell
.\tests\smoke.ps1
```

## License

MIT
