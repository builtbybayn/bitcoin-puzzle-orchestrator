#!/bin/bash
#  GPU MINER CLIENT (VanitySearch / BitCrack)
#  - Connects to Node.js Orchestrator
#  - Auto-configures GPU Fans/Power (Optional)
#  - Loops work units indefinitely
#
#  Safe to stop at any time with Ctrl+C or SIGTERM. The unfinished range is
#  handed back to the orchestrator instead of being recorded as searched.

# 1. CONFIGURATION
# Reads KEY=VALUE lines. Values may contain spaces, and Windows line endings are OK.
load_env() {
    local line key value
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
        key="${BASH_REMATCH[1]}"
        value="${BASH_REMATCH[2]}"
        value="${value%"${value##*[![:space:]]}"}"   # trim trailing spaces
        case "$value" in
            \"*\" | \'*\') value="${value:1:${#value}-2}" ;;
        esac
        export "$key=$value"
    done < "$1"
}

if [ -f .env ]; then
    load_env .env
else
    echo "[ERROR] .env file not found."
    exit 1
fi

# Defaults
SERVER_IP=${SERVER_IP:-10.42.0.1}
PORT=${SERVER_PORT:-${PORT:-3000}}
MINER_PATH=${MINER_BINARY:-"./vanitysearch"}
GPU_ID=${GPU_DEVICE_ID:-${GPU_ID:-0}}
FAN_SPEED=${FAN_SPEED:-85}
POWER_LIMIT=${POWER_LIMIT:-240}
# Default target is Puzzle #71
TARGET_ADDRESS=${TARGET_ADDRESS:-${DEFAULT_TARGET:-1PWo3JeB9jrGwfHDNpdGK54CRas7fsVzXU}}
# Text the miner prints once it has covered the whole range. VanitySearch exits
# with code 0 even if the GPU fails halfway, so the exit code is not enough.
MINER_DONE_MARKER=${MINER_DONE_MARKER:-Range search completed}
RETRY_DELAY=${RETRY_DELAY:-10}
MAX_RETRY_DELAY=300

SERVER_URL="http://$SERVER_IP:$PORT"
WATCHDOG_SCRIPT="./watchdog.sh"
TARGET_FILE="targets.txt"
FOUND_FILE="found.txt"
MINER_LOG="miner_output.log"

JOB_ID=""
MINER_PID=""
TAIL_PID=""
WATCHDOG_PID=""
CLEANED_UP=false

# Check for required dependencies
for cmd in jq curl python3; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "[ERROR] '$cmd' is not installed. Please run: sudo apt install $cmd"
        exit 1
    fi
done

if ! command -v "$MINER_PATH" &> /dev/null; then
    echo "[ERROR] Miner not found or not executable: $MINER_PATH (set MINER_BINARY in .env)"
    exit 1
fi

# A mistyped address would search forever and never match, so verify its checksum.
# (bc1 addresses use a different format and are not checked.)
valid_address() {
    [[ "$1" == bc1* ]] && return 0
    python3 -c '
import hashlib, sys
alphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
try:
    n = 0
    for c in sys.argv[1]:
        n = n * 58 + alphabet.index(c)
    raw = n.to_bytes(25, "big")
except (ValueError, OverflowError):
    sys.exit(1)
digest = hashlib.sha256(hashlib.sha256(raw[:21]).digest()).digest()
sys.exit(0 if digest[:4] == raw[21:] else 1)
' "$1"
}

if ! valid_address "$TARGET_ADDRESS"; then
    echo "[ERROR] TARGET_ADDRESS is not a valid Bitcoin address: $TARGET_ADDRESS"
    exit 1
fi

echo "$TARGET_ADDRESS" > "$TARGET_FILE" || exit 1

# Sleep that Ctrl+C / SIGTERM can interrupt straight away
pause() {
    sleep "$1" &
    wait $!
}

# 2. FOUND KEYS
# A found key is saved as FOUND_KEY_<job>_<time>.pending.txt before anything else
# happens, and only renamed to .submitted.txt once the orchestrator confirms it.

# Prints the private key from any of the given files, if there is one.
extract_key() {
    grep -ahs "Priv (HEX):" "$@" | tail -n 1 | cut -d ':' -f 2 | tr -d '[:space:]'
}

# Usage: save_found_key <job id> <key>. Prints the path of the saved file.
save_found_key() {
    local file
    file="FOUND_KEY_${1}_$(date +%s).pending.txt"
    if [ -n "$(extract_key "$FOUND_FILE")" ]; then
        mv "$FOUND_FILE" "$file"
    else
        # VanitySearch only prints the key if it cannot write its output file
        echo "Priv (HEX): $2" > "$file"
    fi
    echo "$file"
}

# Usage: submit_result <job id> <DONE|FOUND> <speed> <key> [max attempts, 0 = forever]
submit_result() {
    local body code attempt=0 max=${5:-0}
    body=$(jq -n --arg id "$1" --arg result "$2" --arg speed "$3" --arg key "$4" \
        '{id: ($id | tonumber), result: $result, speed: $speed, key: $key}')

    while true; do
        code=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 30 \
            -X POST -H "Content-Type: application/json" -d "$body" "$SERVER_URL/submit-work")
        [ "$code" == "200" ] && return 0

        echo "[WARN] Submitting job #$1 failed (HTTP $code)."
        # Never give up on a found key, but a rejected DONE will not improve.
        if [ "$2" != "FOUND" ] && [[ "$code" == 4* ]]; then return 1; fi

        attempt=$((attempt + 1))
        if [ "$max" -gt 0 ] && [ "$attempt" -ge "$max" ]; then return 1; fi
        pause "$RETRY_DELAY"
    done
}

# Usage: submit_found_file <file> <job id> <speed> <key> [max attempts]
submit_found_file() {
    if submit_result "$2" "FOUND" "$3" "$4" "${5:-0}"; then
        mv "$1" "${1%.pending.txt}.submitted.txt"
    else
        echo "[WARN] Key is saved in $1 and will be submitted on the next start."
    fi
}

# Submit keys left over from a previous run
recover_found_keys() {
    local file key id known=false

    key=$(extract_key "$FOUND_FILE" "$MINER_LOG")
    if [ -n "$key" ]; then
        for file in FOUND_KEY_*.txt; do
            [ "$(extract_key "$file")" == "$key" ] && known=true
        done
        $known || save_found_key 0 "$key" > /dev/null
    fi

    for file in FOUND_KEY_*.pending.txt; do
        [ -f "$file" ] || continue
        key=$(extract_key "$file")
        id=$(echo "$file" | cut -d '_' -f 3)
        echo "[RECOVERY] Submitting unsent key from $file"
        submit_found_file "$file" "$id" "0" "$key"
    done
}

# Hand an unfinished range back so it can be searched later. Older orchestrators
# do not have this endpoint; they reassign the range after their timeout instead.
release_job() {
    [ -n "$JOB_ID" ] || return
    if curl -sf -o /dev/null --connect-timeout 5 --max-time 10 -X POST \
        -H "Content-Type: application/json" -d "{\"id\": $JOB_ID}" "$SERVER_URL/release-work"; then
        echo "[JOB #$JOB_ID] Not finished. Returned to orchestrator."
    else
        echo "[JOB #$JOB_ID] Not finished. Orchestrator will reassign it after its timeout."
    fi
    JOB_ID=""
}

# 3. SHUTDOWN AND HARDWARE CONTROL
stop_miner() {
    [ -n "$MINER_PID" ] || return
    kill -TERM "$MINER_PID" 2>/dev/null
    # A miner paused by the watchdog only handles the signal once resumed
    kill -CONT "$MINER_PID" 2>/dev/null
    local i
    for i in {1..50}; do
        kill -0 "$MINER_PID" 2>/dev/null || break
        sleep 0.2
    done
    kill -KILL "$MINER_PID" 2>/dev/null
    wait "$MINER_PID" 2>/dev/null
    MINER_PID=""
}

shutdown() {
    $CLEANED_UP && return
    CLEANED_UP=true
    trap '' INT TERM HUP

    echo ""
    echo "--- SHUTTING DOWN ---"

    # Kill Watchdog & Miner
    if [ -n "$WATCHDOG_PID" ]; then kill "$WATCHDOG_PID" 2>/dev/null; fi
    stop_miner
    if [ -n "$TAIL_PID" ]; then kill "$TAIL_PID" 2>/dev/null; fi

    if [ -n "$JOB_ID" ]; then
        # The key may have turned up just before we were stopped
        recover_job_key || release_job
    fi

    # Only reset hardware if we were configured to touch it
    if [ "$CONFIGURE_HARDWARE" == "true" ]; then
        echo "Restoring Fans to Auto..."
        export DISPLAY=:0
        sudo -E nvidia-settings -a "[gpu:$GPU_ID]/GPUFanControlState=0" > /dev/null 2>&1
        sudo pkill -f "X :0" 2>/dev/null
    fi

    echo "Exiting."
}

# During shutdown: save the current job's key and try briefly to submit it.
# Fails if there is no key.
recover_job_key() {
    local key file
    key=$(extract_key "$FOUND_FILE" "$MINER_LOG")
    [ -n "$key" ] || return 1
    # Reuse the file if we were stopped while already submitting this key
    file=$(ls "FOUND_KEY_${JOB_ID}_"*.pending.txt 2>/dev/null | tail -n 1)
    [ -n "$file" ] || file=$(save_found_key "$JOB_ID" "$key")
    submit_found_file "$file" "$JOB_ID" "0" "$key" 3
}

trap 'shutdown; exit 130' INT
trap 'shutdown; exit 143' TERM HUP
trap shutdown EXIT

setup_hardware() {
    if [ "$CONFIGURE_HARDWARE" != "true" ]; then
        echo "[INFO] Hardware configuration skipped (CONFIGURE_HARDWARE != true)"
        return
    fi

    echo "--- INITIALIZING HARDWARE (GPU $GPU_ID) ---"
    sudo nvidia-smi -pm 1
    sudo nvidia-smi -i "$GPU_ID" -pl "$POWER_LIMIT"

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

# 4. MAIN LOOP

recover_found_keys
setup_hardware

# Start Watchdog if it exists
if [ -f "$WATCHDOG_SCRIPT" ]; then
    bash "$WATCHDOG_SCRIPT" &
    WATCHDOG_PID=$!
fi

echo "--- MINER ONLINE ---"
echo "Orchestrator: $SERVER_URL"
echo "Target: $TARGET_ADDRESS"

FAILURES=0

while true; do
    # A. GET WORK
    RESPONSE=$(curl -s --connect-timeout 5 --max-time 30 "$SERVER_URL/work")
    JOB_ID=$(echo "$RESPONSE" | jq -r '.id // empty' 2>/dev/null)
    START_HEX=$(echo "$RESPONSE" | jq -r '.start // empty' 2>/dev/null)
    END_HEX=$(echo "$RESPONSE" | jq -r '.end // empty' 2>/dev/null)

    if ! [[ "$JOB_ID" =~ ^[0-9]+$ && "$START_HEX" =~ ^[0-9a-fA-F]+$ && "$END_HEX" =~ ^[0-9a-fA-F]+$ ]]; then
        JOB_ID=""
        echo "[WAIT] No work. Retrying in ${RETRY_DELAY}s..."
        pause "$RETRY_DELAY"
        continue
    fi

    # B. CALCULATE SIZE
    SIZE_HEX=$(python3 -c "print(hex(int('$END_HEX', 16) - int('$START_HEX', 16))[2:])")
    KEYSPACE="${START_HEX}:+${SIZE_HEX}"
    echo -e "\n[JOB #$JOB_ID] Range: $KEYSPACE"

    # C. RUN MINER & TRACK TIME
    rm -f "$FOUND_FILE"   # any key in it was already saved above
    : > "$MINER_LOG"
    START_TIME=$(date +%s)

    "$MINER_PATH" -t 0 -gpu -gpuId "$GPU_ID" -i "$TARGET_FILE" -o "$FOUND_FILE" \
        --keyspace "$KEYSPACE" > "$MINER_LOG" 2>&1 &
    MINER_PID=$!
    tail -n +1 -f --pid="$MINER_PID" "$MINER_LOG" &
    TAIL_PID=$!

    wait "$MINER_PID"
    EXIT_CODE=$?
    MINER_PID=""
    wait "$TAIL_PID" 2>/dev/null
    TAIL_PID=""

    # D. CALCULATE SPEED LOCALLY (MKeys/s)
    DURATION=$(( $(date +%s) - START_TIME ))
    if [ "$DURATION" -eq 0 ]; then DURATION=1; fi
    SPEED=$(python3 -c "print(round((int('$SIZE_HEX', 16) / $DURATION) / 1000000, 2))")

    # E. REPORT
    FOUND_KEY=$(extract_key "$FOUND_FILE" "$MINER_LOG")

    if [ -n "$FOUND_KEY" ]; then
        KEY_FILE=$(save_found_key "$JOB_ID" "$FOUND_KEY")
        echo -e "\n[!!!] KEY FOUND: $FOUND_KEY (saved to $KEY_FILE) [!!!]\n"
        submit_found_file "$KEY_FILE" "$JOB_ID" "$SPEED" "$FOUND_KEY"
        JOB_ID=""
        FAILURES=0

    elif [ "$EXIT_CODE" -eq 0 ] && grep -qaF "$MINER_DONE_MARKER" "$MINER_LOG"; then
        echo "[JOB #$JOB_ID] Completed."
        echo "  > Duration: ${DURATION}s"
        echo "  > Speed: ${SPEED} MKeys/s"
        submit_result "$JOB_ID" "DONE" "$SPEED" ""
        JOB_ID=""
        FAILURES=0

    else
        # Crashed, killed, or stopped early: the range was NOT fully searched
        FAILURES=$((FAILURES + 1))
        DELAY=$((RETRY_DELAY * FAILURES))
        if [ "$DELAY" -gt "$MAX_RETRY_DELAY" ]; then DELAY=$MAX_RETRY_DELAY; fi
        echo "[ERROR] Miner stopped before finishing (exit code $EXIT_CODE, failure #$FAILURES)."
        release_job
        echo "[WAIT] Retrying in ${DELAY}s..."
        pause "$DELAY"
    fi
done
