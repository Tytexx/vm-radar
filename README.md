# OS-Stretch — Distributed VM Monitoring System

A distributed system monitoring project built across two Ubuntu Server VMs (Alpha and Beta), 
featuring automated metric collection, GPG-encrypted data exchange, threshold-based alerting, 
and Redis pub/sub communication.

## Architecture

| VM | Role |
|---|---|
| Alpha | Collects metrics, analyzes thresholds, monitors Beta health, publishes alerts to Redis |
| Beta | Collects metrics, subscribes to Redis alerts, manages backups and systemd service |

## Features

- **Encrypted data transfer** — GPG-encrypted snapshots exchanged between VMs via SCP
- **Real-time alerting** — Redis pub/sub channel for WARNING/CRITICAL threshold alerts
- **Health monitoring** — Ping, SSH, and Redis connectivity checks with state-change detection
- **Automated backups** — Encrypted log rotation and stale file cleanup
- **Systemd service** — Beta runs as a managed daemon with install/start/stop/status/logs
- **C log reporter** — Multi-process log analysis using fork/pipe for parallel file processing

## My Contributions

- `alpha_send.sh` — GPG encryption and SCP transfer of metric snapshots to Beta; decryption of incoming data from Beta
- `beta_send.sh` — Mirror of alpha_send.sh on the Beta side with Alpha as the peer target
- `alpha_health.sh` — Monitors Beta reachability via ping, SSH, and Redis; detects state changes and publishes alerts

## Tech Stack

- Bash scripting
- Redis (pub/sub)
- GPG encryption
- SCP / SSH
- C (fork, pipe, waitpid)
- systemd
- Ubuntu Server 22.04 LTS

## Setup

```bash
# On Alpha VM
bash alpha_VM/alpha_setup.sh

# On Beta VM
bash beta_VM/beta_setup.sh
```

## Usage

```bash
# Collect metrics
bash alpha_collect.sh

# Send/receive encrypted snapshots
bash alpha_send.sh

# Monitor Beta health
bash alpha_health.sh <beta-hostname>

# Start automated monitoring service (Beta)
bash beta_service.sh install
bash beta_service.sh start
```

## Course

CMPS 405 — Operating Systems, Qatar University
