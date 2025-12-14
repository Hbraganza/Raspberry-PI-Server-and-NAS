#!/bin/bash

set -euo pipefail
set -o errtrace

SOURCE="/path/to/source/directory" #the location of the files that will be backedup
DESTINATION="/path/to/backup/directory" #where to backup to on the backup device

SSHKEY="ssh -i /path/to/private/key" #the ssh privatekey command to the backup device
SSHDEVICE="user@device_IP_or_name" #the user you are going to ssh into
SSH_KEEPALIVE_OPTS="-o ServerAliveInterval=60 -o ServerAliveCountMax=5 -o TCPKeepAlive=yes"

DIRECTORIES=("user_1" "user_2" "etc") #due to size of server rsync needed to be broken down to the different user directories setup in the source

SNAPSHOTNAME="Backup_$(date +%F_%H-%M-%S)" #snapshot name
RETENTION_POLICY=56 #backups older than 56 days will be deleted

SECONDS=0

SNAP_LOC="${DESTINATION}/snapshots/${SNAPSHOTNAME}"
LATESTLINK="${DESTINATION}/latest"
link_opts=()

LOGFILE="path/to/logs/backup_error.log"
EMAIL_SENDER="/path/to/Email_Sender.py"
PYTHON_ENV="/path/to/gmailenv/bin/python3"

check_remote_health() {
  local attempts=${1:-3}
  local timeout=10
  local delay=10
  local i
  for ((i=1; i<=attempts; i++)); do
    if timeout "$timeout" $SSHKEY $SSH_KEEPALIVE_OPTS -o ConnectTimeout=5 -n "$SSHDEVICE" "\
        test -d '$DESTINATION' && \
        touch '$DESTINATION/.health_check' && \
        rm '$DESTINATION/.health_check'" 2>/dev/null; then
      return 0
    fi
    echo "Health check attempt $i/$attempts failed; backing off..."
    if (( i < attempts )); then
      sleep "$delay"
    fi
  done
  return 1
}

log_error() {
  local exit_code=${1:-1}
  local cmd=${2:-unknown}
  local line_no=${3:-unknown}
  local details=${4:-}
  {
    echo "[$(date -Is)] ERROR"
    echo "Exit code: $exit_code"
    echo "Failed command: $cmd"
    echo "Line: $line_no"
    echo "Hostname: $(hostname)"
    echo "User: ${USER:-unknown}"
    if [[ -n "$details" ]]; then
      echo "--- Details ---"
      printf "%s\n" "$details"
    fi
  } > "$LOGFILE"
  # Send error email
  "$PYTHON_ENV" "$EMAIL_SENDER" \
    --subject "Backup Error on $(hostname)" \
    --body-file "$LOGFILE" 2>/dev/null || echo "Failed to send error email"

}

trap 'ec=$?; log_error "$ec" "${BASH_COMMAND}" "${LINENO}"; exit "$ec"' ERR

