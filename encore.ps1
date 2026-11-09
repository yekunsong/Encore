#Requires -Version 5.1
<#
  encore - reopen the Claude Code sessions a reboot cut off.

  See README.md. MIT licensed.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Command = 'help',
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest = @()
)

$ErrorActionPreference = 'Stop'
$script:Version = '0.1.0'
$script:AppDir = Join-Path $env:LOCALAPPDATA 'Encore'
$script:SnapDir = Join-Path $script:AppDir 'snapshots'
$script:KeepSnapshots = 50
$script:MissingCwd = @()

# ---------------------------------------------------------------- helpers ---

function Write-Info { param([string]$m) Write-Host $m }
function Write-Warn { param([string]$m) Write-Host "encore: $m" -ForegroundColor Yellow }
function Write-Err  { param([string]$m) Write-Host "encore: $m" -ForegroundColor Red }

function Exit-With { param([int]$Code, [string]$Message)
    if ($Message) { if ($Code -eq 0) { Write-Info $Message } else { Write-Err $Message } }
    exit $Code
}

function Get-Opt {
    param([string[]]$ArgList)
    $o = @{}
    for ($i = 0; $i -lt $ArgList.Count; $i++) {
        $a = $ArgList[$i]
        if ($a -notmatch '^--') { continue }
        $name = $a.Substring(2); $val = $true
        if ($name -match '^(?<k>[^=]+)=(?<v>.*)$') { $name = $Matches.k; $val = $Matches.v }
        elseif ($i + 1 -lt $ArgList.Count -and $ArgList[$i + 1] -notmatch '^--') { $val = $ArgList[$i + 1]; $i++ }
        $o[$name] = $val
    }
    return $o
}

function Resolve-Kinds {
    param([string]$Spec)
    if (-not $Spec) { return @('interactive') }
    return @(([string]$Spec) -split ',' | ForEach-Object {
        $k = $_.Trim()
        if ($k -eq 'bg') { 'background' } else { $k }
    })
}

function Get-ClaudePath {
    $c = Get-Command claude -ErrorAction SilentlyContinue
    if (-not $c) { return $null }
    return $c.Source
}

function Get-ClaudeConfigDir {
    if ($env:CLAUDE_CONFIG_DIR) { return $env:CLAUDE_CONFIG_DIR }
    return (Join-Path $env:USERPROFILE '.claude')
}

function ConvertTo-EpochMs { param($Value)
    if ($null -eq $Value) { return [int64]0 }
    try { return [int64]$Value } catch { return [int64]0 }
}

function ConvertTo-TimeSpan {
    param([string]$Spec)
    if ($Spec -match '^\s*(?<n>\d+)\s*(?<u>[mhdw])\s*$') {
        $n = [int]$Matches.n
        switch ($Matches.u) {
            'm' { return [TimeSpan]::FromMinutes($n) }
            'h' { return [TimeSpan]::FromHours($n) }
            'd' { return [TimeSpan]::FromDays($n) }
            'w' { return [TimeSpan]::FromDays(7 * $n) }
        }
    }
    throw "bad duration '$Spec' (use e.g. 30m, 12h, 7d, 1w)"
}

function Format-Age {
    param([int64]$Ms)
    if (-not $Ms) { return '?' }
    $age = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $Ms
    if ($age -lt 0) { return 'now' }
    $t = [TimeSpan]::FromMilliseconds($age)
    if ($t.TotalMinutes -lt 60) { return ('{0}m' -f [int]$t.TotalMinutes) }
    if ($t.TotalHours -lt 48) { return ('{0}h' -f [int]$t.TotalHours) }
    return ('{0}d' -f [int]$t.TotalDays)
}

# --------------------------------------------------------- session sources ---

function New-Entry {
    param($Raw)
    [pscustomobject]@{
        id        = if ($Raw.sessionId) { [string]$Raw.sessionId } else { [string]$Raw.id }
        cwd       = [string]$Raw.cwd
        name      = [string]$Raw.name
        kind      = if (-not $Raw.kind) { 'interactive' } elseif ($Raw.kind -eq 'bg') { 'background' } else { [string]$Raw.kind }
        startedAt = ConvertTo-EpochMs $Raw.startedAt
        updatedAt = ConvertTo-EpochMs $(if ($Raw.updatedAt) { $Raw.updatedAt } else { $Raw.startedAt })
        pid       = if ($Raw.pid) { [int]$Raw.pid } else { 0 }
    }
}

function Get-LiveSessions {
    <# Live sessions straight from the CLI. Returns @() when unavailable. #>
    $claude = Get-ClaudePath
    if (-not $claude) { return @() }
    try {
        $raw = & $claude agents --json 2>$null
        if (-not $raw) { return @() }
        $parsed = $raw | ConvertFrom-Json
    } catch { return @() }
    foreach ($s in @($parsed)) {
        if (-not $s.sessionId) { continue }
        New-Entry $s
    }
}

