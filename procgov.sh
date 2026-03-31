#!/usr/bin/env bash
# =============================================================================
# procgov.sh — Process Manager & Resource Governor
# =============================================================================
# Monitors running processes and automatically kills any process that exceeds
# a configurable CPU or memory threshold for more than N seconds.
# Every kill action is logged with a timestamp, PID, name, and reason.
#
# Usage:
#   sudo bash procgov.sh [OPTIONS]
#
# Options:
#   --cpu <percent>       CPU threshold (default: 80)
#   --mem <percent>       Memory threshold (default: 70)
#   --duration <seconds>  How long a process must exceed threshold before kill (default: 30)
#   --interval <seconds>  How often to poll processes (default: 5)
#   --config <file>       Path to config file (default: procgov.conf)
#   --whitelist <file>    Path to whitelist file (default: whitelist.txt)
#   --log <file>          Path to log file (default: procgov.log)
#   --dry-run             Show what WOULD be killed without actually killing
#   --summary             Generate a weekly summary from the log file and exit
#   --help                Show this help message
#
# Requirements: bash 4+, ps, awk, bc, kill
# Stretch goals: notify-send (desktop notifications), awk (weekly summary)
# =============================================================================

set -euo pipefail # Exit on error, undefined variable, pipe failure

# =============================================================================
# STEP 1 — CONSTANTS & DEFAULTS
# (Planning Step 7: Config file with CLI overrides — set safe defaults first)
# =============================================================================

readonly SCRIPT_NAME="$(basename "$0")"    # Name of the script
readonly SCRIPT_VERSION="1.0.0"   # Version of the script

# Default thresholds — all overridable via config file or CLI flags
CPU_THRESHOLD=80        # Kill if CPU% exceeds this...
MEM_THRESHOLD=70        # ...or MEM% exceeds this...
DURATION=30             # ...for longer than this many seconds
INTERVAL=5              # Poll every N seconds
DRY_RUN=false           # When true: report only, never kill

# Default file paths — all overridable via CLI
CONFIG_FILE="procgov.conf"
WHITELIST_FILE="whitelist.txt"
LOG_FILE="procgov.log"

# Colour codes for terminal output
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# =============================================================================
# STEP 2 — STATE TRACKING SETUP
# (Planning Step 3: The hard part — duration tracking via associative arrays)
#
# We use two associative arrays keyed by PID:
#   over_threshold_since[PID] = unix timestamp when it first exceeded threshold
#   tracked_name[PID]         = process name at time of first detection
#
# Storing the name alongside the PID solves the PID reuse problem:
# if the name changes, we know it's a different process and reset the timer.
# =============================================================================

declare -A over_threshold_since   # PID → timestamp of first threshold breach
declare -A tracked_name           # PID → process name at time of detection
declare -a WHITELIST=()           # Array of whitelisted process names

# =============================================================================
# STEP 3 — HELPER: LOGGING & OUTPUT
# (Planning Step 8: Structured log format that is both human-readable and
#  parseable by awk for the weekly summary stretch goal)
#
# Log format:
# [YYYY-MM-DD HH:MM:SS] KILLED | PID=X | NAME=Y | CPU=Z% | MEM=W% | DURATION=Ns | REASON=...
# =============================================================================

# Print a timestamped message to stdout
log_info() {
    echo -e "${CYAN}[INFO]${RESET}  $(date '+%Y-%m-%d %H:%M:%S') — $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${RESET}  $(date '+%Y-%m-%d %H:%M:%S') — $*"
}

log_error() {
    echo -e "${RED}[ERROR]${RESET} $(date '+%Y-%m-%d %H:%M:%S') — $*" >&2
}

# Write a structured kill entry to the log file
# Args: pid name cpu mem duration reason
log_kill() {
    local pid="$1" name="$2" cpu="$3" mem="$4" dur="$5" reason="$6"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"

    # Structured format — pipe-delimited so awk can parse it for weekly summary
    local entry="[${timestamp}] KILLED | PID=${pid} | NAME=${name} | CPU=${cpu}% | MEM=${mem}% | DURATION=${dur}s | REASON=${reason}"

    echo "$entry" >> "$LOG_FILE"
    echo -e "${RED}[KILL]${RESET}  ${entry}"
}

# Dry-run variant — same format but prefixed with DRY-RUN, never written to log
dry_run_report() {
    local pid="$1" name="$2" cpu="$3" mem="$4" dur="$5" reason="$6"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    echo -e "${YELLOW}[DRY-RUN]${RESET} [${timestamp}] WOULD KILL | PID=${pid} | NAME=${name} | CPU=${cpu}% | MEM=${mem}% | DURATION=${dur}s | REASON=${reason}"
}

