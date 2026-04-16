#!/bin/bash

# alpha_health.sh
# Runs on Alpha VM. Checks if the Beta is alive.

#ensures hostname is given, -z checks if empty
if [ -z "$1" ]; then
    echo "Usage: $0 <peer-hostname>"
    echo "Example: $0 localhost"
    exit 1
fi

# stores target name for analyzing
TARGET="$1"   

# loading files, ssh keys
SETTINGS="$(dirname "$0")/config/settings.json"
SSH_KEY=$(jq -r '.ssh_key' "$SETTINGS")
PEER_USER=$(jq -r '.peer_user' "$SETTINGS")
SSH_KEY="${SSH_KEY/#\~/$HOME}"

LOG_FILE="$HOME/logs/health.log"

# time stamp should matche the format used in metrics.json
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)


# 1. Ping check
# c send 1 ping, W wait 2 seconds, &>/dev/null is for hiding output
if ping -c 1 -W 2 "$TARGET" &>/dev/null; then
    PING_RESULT="OK"
else
    PING_RESULT="FAIL"
fi

# 2. SSH port check
# nc is netcat for port checking, z checks port, w -2 is timeout of 2 seconds
# only try SSH if SSH port is open

if nc -z -w 2 "$TARGET" 22 &>/dev/null; then
    SSH_RESULT="OPEN"
else
    SSH_RESULT="CLOSED"
fi


# 3. Redis port (TCP 6379)
# nc is netcat for port checking, z checks port, w -2 is timeout of 2 seconds
if nc -z -w 2 "$TARGET" 6379 &>/dev/null; then
    REDIS_PORT_RESULT="OPEN"
else
    REDIS_PORT_RESULT="CLOSED"
fi

# Remote Redis service status via SSH
SVC_REDIS="unknown"

if [ "$SSH_RESULT" = "OPEN" ]; then
#private key to connect, connection timeout, disable password prompting, and the template for the login
    SVC_OUTPUT=$(ssh -i "$SSH_KEY" \
        -o StrictHostKeyChecking=no \
        -o ConnectTimeout=5 \
        -o BatchMode=yes \
        "${PEER_USER}@${TARGET}" \
        "systemctl is-active redis-server 2>/dev/null || \
         systemctl is-active redis 2>/dev/null || \
         echo inactive" 2>/dev/null)

    # remove any whitespace from the output
    SVC_REDIS=$(echo "$SVC_OUTPUT" | tr -d '[:space:]')

    # normalize the result
    if [ "$SVC_REDIS" != "active" ]; then
        SVC_REDIS="inactive"
    fi
fi

# format according to the requirement
LOG_LINE="$TIMESTAMP target=$TARGET ping=$PING_RESULT ssh=$SSH_RESULT redis=$REDIS_PORT_RESULT svc_redis=$SVC_REDIS"

# Append to health.log
echo "$LOG_LINE" >> "$LOG_FILE"

# Print to terminal 
echo "$LOG_LINE"


# state change detection, ping flips triggers a change

# tail -2 gets last 2 lines, head -1 gets first of the previous line
PREV_LINE=$(tail -2 "$LOG_FILE" | head -1)

# extract just the ping result from the line before
PREV_PING=$(echo "$PREV_LINE" | grep -o 'ping=[A-Z]*' | cut -d= -f2)

# only check for state change if there is previous result
# -n means not empty
if [ -n "$PREV_PING" ] && [ "$PREV_PING" != "$PING_RESULT" ]; then

    # determine which direction the change went
    if [ "$PING_RESULT" = "OK" ]; then
        STATE="RECOVERED"
        SEVERITY="WARNING"
    else
        STATE="DOWN"
        SEVERITY="CRITICAL"
    fi

    # create a JSON alert object with template used in alpha_analyze.sh
    ALERT_ID="HEALTH_$(date +%Y%m%d_%H%M%S)"
    ALERT="{\"alert_id\":\"$ALERT_ID\",\"hostname\":\"$TARGET\",\"metric\":\"ping\",\"value\":\"$PING_RESULT\",\"threshold\":\"reachability\",\"severity\":\"$SEVERITY\",\"state\":\"$STATE\",\"timestamp\":\"$TIMESTAMP\"}"

    # publish to Redis channel "vm-alerts"
    # redis-cli PUBLISH sends message to subscribers on that channel
    redis-cli PUBLISH vm-alerts "$ALERT" > /dev/null 2>&1

    echo "STATE CHANGE DETECTED: $TARGET is $STATE — alert published to Redis"
fi