function Get-DiskSessions {
    <# Persisted session records. Survive a reboot; may be stale. #>
    $dir = Join-Path (Get-ClaudeConfigDir) 'sessions'
    if (-not (Test-Path -LiteralPath $dir)) { return @() }
    foreach ($f in Get-ChildItem -LiteralPath $dir -Filter '*.json' -File -ErrorAction SilentlyContinue) {
        try { $s = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json } catch { continue }
        if (-not $s.sessionId) { continue }
        New-Entry $s
    }
}

function Get-SnapshotFiles {
    if (-not (Test-Path -LiteralPath $script:SnapDir)) { return @() }
    Get-ChildItem -LiteralPath $script:SnapDir -Filter '*.json' -File |
        Sort-Object LastWriteTime -Descending
}

function Get-LatestSnapshot {
    $f = Get-SnapshotFiles | Select-Object -First 1
    if (-not $f) { return $null }
    try { return (Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json) } catch { return $null }
}

function Get-CandidateSessions {
    <# Union of the newest snapshot and on-disk records, deduped by id. #>
    $map = @{}
    $snap = Get-LatestSnapshot
    if ($snap) { foreach ($e in @($snap.entries)) { if ($e.id) { $map[[string]$e.id] = (New-Entry $e) } } }
    foreach ($e in Get-DiskSessions) { $map[$e.id] = $e }
    $map.Values
}

# -------------------------------------------------------------- liveness ----

function Get-AliveKeySet {
    $set = @{}
    foreach ($s in Get-LiveSessions) {
        $set["id:$($s.id)"] = $true
        if ($s.pid) { $set["pid:$($s.pid):$($s.startedAt)"] = $true }
    }
    return $set
}

function Test-SessionAlive {
    param($Entry, $AliveSet)
    if ($AliveSet.ContainsKey("id:$($Entry.id)")) { return $true }
    if ($Entry.pid -and $AliveSet.ContainsKey("pid:$($Entry.pid):$($Entry.startedAt)")) { return $true }
    return $false
}

# --------------------------------------------------------------- commands ---

