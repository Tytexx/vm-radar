#!/bin/bash
echo "VM is being set up..."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETTINGS_FILE="$SCRIPT_DIR/config/settings.json"

echo "Installing packages..."
sudo apt-get update -qq
sudo apt-get install -y redis-tools redis-server jq gnupg # jq for JSON files; redis-tools + redis-server for beta Redis support
# gnupg for encryption
sudo systemctl enable redis-server
sudo systemctl start redis-server
sudo systemctl status redis-server --no-pager || true
echo "Packages have been installed."

echo "Creating directory layout..."
mkdir -p ~/data #means create directory if needed which is called x in the parent directory(directory above(ie exchange parent of inbox))
mkdir -p ~/exchange/inbox
mkdir -p ~/exchange/outbox
mkdir -p ~/logs/sent
mkdir -p ~/logs/rejected
mkdir -p ~/backup/logs
echo "Directories have been created."


mkdir -p ~/exchange/{inbox,outbox}
mkdir -p ~/logs/{sent,rejected}
mkdir -p ~/data
mkdir -p ~/backup/logs


# Data file 
echo '[]' > ~/data/metrics.json

# initialize log files
touch ~/logs/health.log
touch ~/logs/alerts.log
touch ~/logs/exchange.log
touch ~/logs/peer_alerts.log
touch ~/logs/log_summary.log
touch ~/logs/peer_alerts.log



echo "Files have been created."

echo "Initializing ~/data/metrics.json..." #main file
if [ ! -f ~/data/metrics.json ]; then #if it doesnt exist then make it else its alr there
    echo '[]' > ~/data/metrics.json #initialized as an empty JSON array
    echo "Created empty metrics.json."
else
    echo "metrics.json already exists, skipping." 
fi

echo "Setting up GPG key pair..."
GPG_NAME="beta-vm"
GPG_EMAIL="beta@vm.local"
if gpg --list-keys "$GPG_EMAIL" &>/dev/null; then # means &> its run silently and only checks if it exists
    echo "GPG key already exists for $GPG_EMAIL, skipping generation."
else 
    cat> /tmp/gpg_batch.txt <<EOF
%no-protection
Key-Type: RSA
Key-Length: 2048
Subkey-Type: RSA
Subkey-Length: 2048
Name-Real: $GPG_NAME
Name-Email: $GPG_EMAIL
Expire-Date: 0
%commit
EOF
#write all this into the txt file
    gpg --batch --gen-key /tmp/gpg_batch.txt #generate a gpg key for this email into the file without any input or anything
    rm -f /tmp/gpg_batch.txt #remove temp file since keys been created
    echo "GPG key generated for $GPG_EMAIL." 
fi
#exchange keys w alpha
gpg --armor --export "$GPG_EMAIL" > ~/beta_pubkey.gpg #armor for readable text - gpg exports it into beta_pubkey file (output file)
echo "Public key has been sent to ~/beta_pubkey.gpg"
#need to manually put ~/beta_pubkey.gpg into alpha then run  gpg --import ~/beta_pubkey.gpg

echo "Fetching peer public key..."
if [ -f "$SETTINGS_FILE" ]; then
    PEER_HOST=$(jq -r '.peer_hostname' "$SETTINGS_FILE")
    PEER_USER=$(jq -r '.peer_user' "$SETTINGS_FILE")
fi
PEER_HOST=${PEER_HOST:-alpha-vm}
PEER_USER=${PEER_USER:-alpha}

if [ -z "$PEER_HOST" ] || [ "$PEER_HOST" = "null" ]; then
    echo "ERROR: peer_hostname is missing from $SETTINGS_FILE and no fallback is available"
    exit 1
fi

if [ -z "$PEER_USER" ] || [ "$PEER_USER" = "null" ]; then
    echo "ERROR: peer_user is missing from $SETTINGS_FILE and no fallback is available"
    exit 1
fi

# download peer public key from the configured peer hostname
scp -i ~/.ssh/id_rsa "$PEER_USER@$PEER_HOST:~/alpha_pubkey.gpg" ~/alpha_pubkey.gpg

# import peer public key into GPG
gpg --import ~/alpha_pubkey.gpg

echo "Peer public key imported successfully."

echo "Creating config/settings.json..."
mkdir -p "$SCRIPT_DIR/config"
cat > "$SCRIPT_DIR/config/settings.json" <<EOF
{
  "peer_hostname": "alpha-vm",
  "peer_user": "alpha",
  "ssh_key": "~/.ssh/id_rsa",
  "collect_interval_sec": 60,
  "exchange_interval_sec": 300,
  "data_dir": "~/data",
  "log_dir": "~/logs",
  "redis_host": "alpha-vm",
  "redis_port": 6379,
  "backup_passphrase_env": "VM_BACKUP_KEY"
}
EOF
#write everything into the JSON which is the now new settings.json
echo "successfully made config/settings.json"

