# Process Manager & Resource Governor — Thought Process & Planning Guide

---

## Step 1: Understand What You're Actually Building

Before touching any code, read the requirements twice and ask yourself: *"What problem does this solve in the real world?"*

This script is essentially a **watchdog daemon** — it sits in the background, watches processes, and enforces resource limits. Think of it like a bouncer at a club: it has a list of VIPs (whitelist) who never get removed, and it kicks out anyone who overstays their welcome while being too loud (high CPU/memory for too long).

Key insight: the word **"for more than N seconds"** is the most important part. It means you can't just check once — you need to track *duration*. A process that spikes to 90% CPU for 1 second is normal. One that holds 90% for 60 seconds is a problem.

---

## Step 2: Break Down the Problem Into Domains

Brainstorm every concern this script touches, grouped by domain:

**Data Collection**
- How do I read CPU and memory per process? (`ps`, `/proc`, `top`)
- How often do I sample? (polling interval)
- What format does the data come in?

**State Tracking**
- How do I remember that a process has been over the threshold for N seconds?
- What if a process drops below threshold and spikes again?
- What if a process dies between checks?

**Decision Logic**
- Is this process whitelisted?
- Has it exceeded *both* thresholds, or *either*?
- Has it been over threshold long enough?

**Action**
- Kill it (SIGTERM first, then SIGKILL?)
- Log the kill with all required details
- Dry-run: report but don't act

**Configuration**
- Where do thresholds live? (hardcoded vs config file vs CLI flags)
- Where does the whitelist live?
- Where does the log file go?

---

## Step 3: Identify the Hard Parts Early

This is where most beginners skip ahead and get stuck. Ask yourself: *"What's the trickiest part of this?"*

The hardest part here is **duration tracking** — Bash doesn't have built-in state between loop iterations. You need to figure out how to remember "PID 1234 has been over threshold since timestamp X."

Options to brainstorm:
- Use an associative array (`declare -A`) to store `[PID]=first_seen_timestamp`
- Use temp files (`/tmp/procgov_1234`) as state markers
- Use a directory where each file is named after a PID

The associative array approach is cleanest for a single-run script. Temp files survive script restarts — worth noting.

Second hardest: **PID reuse**. Linux reuses PIDs. If PID 1234 dies and a new process gets PID 1234, your state tracker might wrongly count the new process's time. You need to also track the process name alongside the PID to detect this.

---

## Step 4: Design the Data Flow (Before Writing Code)

Draw this out mentally or on paper:

```
[Config/Flags loaded]
        ↓
[Whitelist loaded into memory]
        ↓
[Loop every INTERVAL seconds]
        ↓
[Snapshot all processes with CPU% and MEM%]
        ↓
[For each process:]
    → Is it whitelisted? → Skip
    → Is it over threshold? → Yes → Is it already tracked?
                                        → No  → Record start time
                                        → Yes → How long has it been over?
                                                    → Under N seconds → Wait
                                                    → Over N seconds  → Kill/Log/DryRun
    → Is it under threshold? → Remove from tracking if it was tracked
        ↓
[Sleep INTERVAL]
        ↓
[Repeat]
```

This flow tells you exactly what functions you need before writing a single line.

---

## Step 5: Plan Your Functions/Modules

From the data flow, extract your building blocks:

| Function | Responsibility |
|---|---|
| `load_config` | Parse CLI flags and config file, set defaults |
| `load_whitelist` | Read whitelist file into an array |
| `is_whitelisted` | Check if a process name is in the whitelist |
| `get_processes` | Snapshot current processes with resource usage |
| `check_threshold` | Compare a process's usage against limits |
| `track_process` | Add/update a process in the duration tracker |
| `should_kill` | Determine if tracked duration exceeds N seconds |
| `kill_process` | Send signal, log the action |
| `log_kill` | Write structured log entry |
| `dry_run_report` | Print what would happen without acting |
| `main_loop` | Orchestrate everything |

Planning functions first means you can build and test each piece independently.

---