#function to perform the rsync in parralel for each user if there is a latest symbolic directory then it uses that location for hardlinking
rsync_function(){
  declare -a pids=()
  # Common rsync and ssh options to improve resiliency under memory pressure
  local RSYNC_OPTS=("-avz" "--partial" "--append-verify" "--info=progress2,stats2" "--delete" "--timeout=120")
  local SSH_CMD="ssh -i /path/to/private/key $SSH_KEEPALIVE_OPTS"

  rsync_with_retries() {
    local peruser="$1"; shift
    local -a link_args=("$@")
    local attempts=3
    local delay=15
    local try
    for ((try=1; try<=attempts; try++)); do
      rsync "${RSYNC_OPTS[@]}" -e "$SSH_CMD" "$SOURCE/$peruser/" "${link_args[@]}" "$SSHDEVICE:$SNAP_LOC.partial/$peruser/" && return 0
      ec=$?
      echo "rsync for $peruser failed (exit $ec) on attempt $try/$attempts"
      # If interrupted by signal (20) or transient failure, wait and retry
      if (( try < attempts )); then
        # Re-check remote health before retrying
        if ! check_remote_health 3; then
          echo "Remote health check failed during rsync retry for $peruser; will retry after backoff"
        fi
        sleep "$delay"
      fi
    done
    return 1
  }
  for PERUSER in "${DIRECTORIES[@]}"; do
    if $1; then
      link_opts=("--link-dest=$LATESTLINK/$PERUSER")
    fi
    ssh_run "mkdir -p '${SNAP_LOC}.partial/${PERUSER}'"
    echo "Created ${PERUSER} directory"

    rsync_with_retries "$PERUSER" "${link_opts[@]}" &
    pids+=("$!")
    echo "Started rsync for ${PERUSER}"
  done

# Monitor background jobs with periodic health checks
  local check_interval=60  # Check every 60 seconds
  local last_check=$SECONDS
        
  while true; do
    local all_done=true
                
    # Check if any rsync jobs are still running
    for pid in "${pids[@]}"; do
      if kill -0 "$pid" 2>/dev/null; then
        all_done=false
        break
      fi
    done
          
    # If all done, exit monitoring loop
    if $all_done; then
      break
    fi
    
    # Periodic health check (every 60 seconds)
    local elapsed=$((SECONDS - last_check))
    if (( elapsed >= check_interval )); then
      echo "Performing periodic health check..."
            if ! check_remote_health 3; then
        echo "Remote health check failed! Killing rsync jobs..."
        for pid in "${pids[@]}"; do
                kill -TERM "$pid" 2>/dev/null || true
        done
        sleep 2
        # Force kill any stragglers
        for pid in "${pids[@]}"; do
                kill -KILL "$pid" 2>/dev/null || true
        done
        log_error 1 "rsync health check" "${LINENO}" "Remote filesystem became unavailable during backup"
        exit 1
      fi
      echo "Health check passed"
      last_check=$SECONDS
    fi
    
    sleep 5  # Check job status every 5 seconds
  done
  
  # Collect exit codes from all rsync jobs
  local failed=0
  for pid in "${pids[@]}"; do
          if ! wait "$pid"; then
                  failed=1
          fi
  done
  
  if (( failed )); then
          log_error 1 "rsync" "${LINENO}" "One or more rsync jobs failed"
          exit 1
  fi
}

ssh_run() {
  local remote_cmd="$1"
  local attempts=3
  local delay=2
  local status=0
  local last_err=""
  local errfile=""

  for ((i=1; i<=attempts; i++)); do
    errfile=$(mktemp)
    if $SSHKEY -n "$SSHDEVICE" "$remote_cmd" 2> "$errfile"; then
      rm -f "$errfile"
      return 0
    fi
    status=$?
    last_err="$(cat "$errfile")"
    rm -f "$errfile"
    echo "SSH attempt $i/$attempts failed for: $remote_cmd"
    if (( i < attempts )); then
      sleep "$delay"
    fi
  done

  log_error "$status" "ssh $SSHDEVICE -- $remote_cmd" "${LINENO}" "SSH stderr: $last_err"

  echo "SSH failed after $attempts attempts. Aborting."
  # Ensure any background jobs (like rsync) are terminated.
  kill 0
  exit 1
}

echo "Performing initial health check..."
if ! check_remote_health; then
  log_error 1 "pre-flight health check" "${LINENO}" "Remote filesystem not accessible before backup start"
  exit 1
fi

if ssh_run "test -e '$LATESTLINK'"; then
  echo "Detected latest directory at ${LATESTLINK}"
  rsync_function true
else
  echo "No latest directory detected"
  rsync_function false
fi

DURATION=$SECONDS
echo "Rsync success time taken $((DURATION / 3600)):$(((DURATION % 3600)/60)):$((DURATION % 60)). Now finishing snapshot and symbolic link to latest directory"

ssh_run "mkdir -p '${SNAP_LOC}' && mv ${SNAP_LOC}.partial/* ${SNAP_LOC}/ && ln -sfn ${SNAP_LOC} ${LATESTLINK} && chmod 775 '${LATESTLINK}'"
echo "Succesful Creation of snapshot folder and linking to latest directory. Now performing removal of .partial directories"

ssh_run "find '${DESTINATION}/snapshots/' -type d -name '*.partial' -exec rm -r {} +"
echo "Succesful Removal of .partial directories. Now applying retention policy of $RETENTION_POLICY days"

ssh_run "find '${DESTINATION}/snapshots/' -mindepth 1 -maxdepth 1 -type d -mtime +$RETENTION_POLICY -exec rm -rf {} +"
echo "Retention policy applied backup completed"