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

#take a list of hostnames
HOSTNAMES=$(jq -r '[.[].hostname] | unique | .[]' "$METRICS_FILE")
#for each host get each metric of the latest snapshot
for HOST in $HOSTNAMES; do
    SNAP=$(jq --arg h "$HOST" '[.[] | select(.hostname == $h)] | last' "$METRICS_FILE")
    
    CPU=$(echo  "$SNAP" | jq -r '.cpu_pct')
    MEM=$(echo  "$SNAP" | jq -r '.mem_pct')
    DISK=$(echo "$SNAP" | jq -r '.disk_pct')
    TS=$(echo   "$SNAP" | jq -r '.timestamp')
done