# =============================================================================
# STEP 4 — LOAD CONFIG FILE
# (Planning Step 7, Option C: Load file first, CLI flags override after)
#
# Config file uses KEY=VALUE format. Lines starting with # are comments.
# Missing config file is not fatal — we fall back to built-in defaults.
# =============================================================================

load_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_warn "Config file '$CONFIG_FILE' not found — using built-in defaults."
        return
    fi

    log_info "Loading config from '$CONFIG_FILE'..."

    # Read each non-comment, non-empty line and source only known keys
    while IFS='=' read -r key value; do
        # Strip leading/trailing whitespace and skip comments/blank lines
        key="${key// /}"
        value="${value// /}"
        [[ -z "$key" || "$key" == \#* ]] && continue

        case "$key" in
            CPU_THRESHOLD)  CPU_THRESHOLD="$value"  ;;
            MEM_THRESHOLD)  MEM_THRESHOLD="$value"  ;;
            DURATION)       DURATION="$value"        ;;
            INTERVAL)       INTERVAL="$value"        ;;
            WHITELIST_FILE) WHITELIST_FILE="$value"  ;;
            LOG_FILE)       LOG_FILE="$value"        ;;
            *)              log_warn "Unknown config key: '$key' — skipping." ;;
        esac
    done < "$CONFIG_FILE"
}

# =============================================================================
# STEP 5 — PARSE CLI ARGUMENTS
# (Planning Step 7: CLI flags override config file values)
# =============================================================================

parse_args() {
    local generate_summary=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --cpu)       CPU_THRESHOLD="$2";  shift 2 ;;
            --mem)       MEM_THRESHOLD="$2";  shift 2 ;;
            --duration)  DURATION="$2";       shift 2 ;;
            --interval)  INTERVAL="$2";       shift 2 ;;
            --config)    CONFIG_FILE="$2";    shift 2 ;;
            --whitelist) WHITELIST_FILE="$2"; shift 2 ;;
            --log)       LOG_FILE="$2";       shift 2 ;;
            --dry-run)   DRY_RUN=true;        shift   ;;
            --summary)   generate_summary=true; shift ;;
            --help)      usage; exit 0 ;;
            *)
                log_error "Unknown option: '$1'. Use --help for usage."
                exit 1
                ;;
        esac
    done

    # If --summary was passed, generate the report and exit immediately
    # (stretch goal — handled here so it short-circuits before the main loop)
    if [[ "$generate_summary" == true ]]; then
        weekly_summary
        exit 0
    fi
}

# =============================================================================
# STEP 6 — VALIDATE CONFIGURATION
# (Planning Step 6: Edge cases — guard against bad values before the loop)
# =============================================================================

validate_config() {
    # Guard: INTERVAL must be at least 1 to prevent a busy infinite loop
    if [[ "$INTERVAL" -lt 1 ]]; then
        log_error "INTERVAL must be >= 1 second. Got: $INTERVAL"
        exit 1
    fi

    # Guard: thresholds must be numeric and between 1–100
    for var_name in CPU_THRESHOLD MEM_THRESHOLD; do
        local val="${!var_name}"
        if ! [[ "$val" =~ ^[0-9]+$ ]] || [[ "$val" -lt 1 || "$val" -gt 100 ]]; then
            log_error "$var_name must be an integer between 1 and 100. Got: $val"
            exit 1
        fi
    done

    # Guard: DURATION must be a positive integer
    if ! [[ "$DURATION" =~ ^[0-9]+$ ]] || [[ "$DURATION" -lt 1 ]]; then
        log_error "DURATION must be a positive integer. Got: $DURATION"
        exit 1
    fi

    # Guard: ensure log file directory exists (create it if needed)
    local log_dir
    log_dir="$(dirname "$LOG_FILE")"
    if [[ ! -d "$log_dir" ]]; then
        mkdir -p "$log_dir" || { log_error "Cannot create log directory: $log_dir"; exit 1; }
    fi

    # Guard: warn if not running as root (some /proc entries may be unreadable)
    if [[ "$EUID" -ne 0 ]]; then
        log_warn "Not running as root. Some processes may not be visible."
    fi
}

# =============================================================================
# STEP 7 — LOAD WHITELIST
# (Planning Step 5: load_whitelist — read process names that must never be killed)
#
# Edge case: missing whitelist file is a warning, not a fatal error.
# We default to an empty whitelist and continue.
# =============================================================================

