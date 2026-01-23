#!/bin/bash

#  TEST MINER CLIENT (Field Test Mode)

# --- 1. CONFIGURATION ---
# Load .env variables
if [ -f .env ]; then
    export $(grep -v '^#' .env | xargs)
else
    echo "[ERROR] .env file not found."
    exit 1
fi

# Defaults from .env or fallback
PI_IP=${SERVER_IP:-"10.42.0.1"}
PORT=${SERVER_PORT:-3000}
MINER_PATH=${MINER_BINARY:-"./vanitysearch"}
WATCHDOG_SCRIPT="./watchdog.sh"

# --- PUZZLE CONFIGURATION ---
TARGET_FILE="targets.txt"
# Use address from .env or default to Field Test Target
ADDRESS=${TARGET_ADDRESS:-"1AFtgmBG6TB8m5FqFYMVmff4aGaaxeH5q1"}

# Ensure target file exists
echo "$ADDRESS" > "$TARGET_FILE"

# --- PERMISSION CLEANUP ---
sudo rm -f /tmp/miner_speed /tmp/miner_key

# --- CLEANUP FUNCTION ---
restore_fans() {
    echo ""
    echo "--- SHUTTING DOWN ---"
    
    # Only reset hardware if we were configured to touch it
    if [ "$CONFIGURE_HARDWARE" == "true" ]; then
        echo "Restoring Fans to Auto..."
        export DISPLAY=:0
        sudo -E nvidia-settings -a "[gpu:$GPU_ID]/GPUFanControlState=0" > /dev/null 2>&1
        sudo pkill -f "X :0" 2>/dev/null
    fi

    # Kill Watchdog & Miner
    if [ ! -z "$WATCHDOG_PID" ]; then kill $WATCHDOG_PID 2>/dev/null; fi
    pkill -P $$ vanitysearch 2>/dev/null
    
    echo "Exiting."
    exit
}
trap restore_fans SIGINT SIGTERM EXIT

# --- HARDWARE SETUP ---
setup_hardware() {
    if [ "$CONFIGURE_HARDWARE" != "true" ]; then
        echo "[INFO] Hardware configuration skipped (CONFIGURE_HARDWARE != true)"
        return
    fi

    echo "--- INITIALIZING HARDWARE ---"
    sudo nvidia-smi -pm 1
    sudo nvidia-smi -i $GPU_ID -pl $POWER_LIMIT

    # 1. Start X Server
    if ! pgrep -x "Xorg" > /dev/null; then
        echo "Starting X Server..."
        sudo X :0 > /dev/null 2>&1 & disown
        sleep 10
    else
        echo "X Server already running."
    fi

    # 2. Apply Fan Settings
    echo "Configuring Fans to ${FAN_SPEED}%..."
    export DISPLAY=:0
    sudo -E nvidia-settings -a "[gpu:$GPU_ID]/GPUFanControlState=1"
    sleep 2
    sudo -E nvidia-settings -a "[fan:$GPU_ID]/GPUTargetFanSpeed=${FAN_SPEED}"
                            
    CURRENT_FAN=$(nvidia-settings -q "[fan:$GPU_ID]/GPUTargetFanSpeed" | grep "Attribute" | awk '{print $4}')
    echo "[GPU] Fan Control Active. Speed: ${CURRENT_FAN}%"
}

# --- MAIN EXECUTION ---
setup_hardware

if [ -f "$WATCHDOG_SCRIPT" ]; then
    chmod +x $WATCHDOG_SCRIPT
    $WATCHDOG_SCRIPT &
    WATCHDOG_PID=$!
fi

echo "--- BASH MINER ONLINE (TEST MODE) ---"
echo "Orchestrator: http://$PI_IP:$PORT"

while true; do
    # 1. GET WORK
    RESPONSE=$(curl -s --connect-timeout 5 "http://$PI_IP:$PORT/work")
    JOB_ID=$(echo "$RESPONSE" | jq -r '.id')
    
    if [ "$JOB_ID" == "null" ] || [ -z "$JOB_ID" ]; then
        echo "[WAIT] No work. Retrying in 10s..."
        sleep 10
        continue
    fi

    START_HEX=$(echo "$RESPONSE" | jq -r '.start')
    END_HEX=$(echo "$RESPONSE" | jq -r '.end')

    # 2. CALCULATE SIZE
    SIZE_HEX=$(python3 -c "print(hex(int('$END_HEX', 16) - int('$START_HEX', 16))[2:])")
    KEYSPACE="${START_HEX}:+${SIZE_HEX}"
    
    echo -e "\n[JOB #$JOB_ID] Range: $KEYSPACE"

    # 3. RUN MINER & TRACK TIME
    rm -f found.txt
    
    # Capture Start Time (Seconds)
    START_TIME=$(date +%s)

    # Run Miner (Simple Output Mode)
    "$MINER_PATH" -t 0 -gpu -gpuId $GPU_ID -i "$TARGET_FILE" -o found.txt --keyspace "$KEYSPACE"
    
    # Capture End Time
    END_TIME=$(date +%s)

    # 4. CALCULATE SPEED LOCALLY
    DURATION=$((END_TIME - START_TIME))
    
    # Prevent divide by zero if it runs instantly
    if [ "$DURATION" -eq 0 ]; then DURATION=1; fi

    # Calculate MKeys/s: (Total Keys / Seconds) / 1,000,000
    SPEED=$(python3 -c "print(round((int('$SIZE_HEX', 16) / $DURATION) / 1000000, 2))")
    
    echo "  > Duration: ${DURATION}s"
    echo "  > Speed: ${SPEED} MKeys/s"

    # 5. CHECK FOR SUCCESS
    FOUND_KEY=""
    if [ -f found.txt ]; then
        FOUND_KEY_FILE=$(grep "Priv (HEX):" found.txt | cut -d ':' -f 2 | xargs)
        if [ ! -z "$FOUND_KEY_FILE" ]; then FOUND_KEY="$FOUND_KEY_FILE"; fi
    fi

    if [ ! -z "$FOUND_KEY" ]; then
        rm -f found.txt
        RESULT="FOUND"
        echo -e "\n[SUCCESS] KEY FOUND: $FOUND_KEY\n"
    else
        RESULT="DONE"
        echo "[JOB #$JOB_ID] Completed."
    fi

    # 6. SUBMIT
    curl -s -X POST -H "Content-Type: application/json" \
         -d "{\"id\": $JOB_ID, \"result\": \"$RESULT\", \"speed\": \"$SPEED\", \"key\": \"$FOUND_KEY\"}" \
         "http://$PI_IP:$PORT/submit-work" > /dev/null
done