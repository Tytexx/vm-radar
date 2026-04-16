#!/bin/bash
echo "VM is being set up"

echo "Installing packages"
sudo apt-get update -qq
sudo apt-get install -y redis-server jq gnupg openssh-client #jq is to read/translate JSON files. redis-tools. Beta doesnt need all redis stuff so just connects to Alpha for the one thing it needs
#gnupg for encryption. This is alpha so needs the openssh-client bit since beta takes info from here/alpha initiate
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

echo "Initializing ~/data/metrics.json..." #main file
if [ ! -f ~/data/metrics.json ]; then #if it doesnt exist then make it else its alr there
    echo '[]' > ~/data/metrics.json #initialized as an empty JSON array
    echo "Created empty metrics.json."
else
    echo "metrics.json already exists, skipping." 
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" #for the folder path
PEER_HOST="beta-vm" #the peer is beta this is alpha (from the project file in the example
PEER_USER="beta"
BETA_GPG_EMAIL="beta@vm.local"
GPG_EMAIL="alpha@vm.local"
GPG_NAME="alpha-vm"
#SSH key autnetication ->
if [ ! -f ~/.ssh/id_rsa ]; then #if id_rsa file doesnt exit then make the key pair->
    ssh-keygen -t rsa -b 2048 -f ~/.ssh/id_rsa -N "" #""for no password
    #rsa is an encryption algorithm that uses keys to swap data so 
    #here the keys are being swapped safely between alpha and beta
    #uses 2048 bit key size (standard?) this is all so we dont need like a password or anything 
    echo "SSH keypair generated in ~/.ssh/id_rsa"
else
    echo "SSH keypair already exists, skipping key generation." #no overwriting
fi
echo "Copying SSH public key to $PEER_USER@$PEER_HOST..."
echo "(You will be prompted for $PEER_HOST password once — never again after this.)"
ssh-copy-id -i ~/.ssh/id_rsa.pub "$PEER_USER@$PEER_HOST" 
#take the public key and install it then use -i publick key file and put it into user@host

#to make gpg key pair 
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
#export alpha key to file so beta can get it
gpg --armor --export "$GPG_EMAIL" > ~/alpha_pubkey.gpg #armor for readable text - gpg exports it into beta_pubkey file (output file)
echo "Public key has been sent to ~/alpha_pubkey.gpg"
scp -i ~/.ssh/id_rsa ~/alpha_pubkey.gpg "$PEER_USER@$PEER_HOST:~/alpha_pubkey.gpg" #send alphapubkey.gpg ket to peerhost
scp -i ~/.ssh/id_rsa "$PEER_USER@$PEER_HOST:~/beta_pubkey.gpg" ~/beta_pubkey.gpg #get betagpg from host as well
gpg --import ~/beta_pubkey.gpg

echo "Creating config/settings.json..."
mkdir -p "$SCRIPT_DIR/config" #make directory named where we are no after all above
cat > "$SCRIPT_DIR/config/settings.json" <<EOF
{
  "peer_hostname": "beta-vm",
  "peer_user": "beta",
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
#thresholds.json basically just stores akll the warnings and criticals if vale if % is >= the value
echo "Ensuring host name resolution for local and peer hostnames..."
PEER_HOSTNAME=$(jq -r '.peer_hostname' "$SCRIPT_DIR/config/settings.json" 2>/dev/null || echo "beta-vm")
LOCAL_HOSTNAME=$(hostname -s)
SELF_IP="${VM_ALPHA_IP:-${VM_LOCAL_IP:-$(hostname -I | awk '{print $1}')}}"
PEER_IP="${VM_PEER_IP:-${VM_BETA_IP:-}}"

if [ -n "$SELF_IP" ] && ! grep -qE "^[^#]*\b$LOCAL_HOSTNAME\b" /etc/hosts; then
    echo "Adding $SELF_IP $LOCAL_HOSTNAME to /etc/hosts"
    echo "$SELF_IP $LOCAL_HOSTNAME" | sudo tee -a /etc/hosts >/dev/null
fi

if [ -n "$PEER_IP" ] && [ -n "$PEER_HOSTNAME" ] && ! grep -qE "^[^#]*\b$PEER_HOSTNAME\b" /etc/hosts; then
    echo "Adding $PEER_IP $PEER_HOSTNAME to /etc/hosts"
    echo "$PEER_IP $PEER_HOSTNAME" | sudo tee -a /etc/hosts >/dev/null
fi

if [ -z "$SELF_IP" ]; then
    echo "WARNING: Could not determine local IP address; local host entry was not added."
fi
if [ -z "$PEER_IP" ]; then
    echo "WARNING: Set VM_PEER_IP or VM_BETA_IP environment variable before running this script to add the peer host entry automatically."
fi
echo "Setting permissions for all shell scripts"
find "$SCRIPT_DIR" -name "*.sh" -exec chmod +x {} \; #searches everything in SCRIPT_DR for everything ending with .sh
#so it looks for all shell files than adds the execute permission 
echo "All shell files are now executable."

echo "Configuring Redis server to start automatically on boot"
sudo systemctl enable redis-server
sudo systemctl start redis-server
sleep 2 #just for time to reset and all

PING_RESULT=$(redis-cli ping 2>/dev/null || echo "FAIL")
if [ "$PING_RESULT" = "PONG" ]; then
    echo "Redis is running well"
else
    echo "Redis did not respond to ping"
fi
