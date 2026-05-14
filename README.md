# Process Manager & Resource Governor

![License](https://img.shields.io/badge/License-MIT-blue.svg)
![Shell](https://img.shields.io/badge/Shell-Bash-4EAA25.svg?logo=gnubash&logoColor=white)
![Platform](https://img.shields.io/badge/Platform-Linux-FCC624.svg?logo=linux&logoColor=black)
![Status](https://img.shields.io/badge/Status-Stable-success.svg)


![Demo](demo.gif)

A Bash watchdog daemon that monitors running processes and automatically kills any process that exceeds configurable CPU or memory thresholds for longer than a set duration. Every kill action is logged with a timestamp, PID, process name, and reason.

---

## How It Works

`procgov.sh` polls all running processes on a configurable interval. When a process exceeds the CPU or memory threshold, a timer starts. If the process stays over the threshold for longer than the configured duration, it is sent `SIGTERM` (graceful shutdown), followed by `SIGKILL` if it doesn't exit within 3 seconds. Whitelisted processes are never touched.

```
[Config + Whitelist loaded]
        ↓
[Poll every INTERVAL seconds]
        ↓
[For each process]
    → Whitelisted?          → Skip
    → Over threshold?       → Start/continue timer
        → Timer < DURATION  → Warn, keep watching
        → Timer >= DURATION → SIGTERM → SIGKILL if needed → Log
    → Back under threshold? → Reset timer
```

---

## Requirements

- Bash 4+
- `ps`, `awk`, `kill` (standard on all Linux systems)
- `sudo` / root privileges (recommended — some processes may be invisible without it)
- `notify-send` (optional — enables desktop notifications on kill)

---

## Files

| File             | Description |

| `procgov.sh`     | Main script |
| `procgov.conf`   | Configuration file (thresholds, intervals, paths) |
| `whitelist.txt`  | Processes that will never be killed |
| `procgov.log`    | Kill log (auto-created on first kill) |

---

## Quick Start

```bash
# Clone or download the project, then:
cd Process-Manager-Resource-Governor

# Run with defaults (CPU > 80%, MEM > 70%, duration 30s, interval 5s)
sudo bash procgov.sh

# Preview what would be killed without actually killing anything
sudo bash procgov.sh --dry-run

# Custom thresholds
sudo bash procgov.sh --cpu 90 --mem 85 --duration 60

# Use a custom config and log path
sudo bash procgov.sh --config /etc/procgov.conf --log /var/log/procgov.log
```

---

## CLI Options

| Flag | Description | Default |
|---|---|---|
| `--cpu <percent>` | CPU threshold % to start tracking | `80` |
| `--mem <percent>` | Memory threshold % to start tracking | `70` |
| `--duration <seconds>` | Seconds over threshold before kill | `30` |
| `--interval <seconds>` | How often to poll processes | `5` |
| `--config <file>` | Path to config file | `procgov.conf` |
| `--whitelist <file>` | Path to whitelist file | `whitelist.txt` |
| `--log <file>` | Path to log file | `procgov.log` |
| `--dry-run` | Report what would be killed, without acting | — |
| `--summary` | Print a weekly kill summary from the log and exit | — |
| `--help` | Show usage information | — |

CLI flags always override values set in the config file.

---

## Configuration File

`procgov.conf` uses a simple `KEY=VALUE` format. Lines starting with `#` are ignored.

```ini
# Kill threshold — CPU usage percentage
CPU_THRESHOLD=80

# Kill threshold — memory usage percentage
MEM_THRESHOLD=70

# Seconds a process must stay over threshold before being killed
DURATION=30

# Polling interval in seconds
INTERVAL=5

# Path to the whitelist file
WHITELIST_FILE=whitelist.txt

# Path to the log file
LOG_FILE=procgov.log
```

---

## Whitelist

`whitelist.txt` contains one process name per line (matching the `comm` column from `ps`). These processes are never killed regardless of resource usage.

```
# Core system processes
systemd
sshd
bash

# Add your own below
nginx
postgres
```

To find the exact name for a process:
```bash
ps -eo comm | grep <name>
```

---

## Log Format

Each kill is written to the log file in a structured, pipe-delimited format:

```
[2025-07-14 10:32:01] KILLED | PID=4821 | NAME=chrome | CPU=94% | MEM=78% | DURATION=47s | REASON=CPU=94% >= 80% AND MEM=78% >= 70%
```

---

## Weekly Summary

Generate a summary of all kills from the last 7 days:

```bash
bash procgov.sh --summary
bash procgov.sh --summary --log /var/log/procgov.log
```

Example output:
```
========================================
  Weekly Kill Summary — Last 7 Days
========================================
Total kills: 12

Process Name                   Kill Count
------------                   ----------
chrome                         7
ffmpeg                         3
python3                        2
========================================
```

---

## Running as a Background Service

To run `procgov.sh` as a persistent systemd service:

```ini
# /etc/systemd/system/procgov.service
[Unit]
Description=Process Manager & Resource Governor
After=multi-user.target

[Service]
ExecStart=/bin/bash /path/to/procgov.sh --config /etc/procgov.conf --log /var/log/procgov.log
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now procgov
sudo systemctl status procgov
```

---

## Notes

- The script tracks processes by PID + name. If a PID is reused by a different 
  process, the timer resets automatically.
- A process that briefly spikes and drops back below the threshold has its timer 
  reset — it must stay over the threshold continuously for the full duration.
- Running without `sudo` is allowed but will produce a warning; some system 
  processes may not be visible.
- **Desktop notifications** via `notify-send` work on native Linux desktops. 
  On WSL, the binary is present but no notification daemon is running — 
  notifications are silently skipped without affecting any other functionality.

---

## What I Learned

Building this project pushed me deeper into several practical areas of systems programming and Linux administration:

- **Reading `/proc` is faster and more reliable than parsing `ps` output.** Initial versions called `ps aux` and parsed columns — fragile and slow. Switching to direct `/proc/[pid]/stat` reads cut CPU overhead and removed dependency on `ps` output format quirks.

- **CPU percentage calculation is not what it looks like.** A single sample of `%CPU` from `/proc` is meaningless — you need two samples over a time delta. Implementing this taught me what tools like `top` actually do under the hood.

- **Idempotent kill logic matters.** Without a sustained-duration check, a process spiking briefly would get killed unfairly. Adding the N-second threshold required tracking state across iterations — small change, big behavioural improvement.

- **Logging is part of the product.** A tool that kills processes without explaining why is a tool nobody trusts. Structured logs with timestamp, PID, command, threshold, and reason became as important as the kill logic itself.

- **systemd integration changes how you write scripts.** Designing the script to run as a systemd service (instead of cron) forced cleaner signal handling, proper exit codes, and stdout/stderr behaviour that journald can capture.

- **Dry-run mode is non-negotiable for destructive tools.** I wrote it after almost killing my own desktop environment during development. Anything that does irreversible actions needs a `--dry-run` from day one.

--- 

## Production Hardening Checklist

This project demonstrates the core mechanic. For real production use, the following would need to be added:

- [ ] Configurable allowlist of processes to never kill (e.g. `systemd`, `sshd`, critical daemons)
- [ ] Rate limiting on kill actions (e.g. max N kills per minute, to prevent cascading failures)
- [ ] Metrics endpoint (Prometheus-compatible) exposing kill counts, threshold breaches, and uptime
- [ ] Centralised log shipping (rsyslog or Fluent Bit forwarding to ELK / Loki)
- [ ] Alerting integration (PagerDuty / Slack webhook on kill events for critical processes)
- [ ] Configuration validation at startup (fail fast on malformed thresholds rather than at runtime)
- [ ] Multi-tenant config (different threshold profiles for different process groups)