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
    elif awk "BEGIN {exit !($VALUE >= $WARN)}"; then
        SEVERITY="WARNING"
    else
        return 0
    fi

    #TODO write alert and publish to redis
}
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

      check_metric "cpu_pct"  "$CPU"  "$CPU_WARN"  "$CPU_CRIT"  "$TS" "$HOST"
      check_metric "mem_pct"  "$MEM"  "$MEM_WARN"  "$MEM_CRIT"  "$TS" "$HOST"
      check_metric "disk_pct" "$DISK" "$DISK_WARN" "$DISK_CRIT" "$TS" "$HOST"
  done
  sleep "$INTERVAL"
done

