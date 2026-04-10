 #!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$SCRIPT_DIR/config/settings.json"

PEER_HOST=$(jq -r '.peer_hostname' "$CONFIG")

DATA_DIR=$(jq -r  '.data_dir' "$CONFIG" | sed "s|~|$HOME|g")
LOG_DIR=$(jq -r   '.log_dir' "$CONFIG" | sed "s|~|$HOME|g")
METRICS_FILE="$DATA_DIR/metrics.json"

#if directories do not exist
mkdir -p "$DATA_DIR"
mkdir -p "$LOG_DIR"
mkdir -p "$HOME/exchange/outbox"

#intialize metrics.json if it doesn't exist
if [[ ! -f "$DATA_DIR/metrics.json" ]]; then
    echo '[]' > "$DATA_DIR/metrics.json"
fi

#get the memory metrics from files stored in /proc/meminfo
MEM_TOTAL=$(grep MemTotal /proc/meminfo | awk '{print $2}')
MEM_AVAIL=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
MEM_USED=$((MEM_TOTAL - MEM_AVAIL))
MEM_PCT=$(awk "BEGIN {printf \"%.1f\", ($MEM_USED / $MEM_TOTAL) * 100}")
#get the disc metric using df
#gsub used to get rid of % sign at the end
DISK_PCT=$(df -h / | awk 'NR==2 {gsub(/%/,"",$5); print $5}')
#get the loadavg from /proc/load/avg
LOAD_AVG=$(awk '{print $1}' /proc/loadavg)
#get cpu idle % using top
# -bn1 or batch mode used to make it non interactive
CPU_PCT=$(top -bn1 | grep "Cpu(s)" | awk '{print 100 - $8}')
#get the top 5 processes using cpu using ps aux
#we use basename to strip the path and xargs -I{} to inforce basename and jq to turn it into an array
TOP_PROCS=$(ps aux --sort=-%cpu | awk 'NR!=1 {print $11}' | head -5 | xargs -I{} basename {} | jq -R . | jq -sc .)

HOSTNAME=$(hostname)
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
#id using count implemented using length function of jq
CURRENT_COUNT=$(jq 'length' "$DATA_DIR/metrics.json")
SNAP_ID=$((CURRENT_COUNT + 1))

#create the object to store in the json
SNAPSHOT=$(jq -n \
  --argjson id "$SNAP_ID" \
  --arg timestamp "$TIMESTAMP" \
  --arg hostname "$HOSTNAME" \
  --argjson cpu_pct "$CPU_PCT" \
  --argjson mem_pct "$MEM_PCT" \
  --argjson disk_pct "$DISK_PCT" \
  --arg load_avg "$LOAD_AVG" \
  --argjson top_procs "$TOP_PROCS" \
  '{
      id:        $id,
      timestamp: $timestamp,
      hostname:  $hostname,
      cpu_pct:   $cpu_pct,
      mem_pct:   $mem_pct,
      disk_pct:  $disk_pct,
      load_avg:  $load_avg,
      top_procs: $top_procs
  }')
  
# Writing to `~/data/metrics.json`
#write to a temporary json since we cant read and write to the same file at the same time
TMP=$(mktemp)
#append the snapshot object to the file '.' from METRICS_FILE and store it in temp
jq --argjson snap "$SNAPSHOT" '. + [$snap]' "$METRICS_FILE" > "$TMP"
#replace the METRICS_FILE with our temp which has the appended snapshot
mv "$TMP" "$METRICS_FILE"

# Writing to `~/exchange/outbox/...`
TIMESTAMP_FILE=$(date -u +"%Y%m%d_%H%M%S")
OUTBOX="$HOME/exchange/outbox"
echo "$SNAPSHOT" > "$OUTBOX/snapshot_${TIMESTAMP_FILE}.json"

#printing confirmation
echo "COLLECTED snapshot_${TIMESTAMP_FILE}.json (cpu=${CPU_PCT}%, mem=${MEM_PCT}%, disk=${DISK_PCT}%)"
