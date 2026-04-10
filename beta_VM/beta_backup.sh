#!/bin/bash
#Create encrypted backups of monitoring data, rotate old logs, and clean up stale files
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config/settings.json"
DATA_DIR=$(jq -r '.data_dir' "$CONFIG_FILE" | sed "s|~|$HOME|g") #read data.dir from configfile then output it to home.sed=replace~ w HOME
LOG_DIR=$(jq -r '.log_dir' "$CONFIG_FILE" | sed "s|~|$HOME|g") #g means replace all (all the ~)
PASSPHRASE_ENV=$(jq -r '.backup_passphrase_env' "$CONFIG_FILE") #jq is for parsing json . this just means passphraseenv is now 
#equal to whatever is equal to .backup_passphrase_env. CONFIGFILE is path/where
BACKUP_DIR="$HOME/backup"
BACKUP_LOG_DIR="$HOME/backup/logs"
INBOX_DIR="$HOME/exchange/inbox"
OUTBOX_DIR="$HOME/exchange/outbox"
PASSPHRASE="${!PASSPHRASE_ENV}"  #passphrase is now = whatever is inside of passphrase_env
if [ -z "$PASSPHRASE" ]; then #if empty
    echo "Environment variable: '$PASSPHRASE_ENV' is empty" #environment variable is what its called when you refer to something being referred to (line 8)
    exit 1
fi
#for filename to be datestamped
DATE=$(date +"%d%m%Y") 
TIMESTAMP=$(date +"%d-%m-%YT%H:%M:%S")
BACKUP_FILENAME="backup_${DATE}.tar.gz.gpg" #.tar to archive then gz compress, gpg encrypt. Date will be part of name basically
BACKUP_PATH="$BACKUP_DIR/$BACKUP_FILENAME"
TEMP_ARCHIVE="/tmp/vm_backup_${DATE}.tar.gz"
ROTATED_COUNT=0
CLEANED_COUNT=0
DELETED_COUNT=0

echo "Creating compressed archive"
ARCHIVE_TARGETS=()
[ -f "$DATA_DIR/metrics.json" ] && ARCHIVE_TARGETS+=("$DATA_DIR/metrics.json")
[ -d "$LOG_DIR" ] && ARCHIVE_TARGETS+=("$LOG_DIR")
[ -d "$INBOX_DIR" ] && ARCHIVE_TARGETS+=("$INBOX_DIR")
 
if [ ${#ARCHIVE_TARGETS[@]} -eq 0 ]; then
    echo "      WARNING: Nothing to archive. Skipping."
else
    tar -czf "$TEMP_ARCHIVE" --ignore-failed-read "${ARCHIVE_TARGETS[@]}" 2>/dev/null || true
    ARCHIVE_SIZE=$(du -sh "$TEMP_ARCHIVE" 2>/dev/null | cut -f1)
    echo "      Temporary archive created: $TEMP_ARCHIVE ($ARCHIVE_SIZE)"
fi
