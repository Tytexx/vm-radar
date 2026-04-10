#!/bin/bash
echo "VM is being set up..."

echo "Installing packages..."
sudo apt-get update -qq
sudo apt-get install -y redis-tools jq gnupg #jq is editor for JSON files. redis-tools. Beta doesnt need all redis stuff so just connects to Alpha for the one thing it needs
#gnupg for encryption
echo "Packages have been installed."

echo "Creating directory layout..."
mkdir -p ~/data #means create directory if needed which is called x in the parent directory(directory above(ie exchange parent of inbox))
mkdir -p ~/exchange/inbox
mkdir -p ~/exchange/outbox
mkdir -p ~/logs/sent
mkdir -p ~/logs/rejected
mkdir -p ~/backup/logs
echo "Directories have been created."

echo "Initializing ~/data/metrics.json..." #main file
if [ ! -f ~/data/metrics.json ]; then #if it doesnt exist then make it else its alr there
    echo '[]' > ~/data/metrics.json #initialized as an empty JSON array
    echo "Created empty metrics.json."
else
    echo "metrics.json already exists, skipping." 
fi

echo "Setting up GPG key pair..."
GPG_NAME="beta-vm-monitor"
GPG_EMAIL="beta@vm-monitor.local"
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
gpg --armor --export "$GPG_EMAIL" > ~/beta_keys.gpg #armor for readable text - gpg exports it into beta_keys file (output file)
echo "Public key has been sent to ~/beta_keys.gpg"
#need to manually put ~/beta_keys.gpg into alpha then run  gpg --import ~/beta_keys.gpg

echo "Creating config/settings.json..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" #BASHSOURCE for current path then dirname to remove file name
#scriptdir is basically the current VM directory
#/.. to go to parent (=1 directory backwards) then pwd to get the full path of where we now are(via using cd)
mkdir -p "$SCRIPT_DIR/config" #make directory named where we are no after all above
cat > "$SCRIPT_DIR/config/settings.json" <<EOF
{
  "peer_hostname": "alpha-vm",
  "peer_user": "qustudent",
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
  "cpu_warning": 70,
  "cpu_crit": 90,
  "memory_warning": 75,
  "memory_crit": 90,
  "disk_warning": 80,
  "disk_crit": 95
}
EOF
#created the file and write the json into it with all the warnings
echo "config/thresholds.json successfully made."
#thresholds.json basically just stores akll the warnings and criticals if vale if % is >= the value

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
ExecStart=/home/qustudent/beta_VM/beta_service.sh
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
