#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#bash_source[0] is current location and that bit is removed via dirname.if this succeeds pwd print whole directory
CONFIG_FILE="$SCRIPT_DIR/config/settings.json"
SERVICE_NAME="vm-monitor"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
COLLECT_INTERVAL=$(jq -r '.collect_interval_sec' "$CONFIG_FILE" 2>/dev/null || echo "60") 
#read json config file and take the associated value following collect_interval)sec, if that doesnt work use 60
HOME_DIR="$HOME"

if [ $# -ne 1 ]; then #if arguments is not 1 then print use one of these after script name
    echo "Use: $0 <install|start|stop|status|logs>"
    exit 1
fi
ACTION="$1" #so it stores install/start/stop etc one of them
case "$ACTION" in 
install)
 #first case
  echo "Generating a systemd unit file"
  #next is write all this between EOFs to service file
  sudo tee "$SERVICE_FILE" > /dev/null <<EOF
[Unit]
Description=VM Monitoring Service - Beta Collector Daemon
After=network.target

[Service]
ExecStart=/bin/bash -c "while true; do ${SCRIPT_DIR}/beta_collect.sh; sleep ${COLLECT_INTERVAL}; done"
Restart=on-failure
RestartSec=10
User=$(whoami)
WorkingDirectory=${SCRIPT_DIR}

[Install]
WantedBy=multi-user.target
EOF
#unit is  just a statement and says when to run which is after the networks established
#Service: execstart runs beta_collect in a loop w a sleep to wait a bit between each loop cycle
#         restart if any errors/crashes w a 10 second wait before restarting
#         who is on right now and workingdirectory is directory that this is runnign in/looping in
#Install is auto start when system boots up in multi-user mode

    echo "File written to $SERVICE_FILE"
    sudo systemctl daemon-reload     # Tell systemd to reload all unit files so it rechecks after all creations and edits 
    # Enable so the service starts automatically on every boot
    sudo systemctl enable "$SERVICE_NAME" #so that the service (whichever is service name) auto starts when booted up 
    echo "Install complete. Type: $0 start to start"
    ;; #end of case block

  start)
   #case start
    echo "Starting $SERVICE_NAME..."
    sudo systemctl start "$SERVICE_NAME"
    sleep 2  
    STATE=$(systemctl is-active "$SERVICE_NAME" 2>/dev/null || echo "unknown") #get current service state and if cant then state is unknown
    #systemctl is-active  checks if its active or not then outputs it
    if [ "$STATE" = "active" ]; then
        echo "Service $SERVICE_NAME started successfully and is active"
    else
        echo "Service not started, $SERVICE_NAME is $STATE"
    fi
    ;;  #end service under servicename

  stop)
   #case stop
    echo "Stopping $SERVICE_NAME..."
    sudo systemctl stop "$SERVICE_NAME"
    sleep 1
    STATE=$(systemctl is-active "$SERVICE_NAME" 2>/dev/null || echo "inactive")
    echo "Service $SERVICE_NAME has now stopped"
    ;; #confirm service is over in case

  status) 
  #case status
    echo "Service is: $SERVICE_NAME "
    ACTIVE_STATE=$(systemctl show "$SERVICE_NAME" --property=ActiveState 2>/dev/null | cut -d= -f2) 
    #shows all properties of this service then filters so we only see the active status property. last bit basically delimiter is =(separator)
    #and  f2 to take the second part only
    SUB_STATE=$(systemctl show "$SERVICE_NAME" --property=SubState 2>/dev/null | cut -d= -f2)
    #same thing but takes the substate property
    MAIN_PID=$(systemctl show "$SERVICE_NAME" --property=MainPID 2>/dev/null | cut -d= -f2)
    #same again but mainPID porperty
    ENTER_TIMESTAMP=$(systemctl show "$SERVICE_NAME"  --property=ActiveEnterTimestamp 2>/dev/null | cut -d= -f2)
    #again w timestamp of when service was last active so we can get uptime
    UPTIME="None"
    if [ -n "$ENTER_TIMESTAMP" ] ; then #if strings not empty go on
        # Convert the timestamp to epoch seconds and subtract from now
        START_EPOCH=$(date -d "$ENTER_TIMESTAMP" +%s 2>/dev/null || echo "0") #converting the timestamp to epoch so we can get total time passec
        NOW_EPOCH=$(date +%s) #current time
        SECONDS_UP=$((NOW_EPOCH - START_EPOCH)) #to get time passed  = uptime in seconds
        HOURS=$((SECONDS_UP / 3600)) #convert sedonds to hours
        MINUTES=$(((SECONDS_UP % 3600) / 60)) #convert to minutes
        UPTIME="${HOURS}h${MINUTES}m" #total uptime
    fi
    #to get memory usage
    MEMORY_BYTES=$(systemctl show "$SERVICE_NAME" --property=MemoryCurrent 2>/dev/null | cut -d= -f2) #get mem usage in bytes
    MEMORY_MB="None"
    if [ -n "$MEMORY_BYTES" ] && [ "$MEMORY_BYTES" -gt 0 ]; then #check if bytes isnt empty and >0
        MEMORY_MB=$(awk "BEGIN {printf \"%.1fMB\", $MEMORY_BYTES/1048576}") #bytes to MB 1MB is 1048576 bytes
        #awk is so we can use decimals. cant use float since its bash/bash and .1fMB to 1 dp and MB for units
    fi
    echo "SERVICE $SERVICE_NAME"
    echo "state=$ACTIVE_STATE ($SUB_STATE)"
    echo "pid=$MAIN_PID"
    echo "uptime=$UPTIME"
    echo "memory=$MEMORY_MB"
    ;; #summary of services given
  logs) 
  #case is logs 
    echo "Last 20 log entries for $SERVICE_NAME" #show last 20 logs 
    journalctl -u "$SERVICE_NAME" --no-pager -n 20 #show logs for unit(-u) servicename journalctl like ctrl log system to get all of the lofs
    #--no-pager so everything sent to terminal rather in the log where have to interact/type 
    ;; #end case

  *)
   #case anything else
    echo "ERROR: Unknown action has been entered: '$ACTION'"
    echo "Use of of: $0 <install|start|stop|status|logs>"
    exit 1
    ;;
 
 esac