## Step 6: Think About Edge Cases

This is what separates a script that works in demos from one that works in production. Brainstorm failure scenarios:

- What if the whitelist file doesn't exist? → Default to empty whitelist, warn user
- What if a process dies between detection and kill? → `kill` will return an error, handle it gracefully
- What if CPU% from `ps` shows `99.9` with a decimal? → Your threshold comparison needs to handle floats (`bc` or integer truncation)
- What if two processes have the same name but different PIDs? → Track by PID, not name
- What if the script is run without root? → Some `/proc` entries may be unreadable, warn early
- What if `INTERVAL` is set to 0? → Infinite loop with no sleep, guard against it
- What if the log file directory doesn't exist? → Create it or fail with a clear message

---

## Step 7: Plan Your Configuration Strategy

Decide this before coding because it affects everything:

**Option A — CLI flags only**
```bash
./procgov.sh --cpu 80 --mem 70 --duration 30 --dry-run
```
Simple, but tedious for repeated use.

**Option B — Config file only**
```
CPU_THRESHOLD=80
MEM_THRESHOLD=70
DURATION=30
```
Easy to reuse, but less flexible for one-off runs.

**Option C — Config file with CLI overrides (best)**
Load defaults from config, allow CLI flags to override. This is the professional approach.

For the whitelist, a plain text file (one process name per line) is the simplest and most maintainable format.

---

## Step 8: Plan Your Logging Format

Decide what a log entry looks like before you write the logging function. You want it to be:
- Human readable
- Parseable (for the weekly summary stretch goal)

Think through what fields you need:
```
[2025-07-14 10:32:01] KILLED | PID=4821 | NAME=chrome | CPU=94.2% | MEM=78.1% | DURATION=47s | REASON=CPU+MEM exceeded threshold
```

If you plan the format now, the weekly summary stretch goal becomes trivial — just `grep` and `awk` the log file.

---

## Step 9: Plan Your Testing Strategy

You can't test a process killer by just running it and hoping. Think about how to validate each piece:

- Test `is_whitelisted` with known names before the main loop runs
- Test threshold detection by running a CPU hog (`stress` or a simple `while true; do :; done`) and watching if it gets detected
- Test dry-run mode first — it's safe and lets you verify detection logic without killing anything
- Test the duration logic by setting a very short duration (5 seconds) and a low threshold (10% CPU) to trigger kills quickly
- Test PID reuse edge case manually by killing a tracked process and starting a new one

---

## Step 10: Build Order (Incremental Approach)

Don't build everything at once. Here's the order that lets you validate as you go:

1. Config loading + argument parsing → run it, print parsed values, verify
2. Whitelist loading + `is_whitelisted` check → unit test with echo statements
3. Process snapshot (`get_processes`) → print the raw data, make sure it looks right
4. Threshold check logic → test with hardcoded values first
5. Duration tracking (the hard part) → test with a long-running process
6. Dry-run output → verify it reports correctly before enabling real kills
7. Kill + logging → enable only after dry-run is confirmed working
8. Stretch goals last — notifications and weekly summary are additive, not foundational

---

## Step 11: README Planning

Plan the README before you finish the script, not after. It forces you to think about the user experience:

- What's the one-line description?
- What are the prerequisites? (`bc`, `ps`, `notify-send` for stretch goals)
- What does a sample config file look like?
- What does a sample whitelist look like?
- What does sample output look like? (include a real log line)
- What are the CLI flags with examples?
- What permissions are needed?

---

## The Mental Model Summary

Think of this project in three layers:

```
Layer 3 — Interface:    CLI flags, config file, whitelist file, README
Layer 2 — Logic:        Threshold checks, duration tracking, kill decisions
Layer 1 — Data:         ps output, /proc, log file, state tracking
```

Always build from Layer 1 up. Never start at Layer 3. The most common mistake is writing the CLI argument parser first and then realizing the core logic doesn't work the way you assumed.

The script that passes a demo is built top-down. The script that works in production is built bottom-up.
