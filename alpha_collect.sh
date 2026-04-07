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
MEM_USED= $MEM_TOTAL - $MEM_AVAIL
MEM_P= ($MEM_USED/$MEM_TOTAL)*100

