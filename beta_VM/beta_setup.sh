#!/bin/bash
echo "VM is being set up..."

echo "Installing packages..."
sudo apt-get update -qq
sudo apt-get install -y redis-tools jq gnupg openssh-client #jq is editor for JSON files. redis-tools. Beta doesnt need all redis stuff so just connects to Alpha for the one thing it needs
#gnupg for encryption. openssh-client needed for ssh-keygen and ssh-copy-id
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

echo "Files have been created."

echo "Initializing ~/data/metrics.json..." #main file
if [ ! -f ~/data/metrics.json ]; then #if it doesnt exist then make it else its alr there
    echo '[]' > ~/data/metrics.json #initialized as an empty JSON array
    echo "Created empty metrics.json."
else
    echo "metrics.json already exists, skipping." 
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" #for the folder path
PEER_HOST="alpha-vm"
PEER_USER="alpha"
ALPHA_GPG_EMAIL="alpha@vm.local"
GPG_EMAIL="beta@vm.local"
GPG_NAME="beta-vm"

# SSH key authentication -> mirrors alpha exactly
if [ ! -f ~/.ssh/id_rsa ]; then #if id_rsa file doesnt exist then make the key pair
    ssh-keygen -t rsa -b 2048 -f ~/.ssh/id_rsa -N "" #"" for no password
    #rsa is an encryption algorithm that uses keys to swap data so
    #here the keys are being swapped safely between alpha and beta
    #uses 2048 bit key size. this is all so we dont need a password or anything
    echo "SSH keypair generated in ~/.ssh/id_rsa"
else
    echo "SSH keypair already exists, skipping key generation." #no overwriting
fi
echo "Copying SSH public key to $PEER_USER@$PEER_HOST..."
echo "(You will be prompted for $PEER_HOST password once — never again after this.)"
ssh-copy-id -i ~/.ssh/id_rsa.pub "$PEER_USER@$PEER_HOST"
#take the public key and install it then use -i public key file and put it into user@host

# GPG key pair generation
echo "Setting up GPG key pair..."
if gpg --list-keys "$GPG_EMAIL" &>/dev/null; then # means &> its run silently and only checks if it exists
    echo "GPG key already exists for $GPG_EMAIL, skipping generation."
else 
    cat > /tmp/gpg_batch.txt <<EOF
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
    gpg --batch --gen-key /tmp/gpg_batch.txt #generate a gpg key for this email into the file without any input
    rm -f /tmp/gpg_batch.txt #remove temp file since key has been created
    echo "GPG key generated for $GPG_EMAIL." 
fi

# Export beta's public key so alpha can import it, then do the exchange
# This mirrors alpha: alpha exports its key, scps it to beta, then pulls beta's key back
gpg --armor --export "$GPG_EMAIL" > ~/beta_pubkey.gpg #armor for readable text
echo "Public key exported to ~/beta_pubkey.gpg"

# Push beta's public key to alpha so alpha can import it
scp -i ~/.ssh/id_rsa ~/beta_pubkey.gpg "$PEER_USER@$PEER_HOST:~/beta_pubkey.gpg"

# Pull alpha's public key from alpha and import it
scp -i ~/.ssh/id_rsa "$PEER_USER@$PEER_HOST:~/alpha_pubkey.gpg" ~/alpha_pubkey.gpg
gpg --import ~/alpha_pubkey.gpg
echo "Alpha public key imported successfully."

echo "Creating config/settings.json..."
mkdir -p "$SCRIPT_DIR/config" #make directory named where we are after all above
cat > "$SCRIPT_DIR/config/settings.json" <<EOF
{
  "peer_hostname": "alpha-vm",
  "peer_user": "alpha",
  "ssh_key": "$HOME/.ssh/id_rsa",
  "collect_interval_sec": 60,
  "exchange_interval_sec": 300,
  "data_dir": "$HOME/data",
  "log_dir": "$HOME/logs",
  "redis_host": "alpha-vm",
  "redis_port": 6379,
  "backup_passphrase_env": "VM_BACKUP_KEY"
}
EOF
#write everything into the JSON which is the now new settings.json
#note: uses $HOME like alpha does (expands at write time) instead of literal ~/
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
#thresholds.json basically just stores all the warnings and criticals if value % is >= the value

echo "Setting permissions for all shell scripts"
find "$SCRIPT_DIR" -name "*.sh" -exec chmod +x {} \; #searches everything in SCRIPT_DIR for everything ending with .sh
#so it looks for all shell files then adds the execute permission
echo "All shell files are now executable."

echo "Creating systemd service unit file"
HOME_DIR=$(eval echo ~) #to get the home directory path: eval ~ so that ~ is full path to properly unify
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
#unit bit: Descrip is what it is and After means dont start until network is actually ready
#Service ExecStart starts the whole beta service.sh and restarts on any errors
#Install basically says run now so everything is continuous
echo "Systemd unit file created at /etc/systemd/system/vm-monitor.service"
sudo systemctl daemon-reload  #reload service files since systemd is new
sudo systemctl enable vm-monitor #enable service so it starts automatically on boot
echo "vm-monitor auto service enabled"

# Testing Redis connection via ping pong
ALPHA_HOST=$(jq -r '.redis_host' "$SCRIPT_DIR/config/settings.json")
REDIS_PORT=$(jq -r '.redis_port' "$SCRIPT_DIR/config/settings.json")
PING_RESULT=$(redis-cli -h "$ALPHA_HOST" -p "$REDIS_PORT" ping 2>/dev/null || echo "FAIL")
if [ "$PING_RESULT" = "PONG" ]; then
    echo "Redis on $ALPHA_HOST:$REDIS_PORT is reachable. (PONG)"
else
    echo "Cannot reach Redis at $ALPHA_HOST:$REDIS_PORT"
fi