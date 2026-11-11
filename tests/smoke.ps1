#Requires -Version 5.1
<#
  End-to-end smoke test: real model calls, real snapshot, real resume.
  Uses a throwaway background session in .test\smoke and removes it afterwards.
#>
[CmdletBinding()]
param([string]$Model = 'haiku', [string]$Dir)

$root = Split-Path -Parent $PSScriptRoot
$encore = Join-Path $root 'encore.ps1'
$dir = if ($Dir) { $Dir } else { Join-Path $root '.test\smoke' }
$codeword = 'TANGERINE-' + ([char[]]'QUAY' -join '')
$fail = 0
$id = $null

function Step { param($m) Write-Host "`n== $m" }
function Check { param($cond, $m)
    if ($cond) { Write-Host "  ok   $m" }
    else { Write-Host "  FAIL $m" -ForegroundColor Red; $script:fail++ }
}
function Invoke-Encore { param([string[]]$A)
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $encore @A
}

New-Item -ItemType Directory -Force -Path $dir | Out-Null

try {
    Step 'start a background session with a real model call'
    Push-Location $dir
    try { $out = & claude --bg --model $Model "Remember the codeword $codeword. Reply with READY only." 2>&1 } finally { Pop-Location }
    $out = $out -join "`n"
    if ($out -match 'not trusted') {
        Write-Host $out
        Write-Host "`nTrust $dir once (run 'claude' there and accept), then re-run." -ForegroundColor Yellow
        exit 2
    }
    $id = [regex]::Match($out, 'claude stop ([0-9a-f]{8})').Groups[1].Value
    Check ($id -ne '') "session started ($id)"
    if (-not $id) { throw "could not parse session id from: $out" }

    Step 'wait for the session to finish its turn'
    $deadline = (Get-Date).AddMinutes(3)
    $row = $null
    do {
        Start-Sleep -Seconds 2
        $live = claude agents --json | ConvertFrom-Json
        $row = $live | Where-Object { $_.id -eq $id }
    } until ($row.state -eq 'done' -or $row.state -eq 'idle' -or (Get-Date) -gt $deadline)
    Check ($row.state -eq 'done' -or $row.state -eq 'idle') "session settled (state=$($row.state))"

    $full = $row.sessionId

    Step 'the SessionStart hook indexed it'
    $index = Join-Path $env:LOCALAPPDATA 'Encore\index.jsonl'
    $deadline = (Get-Date).AddSeconds(20)
    do { Start-Sleep -Milliseconds 500 } until (
        ((Test-Path $index) -and (Select-String -LiteralPath $index -SimpleMatch $full -Quiet)) -or (Get-Date) -gt $deadline)
    Check ((Test-Path $index) -and (Select-String -LiteralPath $index -SimpleMatch $full -Quiet))         'session appears in the hook index (run encore install first)'

    Step 'stop the session and check it shows up as closed'
    claude stop $id | Out-Null
    Start-Sleep -Seconds 3
    $listed = (Invoke-Encore @('list', '--ids', '--kinds', 'background,interactive', '--since', '10m')) -join "`n"
    Check ($listed -match [regex]::Escape($id)) 'closed session appears in encore list'
    Check ($listed -match 'closed') 'it is reported as closed'

    Step 'a stale index line with no transcript is pruned'
    $staleShort = 'deadbeef'
    $stale = "$staleShort-0000-4000-8000-000000000001"
    $line = '{"id":"' + $stale + '","cwd":"' + ($dir -replace '\\', '\\\\') +
            '","startedAt":' + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() + '}'
    Add-Content -LiteralPath $index -Value $line -Encoding utf8
    try {
        $withStale = (Invoke-Encore @('list', '--ids', '--kinds', 'background,interactive', '--since', '10m', '--project', $dir)) -join "`n"
    } finally {
        $kept = @(Get-Content -LiteralPath $index | Where-Object { $_ -notmatch $stale })
        [IO.File]::WriteAllText($index, ($kept -join "`n") + "`n", (New-Object Text.UTF8Encoding($false)))
    }
    Check ($withStale -match $id.Substring(0, 8)) 'the real session is still listed'
    Check ($withStale -notmatch $staleShort) 'entry without a transcript is dropped'

    Step 'the hook record kept the session kind'
    $bgOnly = (Invoke-Encore @('list', '--ids', '--kinds', 'background', '--since', '10m')) -join "`n"
    Check ($bgOnly -match [regex]::Escape($id)) 'a background session is still found with --kinds background'

    Step 'dry run plans the right command'
    $plan = (Invoke-Encore @('restore', '--yes', '--dry-run', '--only', $id, '--kinds', 'background,interactive', '--since', '10m', '--project', $dir)) -join "`n"
    if ($plan -notmatch "--resume $full") { Write-Host $plan }
    Check ($plan -match "--resume $full") 'plan resumes the right id'
    Check ($plan -match 'Continue from where you left off\.') 'plan sends the continuation prompt'

    Step 'resume refreshes the conversation (real model call)'
    $reply = ''
    foreach ($attempt in 1, 2) {
        Push-Location $dir
        try {
            $json = & claude -p --model $Model --output-format json --resume $full "What was the codeword? Reply with the codeword only." 2>&1
        } finally { Pop-Location }
        try { $reply = ($json -join "`n" | ConvertFrom-Json).result } catch { $reply = ($json -join "`n") }
        if ($reply -match [regex]::Escape($codeword)) { break }
        Write-Host "  (attempt $attempt got: $reply)"
    }
    Check ($reply -match [regex]::Escape($codeword)) "model recalled the codeword"

    Step 'restore modes are configurable'
    $modes = @{}
    foreach ($m in 'window', 'tabs', 'windows', 'background') {
        $modes[$m] = (Invoke-Encore @('restore', '--yes', '--dry-run', '--only', $id, '--mode', $m, '--kinds', 'background,interactive', '--since', '10m', '--project', $dir)) -join "`n"
    }
    Check ($modes['window'] -match 'wt\.exe -w -1 new-tab') 'window mode plans one new window with tabs'
    Check ($modes['tabs'] -match 'powershell -NoExit') 'tabs mode plans a console'
    Check ($modes['windows'] -match 'new-window') 'windows mode plans a new window'
    Check ($modes['background'] -match '--bg') 'background mode plans a headless resume'
    Invoke-Encore @('config', 'mode', 'background') | Out-Null
    Check (((Invoke-Encore @('config', 'mode')) -join ' ') -match 'background') 'mode persists in config'
    Invoke-Encore @('config', 'mode', 'window') | Out-Null

    Step 'background mode restores without a terminal (real model call)'
    Start-Sleep -Seconds 3
    $bgOut = (Invoke-Encore @('restore', '--yes', '--mode', 'background', '--only', $id, '--kinds', 'background,interactive', '--since', '10m', '--project', $dir)) -join "`n"
    $deadline = (Get-Date).AddSeconds(40)
    $bgRow = $null
    do {
        Start-Sleep -Seconds 2
        $live = claude agents --json | ConvertFrom-Json
        $bgRow = $live | Where-Object { $_.sessionId -eq $full -and $_.kind -eq 'background' }
    } until ($bgRow -or (Get-Date) -gt $deadline)
    if (-not $bgRow) { Write-Host $bgOut }
    Check ($null -ne $bgRow) 'session runs in the background with no window'
    if ($bgRow) {
        claude stop $bgRow.id 2>$null | Out-Null
        $deadline = (Get-Date).AddSeconds(15)
        do {
            Start-Sleep -Seconds 1
            $live = claude agents --json | ConvertFrom-Json
            $still = $live | Where-Object { $_.sessionId -eq $full }
        } until (-not $still -or (Get-Date) -gt $deadline)
        Check (-not $still) 'background copy stopped again'
    }

    Step 'encore restore actually opens a resuming terminal'
    Invoke-Encore @('restore', '--yes', '--include-open', '--only', $id, '--kinds', 'background,interactive', '--since', '10m', '--project', $dir) | Out-Null
    $proc = $null
    $deadline = (Get-Date).AddSeconds(60)
    do {
        Start-Sleep -Seconds 2
        # one failed poll must not end the wait: WMI runs out of threads under load
        try {
            $proc = Get-CimInstance Win32_Process -Filter "Name='claude.exe'" -ErrorAction Stop |
                Where-Object { $_.CommandLine -like "*--resume $full*" } | Select-Object -First 1
        } catch { $proc = $null }
    } until ($proc -or (Get-Date) -gt $deadline)
    if (-not $proc) {
        # WMI unavailable: the session being live again still shows it was resumed
        $back = @(claude agents --json | ConvertFrom-Json) | Where-Object { $_.sessionId -eq $full } | Select-Object -First 1
        Check ($null -ne $back) "a terminal is running claude --resume $full (agent list; WMI unavailable)"
    } else {
        Check $true "a terminal is running claude --resume $full"
    }
}
finally {
    Step 'cleanup'
    if ($id) {
        try {
            Get-CimInstance Win32_Process -Filter "Name='claude.exe'" -ErrorAction Stop |
                Where-Object { $_.CommandLine -like "*$id*" } |
                ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        } catch { Write-Host '  (WMI unavailable; left stray processes)' }
        Push-Location $dir
        try { claude rm $id 2>$null | Out-Null } finally { Pop-Location }
        Write-Host "  removed test session $id"
    }
}

Write-Host ''
if ($fail -eq 0) { Write-Host 'SMOKE PASSED' -ForegroundColor Green; exit 0 }
Write-Host "$fail check(s) failed" -ForegroundColor Red; exit 1
