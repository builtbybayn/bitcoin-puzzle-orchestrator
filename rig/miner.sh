#  GPU MINER CLIENT (VanitySearch / BitCrack)
#  - Connects to Node.js Orchestrator
#  - Auto-configures GPU Fans/Power (Optional)
#  - loops work units indefinitely

# CONFIGURATION
# Load .env variables
if [ -f .env ]; then
    export $(grep -v '^#' .env | xargs)
else
    echo "[ERROR] .env file not found."
    exit 1
fi

# Defaults
PORT=${SERVER_PORT:-3000}
MINER_PATH=${MINER_BINARY:-"./vanitysearch"}
WATCHDOG_SCRIPT="./watchdog.sh"
TARGET_FILE="targets.txt"

# Check for required dependencies
if ! command -v jq &> /dev/null; then
    echo "[ERROR] 'jq' is not installed. Please run: sudo apt install jq"
    exit 1
fi

# Ensure target file exists
echo "$TARGET_ADDRESS" > "$TARGET_FILE"

# 2. HARDWARE CONTROL
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

setup_hardware() {
    if [ "$CONFIGURE_HARDWARE" != "true" ]; then
        echo "[INFO] Hardware configuration skipped (CONFIGURE_HARDWARE != true)"
        return
    fi

    echo "--- INITIALIZING HARDWARE (GPU $GPU_ID) ---"
    sudo nvidia-smi -pm 1
    sudo nvidia-smi -i $GPU_ID -pl $POWER_LIMIT

    # Start X Server (Required for headless Fan Control on Linux)
    if ! pgrep -x "Xorg" > /dev/null; then
        echo "Starting X Server..."
        sudo X :0 > /dev/null 2>&1 & disown
        sleep 10
    else
        echo "X Server already running."
    fi

    # Apply Fan Settings
    echo "Configuring Fans to ${FAN_SPEED}%..."
    export DISPLAY=:0
    sudo -E nvidia-settings -a "[gpu:$GPU_ID]/GPUFanControlState=1"
    sleep 2
    sudo -E nvidia-settings -a "[fan:$GPU_ID]/GPUTargetFanSpeed=${FAN_SPEED}"
                            
    CURRENT_FAN=$(nvidia-settings -q "[fan:$GPU_ID]/GPUTargetFanSpeed" | grep "Attribute" | awk '{print $4}')
    echo "[GPU] Fan Control Active. Speed: ${CURRENT_FAN}%"
}

# 3. MAIN LOOP

setup_hardware

# Start Watchdog if it exists
if [ -f "$WATCHDOG_SCRIPT" ]; then
    chmod +x $WATCHDOG_SCRIPT
    $WATCHDOG_SCRIPT &
    WATCHDOG_PID=$!
fi

echo "--- MINER ONLINE ---"
echo "Orchestrator: http://$SERVER_IP:$PORT"
echo "Target: $TARGET_ADDRESS"

while true; do
    # A. GET WORK
    RESPONSE=$(curl -s --connect-timeout 5 "http://$SERVER_IP:$PORT/work")
    JOB_ID=$(echo "$RESPONSE" | jq