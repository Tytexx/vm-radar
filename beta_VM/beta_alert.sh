#!/bin/bash

# find where settings.json is
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETTINGS="$SCRIPT_DIR/config/settings.json"

# find redis connection details from JSON config
REDIS_HOST=$(jq -r '.redis_host' "$SETTINGS")
REDIS_PORT=$(jq -r '.redis_port' "$SETTINGS")

DATA_FILE="$HOME/data/metrics.json"
PEER_ALERTS_LOG="$HOME/logs/peer_alerts.log"
LOCAL_ALERTS_LOG="$HOME/logs/alerts.log"
THRESHOLDS="$SCRIPT_DIR/config/thresholds.json"

CHANNEL="vm-alerts"

# analyze the local metrics and trigger alerts
run_local_analysis() {

    CPU_WARN=$(jq -r '.cpu_warn'  "$THRESHOLDS")
    CPU_CRIT=$(jq -r '.cpu_crit'  "$THRESHOLDS")
    MEM_WARN=$(jq -r '.mem_warn'  "$THRESHOLDS")
    MEM_CRIT=$(jq -r '.mem_crit'  "$THRESHOLDS")
    DISK_WARN=$(jq -r '.disk_warn' "$THRESHOLDS")
    DISK_CRIT=$(jq -r '.disk_crit' "$THRESHOLDS")


    if [ ! -f "$DATA_FILE" ]; then
        return
    fi

    ENTRY_COUNT=$(jq 'length' "$DATA_FILE" 2>/dev/null)

    if [ -z "$ENTRY_COUNT" ] || [ "$ENTRY_COUNT" -eq 0 ]; then
        return
    fi

    HOSTNAMES=$(jq -r '.[].hostname' "$DATA_FILE" 2>/dev/null | sort -u)
    TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    while IFS= read -r HOSTNAME; do
        SNAPSHOT=$(jq -r --arg h "$HOSTNAME" \
            '[.[] | select(.hostname == $h)] | last' \
            "$DATA_FILE" 2>/dev/null)

        CPU=$(echo  "$SNAPSHOT" | jq -r '.cpu_pct  // 0')
        MEM=$(echo  "$SNAPSHOT" | jq -r '.mem_pct  // 0')
        DISK=$(echo "$SNAPSHOT" | jq -r '.disk_pct // 0')

        # cpu checks
        if [ "$(echo "$CPU > $CPU_CRIT" | bc -l)" = "1" ]; then
            publish_local_alert "$HOSTNAME" "cpu_pct" "$CPU" "$CPU_CRIT" "CRITICAL" "$TIMESTAMP"
        elif [ "$(echo "$CPU > $CPU_WARN" | bc -l)" = "1" ]; then
            publish_local_alert "$HOSTNAME" "cpu_pct" "$CPU" "$CPU_WARN" "WARNING" "$TIMESTAMP"
        fi

        if [ "$(echo "$MEM > $MEM_CRIT" | bc -l)" = "1" ]; then
            publish_local_alert "$HOSTNAME" "mem_pct" "$MEM" "$MEM_CRIT" "CRITICAL" "$TIMESTAMP"
        elif [ "$(echo "$MEM > $MEM_WARN" | bc -l)" = "1" ]; then
            publish_local_alert "$HOSTNAME" "mem_pct" "$MEM" "$MEM_WARN" "WARNING" "$TIMESTAMP"
        fi

        if [ "$(echo "$DISK > $DISK_CRIT" | bc -l)" = "1" ]; then
            publish_local_alert "$HOSTNAME" "disk_pct" "$DISK" "$DISK_CRIT" "CRITICAL" "$TIMESTAMP"
        elif [ "$(echo "$DISK > $DISK_WARN" | bc -l)" = "1" ]; then
            publish_local_alert "$HOSTNAME" "disk_pct" "$DISK" "$DISK_WARN" "WARNING" "$TIMESTAMP"
        fi

    done <<< "$HOSTNAMES"
}

