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
$script:MissingCwd = @()
$script:CutWindowSeconds = 180

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
    $o = @{ '@' = @() }
    for ($i = 0; $i -lt $ArgList.Count; $i++) {
        $a = $ArgList[$i]
        if ($a -notmatch '^--') { $o['@'] += @($a); continue }
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

function Get-ConfigPath { Join-Path $script:AppDir 'config.json' }

function Get-Config {
    $f = Get-ConfigPath
    if (-not (Test-Path -LiteralPath $f)) { return @{} }
    try {
        $o = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json
        $h = @{}
        foreach ($pr in $o.PSObject.Properties) { $h[$pr.Name] = [string]$pr.Value }
        return $h
    } catch { return @{} }
}

function Set-ConfigKey {
    param([string]$Key, [string]$Value)
    $cfg = Get-Config
    $cfg[$Key] = $Value
    New-Item -ItemType Directory -Force -Path $script:AppDir | Out-Null
    ($cfg | ConvertTo-Json -Depth 5) | ForEach-Object {
        [IO.File]::WriteAllText((Get-ConfigPath), $_, (New-Object Text.UTF8Encoding($false)))
    }
}

function Resolve-Mode {
    param($Opts)
    foreach ($m in 'tabs', 'window', 'windows', 'background') {
        if ($Opts[$m] -eq $true) { return $m }
    }
    if ($Opts['mode']) {
        $m = [string]$Opts['mode']
        switch ($m) {
            'tab'        { return 'tabs' }
            'tabs'       { return 'tabs' }
            'window'     { return 'window' }
            'windows'    { return 'windows' }
            'bg'         { return 'background' }
            'background' { return 'background' }
            default      { Exit-With 1 "bad --mode '$m' (window | tabs | windows | background)" }
        }
    }
    $cfg = Get-Config
    if ($cfg['mode']) {
        $m = [string]$cfg['mode']
        if (@('tabs', 'window', 'windows', 'background') -notcontains $m) {
            Write-Warn "config mode '$m' is invalid; using window (fix: encore config mode window)"
            return 'window'
        }
        return $m
    }
    return 'window'
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

function ConvertTo-Kind {
    param([string]$Kind)
    if (-not $Kind) { return 'interactive' }
    if ($Kind -eq 'bg') { return 'background' }
    return $Kind
}

function New-Entry {
    param($Raw)
    [pscustomobject]@{
        id        = if ($Raw.sessionId) { [string]$Raw.sessionId } else { [string]$Raw.id }
        cwd       = [string]$Raw.cwd
        name      = [string]$Raw.name
        kind      = ConvertTo-Kind ([string]$Raw.kind)
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

function Add-IndexLine {
    param([string]$Id, [string]$Cwd, [long]$StartedAt, [string]$Kind)
    if (-not $Id -or -not $Cwd) { return }
    New-Item -ItemType Directory -Force -Path $script:AppDir | Out-Null
    $line = [pscustomobject]@{
        ev = 'start'; id = $Id; cwd = $Cwd
        kind = (ConvertTo-Kind $Kind)
        ts = $(if ($StartedAt) { $StartedAt } else { [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() })
        source = 'seed'
    } | ConvertTo-Json -Compress
    [IO.File]::AppendAllText((Join-Path $script:AppDir 'index.jsonl'), $line + "`n", (New-Object Text.UTF8Encoding($false)))
}

function Get-ShutdownTimes {
    <# Timestamps of recent shutdowns/boots, for telling a cut-off session
       from one the user closed on purpose right before shutting down. #>
    $times = @()
    try {
        $filter = @{ LogName = 'System'; ProviderName = 'User32'; Id = 1074, 1075; StartTime = (Get-Date).AddDays(-7) }
        foreach ($e in Get-WinEvent -FilterHashtable $filter -ErrorAction Stop) { $times += $e.TimeCreated.ToUniversalTime() }
    } catch { }
    try {
        $filter = @{ LogName = 'System'; ProviderName = 'EventLog'; Id = 6005, 6006, 6008, 6009; StartTime = (Get-Date).AddDays(-7) }
        foreach ($e in Get-WinEvent -FilterHashtable $filter -ErrorAction Stop) { $times += $e.TimeCreated.ToUniversalTime() }
    } catch { }
    $times
}

function Get-BootTime {
    <# Approximate UTC time of the last boot; a session alive before it was
       cut off by that shutdown, whatever happened to it afterwards. #>
    $grace = 120000
    $ms = [Environment]::TickCount64
    return [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $ms - $grace
}

function Test-WithinShutdown {
    param($When, $ShutdownTimes)
    if (-not $When) { return $false }
    $window = [int64]$script:CutWindowSeconds * 1000
    foreach ($t in $ShutdownTimes) {
        if ([Math]::Abs(([DateTimeOffset]$When).ToUnixTimeMilliseconds() - ([DateTimeOffset]$t).ToUnixTimeMilliseconds()) -le $window) {
            return $true
        }
    }
    return $false
}

function Read-SessionRecords {
    <# One record per session, folded from the hook event log. Events decide
       the state: a session whose last event is an end was closed on purpose
       (unless the end sits inside a shutdown window), one that never ended was
       open when the machine went down. #>
    $map = @{}
    $shutdowns = Get-ShutdownTimes
    $bootTime = Get-BootTime
    $script:BootTime = $bootTime
    $horizon = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - [int64]([TimeSpan]::FromDays(30).TotalMilliseconds)

    $idx = Join-Path $script:AppDir 'index.jsonl'
    if (Test-Path -LiteralPath $idx) {
        foreach ($ln in (Get-Content -LiteralPath $idx -Tail 6000 -ErrorAction SilentlyContinue)) {
            try { $r = $ln | ConvertFrom-Json } catch { continue }
            if (-not $r.id) { continue }
            $id = [string]$r.id
            $ev = if ($r.ev) { [string]$r.ev } else { 'start' }
            $ts = ConvertTo-EpochMs $(if ($r.ts) { $r.ts } else { $r.startedAt })
            if ($ts -lt $horizon) { continue }

            $rec = $map[$id]
            if (-not $rec) {
                $rec = [pscustomobject]@{
                    id = $id; cwd = ''; name = ''; kind = 'interactive'; startedAt = 0; updatedAt = 0
                    pid = 0; endedAt = 0; lastEvent = ''; idledAt = 0; cut = $true
                }
                $map[$id] = $rec
            }
            switch ($ev) {
                'start' {
                    if ($r.cwd) { $rec.cwd = [string]$r.cwd }
                    if ($r.kind) { $rec.kind = ConvertTo-Kind ([string]$r.kind) }
                    if (-not $rec.startedAt) { $rec.startedAt = $ts }
                    $rec.lastEvent = 'start'
                }
                'idle' { $rec.idledAt = $ts; if ($rec.lastEvent -ne 'start') { $rec.lastEvent = 'idle' } }
                'end'   { $rec.endedAt = $ts; $rec.lastEvent = 'end' }
            }
            if ($ts -gt $rec.updatedAt) { $rec.updatedAt = $ts }
        }
    }

    $dir = Join-Path (Get-ClaudeConfigDir) 'sessions'
    if (Test-Path -LiteralPath $dir) {
        foreach ($f in Get-ChildItem -LiteralPath $dir -Filter '*.json' -File -ErrorAction SilentlyContinue) {
            try { $s = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json } catch { continue }
            if (-not $s.sessionId) { continue }
            $e = New-Entry $s
            $rec = $map[$e.id]
            if (-not $rec) {
                $map[$e.id] = [pscustomobject]@{
                    id = $e.id; cwd = $e.cwd; name = $e.name; kind = $e.kind; startedAt = $e.startedAt
                    updatedAt = $e.updatedAt; pid = $e.pid; endedAt = 0; lastEvent = 'start'; idledAt = 0; cut = $true
                }
            } else {
                if ($e.cwd) { $rec.cwd = $e.cwd }
                if ($e.name) { $rec.name = $e.name }
                if ($e.pid) { $rec.pid = $e.pid }
            }
        }
    }

    foreach ($rec in $map.Values) {
        if ($rec.lastEvent -eq 'end') {
            # closed on purpose, unless it happened as part of a shutdown
            $rec.cut = (Test-WithinShutdown ([DateTimeOffset]::FromUnixTimeMilliseconds($rec.endedAt)) $shutdowns)
        } else {
            # never ended: only a survivor if it predates this boot
            $rec.cut = ($rec.updatedAt -lt $bootTime)
        }
    }
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

function Select-Candidates {
    param($Opts)
    $since = if ($Opts['since']) { ConvertTo-TimeSpan ([string]$Opts['since']) } else { [TimeSpan]::FromHours(24) }
    $cutoff = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - [int64]$since.TotalMilliseconds
    $kinds = Resolve-Kinds ([string]$Opts['kinds'])
    $alive = Get-AliveKeySet

    if ($Opts['cut-window']) { $script:CutWindowSeconds = [int]$Opts['cut-window'] * 60 }

    $horizon = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - [int64]([TimeSpan]::FromDays(30).TotalMilliseconds)
    $items = @(Read-SessionRecords | Where-Object {
        $_.id -and $_.cwd -and ($kinds -contains $_.kind) -and ($_.updatedAt -ge $cutoff)
    })

    if ($Opts['project']) {
        $projRoot = ([string]$Opts['project']).TrimEnd('\', '/')
        $items = @($items | Where-Object { $_.cwd.TrimEnd('\', '/') -ieq $projRoot -or $_.cwd -ilike "$projRoot\*" })
    }
    # drop ids whose transcript is gone; a transcript's mtime is the best
    # available "last activity" for a session that recorded no events
    $projects = Join-Path (Get-ClaudeConfigDir) 'projects'
    if (Test-Path -LiteralPath $projects) {
        $known = @{}
        try {
            foreach ($f in [IO.Directory]::EnumerateFiles($projects, '*.jsonl', 'AllDirectories')) {
                $known[[IO.Path]::GetFileNameWithoutExtension($f)] = $f
            }
        } catch { }
        # sessions with a transcript but no record at all (started before the
        # hooks existed) are rebuilt from the transcript itself
        $seen = @{}
        foreach ($it in $items) { $seen[$it.id] = $true }
        foreach ($id in $known.Keys) {
            if ($seen.ContainsKey($id)) { continue }
            if ($id -like 'agent-*') { continue }
            try {
                $mt = [DateTimeOffset](Get-Item -LiteralPath $known[$id]).LastWriteTimeUtc
            } catch { continue }
            if ($mt.ToUnixTimeMilliseconds() -lt $cutoff) { continue }
            $cwd = ''
            try {
                foreach ($ln in (Get-Content -LiteralPath $known[$id] -TotalCount 40 -ErrorAction Stop)) {
                    try { $o = $ln | ConvertFrom-Json } catch { continue }
                    if ($o.cwd) { $cwd = [string]$o.cwd; break }
                }
            } catch { }
            if (-not $cwd) { continue }
            $items += [pscustomobject]@{
                id = $id; cwd = $cwd; name = ''; kind = 'interactive'
                startedAt = $mt.ToUnixTimeMilliseconds(); updatedAt = $mt.ToUnixTimeMilliseconds()
                pid = 0; endedAt = 0; lastEvent = 'start'; idledAt = 0
                cut = ($mt.ToUnixTimeMilliseconds() -lt $script:BootTime)
            }
        }

        $items = @($items | Where-Object { $known.ContainsKey($_.id) } | ForEach-Object {
            $mt = 0
            try { $mt = [DateTimeOffset](Get-Item -LiteralPath $known[$_.id]).LastWriteTimeUtc } catch { }
            if ($mt) {
                $v = $mt.ToUnixTimeMilliseconds()
                if ($v -gt $_.updatedAt) { $_.updatedAt = $v }
            }
            $_
        })
    }

    $script:TotalCandidates = $items.Count
    $script:MissingCwd = @()
    $items = @($items | Where-Object {
        if (Test-Path -LiteralPath $_.cwd -PathType Container) { $true }
        else { $script:MissingCwd += $_.cwd; $false }
    })

    if ($Opts['any-state'] -ne $true) { $items = @($items | Where-Object { $_.cut }) }
    if ($Opts['include-open'] -ne $true) {
        $items = @($items | Where-Object { -not (Test-SessionAlive $_ $alive) })
    }

    # freshest first; a session interrupted mid-turn only breaks ties
    $items = @($items | Sort-Object `
        @{ Expression = { [int64]$_.updatedAt }; Descending = $true },
        @{ Expression = { if ($_.idledAt -and $_.idledAt -ge $_.startedAt) { 1 } else { 0 } } })

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

    $limit = if ($Opts['all'] -eq $true) { 0 } elseif ($Opts['limit']) { [int]$Opts['limit'] } else { 30 }
    if ($limit -gt 0) { $items = @($items | Select-Object -First $limit) }
    return $items
}

function New-LaunchCommand {
    param($Entry, $Opts)
    $cwd = "'" + ($Entry.cwd -replace "'", "''") + "'"
    $flags = ''
    if ($Opts['yolo'] -eq $true) { $flags = ' --dangerously-skip-permissions' }
    $text = if ($Opts.ContainsKey('prompt')) { [string]$Opts['prompt'] } else { 'Continue from where you left off.' }
    $prompt = if ($text) { ' "' + ($text -replace '"', '\"') + '"' } else { '' }
    $self = Join-Path $script:AppDir 'bin\encore.ps1'
    $inner = "Set-Location -LiteralPath $cwd; claude --resume $($Entry.id)$flags$prompt; & '$self' _end $($Entry.id)"
    $title = if ($Entry.name) { $Entry.name } else { Split-Path -Leaf $Entry.cwd }
    if ($title.Length -gt 40) { $title = $title.Substring(0, 39) + [char]0x2026 }

    if ($Opts['mode'] -eq 'background') {
        return [pscustomobject]@{ Kind = 'bg'; Inner = $inner; Argv = @() }
    }

    $useWt = ($Opts['mode'] -eq 'windows') -and (Get-Command wt.exe -ErrorAction SilentlyContinue)
    if (-not $useWt) {
        return [pscustomobject]@{ Kind = 'process'; Inner = $inner; Argv = @() }
    }
    $mode = 'new-window'
    $argv = @('-w', '0', $mode, '-d', $Entry.cwd, '--title', "encore: $title", '--',
              'powershell.exe', '-NoExit', '-Command', $inner)
    return [pscustomobject]@{ Kind = 'wt'; Inner = $inner; Argv = $argv }
}

function Get-StateLabel {
    param($Entry, $Alive)
    if (Test-SessionAlive $Entry $Alive) { return 'open' }
    if ($Entry.cut) {
        if ($Entry.idledAt -and $Entry.idledAt -ge $Entry.startedAt) { return 'idle' }
        return 'busy'
    }
    return 'closed'
}

function Show-Plan {
    param($Items)
    $alive = Get-AliveKeySet
    $i = 0
    foreach ($e in $Items) {
        $i++
        '{0,3}  {1,6}  {2,4}  {3}  {4}' -f $i, (Get-StateLabel $e $alive), (Format-Age $e.updatedAt), $e.cwd, $e.name
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
        $state = Get-StateLabel $e $alive
        $pre = if ($Opts['ids'] -eq $true) { $e.id.Substring(0, 8) } else { '' }
        '{0,3}  {1,6}  {2,4}  {3}  {4}  {5}' -f $i, $state, (Format-Age $e.updatedAt), $pre, $e.cwd, $e.name
    }
    Write-Info ''
    Write-Info ("{0} session(s)" -f $items.Count)
    if ($script:MissingCwd.Count) { Write-Warn ("{0} session(s) skipped: folder gone" -f $script:MissingCwd.Count) }
}

function Start-SessionWindow {
    param($Entry, $Opts)
    Start-Process powershell.exe -ArgumentList '-NoExit', '-Command', (New-LaunchCommand $Entry $Opts).Inner | Out-Null
}

function Invoke-WindowBatch {
    <# One new terminal window, every session as a tab inside it. #>
    param($Items, $Opts)
    $argv = @('-w', '-1')
    $first = $true
    foreach ($e in $Items) {
        if (-not $first) { $argv += ';' }
        $first = $false
        $c = New-LaunchCommand $e $Opts
        $argv += @('new-tab', '-d', $e.cwd, '--title', "encore: $(if ($e.name) { $e.name } else { Split-Path -Leaf $e.cwd })", '--',
                   'powershell.exe', '-NoExit', '-Command', $c.Inner)
    }
    & wt.exe $argv | Out-Null
    $deadline = (Get-Date).AddSeconds(6)
    $live = $null
    do {
        Start-Sleep -Milliseconds 500
        $live = Get-CimInstance Win32_Process -Filter "Name='claude.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -like "*--resume $($Items[0].id)*" }
    } until ($live -or (Get-Date) -gt $deadline)
    return [bool]$live
}

function Invoke-Restore {
    param($Opts)
    $Opts['mode'] = Resolve-Mode $Opts
    $promptText = if ($Opts.ContainsKey('prompt')) { [string]$Opts['prompt'] } else { 'Continue from where you left off.' }

    $items = @(Select-Candidates $Opts)
    if ($items.Count -eq 0) { Exit-With 0 'nothing to restore' }
    if ($script:MissingCwd.Count) { Write-Warn ("{0} session(s) skipped: folder gone" -f $script:MissingCwd.Count) }

    Write-Info ('{0} session(s) to reopen [{1} mode]:' -f $items.Count, $Opts['mode'])
    Show-Plan $items
    if ($script:TotalCandidates -gt $items.Count) {
        Write-Info ("  ... {0} more matching, use --all or a wider --limit" -f ($script:TotalCandidates - $items.Count))
    }
    Write-Info ''

    if ($Opts['dry-run'] -eq $true) {
        if ($Opts['mode'] -eq 'window') {
            $parts = @('wt.exe', '-w', '-1')
            $first = $true
            foreach ($e in $items) {
                if (-not $first) { $parts += ';' }
                $first = $false
                $parts += @('new-tab', '-d', $e.cwd, '--', 'powershell.exe', '-NoExit', '-Command',
                            (New-LaunchCommand $e $Opts).Inner)
            }
            Write-Info ('  ' + ($parts -join ' '))
        }
        foreach ($e in $items) {
            if ($Opts['mode'] -eq 'window') { continue }
            $c = New-LaunchCommand $e $Opts
            switch ($c.Kind) {
                'wt'    { Write-Info ('  wt.exe ' + ($c.Argv -join ' ')) }
                'bg'    { Write-Info ('  claude --resume {0} --bg "{1}"' -f $e.id, $promptText) }
                default { Write-Info ('  powershell -NoExit -Command "' + $c.Inner + '"') }
            }
        }
        Exit-With 0 'dry run: nothing launched'
    }

    if ($Opts['yes'] -ne $true) {
        $answer = 'y'
        try { $answer = Read-Host ("Restore {0} session(s)? [Y/n]" -f $items.Count) } catch { }
        if ($answer -match '^\s*(n|no)\s*$') { Exit-With 0 'cancelled' }
    }

    $claude = Get-ClaudePath
    $opened = 0

    if ($Opts['mode'] -eq 'window') {
        if (Get-Command wt.exe -ErrorAction SilentlyContinue) {
            if (Invoke-WindowBatch $items $Opts) {
                Exit-With 0 ("reopened {0} session(s) in one new window" -f $items.Count)
            }
            Write-Warn 'Windows Terminal did not start the commands; opening separate windows instead'
        }
        foreach ($e in $items) {
            try { Start-SessionWindow $e $Opts; $opened++ } catch { Write-Warn ("could not open {0}" -f $e.cwd) }
        }
        Exit-With 0 ("reopened {0} session(s)" -f $opened)
    }

    $warnedFallback = $false
    foreach ($e in $items) {
        $c = New-LaunchCommand $e $Opts
        try {
            switch ($c.Kind) {
                'bg' {
                    Push-Location -LiteralPath $e.cwd
                    $prevEap = $ErrorActionPreference
                    $ErrorActionPreference = 'Continue'
                    try { $out = & $claude --resume $e.id --bg $promptText 2>&1 }
                    finally { $ErrorActionPreference = $prevEap; Pop-Location }
                    $plain = (($out -join ' ') -replace ([char]27 + '\[[0-9;]*m'), '')
                    $short = [regex]::Match($plain, 'claude attach ([0-9a-f]{8})').Groups[1].Value
                    $copy = [regex]::Match($plain, 'copy as ([0-9a-f]{8})').Groups[1].Value
                    if (-not $short) { throw ($plain -replace '\s+', ' ') }
                    $note = if ($copy) { " (copy $copy)" } else { '' }
                    Write-Info ('  running in background: claude attach {0}{1}  ({2})' -f $short, $note, $e.cwd)
                    $opened++
                }
                'wt' {
                    & wt.exe $c.Argv | Out-Null
                    $deadline = (Get-Date).AddSeconds(4)
                    do { Start-Sleep -Milliseconds 400 } until ((Get-Date) -gt $deadline)
                    $live = Get-CimInstance Win32_Process -Filter "Name='claude.exe'" -ErrorAction SilentlyContinue |
                        Where-Object { $_.CommandLine -like "*--resume $($e.id)*" }
                    if (-not $live -and -not $warnedFallback) {
                        Write-Warn 'Windows Terminal did not start the command; falling back to plain windows'
                        $warnedFallback = $true
                    }
                    if (-not $live) { Start-SessionWindow $e $Opts }
                    $opened++
                }
                default { Start-SessionWindow $e $Opts; $opened++ }
            }
        } catch {
            Write-Warn ("could not open {0}: {1}" -f $e.cwd, $_.Exception.Message)
        }
    }
    Exit-With 0 ("reopened {0} session(s)" -f $opened)
}

function Invoke-Doctor {
    $bad = $false
    foreach ($c in 'claude', 'powershell.exe', 'wt.exe') {
        $found = Get-Command $c -ErrorAction SilentlyContinue
        if ($found) { Write-Info "[ok]   $c" } else { Write-Info "[     ] $c"; if ($c -eq 'claude') { $bad = $true } }
    }
    $all = @(Read-SessionRecords)
    Write-Info ("[info] {0} live, {1} cut-off, {2} closed, mode {3}" -f
        @(Get-LiveSessions).Count, @($all | Where-Object { $_.cut }).Count, @($all | Where-Object { -not $_.cut }).Count, (Resolve-Mode @{}))
    $idx = Join-Path $script:AppDir 'index.jsonl'
    $lines = if (Test-Path -LiteralPath $idx) { @(Get-Content -LiteralPath $idx).Count } else { 0 }
    if ($lines) { Write-Info "[ok]   hook index has $lines record(s)" }
    else { Write-Info '[ ]    hook index empty — run: encore install' }
    if ($bad) { exit 1 }
}

function Invoke-Install {
    param($Opts)
    $here = $PSScriptRoot
    $bin = Join-Path $script:AppDir 'bin'
    New-Item -ItemType Directory -Force -Path $bin | Out-Null
    Copy-Item -LiteralPath (Join-Path $here 'encore.ps1') -Destination $bin -Force
    Copy-Item -LiteralPath (Join-Path $here 'encore-hook.ps1') -Destination $bin -Force
    $shim = "@echo off`r`npowershell.exe -NoProfile -ExecutionPolicy Bypass -File `"%~dp0encore.ps1`" %*`r`n"
    Set-Content -LiteralPath (Join-Path $bin 'encore.cmd') -Value $shim -Encoding ASCII -NoNewline

    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ($userPath -notlike "*$bin*") {
        [Environment]::SetEnvironmentVariable('Path', ($userPath.TrimEnd(';') + ';' + $bin), 'User')
        Write-Info "added $bin to your user PATH (open a new terminal to use it)"
    }

    $settingsFile = Join-Path (Get-ClaudeConfigDir) 'settings.json'
    $hookCmd = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $bin 'encore-hook.ps1') + '"'
    $cfg = if (Test-Path -LiteralPath $settingsFile) { Get-Content -LiteralPath $settingsFile -Raw -Encoding UTF8 | ConvertFrom-Json } else { [pscustomobject]@{} }
    if (-not $cfg.PSObject.Properties['hooks']) { $cfg | Add-Member -NotePropertyName hooks -NotePropertyValue ([pscustomobject]@{}) }
    if (-not $cfg.hooks.PSObject.Properties['SessionStart']) { $cfg.hooks | Add-Member -NotePropertyName SessionStart -NotePropertyValue @() }
    $wanted = @(
        @{ event = 'SessionStart'; matcher = 'startup|resume|fork' },
        @{ event = 'SessionEnd'; matcher = '*' },
        @{ event = 'Stop'; matcher = '*' }
    )
    $added = 0
    foreach ($w in $wanted) {
        if (-not $cfg.hooks.PSObject.Properties[$w.event]) {
            $cfg.hooks | Add-Member -NotePropertyName $w.event -NotePropertyValue @()
        }
        $exists = @($cfg.hooks.($w.event)) | Where-Object { (@($_.hooks) | Where-Object { $_.command -like '*encore-hook.ps1*' }) }
        if (-not $exists) {
            $cfg.hooks.($w.event) = @($cfg.hooks.($w.event)) + [pscustomobject]@{
                matcher = $w.matcher
                hooks = @([pscustomobject]@{ type = 'command'; command = $hookCmd; timeout = 10 })
            }
            $added++
        }
    }
    if ($added) {
        [IO.File]::WriteAllText($settingsFile, ($cfg | ConvertTo-Json -Depth 20), (New-Object Text.UTF8Encoding($false)))
        Write-Info "registered $added hook(s) in $settingsFile"
    }

    $seeded = 0
    foreach ($s in Get-LiveSessions) {
        if (-not $s.id -or -not $s.cwd) { continue }
        Add-IndexLine $s.id $s.cwd $s.startedAt $s.kind
        $seeded++
    }
    if ($seeded) { Write-Info "seeded $seeded already-open session(s) into the index" }
    Write-Info 'installed. Try: encore list'
}

function Invoke-Uninstall {
    $settingsFile = Join-Path (Get-ClaudeConfigDir) 'settings.json'
    if (Test-Path -LiteralPath $settingsFile) {
        try {
            $cfg = Get-Content -LiteralPath $settingsFile -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($evn in 'SessionStart', 'SessionEnd', 'Stop') {
                if (-not $cfg.hooks.PSObject.Properties[$evn]) { continue }
                $cfg.hooks.($evn) = @(@($cfg.hooks.($evn)) | Where-Object {
                    -not (@($_.hooks) | Where-Object { $_.command -like '*encore-hook.ps1*' })
                })
            }
            [IO.File]::WriteAllText($settingsFile, ($cfg | ConvertTo-Json -Depth 20), (New-Object Text.UTF8Encoding($false)))
        } catch { Write-Warn "could not edit $settingsFile; remove the encore hook by hand" }
    }
    $bin = Join-Path $script:AppDir 'bin'
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ($userPath -like "*$bin*") {
        $new = ($userPath -split ';' | Where-Object { $_ -and $_ -ne $bin }) -join ';'
        [Environment]::SetEnvironmentVariable('Path', $new, 'User')
    }
    Remove-Item -LiteralPath $bin -Recurse -Force -ErrorAction SilentlyContinue
    Exit-With 0 'uninstalled (hook index kept in %LOCALAPPDATA%\Encore)'
}

# ------------------------------------------------------------------ main ----

$opts = Get-Opt $Rest

switch ($Command.ToLower()) {
    'list'      { Invoke-List $opts }
    'restore'   { Invoke-Restore $opts }
    'doctor'    { Invoke-Doctor }
    'install'   { Invoke-Install $opts }
    'uninstall' { Invoke-Uninstall }
    'config' {
        $pos = @($opts['@'])
        if (-not $pos.Count) {
            $cfg = Get-Config
            if (-not $cfg.Count) { Exit-With 0 'no config set (default: mode = window)' }
            foreach ($k in $cfg.Keys) { Write-Info ("{0} = {1}" -f $k, $cfg[$k]) }
            exit 0
        }
        if ($pos.Count -eq 1) {
            $cfg = Get-Config
            Exit-With 0 ("{0} = {1}" -f $pos[0], $(if ($cfg.ContainsKey($pos[0])) { $cfg[$pos[0]] } else { '' }))
        }
        if ($pos[0] -eq 'mode' -and @('tabs', 'window', 'windows', 'background') -notcontains $pos[1]) {
            Exit-With 1 'mode must be tabs | window | windows | background'
        }
        Set-ConfigKey $pos[0] $pos[1]
        Exit-With 0 ("{0} = {1}" -f $pos[0], $pos[1])
    }
    'close'     {
        $items = @(Select-Candidates $opts)
        if ($items.Count -eq 0) { Exit-With 0 'nothing to close' }
        Show-Plan $items
        if ($opts['yes'] -ne $true) {
            $a = 'y'
            try { $a = Read-Host ("Mark {0} session(s) as closed? [Y/n]" -f $items.Count) } catch { }
            if ($a -match '^\s*(n|no)\s*$') { Exit-With 0 'cancelled' }
        }
        $idx = Join-Path $script:AppDir 'index.jsonl'
        foreach ($e in $items) {
            $line = [pscustomobject]@{ ev = 'end'; id = $e.id; ts = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds(); reason = 'manual' } | ConvertTo-Json -Compress
            [IO.File]::AppendAllText($idx, $line + "`n", (New-Object Text.UTF8Encoding($false)))
        }
        Exit-With 0 ("closed {0} session(s)" -f $items.Count)
    }
    '_end'      {
        $eid = @($opts['@'])[0]
        if ($eid) {
            $line = [pscustomobject]@{ ev = 'end'; id = [string]$eid; ts = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds(); reason = 'shell' } | ConvertTo-Json -Compress
            New-Item -ItemType Directory -Force -Path $script:AppDir | Out-Null
            [IO.File]::AppendAllText((Join-Path $script:AppDir 'index.jsonl'), $line + "`n", (New-Object Text.UTF8Encoding($false)))
        }
        exit 0
    }
    'version'   { Exit-With 0 "encore $script:Version" }
    default {
@"
encore $script:Version - reopen the Claude Code sessions a reboot cut off

  encore list                      show sessions (default: last 7 days)
  encore restore                   reopen every closed one, a tab each
  encore restore --only 1,3        reopen selected ones
  encore restore --dry-run         print the commands only
  encore restore --mode background reopen with no terminal (claude attach <id>)
  encore config [key value]        show or set config (e.g. config mode windows)
  encore close [filters]           mark cut-off sessions as closed (default: all now listed)
  encore doctor                    check the install
  encore install                   put encore on PATH and register the hook
  encore uninstall                 undo install

filters: --since 30m|12h|2d|7d (default 24h)  --project <dir>  --limit N (default 30)  --all  --include-open
         --any-state (also list sessions you closed on purpose)  --cut-window <minutes>
         --prompt "text" (sent on resume; default "Continue from where you left off.", "" = none)
         --mode window|tabs|windows|background  (default window; --tabs/--windows/--background)
         --yes (skip the confirmation)   --all (no 30-session cap)
         --tabs / --windows / --background  one-off mode override
         --ids (show session ids in list)  --kinds interactive,background (default interactive)
         --yolo (add --dangerously-skip-permissions)
"@ | Write-Host
    }
}