load_whitelist() {
    if [[ ! -f "$WHITELIST_FILE" ]]; then
        log_warn "Whitelist file '$WHITELIST_FILE' not found — no processes are protected."
        return
    fi

    log_info "Loading whitelist from '$WHITELIST_FILE'..."

    while IFS= read -r line; do
        # Skip blank lines and comments
        [[ -z "$line" || "$line" == \#* ]] && continue
        WHITELIST+=("$line")
    done < "$WHITELIST_FILE"

    log_info "Whitelist loaded: ${#WHITELIST[@]} protected process(es): ${WHITELIST[*]:-none}"
}

# =============================================================================
# STEP 8 — IS_WHITELISTED CHECK
# (Planning Step 5: is_whitelisted — called per-process before any action)
#
# Returns 0 (true) if the process name is in the whitelist, 1 (false) otherwise.
# =============================================================================

is_whitelisted() {
    local name="$1"
    local entry
    for entry in "${WHITELIST[@]}"; do
        [[ "$entry" == "$name" ]] && return 0
    done
    return 1
}

# =============================================================================
# STEP 9 — GET PROCESSES
# (Planning Step 5: get_processes — snapshot all running processes)
#
# Uses `ps` to get: PID, process name, CPU%, MEM%
# Output format (one process per line): PID NAME CPU MEM
#
# Edge case: CPU% from ps can be a float (e.g. 99.9).
# We truncate to integer using awk for threshold comparison with bash arithmetic.
# =============================================================================

get_processes() {
    # ps flags:
    #   -e        = all processes
    #   -o        = custom output columns
    #   --no-header = suppress the header row
    # awk truncates CPU and MEM to integers (bash can't do float comparisons natively)
    # ettime = elapsed time the process has been running
    # We filter out processes younger than DURATION seconds —
    # they can't possibly have exceeded the threshold long enough to kill.
    # This also eliminates the ps/awk processes spawned by this script itself.
    ps -eo pid,comm,%cpu,%mem,etimes --no-headers \
        | awk -v min_age="$DURATION" '
            {
                pid=$1; name=$2; cpu=int($3); mem=int($4); age=int($5)
                if (age >= min_age)
                    printf "%s %s %d %d\n", pid, name, cpu, mem
            }'
}

# =============================================================================
# STEP 10 — CHECK THRESHOLD
# (Planning Step 5: check_threshold — does this process exceed CPU or MEM limit?)
#
# Returns 0 if over threshold, 1 if within limits.
# Also sets the global THRESHOLD_REASON string for use in log messages.
# =============================================================================

THRESHOLD_REASON=""

check_threshold() {
    local cpu="$1" mem="$2"
    local reasons=()

    [[ "$cpu" -ge "$CPU_THRESHOLD" ]] && reasons+=("CPU=${cpu}% >= ${CPU_THRESHOLD}%")
    [[ "$mem" -ge "$MEM_THRESHOLD" ]] && reasons+=("MEM=${mem}% >= ${MEM_THRESHOLD}%")

    if [[ "${#reasons[@]}" -gt 0 ]]; then
        # Join reasons with " AND " for the log entry
        THRESHOLD_REASON="$(IFS=' AND '; echo "${reasons[*]}")"
        return 0  # over threshold
    fi

    THRESHOLD_REASON=""
    return 1  # within limits
}

# =============================================================================
# STEP 11 — TRACK PROCESS
# (Planning Step 3 & 5: track_process — the core of duration tracking)
#
# Called when a process is over threshold. Records the first-seen timestamp
# in over_threshold_since[PID] and the name in tracked_name[PID].
#
# PID reuse guard: if the stored name doesn't match the current name,
# the old PID was recycled — reset the timer for the new process.
# =============================================================================

track_process() {
    local pid="$1" name="$2"

    if [[ -n "${over_threshold_since[$pid]+_}" ]]; then
        # PID is already being tracked — check for PID reuse
        if [[ "${tracked_name[$pid]}" != "$name" ]]; then
            log_warn "PID $pid name changed (${tracked_name[$pid]} → $name). Resetting timer (PID reuse detected)."
            over_threshold_since[$pid]="$(date +%s)"
            tracked_name[$pid]="$name"
        fi
        # Otherwise: same process, same PID — timer keeps running, nothing to do
    else
        # First time we've seen this PID over threshold — start the clock
        over_threshold_since[$pid]="$(date +%s)"
        tracked_name[$pid]="$name"
    fi
}

# =============================================================================
# STEP 12 — SHOULD KILL
# (Planning Step 5: should_kill — has the process been over threshold long enough?)
#
# Compares current time against the first-seen timestamp.
# Returns 0 if duration exceeded, 1 if still within grace period.
# Sets global ELAPSED_SECONDS for use in log messages.
# =============================================================================

ELAPSED_SECONDS=0

should_kill() {
    local pid="$1"
    local now
    now="$(date +%s)"
    ELAPSED_SECONDS=$(( now - over_threshold_since[$pid] ))

    [[ "$ELAPSED_SECONDS" -ge "$DURATION" ]] && return 0
    return 1
}

# =============================================================================
# STEP 13 — KILL PROCESS
# (Planning Step 5: kill_process — send SIGTERM, fall back to SIGKILL)
#
# Strategy: try SIGTERM first (graceful shutdown), wait 3 seconds,
# then send SIGKILL if the process is still alive.
#
# Edge case: process may have died between detection and kill attempt.
# We check kill's exit code and handle it gracefully.
# =============================================================================

kill_process() {
    local pid="$1" name="$2" cpu="$3" mem="$4" reason="$5"

    if [[ "$DRY_RUN" == true ]]; then
        dry_run_report "$pid" "$name" "$cpu" "$mem" "$ELAPSED_SECONDS" "$reason"
        # In dry-run mode, remove from tracking so we don't keep reporting it every cycle
        return
    fi

    # Attempt graceful termination first
    if kill -SIGTERM "$pid" 2>/dev/null; then
        log_kill "$pid" "$name" "$cpu" "$mem" "$ELAPSED_SECONDS" "$reason (SIGTERM)"

        # Give the process 3 seconds to exit cleanly
        sleep 3

        # If still alive, force kill
        if kill -0 "$pid" 2>/dev/null; then
            kill -SIGKILL "$pid" 2>/dev/null && \
                log_warn "PID $pid ($name) did not exit after SIGTERM — sent SIGKILL."
        fi

        # Stretch goal: send desktop notification if notify-send is available
        if command -v notify-send &>/dev/null; then
            notify-send "procgov: Process Killed" \
                "PID $pid ($name) was killed.\nReason: $reason" \
                --urgency=normal 2>/dev/null || true
        fi
    else
        # Process already gone — not an error, just clean up tracking state
        log_warn "PID $pid ($name) was already gone before kill attempt."
    fi

    # Remove from tracking regardless of outcome
    unset "over_threshold_since[$pid]"
    unset "tracked_name[$pid]"
}

# =============================================================================
# STEP 14 — MAIN LOOP
# (Planning Step 4: the data flow — this is where everything comes together)
#
# Flow per iteration:
#   1. Snapshot all processes
#   2. For each process:
#      a. Skip if whitelisted
#      b. Check if over threshold
#      c. If over: track it, check duration, kill if duration exceeded
#      d. If under: remove from tracking (process recovered)
#   3. Sleep INTERVAL seconds
#   4. Repeat
# =============================================================================

main_loop() {
    log_info "Starting process governor. CPU>=${CPU_THRESHOLD}% | MEM>=${MEM_THRESHOLD}% | DURATION=${DURATION}s | INTERVAL=${INTERVAL}s"
    log_info "Log file: $LOG_FILE"
    [[ "$DRY_RUN" == true ]] && log_warn "DRY-RUN mode enabled — no processes will be killed."

    # Trap SIGINT/SIGTERM so we exit cleanly on Ctrl+C or system shutdown
    trap 'log_info "Shutting down procgov. Goodbye."; exit 0' SIGINT SIGTERM

    while true; do
        # --- Snapshot: get all current processes as "PID NAME CPU MEM" lines ---
        while IFS=' ' read -r pid name cpu mem; do

            # Skip kernel threads and the script itself
            [[ "$pid" -eq "$$" ]] && continue
            [[ "$pid" -eq "$PPID" ]] && continue
            [[ -z "$name" ]]      && continue

            # --- Decision: is this process whitelisted? ---
            if is_whitelisted "$name"; then
                # Remove from tracking if it was previously tracked (e.g. threshold was
                # lowered mid-run and a whitelisted process briefly appeared over it)
                unset "over_threshold_since[$pid]" 2>/dev/null || true
                continue
            fi

            # --- Decision: is this process over threshold? ---
            if check_threshold "$cpu" "$mem"; then

                # Start or continue tracking this PID
                track_process "$pid" "$name"

                # Check if it has been over threshold long enough to act
                if should_kill "$pid"; then
                    kill_process "$pid" "$name" "$cpu" "$mem" "$THRESHOLD_REASON"
                else
                    # Still within grace period — show a warning so the user can see it building up
                    local remaining=$(( DURATION - ELAPSED_SECONDS ))
                    log_warn "PID $pid ($name) over threshold [${THRESHOLD_REASON}] for ${ELAPSED_SECONDS}s — will act in ${remaining}s."
                fi

            else
                # Process is back within limits — remove from tracking if it was being watched
                # Fixed code:
                if [[ -n "${over_threshold_since[$pid]+_}" ]]; then
                    local recovery_elapsed=$(( $(date +%s) - over_threshold_since[$pid] ))
                    log_info "PID $pid ($name) dropped below threshold after ${recovery_elapsed}s — removed from tracking."
                    unset "over_threshold_since[$pid]"
                    unset "tracked_name[$pid]"
                fi
            fi

        done < <(get_processes)

        sleep "$INTERVAL"
    done
}

# =============================================================================
# STRETCH GOAL — WEEKLY SUMMARY
# (Planning Step 8: because the log format is structured, this is just awk)
#
# Parses the log file for entries from the last 7 days and prints a summary:
# total kills, kills per process name, and the top offender.
# =============================================================================

weekly_summary() {
    if [[ ! -f "$LOG_FILE" ]]; then
        log_error "Log file '$LOG_FILE' not found. No summary available."
        exit 1
    fi

    echo -e "\n${BOLD}========================================${RESET}"
    echo -e "${BOLD}  Weekly Kill Summary — Last 7 Days${RESET}"
    echo -e "${BOLD}========================================${RESET}"

    # Calculate the unix timestamp for 7 days ago
    local cutoff
    cutoff=$(date -d '7 days ago' '+%Y-%m-%d' 2>/dev/null || date -v-7d '+%Y-%m-%d')

    # Use awk to filter entries within the last 7 days and count by process name
    awk -v cutoff="$cutoff" '
        /KILLED/ {
            # Extract date from [YYYY-MM-DD HH:MM:SS]
            match($0, /\[([0-9-]+) /, arr)
            entry_date = arr[1]

            # Only count entries on or after the cutoff date
            if (entry_date >= cutoff) {
                # Extract NAME=value
                match($0, /NAME=([^ |]+)/, name_arr)
                name = name_arr[1]
                count[name]++
                total++
            }
        }
        END {
            if (total == 0) {
                print "No processes were killed in the last 7 days."
            } else {
                printf "Total kills: %d\n\n", total
                printf "%-30s %s\n", "Process Name", "Kill Count"
                printf "%-30s %s\n", "------------", "----------"
                for (name in count) {
                    printf "%-30s %d\n", name, count[name]
                }
            }
        }
    ' "$LOG_FILE"

    echo -e "${BOLD}========================================${RESET}\n"
}

# =============================================================================
# USAGE / HELP
# =============================================================================

usage() {
    cat <<EOF

${BOLD}procgov.sh${RESET} v${SCRIPT_VERSION} — Process Manager & Resource Governor

${BOLD}USAGE:${RESET}
  sudo bash procgov.sh [OPTIONS]

${BOLD}OPTIONS:${RESET}
  --cpu <percent>       CPU threshold % before tracking starts     (default: 80)
  --mem <percent>       Memory threshold % before tracking starts  (default: 70)
  --duration <seconds>  Seconds over threshold before kill         (default: 30)
  --interval <seconds>  Polling interval in seconds                (default: 5)
  --config <file>       Path to config file                        (default: procgov.conf)
  --whitelist <file>    Path to whitelist file                     (default: whitelist.txt)
  --log <file>          Path to log file                           (default: procgov.log)
  --dry-run             Report what WOULD be killed, without acting
  --summary             Print a weekly kill summary from the log and exit
  --help                Show this help message

${BOLD}EXAMPLES:${RESET}
  sudo bash procgov.sh
  sudo bash procgov.sh --cpu 90 --mem 80 --duration 60
  sudo bash procgov.sh --dry-run --interval 2
  sudo bash procgov.sh --config /etc/procgov.conf --log /var/log/procgov.log
  bash procgov.sh --summary --log /var/log/procgov.log

EOF
}

# =============================================================================
# ENTRYPOINT
# (Planning Step 10: Build order — config → whitelist → validate → loop)
# =============================================================================

main() {
    # Step 1: Parse CLI args first so --config can point to a custom file
    parse_args "$@"

    # Step 2: Load config file (CLI values already set will be overridden below
    #         only if the config file sets them — CLI wins because parse_args ran first)
    # NOTE: To make CLI truly override config, we re-parse after loading config.
    #       We save CLI args and re-apply them after config load.
    local saved_args=("$@")
    load_config
    parse_args "${saved_args[@]}"   # CLI flags win over config file

    # Step 3: Load whitelist into memory
    load_whitelist

    # Step 4: Validate all configuration values before entering the loop
    validate_config

    # Step 5: Enter the main monitoring loop
    main_loop
}

main "$@"
