#!/bin/bash
echo "VM is being set up..."

echo "Step 1: Installing packages..."
sudo apt-get update -qq
sudo apt-get install -y redis-tools jq gnupg #jq is editor for JSON files. redis-tools. Beta doesnt need all redis stuff so just connects to Alpha for the one thing it needs
#gnupg for encryption
echo "Packages have been installed."

echo "Step 2: Creating directory layout..."
mkdir -p ~/data #means create directory if needed which is called x in the parent directory(directory above(ie exchange parent of inbox))
mkdir -p ~/exchange/inbox
mkdir -p ~/exchange/outbox
mkdir -p ~/logs/sent
mkdir -p ~/logs/rejected
mkdir -p ~/backup/logs
echo "Directories have been created."

echo "Step 3: Initializing ~/data/metrics.json..." #main file
if [ ! -f ~/data/metrics.json ]; then #if it doesnt exist then make it else its alr there
    echo '[]' > ~/data/metrics.json #initialized as an empty JSON array
    echo "Created empty metrics.json."
else
    echo "metrics.json already exists, skipping." 
fi
