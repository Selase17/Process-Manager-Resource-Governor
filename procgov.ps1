#Requires -Version 5.1
<#
.SYNOPSIS
    procgov.ps1 — Process Manager & Resource Governor (Windows)

.DESCRIPTION
    Monitors running processes and automatically terminates any process that
    exceeds a configurable CPU or memory threshold for more than N seconds.
    Every kill action is logged with a timestamp, PID, name, and reason.

.PARAMETER Cpu
    CPU threshold percentage (default: 80)

.PARAMETER Mem
    Memory threshold percentage (default: 70)

.PARAMETER Duration
    Seconds a process must exceed threshold before being killed (default: 30)

.PARAMETER Interval
    How often to poll processes in seconds (default: 5)

.PARAMETER Config
    Path to config file (default: procgov.conf)

.PARAMETER Whitelist
    Path to whitelist file (default: whitelist.txt)

.PARAMETER Log
    Path to log file (default: procgov.log)

.PARAMETER DryRun
    Show what WOULD be killed without actually killing

.PARAMETER Summary
    Generate a weekly summary from the log file and exit

.PARAMETER Help
    Show this help message

.EXAMPLE
    # Run with defaults (as Administrator)
    .\procgov.ps1

.EXAMPLE
    # Preview kills without acting
    .\procgov.ps1 -DryRun

.EXAMPLE
    # Custom thresholds
    .\procgov.ps1 -Cpu 90 -Mem 85 -Duration 60

.EXAMPLE
    # Use a custom config and log path
    .\procgov.ps1 -Config C:\etc\procgov.conf -Log C:\logs\procgov.log

.NOTES
    Requirements: PowerShell 5.1+, Administrator privileges recommended
    Stretch goals: Windows balloon notifications (System.Windows.Forms)
#>