function Invoke-Prune {
    $files = @(Get-SnapshotFiles)
    if ($files.Count -le $script:KeepSnapshots) { return }
    $files | Select-Object -Skip $script:KeepSnapshots | ForEach-Object {
        Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-Save {
    param($Opts)
    $kinds = Resolve-Kinds ([string]$Opts['kinds'])

    $live = @(Get-LiveSessions | Where-Object { $kinds -contains $_.kind })
    if ($live.Count -eq 0) {
        $cut = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - 600000
        $live = @(Get-DiskSessions | Where-Object { $kinds -contains $_.kind -and $_.updatedAt -gt $cut })
    }
    if ($live.Count -eq 0) { Exit-With 0 'nothing to snapshot' }

    $entries = $live | Sort-Object updatedAt -Descending

    New-Item -ItemType Directory -Force -Path $script:SnapDir | Out-Null
    $stamp = [DateTimeOffset]::UtcNow.ToString('yyyyMMddTHHmmssZ')
    $path = Join-Path $script:SnapDir "$stamp.json"
    [pscustomobject]@{
        version   = 1
        createdAt = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        machine   = $env:COMPUTERNAME
        entries   = @($entries)
    } | ConvertTo-Json -Depth 5 | Out-String | ForEach-Object {
        [IO.File]::WriteAllText($path, $_, (New-Object Text.UTF8Encoding($false)))
    }

    Invoke-Prune
    if ($Opts['quiet'] -ne $true) { Write-Info ("saved {0} session(s) to {1}" -f @($entries).Count, $path) }
}

function Select-Candidates {
    param($Opts)
    $since = if ($Opts['since']) { ConvertTo-TimeSpan ([string]$Opts['since']) } else { [TimeSpan]::FromDays(7) }
    $cutoff = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - [int64]$since.TotalMilliseconds
    $kinds = Resolve-Kinds ([string]$Opts['kinds'])
    $alive = Get-AliveKeySet

    $items = @(Get-CandidateSessions | Where-Object {
        $_.id -and $_.cwd -and ($kinds -contains $_.kind) -and ($_.updatedAt -ge $cutoff)
    })

    if ($Opts['project']) {
        $root = ([string]$Opts['project']).TrimEnd('\', '/')
        $items = @($items | Where-Object { $_.cwd.TrimEnd('\', '/') -ieq $root -or $_.cwd -ilike "$root\*" })
    }
    if ($Opts['include-open'] -ne $true) {
        $items = @($items | Where-Object { -not (Test-SessionAlive $_ $alive) })
    }
    $items = @($items | Sort-Object updatedAt -Descending)

    $script:MissingCwd = @()
    $items = @($items | Where-Object {
        if (Test-Path -LiteralPath $_.cwd -PathType Container) { $true }
        else { $script:MissingCwd += $_.cwd; $false }
    })

    if ($Opts['limit']) { $items = @($items | Select-Object -First ([int]$Opts['limit'])) }

    if ($Opts['only']) {
        $picked = @()
        foreach ($sel in (([string]$Opts['only']) -split ',')) {
            $sel = $sel.Trim()
            if ($sel -match '^\d+$') {
                $idx = [int]$sel
                if ($idx -ge 1 -and $idx -le $items.Count) { $picked += $items[$idx - 1] }
            } else {
                $picked += @($items | Where-Object { $_.id -like "$sel*" })
            }
        }
        $items = @($picked)
    }
    return $items
}

function New-LaunchCommand {
    param($Entry, $Opts)
    $cwd = "'" + ($Entry.cwd -replace "'", "''") + "'"
    $flags = ''
    if ($Opts['yolo'] -eq $true) { $flags = ' --dangerously-skip-permissions' }
    $prompt = ''
    if ($Opts['no-prompt'] -ne $true) {
        $text = if ($Opts['prompt']) { [string]$Opts['prompt'] } else { 'Continue from where you left off.' }
        $prompt = ' "' + ($text -replace '"', '\"') + '"'
    }
    $inner = "Set-Location -LiteralPath $cwd; claude --resume $($Entry.id)$flags$prompt"
    $title = if ($Entry.name) { $Entry.name } else { Split-Path -Leaf $Entry.cwd }

    if ($Opts['wt'] -ne $true -or -not (Get-Command wt.exe -ErrorAction SilentlyContinue)) {
        return [pscustomobject]@{ Kind = 'process'; Inner = $inner; Argv = @() }
    }
    $mode = if ($Opts['window'] -eq $true) { 'new-window' } else { 'new-tab' }
    $argv = @('-w', '0', $mode, '-d', $Entry.cwd, '--title', "encore: $title", '--',
              'powershell.exe', '-NoExit', '-Command', $inner)
    return [pscustomobject]@{ Kind = 'wt'; Inner = $inner; Argv = $argv }
}

function Show-Plan {
    param($Items)
    $i = 0
    foreach ($e in $Items) {
        $i++
        '{0,3}  {1,4}  {2}  {3}' -f $i, (Format-Age $e.updatedAt), $e.cwd, $e.name
    }
}

function Invoke-List {
    param($Opts)
    $o = @{}; foreach ($k in $Opts.Keys) { $o[$k] = $Opts[$k] }
    $o['include-open'] = $true
    $items = @(Select-Candidates $o)
    if ($items.Count -eq 0) { Exit-With 0 'no matching sessions' }
    $alive = Get-AliveKeySet
    $i = 0
    foreach ($e in $items) {
        $i++
        $state = if (Test-SessionAlive $e $alive) { 'open' } else { 'closed' }
        $pre = if ($Opts['ids'] -eq $true) { $e.id.Substring(0, 8) } else { '' }
        '{0,3}  {1,6}  {2,4}  {3}  {4}  {5}' -f $i, $state, (Format-Age $e.updatedAt), $pre, $e.cwd, $e.name
    }
    Write-Info ''
    Write-Info ("{0} session(s)" -f $items.Count)
    if ($script:MissingCwd.Count) { Write-Warn ("{0} session(s) skipped: folder gone" -f $script:MissingCwd.Count) }
}

function Invoke-Restore {
    param($Opts)
    $items = @(Select-Candidates $Opts)
    if ($items.Count -eq 0) { Exit-With 0 'nothing to restore' }
    if ($script:MissingCwd.Count) { Write-Warn ("{0} session(s) skipped: folder gone" -f $script:MissingCwd.Count) }

    Write-Info ('{0} session(s) to reopen:' -f $items.Count)
    Show-Plan $items
    Write-Info ''

    if ($Opts['dry-run'] -eq $true) {
        foreach ($e in $items) {
            $c = New-LaunchCommand $e $Opts
            if ($c.Kind -eq 'wt') { Write-Info ('  wt.exe ' + ($c.Argv -join ' ')) }
            else { Write-Info ('  powershell -NoExit -Command "' + $c.Inner + '"') }
        }
        Exit-With 0 'dry run: nothing launched'
    }

    $opened = 0
    foreach ($e in $items) {
        $c = New-LaunchCommand $e $Opts
        try {
            if ($c.Kind -eq 'wt') { & wt.exe $c.Argv | Out-Null }
            else { Start-Process powershell.exe -ArgumentList '-NoExit', '-Command', $c.Inner | Out-Null }
            $opened++
        } catch {
            Write-Warn ("could not open {0}: {1}" -f $e.cwd, $_.Exception.Message)
        }
    }
    Exit-With 0 ("reopened {0} session(s)" -f $opened)
}

function Invoke-Doctor {
    $ok = $true
    foreach ($c in 'claude', 'wt.exe', 'powershell.exe') {
        $found = Get-Command $c -ErrorAction SilentlyContinue
        if ($found) { Write-Info ("[ok]   {0} -> {1}" -f $c, $found.Source) }
        else { Write-Info ("[warn] {0} not found" -f $c); if ($c -eq 'claude') { $ok = $false } }
    }
    $live = @(Get-LiveSessions)
    Write-Info ("[info] {0} live session(s) visible" -f $live.Count)
    Write-Info ("[info] {0} snapshot(s) in {1}" -f @(Get-SnapshotFiles).Count, $script:SnapDir)
    $task = Get-ScheduledTask -TaskName 'Encore-Autosave' -ErrorAction SilentlyContinue
    if ($task) { Write-Info '[ok]   autosave task registered' }
    else { Write-Info '[warn] autosave task not registered (run: encore install)' }
    if (-not $ok) { exit 1 }
}

function Invoke-Install {
    param($Opts)
    $here = $PSScriptRoot
    $bin = Join-Path $script:AppDir 'bin'
    New-Item -ItemType Directory -Force -Path $bin | Out-Null
    Copy-Item -LiteralPath (Join-Path $here 'encore.ps1') -Destination $bin -Force
    $shim = "@echo off`r`npowershell.exe -NoProfile -ExecutionPolicy Bypass -File `"%~dp0encore.ps1`" %*`r`n"
    Set-Content -LiteralPath (Join-Path $bin 'encore.cmd') -Value $shim -Encoding ASCII -NoNewline

    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ($userPath -notlike "*$bin*") {
        [Environment]::SetEnvironmentVariable('Path', ($userPath.TrimEnd(';') + ';' + $bin), 'User')
        Write-Info "added $bin to your user PATH (open a new terminal to use it)"
    }

    if ($Opts['no-task'] -ne $true) {
        $ps1 = Join-Path $bin 'encore.ps1'
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
            -Argument ('-NoProfile -ExecutionPolicy Bypass -File "{0}" save --quiet' -f $ps1)
        $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
            -RepetitionInterval (New-TimeSpan -Minutes 15)
        $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
        Register-ScheduledTask -TaskName 'Encore-Autosave' -Action $action -Trigger $trigger `
            -Settings $settings -Description 'Snapshot open Claude Code sessions' -Force | Out-Null
        Write-Info 'registered autosave task (every 15 minutes while logged in)'
    }
    Write-Info 'installed. Try: encore list'
}

function Invoke-Uninstall {
    Unregister-ScheduledTask -TaskName 'Encore-Autosave' -Confirm:$false -ErrorAction SilentlyContinue
    $bin = Join-Path $script:AppDir 'bin'
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ($userPath -like "*$bin*") {
        $new = ($userPath -split ';' | Where-Object { $_ -and $_ -ne $bin }) -join ';'
        [Environment]::SetEnvironmentVariable('Path', $new, 'User')
    }
    Remove-Item -LiteralPath $bin -Recurse -Force -ErrorAction SilentlyContinue
    Exit-With 0 'uninstalled (snapshots kept in %LOCALAPPDATA%\Encore)'
}

# ------------------------------------------------------------------ main ----

$opts = Get-Opt $Rest

switch ($Command.ToLower()) {
    'save'      { Invoke-Save $opts }
    'list'      { Invoke-List $opts }
    'restore'   { Invoke-Restore $opts }
    'doctor'    { Invoke-Doctor }
    'install'   { Invoke-Install $opts }
    'uninstall' { Invoke-Uninstall }
    'prune'     { Invoke-Prune; Exit-With 0 'pruned' }
    'version'   { Exit-With 0 "encore $script:Version" }
    default {
@"
encore $script:Version - reopen the Claude Code sessions a reboot cut off

  encore list                      show sessions (default: last 7 days)
  encore restore                   reopen every closed one, a tab each
  encore restore --only 1,3        reopen selected ones
  encore restore --dry-run         print the commands only
  encore save                      snapshot what is open right now
  encore doctor                    check the install
  encore install [--no-task]       put encore on PATH (+ 15-min autosave task)
  encore uninstall                 undo install

filters: --since 12h|2d|7d|1w  --project <dir>  --limit N  --include-open
         --prompt "text" (sent on resume; default "Continue from where you left off.")
         --no-prompt (resume without a turn)
         --ids (show session ids in list)
         --yolo (add --dangerously-skip-permissions)  --wt (force Windows Terminal)
         --window (new window, affects --wt only)
"@ | Write-Host
    }
}
