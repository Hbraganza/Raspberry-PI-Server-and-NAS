#!/bin/bash
set -euo pipefail

SSHDEVICES=("IP_DEVICE1" "IP_DEVICE2") #Devices being SSH into
CHECKSUM_DIR="/path/to/directory/" #Directory with the .md5 files
CHECKSUM_DEVICE=("device1.md5" "device2.md5") #each .md5 file represents one device

SSH_KEY="ssh -i path/to/private/key" #ssh key

unreachable=()

run_ssh() {
    local device="$1"; shift
    local cmd="$*"
    local attempt
    for attempt in 1 2 3 4 5; do
        if output=$($SSH_KEY "$device" bash -lc "$cmd" 2>&1); then
            printf '%s\n' "$output"
            return 0
        else
            echo "SSH attempt $attempt to $device failed" >&2
            sleep 2
        fi
    done
    echo "Device $device is unreachable after multiple attempts." >&2
    return 1
}


checkfunction (){
    while read -r line; do #read each line of the .md5 file
    # collect the local checksum, filename and remote checksum
        checksum=$(echo "$line" | awk '{print $1}')
        filename=$(echo "$line" | awk '{print $2}')
        remote_checksum=$($SSH_KEY -n "$2" "md5sum $filename" | awk '{print $1}')

        if [[ -z "$remote_checksum"]]; then
            echo "$filename: ERROR"
        elif [ "$checksum" != "$remote_checksum" ]; then #compare checksums if they fail state so
           echo "$filename: FAILED" 
        
        else
            echo "$filename: OK"
        fi
    done <$1
}

for i in "${!CHECKSUM_DEVICE[@]}"; do #loop through each device
    CHECKSUM_SOURCE="$CHECKSUM_DIR/${CHECKSUM_DEVICE[$i]}"
    SSHDEVICE="${SSHDEVICES[$i]}"
    echo "Checking files on $SSHDEVICE using $CHECKSUM_SOURCE"
    checkfunction "$CHECKSUM_SOURCE" "$SSHDEVICE"
done

if ((${#unreachable[@]})); then
    echo "Unreachable devices:"
    for d in "${unreachable[@]}"; do
        echo " - $d"
    done
    echo "Files on reachable devices were checked."
else
    echo "All files checked and devices were reachable."
fi