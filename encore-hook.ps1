#Requires -Version 5.1
<#
  SessionStart hook: append this session to Encore's index so a reboot
  cannot lose it. Must stay fast and never block the session.
#>
try {
    $raw = [Console]::In.ReadToEnd()
    $j = $raw | ConvertFrom-Json
    if (-not $j.session_id -or -not $j.cwd) { exit 0 }

    # a background session is one launched with --bg (its record may not exist yet)
    $kind = 'interactive'
    try {
        $cfgDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $env:USERPROFILE '.claude' }
        $sd = Join-Path $cfgDir 'sessions'
        $ppid = $PID
        for ($hop = 0; $hop -lt 3; $hop++) {
            $self = Get-CimInstance Win32_Process -Filter "ProcessId=$ppid" -ErrorAction SilentlyContinue
            if (-not $self -or -not $self.ParentProcessId) { break }
            $ppid = [int]$self.ParentProcessId
            $par = Get-CimInstance Win32_Process -Filter "ProcessId=$ppid" -ErrorAction SilentlyContinue
            if (-not $par -or $par.Name -ne 'claude.exe') { continue }
            $rec = Join-Path $sd "$ppid.json"
            if (Test-Path -LiteralPath $rec) {
                $s = Get-Content -LiteralPath $rec -Raw -ErrorAction Stop | ConvertFrom-Json
                if ($s.kind) { $kind = [string]$s.kind }
            }
            if ($par.CommandLine -match '(^|\s)--bg(\s|$)') { $kind = 'bg' }
            break
        }
    } catch { }

    $dir = Join-Path $env:LOCALAPPDATA 'Encore'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $line = [pscustomobject]@{
        id        = [string]$j.session_id
        cwd       = [string]$j.cwd
        kind      = $kind
        startedAt = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        source    = [string]$j.source
    } | ConvertTo-Json -Compress
    $file = Join-Path $dir 'index.jsonl'
    [IO.File]::AppendAllText($file, $line + "`n", (New-Object Text.UTF8Encoding($false)))

    if ((Get-Item -LiteralPath $file).Length -gt 400KB) {
        $keep = Get-Content -LiteralPath $file -Tail 2000
        [IO.File]::WriteAllLines($file, $keep, (New-Object Text.UTF8Encoding($false)))
    }
} catch { }
exit 0
