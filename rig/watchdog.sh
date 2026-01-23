#!/bin/bash
# Loops and every five seconds checks if temps are 80C or greater. If so will pause the rig and wait until it's cooled to 60C

if [ -f .env ]; then
    export $(grep -v '^#' .env | xargs)
fi

# CONFIGURATION (LONGEVITY MODE)
# 80C is the new "Safety Cutoff". 
# If it hits 80C, we stop to protect the card.
CRITICAL_TEMP=80
RESUME_TEMP=60
MINER_PATH=${MINER_BINARY:-"./vanitysearch"}
PROCESS_NAME=$(basename "$MINER_PATH")

echo "--- THERMAL SAFETY WATCHDOG ONLINE ---"
echo "Monitoring for temps > ${CRITICAL_TEMP}C"

PAUSED=false

while true; do
    # Get Temp
    CURRENT_TEMP=$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits)
    
    # Get PID (Matches your specific binary name)
    PID=$(pgrep -f "$PROCESS_NAME" | head -n 1)

    # If miner isn't running, wait
    if [ -z "$PID" ]; then
        sleep 5
        continue
    fi

    # EMERGENCY: Too Hot
    if [ "$CURRENT_TEMP" -ge "$CRITICAL_TEMP" ] && [ "$PAUSED" = false ]; then
        echo "[DANGER] Temp ${CURRENT_TEMP}C exceeds limit. Pausing miner..."
        kill -STOP $PID
        PAUSED=true
    
    # RECOVERY: Safe to continue
    elif [ "$CURRENT_TEMP" -le "$RESUME_TEMP" ] && [ "$PAUSED" = true ]; then
        echo "[SAFE] Cooled to ${CURRENT_TEMP}C. Resuming miner..."
        kill -CONT $PID
        PAUSED=false
    fi

    sleep 5
done