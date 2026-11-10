#Requires -Version 5.1
<#
  SessionStart hook: append this session to Encore's index so a reboot
  cannot lose it. Must stay fast and never block the session.
#>
try {
    $raw = [Console]::In.ReadToEnd()
    $j = $raw | ConvertFrom-Json
    if (-not $j.session_id -or -not $j.cwd) { exit 0 }

    $dir = Join-Path $env:LOCALAPPDATA 'Encore'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $line = [pscustomobject]@{
        id        = [string]$j.session_id
        cwd       = [string]$j.cwd
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
