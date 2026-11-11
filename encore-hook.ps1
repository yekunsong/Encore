#Requires -Version 5.1
<#
  Encore hooks. Records the lifecycle of a session so that "was open at
  shutdown" can be told apart from "was closed on purpose".

    SessionStart -> start event (session id, folder, kind)
    Stop         -> idle event (a turn finished)
    SessionEnd   -> end event (with the CLI's reason)

  Must stay fast and never block the session.
#>
try {
    $raw = [Console]::In.ReadToEnd()
    if (-not $raw) { exit 0 }
    $j = $raw | ConvertFrom-Json
    $id = [string]$j.session_id
    $ev = [string]$j.hook_event_name
    if (-not $id -or -not $ev) { exit 0 }

    $dir = Join-Path $env:LOCALAPPDATA 'Encore'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()

    switch ($ev) {
        'SessionStart' {
            if (-not $j.cwd) { exit 0 }
            $kind = 'interactive'
            try {
                $me = Get-CimInstance Win32_Process -Filter "ProcessId=$PID" -ErrorAction Stop
                $par = Get-CimInstance Win32_Process -Filter "ProcessId=$($me.ParentProcessId)" -ErrorAction Stop
                if ($par -and $par.Name -eq 'claude.exe' -and $par.CommandLine -match '(^|\s)--bg(\s|$)') {
                    $kind = 'bg'
                }
            } catch { }
            $line = [pscustomobject]@{
                ev = 'start'; id = $id; cwd = [string]$j.cwd; kind = $kind
                ts = $now; source = [string]$j.source
            }
        }
        'Stop' {
            $line = [pscustomobject]@{ ev = 'idle'; id = $id; ts = $now }
        }
        'SessionEnd' {
            $line = [pscustomobject]@{ ev = 'end'; id = $id; ts = $now; reason = [string]$j.reason }
        }
        default { exit 0 }
    }

    $file = Join-Path $dir 'index.jsonl'
    [IO.File]::AppendAllText($file, ($line | ConvertTo-Json -Compress) + "`n", (New-Object Text.UTF8Encoding($false)))

    if ((Get-Item -LiteralPath $file).Length -gt 700KB) {
        $keep = Get-Content -LiteralPath $file -Tail 4000
        [IO.File]::WriteAllLines($file, $keep, (New-Object Text.UTF8Encoding($false)))
    }
} catch { }
exit 0