# Create and send alerts
publish_local_alert() {
    local HOSTNAME="$1"
    local METRIC="$2"
    local VALUE="$3"
    local THRESHOLD="$4"
    local SEVERITY="$5"
    local TIMESTAMP="$6"

    # generate an unique alert ID using timestamp and a random number
    local ALERT_ID="ALT_$(date +%Y%m%d_%H%M%S)_$(shuf -i 1000-9999 -n 1)"

    # Build alert JSON string
    local ALERT="{\"alert_id\":\"$ALERT_ID\",\"hostname\":\"$HOSTNAME\",\"metric\":\"$METRIC\",\"value\":$VALUE,\"threshold\":$THRESHOLD,\"severity\":\"$SEVERITY\",\"timestamp\":\"$TIMESTAMP\"}"

    # Save alerts locally
    echo "$ALERT" >> "$LOCAL_ALERTS_LOG"

    # Publish alert to Redis channel (silent mode)
    redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" \
        PUBLISH "$CHANNEL" "$ALERT" > /dev/null 2>&1

    # Print alert summary to console
    if [ "$SEVERITY" = "CRITICAL" ]; then
        echo "[CRIT] $TIMESTAMP $HOSTNAME ${METRIC}=${VALUE} (threshold=${THRESHOLD})"
    else
        echo "[WARN] $TIMESTAMP $HOSTNAME ${METRIC}=${VALUE} (threshold=${THRESHOLD})"
    fi
}

# These are starup messages
RETRY_DELAY=2    # Initial reconnect delay

echo "Starting beta_alert.sh"
echo "Subscribing to Redis at $REDIS_HOST:$REDIS_PORT channel: $CHANNEL"
echo "Press Ctrl+C to stop"
echo ""

# Run analysis before listening to alerts
echo "Running initial local threshold analysis..."
run_local_analysis

# Main loop listens for alerts from Redis
while true; do

    echo "Connecting to Redis $REDIS_HOST:$REDIS_PORT..."

    # Subscribe to Redis channel and read incoming messages line by line
    redis-cli -h "$REDIS_HOST" \
              -p "$REDIS_PORT" \
              SUBSCRIBE "$CHANNEL" 2>/dev/null | \

    while IFS= read -r redis_line; do

        if [[ "$redis_line" == "{"* ]]; then
            # Process only JSON messages so that subscription metadata is ignored
            RECEIVED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)

            # Log received alert
            echo "$redis_line" >> "$PEER_ALERTS_LOG"

            # Extract fields from JSON
            SEVERITY=$(echo "$redis_line" | jq -r '.severity // "UNKNOWN"' 2>/dev/null)
            HOSTNAME=$(echo "$redis_line" | jq -r '.hostname // "unknown"' 2>/dev/null)
            METRIC=$(echo "$redis_line"   | jq -r '.metric // "unknown"' 2>/dev/null)
            VALUE=$(echo "$redis_line"    | jq -r '.value // "?"' 2>/dev/null)
            THRESHOLD=$(echo "$redis_line" | jq -r '.threshold // "?"' 2>/dev/null)

            # Print received alert
            if [ "$SEVERITY" = "CRITICAL" ]; then
                echo "[CRIT] $RECEIVED_AT $HOSTNAME ${METRIC}=${VALUE} (threshold=${THRESHOLD})"
            else
                echo "[WARN] $RECEIVED_AT $HOSTNAME ${METRIC}=${VALUE} (threshold=${THRESHOLD})"
            fi
            # Re-run local analysis after receiving an alert
            run_local_analysis
        fi

    done

    # print when Redis is disconnected
    echo "Reached here"
    echo "WARNING: Redis connection lost. Retrying in ${RETRY_DELAY}s..."
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) Redis connection lost, retry in ${RETRY_DELAY}s" >> "$PEER_ALERTS_LOG"

    sleep "$RETRY_DELAY"

    # Exponential backoff (max 60s)
    #Without this, the script would retry too fast and waste CPU/network
    RETRY_DELAY=$((RETRY_DELAY * 2))
    if [ "$RETRY_DELAY" -gt 60 ]; then
        RETRY_DELAY=60
    fi
done
