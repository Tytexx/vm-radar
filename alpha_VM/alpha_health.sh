#!/bin/bash

# alpha_health.sh
# Runs on Alpha VM. Checks if the Beta is alive.

if [ -z "$1" ]; then
    echo "Usage: $0 <peer-hostname>"
    echo "Example: $0 localhost"
    exit 1
fi

TARGET="$1"   # The hostname or IP to check — e.g. localhost or beta-vm

SETTINGS="$(dirname "$0")/config/settings.json"
SSH_KEY=$(jq -r '.ssh_key' "$SETTINGS")
PEER_USER=$(jq -r '.peer_user' "$SETTINGS")
SSH_KEY="${SSH_KEY/#\~/$HOME}"

LOG_FILE="$HOME/logs/health.log"

# UTC timestamp in ISO 8601 format — matches the format used in metrics.json
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# ==============================================================
# Check 1 — Ping
# -c 1 = send only 1 packet (don't keep pinging)
# -W 2 = wait max 2 seconds for a reply
# &>/dev/null = discard all output (we only care about exit code)

if ping -c 1 -W 2 "$TARGET" &>/dev/null; then
    PING_RESULT="OK"
else
    PING_RESULT="FAIL"
fi

# ==============================================================
# Check 2 — SSH port (TCP 22)
# nc = netcat, a tool for checking network connections
# -z = "zero I/O mode" — just check if port is open, don't send data
# -w 2 = give up after 2 seconds
# ==============================================================
if nc -z -w 2 "$TARGET" 22 &>/dev/null; then
    SSH_RESULT="OPEN"
else
    SSH_RESULT="CLOSED"
fi


# Redis port (TCP 6379)
# Same as SSH check but for Redis's default port

if nc -z -w 2 "$TARGET" 6379 &>/dev/null; then
    REDIS_PORT_RESULT="OPEN"
else
    REDIS_PORT_RESULT="CLOSED"
fi

# Remote Redis service status via SSH
# Only attempt this if SSH port is open (otherwise it will hang)
# We SSH into the peer and run "systemctl is-active redis-server"
# systemctl is-active returns "active" if running, "inactive" if not
# -o ConnectTimeout=5 = give up SSH connection after 5 seconds
SVC_REDIS="unknown"

if [ "$SSH_RESULT" = "OPEN" ]; then
    SVC_OUTPUT=$(ssh -i "$SSH_KEY" \
        -o StrictHostKeyChecking=no \
        -o ConnectTimeout=5 \
        -o BatchMode=yes \
        "${PEER_USER}@${TARGET}" \
        "systemctl is-active redis-server 2>/dev/null || \
         systemctl is-active redis 2>/dev/null || \
         echo inactive" 2>/dev/null)

    # Trim any whitespace or newlines from the output
    SVC_REDIS=$(echo "$SVC_OUTPUT" | tr -d '[:space:]')

    # Normalize — if anything other than "active" came back, mark inactive
    if [ "$SVC_REDIS" != "active" ]; then
        SVC_REDIS="inactive"
    fi
fi

# Build the log line and write it
# Format matches exactly what the project spec requires

LOG_LINE="$TIMESTAMP target=$TARGET ping=$PING_RESULT ssh=$SSH_RESULT redis=$REDIS_PORT_RESULT svc_redis=$SVC_REDIS"

# Append to health.log — >> means append, > would overwrite
echo "$LOG_LINE" >> "$LOG_FILE"

# Print to terminal so you can see it running
echo "$LOG_LINE"

# State change detection
# Read the previous check line (second to last line in the log)
# If ping flipped from OK->FAIL or FAIL->OK, publish a Redis alert

# tail -2 gets last 2 lines, head -1 gets the first of those = previous line
PREV_LINE=$(tail -2 "$LOG_FILE" | head -1)

# Extract just the ping result from the previous line
# grep -o 'ping=[A-Z]*' finds "ping=OK" or "ping=FAIL"
# cut -d= -f2 takes everything after the = sign

PREV_PING=$(echo "$PREV_LINE" | grep -o 'ping=[A-Z]*' | cut -d= -f2)

# Only check for state change if we have a previous result to compare to
# -n means "not empty"
if [ -n "$PREV_PING" ] && [ "$PREV_PING" != "$PING_RESULT" ]; then

    # Determine which direction the change went
    if [ "$PING_RESULT" = "OK" ]; then
        STATE="RECOVERED"
        SEVERITY="WARNING"
    else
        STATE="DOWN"
        SEVERITY="CRITICAL"
    fi

    # Build a JSON alert object matching the format used in alpha_analyze.sh
    ALERT_ID="HEALTH_$(date +%Y%m%d_%H%M%S)"
    ALERT="{\"alert_id\":\"$ALERT_ID\",\"hostname\":\"$TARGET\",\"metric\":\"ping\",\"value\":\"$PING_RESULT\",\"threshold\":\"reachability\",\"severity\":\"$SEVERITY\",\"state\":\"$STATE\",\"timestamp\":\"$TIMESTAMP\"}"

    # Publish to Redis channel "vm-alerts"
    # redis-cli PUBLISH sends a message to all subscribers on that channel
    redis-cli PUBLISH vm-alerts "$ALERT" > /dev/null 2>&1

    echo "STATE CHANGE DETECTED: $TARGET is $STATE — alert published to Redis"
fi