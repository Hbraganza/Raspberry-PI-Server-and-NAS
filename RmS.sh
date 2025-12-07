#!/bin/bash
set -euo pipefail

SSHDEVICES=("device_1_user@device_1_IP" "device_2_user@device_2_IP")
CHECKSUM_DIR="/path/to/Checksum/directory"
CHECKSUM_DEVICE=("device_1_checksum.md5" "device_2_checksum.md5")
LOG_FILE="/path/to/error/log.txt"

# Errors collected during the run; if empty, no log is written
declare -a ERRORS
# Ensure array is initialized to avoid unbound errors with set -u
ERRORS=()

SSH_KEY="ssh -i /path/to/your/private_key"

# Run an SSH command with retries (up to 5 attempts)
ssh_with_retries() {
    local host="$1"
    shift
    local cmd="$*"
    local attempt=1
    local max_attempts=5
    local output=""
    local status=0

    while (( attempt <= max_attempts )); do
        # -o BatchMode=yes prevents password prompts; keeps non-interactive
        if output=$($SSH_KEY -o BatchMode=yes -n "$host" "$cmd" 2>/dev/null); then
            echo "$output"
            return 0
        else
            status=$?
            (( attempt++ ))
            sleep 1
        fi
    done
    return "$status"
}

checkfunction (){
    local checksum_file="$1"
    local host="$2"

    while read -r line; do
        # Show the line for parity with existing output
        echo "$line"
        local checksum filename
        checksum=$(echo "$line" | awk '{print $1}')
        filename=$(echo "$line" | awk '{print $2}')

        # First check if file exists on remote
        if ! ssh_with_retries "$host" "test -f $filename"; then
            echo "$filename: MISSING"
            ERRORS+=("$host: $filename missing")
            continue
        fi

        # Compute remote checksum with retries
        local remote_checksum
        if ! remote_checksum=$(ssh_with_retries "$host" "md5sum $filename" | awk '{print $1}'); then
            echo "$filename: ERROR"
            ERRORS+=("$host: failed to compute checksum for $filename")
            continue
        fi

        if [ "$checksum" != "$remote_checksum" ]; then
            echo "$filename: FAILED"
            ERRORS+=("$host: checksum mismatch for $filename file tampered with or corrupted check device")
        else
            echo "$filename: OK"
        fi
    done <"$checksum_file"
}

for i in "${!CHECKSUM_DEVICE[@]}"; do
    CHECKSUM_SOURCE="$CHECKSUM_DIR/${CHECKSUM_DEVICE[$i]}"
    SSHDEVICE="${SSHDEVICES[$i]}"
    echo "Checking files on $SSHDEVICE using $CHECKSUM_SOURCE"
    # Quick connectivity check with retries; on failure, record and skip to next
    if ! ssh_with_retries "$SSHDEVICE" "echo connected" >/dev/null; then
        echo "Could not connect to $SSHDEVICE, skipping."
        ERRORS+=("$SSHDEVICE: connection failed after retries")
        continue
    fi

    checkfunction "$CHECKSUM_SOURCE" "$SSHDEVICE"
done

echo "All files checked."

# Write error log only if there were errors
if (( ${#ERRORS[@]} > 0 )); then
    : > "$LOG_FILE"  # truncate/overwrite
    echo "Last error timestamp: $(date +'%Y-%m-%d %H:%M:%S')" >> "$LOG_FILE"
    for err in "${ERRORS[@]}"; do
        echo "$err" >> "$LOG_FILE"
    done
fi