echo "Creating config/thresholds.json"
cat > "$SCRIPT_DIR/config/thresholds.json" <<EOF
{
  "cpu_warn": 70,
  "cpu_crit": 90,
  "mem_warn": 75,
  "mem_crit": 90,
  "disk_warn": 80,
  "disk_crit": 95
}
EOF
#created the file and write the json into it with all the warnings
echo "config/thresholds.json successfully made."
#thresholds.json basically just stores all the warning and critical thresholds

echo "Ensuring host name resolution for peer hostname..."
SETTINGS_FILE="$SCRIPT_DIR/config/settings.json"
PEER_HOSTNAME=$(jq -r '.peer_hostname' "$SETTINGS_FILE")
LOCAL_HOSTNAME=$(hostname)
PEER_IP="${VM_PEER_IP:-${VM_ALPHA_IP:-}}"
LOCAL_IP="${VM_LOCAL_IP:-${VM_BETA_IP:-$(hostname -I | awk '{print $1}')}}"

if [ -z "$PEER_HOSTNAME" ] || [ "$PEER_HOSTNAME" = "null" ]; then
    echo "WARNING: Could not read peer_hostname from $SETTINGS_FILE; host entries will not be added."
else
    if [ -n "$PEER_IP" ] && ! grep -qE "^[^#]*\b$PEER_HOSTNAME\b" /etc/hosts; then
        echo "Adding $PEER_IP $PEER_HOSTNAME to /etc/hosts"
        echo "$PEER_IP $PEER_HOSTNAME" | sudo tee -a /etc/hosts >/dev/null
    fi
fi

if [ -n "$LOCAL_IP" ] && ! grep -qE "^[^#]*\b$LOCAL_HOSTNAME\b" /etc/hosts; then
    echo "Adding $LOCAL_IP $LOCAL_HOSTNAME to /etc/hosts"
    echo "$LOCAL_IP $LOCAL_HOSTNAME" | sudo tee -a /etc/hosts >/dev/null
fi

if [ -z "$PEER_IP" ]; then
    echo "WARNING: Set VM_PEER_IP or VM_ALPHA_IP environment variable before running this script to add the peer host entry automatically."
fi
if [ -z "$LOCAL_IP" ]; then
    echo "WARNING: Could not determine local IP address; local host entry was not added."
fi

echo "Setting permissions for all shell scripts"
find "$SCRIPT_DIR" -name "*.sh" -exec chmod +x {} \; #searches everything in SCRIPT_DR for everything ending with .sh
#so it looks for all shell files than adds the execute permission 
echo "All shell files are now executable."
#up to now is whats mostly non-specific to the VMs
echo "Creating systemd service unit file"
HOME_DIR=$(eval echo ~) #to get the home directory path: eval ~ so that ~ is full path to properly unify
# Determine the absolute path to beta_collect.sh from this script's location
BETA_DIR="$SCRIPT_DIR"
#next line is to make the systemd service file then writes everything in between the EOF into it. dev/null to hide output
#needed so everything constantly run rather than a one and done service type thing
sudo tee /etc/systemd/system/vm-monitor.service > /dev/null <<EOF
[Unit]
Description=VM Monitoring Service
After=network.target
[Service]
ExecStart=/home/beta/beta_VM/beta_service.sh
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
#[] are keywords to be recognized by systemd
#unit bit  Descrip is what it is and after means dont start until network is actually ready to accept everything
#Service execstart starts the whole beta service.sh and restart if theres any errors
#install basically just says run now so everything is continuous
echo "Systemd unit file created at /etc/systemd/system/vm-monitor.service"
sudo systemctl daemon-reload  #reload service files since systemd is new
# Enable the service so it starts automatically on boot
sudo systemctl enable vm-monitor #enable  service so it starts automatically
echo "vm-monitor auto service enabled"

#testing connection via ping pong
ALPHA_HOST=$(jq -r '.redis_host' "$SCRIPT_DIR/config/settings.json")
REDIS_PORT=$(jq -r '.redis_port' "$SCRIPT_DIR/config/settings.json")
PING_RESULT=$(redis-cli -h "$ALPHA_HOST" -p "$REDIS_PORT" ping 2>/dev/null || echo "FAIL")
if [ "$PING_RESULT" = "PONG" ]; then
    echo "Redis on $ALPHA_HOST:$REDIS_PORT is reachable. (PONG)"
else
    echo "Cannot reach Redis at $ALPHA_HOST:$REDIS_PORT"
    if [ -f /etc/redis/redis.conf ]; then
        SELF_IP=$(hostname -I | awk '{print $1}')
        if [ -n "$SELF_IP" ]; then
            echo "Updating Redis configuration to bind on 127.0.0.1 and local IP $SELF_IP"
            if grep -qE '^\s*bind\s+' /etc/redis/redis.conf; then
                sudo sed -i.bak -E "s#^\s*bind\s+.*#bind 127.0.0.1 $SELF_IP#" /etc/redis/redis.conf
            else
                echo "bind 127.0.0.1 $SELF_IP" | sudo tee -a /etc/redis/redis.conf >/dev/null
            fi
            sudo systemctl restart redis-server
            echo "Redis server restarted with updated bind configuration."
        else
            echo "Could not determine local IP address to update Redis bind settings."
        fi
    fi
fi
