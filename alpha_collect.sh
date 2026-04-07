 #!/usr/bin/env bash

CONFIG="config/settings.json"

PEER_HOST=$(jq -r '.peer_hostname' "$CONFIG")

DATA_DIR=$(jq -r  '.data_dir' "$CONFIG" | sed "s|~|$HOME|g")
LOG_DIR=$(jq -r   '.log_dir' "$CONFIG" | sed "s|~|$HOME|g")

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
#we use basename to strip the path and xargs -I{} to inforce basename
TOP_PROCS=$(ps aux --sort=-%cpu | awk 'NR!=1 {print $11}' | head -5 | xargs -I{} basename {})
