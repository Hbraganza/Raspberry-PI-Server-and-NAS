#!/bin/bash

set -euo pipefail

SOURCE="/path/to/source/directory" #the location of the files that will be backedup
DESTINATION="/path/to/backup/directory" #where to backup to on the backup device
SSHKEY="ssh -i /path/to/private/key" #the ssh privatekey command to the backup device
SSHDEVICE="user@device_IP_or_name" #the user you are going to ssh into
DIRECTORIES=("user_1" "user_2" "etc") #due to size of server rsync needed to be broken down to the different user directories setup in the source
SNAPSHOTNAME="Backup_$(date +%F_%H-%M-%S)" #snapshot name
RETENTION_POLICY=56 #backups older than 56 days will be deleted

SECONDS=0

SNAP_LOC="${DESTINATION}/snapshots/${SNAPSHOTNAME}"
LATESTLINK="${DESTINATION}/latest"
link_opts=()

#function to perform the rsync in parralel for each user if there is a latest symbolic directory then it uses that location for hardlinking
rsync_function(){
        for PERUSER in "${DIRECTORIES[@]}"; do
                if $1; then
                        link_opts=("--link-dest=$LATESTLINK/$PERUSER")
                fi
                ssh_run "mkdir -p '${SNAP_LOC}.partial/${PERUSER}'"
                echo "Created ${PERUSER} directory"

                rsync -avz -e "$SSHKEY" --info=progress2,stats2 --delete "$SOURCE/$PERUSER/" "${link_opts[@]}" "$SSHDEVICE:$SNAP_LOC.partial/$PERUSER/" &
                echo "Started rsync for ${PERUSER}"
        done
        wait
}

ssh_run() {
  local remote_cmd="$1"
  local attempts=3
  local delay=2

  for ((i=1; i<=attempts; i++)); do
    if $SSHKEY "$SSHDEVICE" "$remote_cmd"; then
      return 0
    fi
    echo "SSH attempt $i/$attempts failed for: $remote_cmd"
    if (( i < attempts )); then
      sleep "$delay"
    fi
  done

  echo "SSH failed after $attempts attempts. Aborting."
  # Ensure any background jobs (like rsync) are terminated.
  kill 0
  exit 1
}

if ssh_run "test -e '$LATESTLINK'"; then
        echo "Detected latest directory at ${LATESTLINK}"
        rsync_function true
else
        echo "No latest directory detected"
        rsync_function false
fi

DURATION=$SECONDS
echo "Rsync success time taken $((DURATION / 3600)):$(((DURATION % 3600)/60)):$((DURATION % 60)). Now finishing snapshot and symbolic link to latest directory"

ssh_run "mkdir -p '${SNAP_LOC}' && mv ${SNAP_LOC}.partial/* ${SNAP_LOC}/ && ln -sfn ${SNAP_LOC} ${LATESTLINK}"
echo "Succesful Creation of snapshot folder and linking to latest directory. Now performing removal of .partial directories"

ssh_run "find '${DESTINNATION}/snapshots/' -type d -name '*.partial' -exec rm -r {} +"
echo "Succesful Removal of .partial directories. Now applying retention policy of $RETENTION_POLICY days"

ssh_run "find '${DESTINATION}/snapshots/' -mindepth 1 -maxdepth 1 -type d -mtime +$RETENTION_POLICY -exec rm -rf {} +"
echo "Retention policy applied backup completed"