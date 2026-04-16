#!/bin/bash

# beta_send.sh

SETTINGS="$(dirname "$0")/config/settings.json"

PEER_HOST=$(jq -r '.peer_hostname' "$SETTINGS")
PEER_USER=$(jq -r '.peer_user' "$SETTINGS")
SSH_KEY=$(jq -r '.ssh_key' "$SETTINGS")
SSH_KEY="${SSH_KEY/#\~/$HOME}"

# data file under home
DATA_FILE="$HOME/data/metrics.json"

LOG_SENT="$HOME/logs/sent"
LOG_REJECTED="$HOME/logs/rejected"
EXCHANGE_LOG="$HOME/logs/exchange.log"
OUTBOX="$HOME/exchange/outbox"
INBOX="$HOME/exchange/inbox"

# These two lines are the only real difference from alpha_send.sh
# Beta encrypts FOR Alpha, and decrypts AS Beta
PEER_GPG_EMAIL="alpha@vm.local"
MY_GPG_EMAIL="beta@vm.local"

SENT_COUNT=0
VALID_COUNT=0
REJECTED_COUNT=0

# Send outgoing files to Alpha

for JSON_FILE in "$OUTBOX"/*.json; do

    [ -f "$JSON_FILE" ] || continue

    FILENAME=$(basename "$JSON_FILE")
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    GPG_FILE="${JSON_FILE}.gpg"

    echo "Encrypting: $FILENAME"

    # Encrypt using Alpha's public key
    gpg --recipient "$PEER_GPG_EMAIL" \
        --trust-model always \
        --encrypt \
        --output "$GPG_FILE" \
        "$JSON_FILE"

    if [ $? -ne 0 ]; then
        echo "ERROR: GPG encryption failed for $FILENAME"
        continue
    fi

    # SCP to Alpha's inbox
    scp -i "$SSH_KEY" \
        -o StrictHostKeyChecking=no \
        "$GPG_FILE" \
        "${PEER_USER}@${PEER_HOST}:~/exchange/inbox/"

    if [ $? -ne 0 ]; then
        echo "ERROR: SCP failed for $FILENAME"
        rm -f "$GPG_FILE"
        continue
    fi

    mv "$JSON_FILE" "$LOG_SENT/${TIMESTAMP}_${FILENAME}"
    rm -f "$GPG_FILE"
    SENT_COUNT=$((SENT_COUNT + 1))
    echo "Sent: $FILENAME"
done

# Receive and decrypt files Alpha sent us

for GPG_FILE in "$INBOX"/*.json.gpg; do

    [ -f "$GPG_FILE" ] || continue

    FILENAME=$(basename "$GPG_FILE")
    DECRYPTED_FILE="${GPG_FILE%.gpg}"

    echo "Decrypting: $FILENAME"

    # use Beta's private key to decrypt
    gpg --decrypt \
        --output "$DECRYPTED_FILE" \
        "$GPG_FILE" 2>/dev/null

    if [ $? -ne 0 ]; then
        echo "ERROR: Decryption failed for $FILENAME"
        echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) REJECTED $FILENAME" >> "$EXCHANGE_LOG"
        mv "$GPG_FILE" "$LOG_REJECTED/$FILENAME"
        REJECTED_COUNT=$((REJECTED_COUNT + 1))
        continue
    fi

    if ! jq empty "$DECRYPTED_FILE" 2>/dev/null; then
        echo "ERROR: Not valid JSON: $FILENAME"
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
    echo "Stored peer snapshot into metrics.json"
done

SUMMARY="SENT $SENT_COUNT files to $PEER_HOST | RECEIVED $((VALID_COUNT + REJECTED_COUNT)) files (valid=$VALID_COUNT rejected=$REJECTED_COUNT)"
echo "$SUMMARY"
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $SUMMARY" >> "$EXCHANGE_LOG"