#Requires -Version 5.1
<#
  SessionStart hook: append this session to Encore's index so a reboot
  cannot lose it. Must stay fast and never block the session.
#>
try {
    $raw = [Console]::In.ReadToEnd()
    $j = $raw | ConvertFrom-Json
    if (-not $j.session_id -or -not $j.cwd) { exit 0 }

    # background iff the live record for this session says so, else iff the
    # launching command used --bg (a fresh resumed copy has no record yet)
    $kind = 'interactive'
    try {
        $cfgDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $env:USERPROFILE '.claude' }
        $sd = Join-Path $cfgDir 'sessions'
        $found = $false
        if (Test-Path -LiteralPath $sd) {
            foreach ($f in Get-ChildItem -LiteralPath $sd -Filter '*.json' -File -ErrorAction SilentlyContinue) {
                try { $s = Get-Content -LiteralPath $f.FullName -Raw -ErrorAction Stop | ConvertFrom-Json } catch { continue }
                if ($s.sessionId -ne [string]$j.session_id) { continue }
                if ($s.kind) { $kind = [string]$s.kind }
                $found = $true
                break
            }
        }
        if (-not $found) {
            $self = Get-CimInstance Win32_Process -Filter "ProcessId=$PID" -ErrorAction SilentlyContinue
            $par = if ($self) { Get-CimInstance Win32_Process -Filter "ProcessId=$($self.ParentProcessId)" -ErrorAction SilentlyContinue }
            if ($par -and $par.Name -eq 'claude.exe' -and $par.CommandLine -match '(^|\s)--bg(\s|$)') { $kind = 'bg' }
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