[CmdletBinding()]
param(
    [int]$Cpu       = -1,   # -1 = not provided by user (sentinel)
    [int]$Mem       = -1,
    [int]$Duration  = -1,
    [int]$Interval  = -1,
    [string]$Config    = '',
    [string]$Whitelist = '',
    [string]$Log       = '',
    [switch]$DryRun,
    [switch]$Summary,
    [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# =============================================================================
# STEP 1 — CONSTANTS & DEFAULTS
# (Planning Step 7: Config file with CLI overrides — set safe defaults first)
# =============================================================================

$script:ScriptName    = 'procgov.ps1'
$script:ScriptVersion = '1.0.0'

# Default thresholds — all overridable via config file or CLI flags
$script:CpuThreshold = 80       # Kill if CPU% exceeds this...
$script:MemThreshold = 70       # ...or MEM% exceeds this...
$script:Duration     = 30       # ...for longer than this many seconds
$script:Interval     = 5        # Poll every N seconds
$script:IsDryRun     = $false   # When true: report only, never kill

# Default file paths — resolved relative to the script's own directory
$script:ConfigFile    = Join-Path $PSScriptRoot 'procgov.conf'
$script:WhitelistFile = Join-Path $PSScriptRoot 'whitelist.txt'
$script:LogFile       = Join-Path $PSScriptRoot 'procgov.log'

# Total physical RAM in bytes — cached once at startup, reused every loop iteration
$script:TotalRamBytes = 0

# Number of logical CPU cores — used to normalise CPU% to 0–100 (Task Manager style)
$script:LogicalCores = [Environment]::ProcessorCount

# =============================================================================
# STEP 2 — STATE TRACKING SETUP
# (Planning Step 3: The hard part — duration tracking via hashtables)
#
# We use two hashtables keyed by PID:
#   OverThresholdSince[PID] = [datetime] when it first exceeded threshold
#   TrackedName[PID]        = process name at time of first detection
#
# Storing the name alongside the PID solves the PID reuse problem:
# if the name changes, we know it's a different process and reset the timer.
# =============================================================================

$script:OverThresholdSince = @{}   # PID → [datetime] of first threshold breach
$script:TrackedName        = @{}   # PID → process name at time of detection
$script:WhitelistNames     = @()   # Array of whitelisted process names

# Shared output state — set by Test-Threshold and Test-ShouldKill
$script:ThresholdReason = ''
$script:ElapsedSeconds  = 0

# =============================================================================
# STEP 3 — HELPER: LOGGING & OUTPUT
# (Planning Step 8: Structured log format — human-readable and parseable)
#
# Log format (identical to the Linux version for cross-platform compatibility):
# [YYYY-MM-DD HH:MM:SS] KILLED | PID=X | NAME=Y | CPU=Z% | MEM=W% | DURATION=Ns | REASON=...
# =============================================================================

function Write-LogInfo {
    param([string]$Message)
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Write-Host "[INFO]  $ts — $Message" -ForegroundColor Cyan
}

function Write-LogWarn {
    param([string]$Message)
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Write-Host "[WARN]  $ts — $Message" -ForegroundColor Yellow
}

function Write-LogError {
    param([string]$Message)
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Write-Host "[ERROR] $ts — $Message" -ForegroundColor Red
}

# Write a structured kill entry to the log file
# Args: Pid Name Cpu Mem ElapsedSec Reason
function Write-LogKill {
    param(
        [int]$KillPid,
        [string]$Name,
        [int]$CpuPct,
        [int]$MemPct,
        [int]$ElapsedSec,
        [string]$Reason
    )
    $ts    = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $entry = "[$ts] KILLED | PID=$KillPid | NAME=$Name | CPU=${CpuPct}% | MEM=${MemPct}% | DURATION=${ElapsedSec}s | REASON=$Reason"

    # Append to log file — create it if it doesn't exist
    Add-Content -Path $script:LogFile -Value $entry -ErrorAction SilentlyContinue
    Write-Host "[KILL]  $entry" -ForegroundColor Red
}

# Dry-run variant — same format but prefixed with DRY-RUN, never written to log file
function Write-DryRunReport {
    param(
        [int]$KillPid,
        [string]$Name,
        [int]$CpuPct,
        [int]$MemPct,
        [int]$ElapsedSec,
        [string]$Reason
    )
    $ts    = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $entry = "[$ts] WOULD KILL | PID=$KillPid | NAME=$Name | CPU=${CpuPct}% | MEM=${MemPct}% | DURATION=${ElapsedSec}s | REASON=$Reason"
    Write-Host "[DRY-RUN] $entry" -ForegroundColor Yellow
}

# =============================================================================
# STEP 4 — LOAD CONFIG FILE
# (Planning Step 7, Option C: Load file first, CLI flags override after)
#
# Config file uses KEY=VALUE format — the same procgov.conf works on both
# Linux (procgov.sh) and Windows (procgov.ps1).
# Missing config file is not fatal — we fall back to built-in defaults.
# =============================================================================

function Load-Config {
    if (-not (Test-Path $script:ConfigFile)) {
        Write-LogWarn "Config file '$($script:ConfigFile)' not found — using built-in defaults."
        return
    }

    Write-LogInfo "Loading config from '$($script:ConfigFile)'..."

    Get-Content $script:ConfigFile -ErrorAction Stop | ForEach-Object {
        $line = $_.Trim()

        # Skip blank lines and comments
        if ($line -eq '' -or $line.StartsWith('#')) { return }

        # Match KEY=VALUE (optional whitespace around =)
        if ($line -match '^([A-Z_]+)\s*=\s*(.*)$') {
            $key   = $Matches[1]
            $value = $Matches[2].Trim()

            switch ($key) {
                'CPU_THRESHOLD'  { $script:CpuThreshold  = [int]$value }
                'MEM_THRESHOLD'  { $script:MemThreshold  = [int]$value }
                'DURATION'       { $script:Duration       = [int]$value }
                'INTERVAL'       { $script:Interval       = [int]$value }
                'WHITELIST_FILE' { $script:WhitelistFile  = $value      }
                'LOG_FILE'       { $script:LogFile        = $value      }
                default          { Write-LogWarn "Unknown config key: '$key' — skipping." }
            }
        }
    }
}

# =============================================================================
# STEP 5 — APPLY CLI OVERRIDES
# (Planning Step 7: CLI flags win over config file — called after Load-Config)
#
# We use -1 as a sentinel for int params and '' for string params to distinguish
# "user passed this flag" from "user left it at the default".
# =============================================================================

function Apply-CliOverrides {
    # Integer flags: only override if the user actually passed them (sentinel = -1)
    if ($Cpu      -ge 0) { $script:CpuThreshold  = $Cpu      }
    if ($Mem      -ge 0) { $script:MemThreshold  = $Mem      }
    if ($Duration -ge 0) { $script:Duration       = $Duration }
    if ($Interval -ge 0) { $script:Interval       = $Interval }

    # String flags: only override if non-empty
    if ($Whitelist -ne '') { $script:WhitelistFile = $Whitelist }
    if ($Log       -ne '') { $script:LogFile       = $Log       }

    # Switch flags: set unconditionally (they're false by default if not passed)
    if ($DryRun) { $script:IsDryRun = $true }
}

# =============================================================================
# STEP 6 — VALIDATE CONFIGURATION
# (Planning Step 6: Edge cases — guard against bad values before the loop)
# =============================================================================

function Validate-Config {
    # Guard: INTERVAL must be at least 1 to prevent a busy infinite loop
    if ($script:Interval -lt 1) {
        Write-LogError "INTERVAL must be >= 1 second. Got: $($script:Interval)"
        exit 1
    }

    # Guard: CPU threshold must be between 1 and 100
    if ($script:CpuThreshold -lt 1 -or $script:CpuThreshold -gt 100) {
        Write-LogError "CPU_THRESHOLD must be between 1 and 100. Got: $($script:CpuThreshold)"
        exit 1
    }

    # Guard: MEM threshold must be between 1 and 100
    if ($script:MemThreshold -lt 1 -or $script:MemThreshold -gt 100) {
        Write-LogError "MEM_THRESHOLD must be between 1 and 100. Got: $($script:MemThreshold)"
        exit 1
    }

    # Guard: DURATION must be a positive integer
    if ($script:Duration -lt 1) {
        Write-LogError "DURATION must be a positive integer. Got: $($script:Duration)"
        exit 1
    }

    # Guard: ensure log file directory exists (create it if needed)
    $logDir = Split-Path $script:LogFile -Parent
    if ($logDir -ne '' -and -not (Test-Path $logDir)) {
        try {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        } catch {
            Write-LogError "Cannot create log directory: $logDir"
            exit 1
        }
    }

    # Guard: warn if not running as Administrator (some processes may be unreadable)
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
    if (-not $isAdmin) {
        Write-LogWarn "Not running as Administrator. Some processes may not be visible or killable."
    }
}

# =============================================================================
# STEP 7 — LOAD WHITELIST
# (Planning Step 5: load_whitelist — read process names that must never be killed)
#
# Edge case: missing whitelist file is a warning, not a fatal error.
# We default to an empty whitelist and continue.
# =============================================================================

function Load-Whitelist {
    if (-not (Test-Path $script:WhitelistFile)) {
        Write-LogWarn "Whitelist file '$($script:WhitelistFile)' not found — no processes are protected."
        return
    }

    Write-LogInfo "Loading whitelist from '$($script:WhitelistFile)'..."

    Get-Content $script:WhitelistFile -ErrorAction Stop | ForEach-Object {
        $line = $_.Trim()
        if ($line -eq '' -or $line.StartsWith('#')) { return }
        $script:WhitelistNames += $line
    }

    $names = if ($script:WhitelistNames.Count -gt 0) { $script:WhitelistNames -join ', ' } else { 'none' }
    Write-LogInfo "Whitelist loaded: $($script:WhitelistNames.Count) protected process(es): $names"
}

# =============================================================================
# STEP 8 — IS_WHITELISTED CHECK
# (Planning Step 5: is_whitelisted — called per-process before any action)
#
# Returns $true if the process name is in the whitelist, $false otherwise.
# =============================================================================

function Test-Whitelisted {
    param([string]$Name)
    return $script:WhitelistNames -contains $Name
}

# =============================================================================
# STEP 9 — GET PROCESSES
# (Planning Step 5: get_processes — snapshot all running processes)
#
# Uses Win32_PerfFormattedData_PerfProc_Process for per-process CPU%
# and Get-Process for working set and process age.
#
# CPU normalisation: Windows perf counters report CPU% across all cores
# (so a process maxing one core on an 8-core machine shows 100%, not 12.5%).
# We divide by logical core count to match Task Manager's 0–100% display.
#
# Edge case: processes younger than DURATION seconds are skipped —
# they can't have been over threshold long enough to warrant killing.
# This also filters out the ps/awk/sleep equivalents spawned per loop.
# =============================================================================

function Get-MonitoredProcesses {
    $now = Get-Date

    # Query per-process CPU% from the Windows performance counter subsystem.
    # IDProcess is the PID; PercentProcessorTime is the raw (unnormalised) value.
    $cpuData = @{}
    try {
        Get-CimInstance -ClassName Win32_PerfFormattedData_PerfProc_Process `
                        -ErrorAction Stop |
        Where-Object { $_.IDProcess -gt 0 } |
        ForEach-Object {
            # Normalise to 0–100 across all cores, capped at 100
            $normalised = [int][Math]::Min(100, [Math]::Round(
                $_.PercentProcessorTime / $script:LogicalCores
            ))
            $cpuData[[int]$_.IDProcess] = $normalised
        }
    } catch {
        Write-LogWarn "Could not query CPU performance counters: $_"
    }

    $results = [System.Collections.Generic.List[PSCustomObject]]::new()

    Get-Process -ErrorAction SilentlyContinue | ForEach-Object {
        $proc     = $_
        $procPid  = $proc.Id
        $procName = $proc.ProcessName

        # Skip the script's own PowerShell host process
        if ($procPid -eq $PID) { return }

        # Calculate process age — skip processes younger than DURATION seconds
        # (they can't possibly have been over threshold long enough)
        $age = $script:Duration  # default: assume old enough if StartTime is inaccessible
        try {
            if ($proc.StartTime) {
                $age = ($now - $proc.StartTime).TotalSeconds
            }
        } catch {
            # Some system/protected processes don't expose StartTime — leave default
        }

        if ($age -lt $script:Duration) { return }

        # CPU% from performance counter lookup, default 0 if not found
        $cpuPct = if ($cpuData.ContainsKey($procPid)) { $cpuData[$procPid] } else { 0 }

        # MEM% = process working set / total RAM * 100, capped at 100
        $memPct = if ($script:TotalRamBytes -gt 0) {
            [int][Math]::Min(100, [Math]::Round($proc.WorkingSet64 / $script:TotalRamBytes * 100))
        } else { 0 }

        $results.Add([PSCustomObject]@{
            Pid  = $procPid
            Name = $procName
            Cpu  = $cpuPct
            Mem  = $memPct
        })
    }

    return $results
}

# =============================================================================
# STEP 10 — CHECK THRESHOLD
# (Planning Step 5: check_threshold — does this process exceed CPU or MEM limit?)
#
# Returns $true if over threshold, $false if within limits.
# Sets $script:ThresholdReason for use in log messages.
# =============================================================================

function Test-Threshold {
    param([int]$CpuPct, [int]$MemPct)

    $reasons = @()
    if ($CpuPct -ge $script:CpuThreshold) { $reasons += "CPU=${CpuPct}% >= $($script:CpuThreshold)%" }
    if ($MemPct -ge $script:MemThreshold) { $reasons += "MEM=${MemPct}% >= $($script:MemThreshold)%" }

    if ($reasons.Count -gt 0) {
        $script:ThresholdReason = $reasons -join ' AND '
        return $true   # over threshold
    }

    $script:ThresholdReason = ''
    return $false   # within limits
}

# =============================================================================
# STEP 11 — TRACK PROCESS
# (Planning Step 3 & 5: track_process — the core of duration tracking)
#
# Called when a process is over threshold. Records the first-seen datetime
# in OverThresholdSince[PID] and the name in TrackedName[PID].
#
# PID reuse guard: if the stored name doesn't match the current name,
# the old PID was recycled — reset the timer for the new process.
# =============================================================================

function Track-Process {
    param([int]$TrackPid, [string]$Name)

    if ($script:OverThresholdSince.ContainsKey($TrackPid)) {
        # PID is already being tracked — check for PID reuse
        if ($script:TrackedName[$TrackPid] -ne $Name) {
            Write-LogWarn "PID $TrackPid name changed ($($script:TrackedName[$TrackPid]) → $Name). Resetting timer (PID reuse detected)."
            $script:OverThresholdSince[$TrackPid] = Get-Date
            $script:TrackedName[$TrackPid]        = $Name
        }
        # Otherwise: same process, same PID — timer keeps running, nothing to do
    } else {
        # First time we've seen this PID over threshold — start the clock
        $script:OverThresholdSince[$TrackPid] = Get-Date
        $script:TrackedName[$TrackPid]        = $Name
    }
}

# =============================================================================
# STEP 12 — SHOULD KILL
# (Planning Step 5: should_kill — has the process been over threshold long enough?)
#
# Compares current time against the first-seen datetime.
# Returns $true if duration exceeded, $false if still within grace period.
# Sets $script:ElapsedSeconds for use in log messages.
# =============================================================================

function Test-ShouldKill {
    param([int]$KillPid)

    $elapsed = (Get-Date) - $script:OverThresholdSince[$KillPid]
    $script:ElapsedSeconds = [int]$elapsed.TotalSeconds

    return $script:ElapsedSeconds -ge $script:Duration
}

# =============================================================================
# STEP 13 — KILL PROCESS
# (Planning Step 5: kill_process — attempt graceful stop, escalate to force kill)
#
# Windows equivalent of SIGTERM/SIGKILL strategy:
#   Stop-Process           → sends WM_CLOSE to GUI windows (graceful for GUI apps)
#   Stop-Process -Force    → calls TerminateProcess() immediately (force kill)
#
# Edge case: process may have died between detection and kill attempt.
# We check Get-Process first and handle the missing process gracefully.
# =============================================================================

function Invoke-KillProcess {
    param(
        [int]$KillPid,
        [string]$Name,
        [int]$CpuPct,
        [int]$MemPct,
        [string]$Reason
    )

    if ($script:IsDryRun) {
        Write-DryRunReport $KillPid $Name $CpuPct $MemPct $script:ElapsedSeconds $Reason
        # Remove from tracking so we don't keep reporting it every cycle
        $script:OverThresholdSince.Remove($KillPid)
        $script:TrackedName.Remove($KillPid)
        return
    }

    # Verify the process still exists before attempting to kill it
    $proc = Get-Process -Id $KillPid -ErrorAction SilentlyContinue
    if ($null -eq $proc) {
        Write-LogWarn "PID $KillPid ($Name) was already gone before kill attempt."
        $script:OverThresholdSince.Remove($KillPid)
        $script:TrackedName.Remove($KillPid)
        return
    }

    try {
        # Attempt graceful termination first (WM_CLOSE for GUI, passthrough for services)
        Stop-Process -Id $KillPid -ErrorAction Stop
        Write-LogKill $KillPid $Name $CpuPct $MemPct $script:ElapsedSeconds "$Reason (graceful)"

        # Give the process 3 seconds to exit cleanly
        Start-Sleep -Seconds 3

        # If still alive, force terminate (equivalent of SIGKILL)
        if (Get-Process -Id $KillPid -ErrorAction SilentlyContinue) {
            Stop-Process -Id $KillPid -Force -ErrorAction SilentlyContinue
            Write-LogWarn "PID $KillPid ($Name) did not exit after graceful stop — forced termination."
        }

        # Stretch goal: Windows balloon tip notification
        Send-Notification "procgov: Process Killed" "PID $KillPid ($Name) was killed.`nReason: $Reason"

    } catch {
        Write-LogWarn "PID $KillPid ($Name) could not be terminated: $_"
    }

    # Remove from tracking regardless of outcome
    $script:OverThresholdSince.Remove($KillPid)
    $script:TrackedName.Remove($KillPid)
}

# Stretch goal — Windows balloon tip via System.Windows.Forms
# Mirrors the notify-send stretch goal in procgov.sh
function Send-Notification {
    param([string]$Title, [string]$Message)
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
        Add-Type -AssemblyName System.Drawing        -ErrorAction SilentlyContinue
        $balloon                 = New-Object System.Windows.Forms.NotifyIcon
        $balloon.Icon            = [System.Drawing.SystemIcons]::Warning
        $balloon.Visible         = $true
        $balloon.BalloonTipTitle = $Title
        $balloon.BalloonTipText  = $Message
        $balloon.ShowBalloonTip(5000)
        Start-Sleep -Seconds 1
        $balloon.Dispose()
    } catch {
        # Notifications are a stretch goal — silently skip if unavailable
    }
}

# =============================================================================
# STEP 14 — MAIN LOOP
# (Planning Step 4: the data flow — this is where everything comes together)
#
# Flow per iteration:
#   1. Snapshot all processes (CPU%, MEM%, age)
#   2. For each process:
#      a. Skip if whitelisted
#      b. Check if over threshold
#      c. If over: track it, check duration, kill if duration exceeded
#      d. If under: remove from tracking (process recovered)
#   3. Sleep INTERVAL seconds
#   4. Repeat
# =============================================================================

function Start-MainLoop {
    Write-LogInfo "Starting process governor. CPU>=$($script:CpuThreshold)% | MEM>=$($script:MemThreshold)% | DURATION=$($script:Duration)s | INTERVAL=$($script:Interval)s"
    Write-LogInfo "Log file: $($script:LogFile)"
    if ($script:IsDryRun) {
        Write-LogWarn "DRY-RUN mode enabled — no processes will be killed."
    }

    # try/finally ensures the shutdown message prints on Ctrl+C
    try {
        while ($true) {
            # --- Snapshot: get all current processes ---
            $processes = Get-MonitoredProcesses

            foreach ($proc in $processes) {
                $procPid  = $proc.Pid
                $procName = $proc.Name
                $procCpu  = $proc.Cpu
                $procMem  = $proc.Mem

                # --- Decision: is this process whitelisted? ---
                if (Test-Whitelisted $procName) {
                    # Remove from tracking if it was previously tracked
                    # (e.g. threshold was lowered mid-run and it briefly appeared over limit)
                    if ($script:OverThresholdSince.ContainsKey($procPid)) {
                        $script:OverThresholdSince.Remove($procPid)
                        $script:TrackedName.Remove($procPid)
                    }
                    continue
                }

                # --- Decision: is this process over threshold? ---
                if (Test-Threshold $procCpu $procMem) {

                    # Start or continue tracking this PID
                    Track-Process $procPid $procName

                    # Check if it has been over threshold long enough to act
                    if (Test-ShouldKill $procPid) {
                        Invoke-KillProcess $procPid $procName $procCpu $procMem $script:ThresholdReason
                    } else {
                        # Still within grace period — show warning so user can see it building up
                        $remaining = $script:Duration - $script:ElapsedSeconds
                        Write-LogWarn "PID $procPid ($procName) over threshold [$($script:ThresholdReason)] for $($script:ElapsedSeconds)s — will act in ${remaining}s."
                    }

                } else {
                    # Process is back within limits — remove from tracking if it was being watched
                    if ($script:OverThresholdSince.ContainsKey($procPid)) {
                        $recoveryElapsed = [int]((Get-Date) - $script:OverThresholdSince[$procPid]).TotalSeconds
                        Write-LogInfo "PID $procPid ($procName) dropped below threshold after ${recoveryElapsed}s — removed from tracking."
                        $script:OverThresholdSince.Remove($procPid)
                        $script:TrackedName.Remove($procPid)
                    }
                }
            }

            Start-Sleep -Seconds $script:Interval
        }
    } finally {
        Write-LogInfo "Shutting down procgov. Goodbye."
    }
}

# =============================================================================
# STRETCH GOAL — WEEKLY SUMMARY
# (Planning Step 8: because the log format is structured, this is just regex + counting)
#
# Parses the log file for entries from the last 7 days and prints a summary:
# total kills and kills per process name, sorted by count descending.
# =============================================================================

function Show-WeeklySummary {
    if (-not (Test-Path $script:LogFile)) {
        Write-LogError "Log file '$($script:LogFile)' not found. No summary available."
        exit 1
    }

    $cutoff     = (Get-Date).AddDays(-7)
    $killCounts = @{}
    $total      = 0

    Get-Content $script:LogFile -ErrorAction Stop | ForEach-Object {
        if ($_ -notmatch 'KILLED') { return }

        # Extract timestamp: [YYYY-MM-DD HH:MM:SS]
        if ($_ -match '^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\]') {
            $entryDate = [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd HH:mm:ss', $null)
            if ($entryDate -lt $cutoff) { return }

            # Extract NAME=value (stops at space or pipe)
            if ($_ -match 'NAME=([^\s|]+)') {
                $name = $Matches[1]
                if (-not $killCounts.ContainsKey($name)) { $killCounts[$name] = 0 }
                $killCounts[$name]++
                $total++
            }
        }
    }

    Write-Host ''
    Write-Host ('=' * 40) -ForegroundColor White
    Write-Host '  Weekly Kill Summary — Last 7 Days'  -ForegroundColor White
    Write-Host ('=' * 40) -ForegroundColor White

    if ($total -eq 0) {
        Write-Host 'No processes were killed in the last 7 days.'
    } else {
        Write-Host "Total kills: $total"
        Write-Host ''
        Write-Host ('{0,-30} {1}' -f 'Process Name', 'Kill Count') -ForegroundColor White
        Write-Host ('{0,-30} {1}' -f '------------', '----------') -ForegroundColor White

        $killCounts.GetEnumerator() |
            Sort-Object Value -Descending |
            ForEach-Object {
                Write-Host ('{0,-30} {1}' -f $_.Key, $_.Value)
            }
    }

    Write-Host ('=' * 40) -ForegroundColor White
    Write-Host ''
}

# =============================================================================
# USAGE / HELP
# =============================================================================

function Show-Usage {
    Write-Host @"

$($script:ScriptName) v$($script:ScriptVersion) — Process Manager & Resource Governor (Windows)

USAGE:
  .\procgov.ps1 [OPTIONS]
  # Run as Administrator for full process visibility and kill rights

OPTIONS:
  -Cpu <percent>        CPU threshold % before tracking starts     (default: 80)
  -Mem <percent>        Memory threshold % before tracking starts  (default: 70)
  -Duration <seconds>   Seconds over threshold before kill         (default: 30)
  -Interval <seconds>   Polling interval in seconds                (default: 5)
  -Config <file>        Path to config file                        (default: procgov.conf)
  -Whitelist <file>     Path to whitelist file                     (default: whitelist.txt)
  -Log <file>           Path to log file                           (default: procgov.log)
  -DryRun               Report what WOULD be killed, without acting
  -Summary              Print a weekly kill summary from the log and exit
  -Help                 Show this help message

EXAMPLES:
  .\procgov.ps1
  .\procgov.ps1 -Cpu 90 -Mem 80 -Duration 60
  .\procgov.ps1 -DryRun -Interval 2
  .\procgov.ps1 -Config C:\etc\procgov.conf -Log C:\logs\procgov.log
  .\procgov.ps1 -Summary -Log C:\logs\procgov.log

NOTE:
  If execution policy blocks the script, run:
  Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
"@
}

# =============================================================================
# ENTRYPOINT
# (Planning Step 10: Build order — config → whitelist → validate → loop)
# =============================================================================

function Main {
    if ($Help) {
        Show-Usage
        exit 0
    }

    # Step 1: Honour -Config immediately so Load-Config reads the right file
    if ($Config -ne '') { $script:ConfigFile = $Config }

    # Step 2: Load config file (sets values from file)
    Load-Config

    # Step 3: Apply CLI overrides (CLI flags always win over config file)
    Apply-CliOverrides

    # Step 4: If -Summary was passed, generate the report and exit
    if ($Summary) {
        Show-WeeklySummary
        exit 0
    }

    # Step 5: Load whitelist into memory
    Load-Whitelist

    # Step 6: Validate all configuration values before entering the loop
    Validate-Config

    # Step 7: Cache total physical RAM once (avoids a CIM query every loop iteration)
    try {
        $script:TotalRamBytes = (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).TotalPhysicalMemory
    } catch {
        Write-LogWarn "Could not query total RAM — memory percentages will show 0%."
        $script:TotalRamBytes = 0
    }

    # Step 8: Enter the main monitoring loop
    Start-MainLoop
}

Main
