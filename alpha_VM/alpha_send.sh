#!/bin/bash

# jq reads JSON files - Please change the variables to actual names when executing
SETTINGS="$(dirname "$0")/config/settings.json" #Load config files

PEER_HOST=$(jq -r '.peer_hostname' "$SETTINGS")   #beta-vm
PEER_USER=$(jq -r '.peer_user' "$SETTINGS")        #qustudent
SSH_KEY=$(jq -r '.ssh_key' "$SETTINGS")            #~/.ssh/id_rsa
DATA_FILE=$(jq -r '.data_dir' "$SETTINGS")/metrics.json
LOG_SENT="$HOME/logs/sent"
LOG_REJECTED="$HOME/logs/rejected"
OUTBOX="$HOME/exchange/outbox"
INBOX="$HOME/exchange/inbox"

SSH_KEY="${SSH_KEY/#\~/$HOME}"
DATA_FILE="${DATA_FILE/#\~/$HOME}"

# gpg identities
PEER_EMAIL="beta@vm.local"
MY_EMAIL="alpha@vm.local"

#Counters - used for log summary
SENT_COUNT=0
VALID_COUNT=0
REJECTED_COUNT=0

# SENDING MECHANISM

#Scan outbox
for JSON_FILE in "$OUTBOX"/*.json; do

    [ -f "$JSON_FILE" ] || continue

    FILENAME=$(basename "$JSON_FILE")
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    GPG_FILE="${JSON_FILE}.gpg"

    echo "Encrypting $FILENAME..."

    # Encryption of the file using peer's public key
    gpg --recipient "$PEER_EMAIL" \
        --trust-model always \
        --encrypt \
        --output "$GPG_FILE" \
        "$JSON_FILE"

    if [ $? -ne 0 ]; then
        echo "ERROR: Failed to encrypt $FILENAME"
        continue
    fi

    # SCP encrypted file to peer
    scp -i "$SSH_KEY" \
        -o StrictHostKeyChecking=no \
        "$GPG_FILE" \
        "${PEER_USER}@${PEER_HOST}:~/exchange/inbox/"   

    if [ $? -ne 0 ]; then
        echo "ERROR: Failed to SCP $FILENAME to $PEER_HOST"
        rm -f "$GPG_FILE"
        continue
    fi

    mv "$JSON_FILE" "$LOG_SENT/${TIMESTAMP}_${FILENAME}"

    rm -f "$GPG_FILE"

    SENT_COUNT=$((SENT_COUNT + 1))
    echo "Sent $FILENAME to $PEER_HOST"
done

# RECEIVING MECHANISM
for GPG_FILE in "$INBOX"/*.json.gpg; do

    [ -f "$GPG_FILE" ] || continue

    FILENAME=$(basename "$GPG_FILE")
    DECRYPTED_FILE="${GPG_FILE%.gpg}"

    echo "Decrypting $FILENAME..."

    # Decrypt using Alpha's private key
    gpg --decrypt \
        --output "$DECRYPTED_FILE" \
        "$GPG_FILE" 2>/dev/null

    if [ $? -ne 0 ]; then
        echo "ERROR: Failed to decrypt $FILENAME"
        echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) REJECTED $FILENAME" >> "$HOME/logs/exchange.log"

        mv "$GPG_FILE" "$LOG_REJECTED/$FILENAME"

        REJECTED_COUNT=$((REJECTED_COUNT + 1))
        continue
    fi

    # Check if decrypted file is valid JSON
    if ! jq empty "$DECRYPTED_FILE" 2>/dev/null; then
        echo "ERROR: Decrypted file is not valid JSON: $FILENAME"
        mv "$GPG_FILE" "$LOG_REJECTED/$FILENAME"
        rm -f "$DECRYPTED_FILE"
        REJECTED_COUNT=$((REJECTED_COUNT + 1))
        continue
    fi

    TEMP_FILE=$(mktemp)
    jq ". + [$(cat "$DECRYPTED_FILE")]" "$DATA_FILE" > "$TEMP_FILE"
    mv "$TEMP_FILE" "$DATA_FILE"

    rm -f "$GPG_FILE" "$DECRYPTED_FILE"

    VALID_COUNT=$((VALID_COUNT + 1))
    echo "Received and stored snapshot from peer"
done

# Update logs
echo "SENT $SENT_COUNT files to $PEER_HOST | RECEIVED $((VALID_COUNT + REJECTED_COUNT)) files (valid=$VALID_COUNT rejected=$REJECTED_COUNT)"

echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) SENT=$SENT_COUNT RECEIVED=$VALID_COUNT REJECTED=$REJECTED_COUNT" >> "$HOME/logs/exchange.log"