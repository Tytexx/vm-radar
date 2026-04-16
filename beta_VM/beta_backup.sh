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
mkdir -p "$BACKUP_DIR" #make directories -p = if we need it
mkdir -p "$BACKUP_LOG_DIR"
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
ARCHIVE_TARGETS=() #empty array
[ -f "$DATA_DIR/metrics.json" ] && ARCHIVE_TARGETS+=("$DATA_DIR/metrics.json")

#&& is the same as if true for this so conditionally adding to array
[ -d "$LOG_DIR" ] && ARCHIVE_TARGETS+=("$LOG_DIR")
#ie here if logdir is a directory then add it to archive targets array
[ -d "$INBOX_DIR" ] && ARCHIVE_TARGETS+=("$INBOX_DIR")
 
if [ ${#ARCHIVE_TARGETS[@]} -eq 0 ]; then #if empty by taking number of elements # is count @ is all elements within array
    echo "There is nothing to be archived"
else
    tar -czf "$TEMP_ARCHIVE" --ignore-failed-read "${ARCHIVE_TARGETS[@]}" 2>/dev/null || true #czf create,compress,output to next. skips unreadable files
    #redirect errors to void. dont stop if tar fails
    ARCHIVE_SIZE=$(du -sh "$TEMP_ARCHIVE" 2>/dev/null | cut -f1) #get archive size(du-sh), hide errors and then split into fields and take first field (size)
   #du is disk usage 
    echo "Temporary archive created under: $TEMP_ARCHIVE ($ARCHIVE_SIZE)"
fi

echo "Encrypting archive with GPG"
#pass based encryp
#no inputs needed
#read the passphrase from stdin
#where encrypted files sent
#only tries encryption if there even is a file
#gpg takes password using stdin

if [ -f "$TEMP_ARCHIVE" ]; then
    echo "$PASSPHRASE" | gpg \
        --symmetric \
        --batch \
        --passphrase-fd 0 \
        --output "$BACKUP_PATH" \
        "$TEMP_ARCHIVE"
    rm -f "$TEMP_ARCHIVE" 
    #remove the unencrypted file after encryption
    ENCRYPTED_SIZE=$(du -sh "$BACKUP_PATH" 2>/dev/null | cut -f1) 
    #same as before=get archive size(du-sh), hide errors and then split into fields and take first field (size)
    #du is disk usage 
    echo "BACKUP created $BACKUP_PATH (size=${ENCRYPTED_SIZE})"
else
    echo "Skipping encryption since no archive was created)."
fi

echo "Rotating Logs "
while IFS= read -r -d '' LOG_FILE;  #IFS is international field separator but w empty after so dont split
#while its reading put into log file. -r to avoid \ and '' is the delimiter = null is delimiter = \0 all looking in logfile
    do
    BASENAME=$(basename "$LOG_FILE") #basename returns just directory name = take only file name and make that the basename
    gzip "$LOG_FILE" #compress with gzip
    COMPRESSED_FILE="${LOG_FILE}.gz" #adds .gz to the og file name
    # Move the compressed log to the backup/logs archive directory
    mv "$COMPRESSED_FILE" "$BACKUP_LOG_DIR/${BASENAME}.gz" #move compressed file into backup log archive dir
    ROTATED_COUNT=$((ROTATED_COUNT + 1)) 
    echo "Rotated: $BASENAME into: ~/backup/logs/${BASENAME}.gz"
done < <(find "$LOG_DIR" -maxdepth 1 -name "*.log" -mtime +7 -type f -print0 2>/dev/null) #take input and feed into the beginning of the loop
#search in log dir but the current folder only (maxdepth -1) ie not a file withn a file only the main one, and only the files ending in .log (-name...) 
#make sure they were modified more than 7 days ago, are type file not dir, and seperate the results w null instead of ' ', then hide errors
echo "ROTATED $ROTATED_COUNT log files to ~/backup/logs/" #display amount rotated

echo "Deleting old backup archives (more than 30 days)"
while IFS= read -r -d '' OLD_BACKUP; 
do #keep taking inputs and store in the old backup
    rm -f "$OLD_BACKUP" #remove files from old backup
    DELETED_COUNT=$((DELETED_COUNT + 1)) #increment count
    echo "Deleted: $(basename "$OLD_BACKUP")" #basename just so output isnt the entire path w home user etc 
    #instead just says u deleted x from backups
done < <(find "$BACKUP_DIR" -maxdepth 1 -name "*.tar.gz.gpg" -mtime +30 -type f -print0 2>/dev/null) 
#delete smth last updated more than 30 days ago ending in tar.gz.gpg type file and hide errors
#searching current folder again means only file a not file a.1
echo "DELETED $DELETED_COUNT backups that were older than 30 days"

echo "Clean up: Removing processed files from ~/exchange/inbox/ and ~/exchange/outbox/ older than 3 days"
while IFS= read -r -d '' STALE_FILE; do
    rm -f "$STALE_FILE"
    CLEANED_COUNT=$((CLEANED_COUNT + 1))
done < <(find "$INBOX_DIR" -type f -mtime +3 -print0 2>/dev/null)
# Clean inbox — remove .gpg files older than 3 days. Same main idea as when we deleted old archives just looking somewhere else
# Clean outbox — remove .json and .gpg files older than 3 days
while IFS= read -r -d '' STALE_FILE; do
    rm -f "$STALE_FILE" #remove it then inc
    CLEANED_COUNT=$((CLEANED_COUNT + 1))
done < <(find "$OUTBOX_DIR" -type f -mtime +3 -print0 2>/dev/null) #check that its older than 3 days
echo "CLEANED $CLEANED_COUNT stale file"

