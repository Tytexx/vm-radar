#!/bin/bash

#take values from config
CONFIG="config/settings.json"
THRESHOLDS="config/thresholds.json"

INTERVAL=$(jq -r '.collect_interval_sec' "$CONFIG")
REDIS_HOST=$(jq -r '.redis_host' "$CONFIG")
DATA_DIR=$(jq -r '.data_dir' "$CONFIG" | sed "s|~|$HOME|g")
LOG_DIR=$(jq -r '.log_dir' "$CONFIG" | sed "s|~|$HOME|g")

#take thresholds
CPU_WARN=$(jq -r '.cpu_warn' "$THRESHOLDS")
CPU_CRIT=$(jq -r '.cpu_crit' "$THRESHOLDS")
MEM_WARN=$(jq -r '.mem_warn' "$THRESHOLDS")
MEM_CRIT=$(jq -r '.mem_crit' "$THRESHOLDS")
DISK_WARN=$(jq -r '.disk_warn' "$THRESHOLDS")
DISK_CRIT=$(jq -r '.disk_crit' "$THRESHOLDS")

METRICS_FILE="$DATA_DIR/metrics.json"

#use awk to calculate if metrics are under threshold
check_metric() {
    local METRIC_NAME=$1
    local VALUE=$2
    local WARN=$3
    local CRIT=$4
    local TIMESTAMP=$5
    local HOST=$6

    if awk "BEGIN {exit !($VALUE >= $CRIT)}"; then
        SEVERITY="CRITICAL"
        THRESHOLD=$CRIT
    elif awk "BEGIN {exit !($VALUE >= $WARN)}"; then
        SEVERITY="WARNING"
        THRESHOLD=$WARN
    else
        return 0
    fi

    #create the alert json with jq
    #create the ALERT_ID
    ALERT_SEQ=$((ALERT_SEQ + 1))
    ALERT_ID="ALT_$(date -u +"%Y%m%d_%H%M%S")_$(printf '%04d' $ALERT_SEQ)"
    #create ALERT OBJECT
    ALERT=$(jq -n \
      --arg alert_id "$ALERT_ID" \
      --arg hostname "$HOSTNAME" \
      --arg metric "$METRIC_NAME" \
      --argjson value "$VALUE" \
      --argjson threshold "$THRESHOLD" \
      --arg severity "$SEVERITY" \
      --arg timestamp "$TIMESTAMP" \
      '{
          alert_id: $alert_id,
          hostname: $hostname,
          metric: $metric,
          value: $value,
          threshold: $threshold,
          severity: $severity,
          timestamp: $timestamp,
      }')
    
    #add to logs
    ALERTS_LOG="$LOG_DIR/alerts.log"
    echo "$ALERT" >> "$ALERTS_LOG"

    #TODO publish to redis

    }

ALERT_SEQ=0
ALERTS_LOG="$LOG_DIR/alerts.log"
mkdir -p "$LOG_DIR"

while true; do
  #take a list of hostnames
  HOSTNAMES=$(jq -r '[.[].hostname] | unique | .[]' "$METRICS_FILE")
  #for each host get each metric of the latest snapshot
  for HOST in $HOSTNAMES; do
      SNAP=$(jq --arg h "$HOST" '[.[] | select(.hostname == $h)] | last' "$METRICS_FILE")
      
      CPU=$(echo  "$SNAP" | jq -r '.cpu_pct')
      MEM=$(echo  "$SNAP" | jq -r '.mem_pct')
      DISK=$(echo "$SNAP" | jq -r '.disk_pct')
      TS=$(echo   "$SNAP" | jq -r '.timestamp')
      #call check_metric() to compare against threshold
      check_metric "cpu_pct"  "$CPU"  "$CPU_WARN"  "$CPU_CRIT"  "$TS" "$HOST"
      check_metric "mem_pct"  "$MEM"  "$MEM_WARN"  "$MEM_CRIT"  "$TS" "$HOST"
      check_metric "disk_pct" "$DISK" "$DISK_WARN" "$DISK_CRIT" "$TS" "$HOST"
  done
  sleep "$INTERVAL"
done

