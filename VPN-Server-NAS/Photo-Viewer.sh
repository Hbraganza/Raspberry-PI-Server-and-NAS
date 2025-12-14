#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
# Use project-local virtual environment for Python helpers (evdev, etc.)
PYTHON_BIN="${PYTHON_BIN:-$SCRIPT_DIR/photo-display/bin/python}"

# ---------------- Configuration (override via env) ----------------
DB_PATH="${DB_PATH:-$SCRIPT_DIR/share_detections.db}"

# How many items per bucket (images)
IMG_BOTH_COUNT="${IMG_BOTH_COUNT:-20}"
IMG_DOG_ONLY_COUNT="${IMG_DOG_ONLY_COUNT:-10}"
IMG_PERSON_ONLY_COUNT="${IMG_PERSON_ONLY_COUNT:-10}"
IMG_NEITHER_COUNT="${IMG_NEITHER_COUNT:-10}"

# How many items per bucket (videos)
VID_BOTH_COUNT="${VID_BOTH_COUNT:-5}"
VID_DOG_ONLY_COUNT="${VID_DOG_ONLY_COUNT:-5}"
VID_PERSON_ONLY_COUNT="${VID_PERSON_ONLY_COUNT:-5}"
VID_NEITHER_COUNT="${VID_NEITHER_COUNT:-5}"

# Daily schedule
SELECT_TIME="${SELECT_TIME:-05:30}"   # Build next playlist
START_TIME="${START_TIME:-06:00}"     # Turn screen on + start playback
STOP_TIME="${STOP_TIME:-23:00}"      # Turn screen off + pause

# Behavior
AUTO_ADVANCE_SEC="${AUTO_ADVANCE_SEC:-60}"   # Move to next item every N seconds
IDLE_TIMEOUT_SEC="${IDLE_TIMEOUT_SEC:-300}"  # Night desktop idle -> screen off
DEBUG_AFTER_HOURS="${DEBUG_AFTER_HOURS:-0}"  # 1 = allow playback after STOP_TIME
FORCE_PLAY="${FORCE_PLAY:-0}"               # 1 = play regardless of schedule (testing)

# Screen power commands (run as user)
SCREEN_ON_CMD="${SCREEN_ON_CMD:-sh -c 'echo "31" > /sys/class/backlight/11-0045/brightness'}"
SCREEN_OFF_CMD="${SCREEN_OFF_CMD:-sh -c 'echo "0" > /sys/class/backlight/11-0045/brightness'}"
export SCREEN_ON_CMD

# Paths
PLAYLIST_FILE="/tmp/photo_viewer_playlist.txt"
PLAYLIST_TMP="/tmp/photo_viewer_playlist.tmp"
STATE_DAY_FILE="/tmp/photo_viewer_day.txt"
IPC_SOCKET="/tmp/mpv-photo-viewer.sock"
LOG_FILE="/tmp/photo_viewer.log"
LOG_DAY_FILE="/tmp/photo_viewer_log_day.txt"

# ---------------- Utilities ----------------
log(){ printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE"; }
reset_log(){ > "$LOG_FILE"; log "Log reset"; }
daily_log_reset(){
	local today_val t
	today_val=$(today)
	t=$(now_time)
	if time_ge "$t" "$SELECT_TIME"; then
		if [ ! -f "$LOG_DAY_FILE" ] || ! grep -qx "$today_val" "$LOG_DAY_FILE"; then
			reset_log
			echo "$today_val" >"$LOG_DAY_FILE"
		fi
	fi
}

require_cmd(){ command -v "$1" >/dev/null 2>&1 || { log "Missing dependency: $1"; exit 1; }; }
require_python(){ [ -x "$PYTHON_BIN" ] || { log "Missing venv python: $PYTHON_BIN"; log "Create it with: python3 -m venv $SCRIPT_DIR/photo-display && $SCRIPT_DIR/photo-display/bin/pip install evdev"; exit 1; }; }

mpv_running(){ [ -n "${MPV_PID:-}" ] && kill -0 "$MPV_PID" 2>/dev/null; }

clear_playlist_files(){ rm -f "$PLAYLIST_FILE" "$PLAYLIST_TMP"; }

mpv_send(){
	local payload="$1"
	[ -S "$IPC_SOCKET" ] || return 1
	"$PYTHON_BIN" - "$IPC_SOCKET" "$payload" <<'PY'
import json, socket, sys
sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
try:
	sock.connect(sys.argv[1])
	sock.sendall((json.dumps({"command": json.loads(sys.argv[2])}) + "\n").encode())
finally:
	sock.close()
PY
}

mpv_get(){
	local prop="$1"
	[ -S "$IPC_SOCKET" ] || return 1
	"$PYTHON_BIN" - "$IPC_SOCKET" "$prop" <<'PY'
import json, socket, sys
sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.connect(sys.argv[1])
req = json.dumps({"command": ["get_property", sys.argv[2]]}) + "\n"
sock.sendall(req.encode())
data = sock.recv(65536)
sock.close()
try:
	resp = json.loads(data.decode())
	if resp.get("error") == "success":
		val = resp.get("data")
		if isinstance(val, bool):
			print("true" if val else "false")
		else:
			print(val)
except Exception:
	pass
PY
}

turn_screen_on(){ eval "$SCREEN_ON_CMD" || true; }
turn_screen_off(){ eval "$SCREEN_OFF_CMD" || true; }

now_time(){ date +%H:%M; }
today(){ date +%F; }

time_ge(){ [[ "$1" > "$2" || "$1" == "$2" ]]; }
time_lt(){ [[ "$1" < "$2" ]]; }

# ---------------- Selection ----------------
select_group(){
	local media_type="$1" cond="$2" limit="$3"
	(( limit > 0 )) || return 0
	local oversample=$((limit * 5))
	local picked=0
	local seen=""
	# Oversample from DB, keep only existing readable files, ensure uniqueness, and stop when we hit the target.
	while IFS= read -r path; do
		[ -z "$path" ] && continue
		# ensure uniqueness
		case " $seen " in *" $path "*) continue;; esac
		if [ -f "$path" ] && [ -r "$path" ]; then
			printf '%s\n' "$path"
			seen="$seen $path"
			picked=$((picked+1))
			if [ $picked -ge $limit ]; then
				break
			fi
		fi
	done < <(sqlite3 "$DB_PATH" "SELECT f.path FROM files f WHERE f.media_type='$media_type' AND $cond ORDER BY RANDOM() LIMIT $oversample;")
	if [ $picked -lt $limit ]; then
		log "Warning: only $picked/$limit $media_type files available for condition [$cond]"
	fi
}

build_playlist(){
	log "Building playlist from DB $DB_PATH"
	: >"$PLAYLIST_TMP"

	local cond_both="EXISTS (SELECT 1 FROM detections d WHERE d.file_id=f.id AND d.object_class='person') AND EXISTS (SELECT 1 FROM detections d2 WHERE d2.file_id=f.id AND d2.object_class='dog')"
	local cond_dog_only="EXISTS (SELECT 1 FROM detections d WHERE d.file_id=f.id AND d.object_class='dog') AND NOT EXISTS (SELECT 1 FROM detections d2 WHERE d2.file_id=f.id AND d2.object_class='person')"
	local cond_person_only="EXISTS (SELECT 1 FROM detections d WHERE d.file_id=f.id AND d.object_class='person') AND NOT EXISTS (SELECT 1 FROM detections d2 WHERE d2.file_id=f.id AND d2.object_class='dog')"
	local cond_neither="NOT EXISTS (SELECT 1 FROM detections d WHERE d.file_id=f.id AND d.object_class='dog') AND NOT EXISTS (SELECT 1 FROM detections d2 WHERE d2.file_id=f.id AND d2.object_class='person')"

	select_group image "$cond_both" "$IMG_BOTH_COUNT" >>"$PLAYLIST_TMP"
	select_group image "$cond_dog_only" "$IMG_DOG_ONLY_COUNT" >>"$PLAYLIST_TMP"
	select_group image "$cond_person_only" "$IMG_PERSON_ONLY_COUNT" >>"$PLAYLIST_TMP"
	select_group image "$cond_neither" "$IMG_NEITHER_COUNT" >>"$PLAYLIST_TMP"

	select_group video "$cond_both" "$VID_BOTH_COUNT" >>"$PLAYLIST_TMP"
	select_group video "$cond_dog_only" "$VID_DOG_ONLY_COUNT" >>"$PLAYLIST_TMP"
	select_group video "$cond_person_only" "$VID_PERSON_ONLY_COUNT" >>"$PLAYLIST_TMP"
	select_group video "$cond_neither" "$VID_NEITHER_COUNT" >>"$PLAYLIST_TMP"

	if ! [ -s "$PLAYLIST_TMP" ]; then
		log "No media matched selection criteria"
		return 1
	fi

	shuf "$PLAYLIST_TMP" >"$PLAYLIST_FILE"
	rm -f "$PLAYLIST_TMP"
	today >"$STATE_DAY_FILE"
	log "Playlist items:"
	while IFS= read -r path; do
		log "  $path"
	done <"$PLAYLIST_FILE"
	# Reload mpv with the new playlist so old entries are dropped from memory
	if mpv_running; then
		mpv_send '["loadlist", "'$PLAYLIST_FILE'", "replace"]' || mpv_send '["stop"]' || true
	fi
	log "Playlist built with $(wc -l < "$PLAYLIST_FILE") items"
}

# ---------------- MPV control ----------------
start_mpv(){
	rm -f "$IPC_SOCKET"
	log "Starting mpv viewer"
	mpv --idle=yes --force-window=yes --fullscreen --loop-playlist=inf \
		--input-ipc-server="$IPC_SOCKET" --image-display-duration="$AUTO_ADVANCE_SEC" \
		--keep-open=yes --no-terminal --no-resume-playback --cursor-autohide=no \
		--playlist="$PLAYLIST_FILE" >/tmp/mpv_photo_viewer.log 2>&1 &
	MPV_PID=$!
	log "mpv pid=$MPV_PID"
}

stop_mpv(){
	if mpv_running; then
		log "Stopping mpv"
		kill "$MPV_PID" 2>/dev/null || true
		wait "$MPV_PID" 2>/dev/null || true
	fi
	MPV_PID=""
	rm -f "$IPC_SOCKET"
}

auto_advance_loop(){
	while true; do
		sleep "$AUTO_ADVANCE_SEC"
		if ! mpv_running; then continue; fi
		if [ "$DEBUG_AFTER_HOURS" = "0" ] && ! is_play_window; then continue; fi
		local paused
		paused=$(mpv_get pause || echo "false")
		if [ "$paused" != "true" ]; then
			mpv_send '["playlist-next", "weak"]' || true
		fi
	done
}

# ---------------- Gesture listener ----------------
start_gestures(){
	"$PYTHON_BIN" - "$IPC_SOCKET" <<'PY' &
import json, os, socket, sys, time

try:
	from evdev import InputDevice, list_devices, ecodes
except Exception:
	print("[gesture] evdev not available; gestures disabled", flush=True)
	sys.exit(0)

ipc_path = sys.argv[1]
screen_cmd = os.environ.get("SCREEN_ON_CMD", "")
log_file = "/tmp/photo_viewer.log"

def log_touch(msg):
	try:
		with open(log_file, "a") as f:
			from datetime import datetime
			f.write(f"[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] {msg}\n")
	except Exception:
		pass

def wake_screen():
	if screen_cmd:
		log_touch("wake_screen trigger")
		os.system(screen_cmd)

def minimize_mpv_window():
	# Best-effort minimize so desktop is reachable when paused
	if os.system("command -v xdotool >/dev/null 2>&1") == 0:
		os.system("xdotool search --class mpv windowminimize 2>/dev/null")

def send(cmd):
	if not os.path.exists(ipc_path):
		log_touch(f"IPC missing; cannot send {cmd}")
		return
	for _ in range(3):
		try:
			s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
			s.settimeout(0.3)
			s.connect(ipc_path)
			s.sendall((json.dumps({"command": cmd}) + "\n").encode())
			s.close()
			log_touch(f"IPC send ok: {cmd}")
			return
		except Exception as e:
			time.sleep(0.05)
	log_touch(f"IPC send failed after retries: {cmd}")

def find_touch():
	for dev in list_devices():
		d = InputDevice(dev)
		name = d.name.lower()
		if any(k in name for k in ["touch", "ft5406", "goodix", "ft5"]):
			return d
	return None

device = find_touch()
if device is None:
	print("[gesture] No touchscreen found; gestures disabled", flush=True)
	sys.exit(0)

try:
	device.grab()
except OSError:
	print("[gesture] Could not grab device; continuing without exclusive access", flush=True)

start_pos = None
last_x = None
last_y = None
SWIPE_DIST = 100
SWIPE_TIME = 1.0

def handle_swipe(dx_raw, dy_raw, dt):
	# Rotate touch axes by +90 degrees so physical up/down become next/prev
	# and physical left/right control desktop toggle, matching rotated screen.
	rot_dx = dy_raw   # physical up -> negative dy -> rot_dx negative (next)
	rot_dy = -dx_raw  # physical left -> negative dx -> rot_dy positive (desktop)

	if dt > SWIPE_TIME:
		return
	if abs(rot_dx) > abs(rot_dy) and abs(rot_dx) > SWIPE_DIST:
		if rot_dx < 0:
			log_touch(f"Swipe (phys up -> next): rot_dx={rot_dx:.0f}")
			send(["playlist-next", "force"])
			log_touch("Action: requested next item")
		else:
			log_touch(f"Swipe (phys down -> prev): rot_dx={rot_dx:.0f}")
			send(["playlist-prev"])
			log_touch("Action: requested previous item")
	elif abs(rot_dy) > abs(rot_dx) and abs(rot_dy) > SWIPE_DIST:
		if rot_dy > 0:
			log_touch(f"Swipe (phys left -> desktop): rot_dy={rot_dy:.0f}")
			send(["set", "fullscreen", False])
			send(["set", "pause", True])
			minimize_mpv_window()
			log_touch("Action: pause and exit fullscreen (desktop)")
		else:
			log_touch(f"Swipe (phys right -> resume): rot_dy={rot_dy:.0f}")
			send(["set", "fullscreen", True])
			send(["set", "pause", False])
			log_touch("Action: resume and fullscreen")

try:
	for event in device.read_loop():
		if event.type == ecodes.EV_ABS:
			if event.code in (ecodes.ABS_MT_POSITION_X, ecodes.ABS_X):
				x = event.value
				last_x = x
			if event.code in (ecodes.ABS_MT_POSITION_Y, ecodes.ABS_Y):
				y = event.value
				last_y = y
			if 'x' in locals() and 'y' in locals():
				if start_pos is None:
					start_pos = (x, y, time.time())
					log_touch(f"Touch at ({x}, {y})")
					wake_screen()
				else:
					dx = x - start_pos[0]
					dy = y - start_pos[1]
					dt = time.time() - start_pos[2]
					if abs(dx) > SWIPE_DIST or abs(dy) > SWIPE_DIST:
						handle_swipe(dx, dy, dt)
						start_pos = None
		elif event.type == ecodes.EV_KEY and event.code == ecodes.BTN_TOUCH:
			if event.value == 1:
				# Log tap with last known coordinates even if ABS events didn't arrive yet for this touch
				if last_x is not None and last_y is not None:
					log_touch(f"Tap press at ({last_x}, {last_y})")
				else:
					log_touch("Tap press (coords unknown)")
				start_pos = ((last_x or 0), (last_y or 0), time.time())
				wake_screen()
			elif event.value == 0:
				if last_x is not None and last_y is not None:
					log_touch(f"Tap release at ({last_x}, {last_y})")
				else:
					log_touch("Tap release (coords unknown)")
				start_pos = None
				wake_screen()
except KeyboardInterrupt:
	pass
finally:
	try:
		device.ungrab()
	except Exception:
		pass
PY
	GESTURE_PID=$!
	log "Gestures pid=$GESTURE_PID"
}

# ---------------- Idle watcher ----------------
idle_watch(){
	if ! command -v xprintidle >/dev/null 2>&1; then
		log "xprintidle not installed; idle detection disabled"
		return
	fi
	while true; do
		sleep 15
		local t
		t=$(now_time)
		if time_ge "$t" "$STOP_TIME" || time_lt "$t" "$START_TIME"; then
			local idle_ms
			idle_ms=$(xprintidle 2>/dev/null || echo 0)
			if [ "$idle_ms" -ge $((IDLE_TIMEOUT_SEC*1000)) ]; then
				turn_screen_off
				mpv_send '["set", "fullscreen", false]' || true
				mpv_send '["set", "pause", true]' || true
			fi
		fi
	done
}

# ---------------- Time windows ----------------
is_select_window(){ local t=$(now_time); time_ge "$t" "$SELECT_TIME" && time_lt "$t" "$START_TIME"; }
is_play_window(){
	local t=$(now_time)
	if [ "$FORCE_PLAY" = "1" ]; then return 0; fi
	if time_ge "$t" "$START_TIME" && ( time_lt "$t" "$STOP_TIME" || [ "$DEBUG_AFTER_HOURS" = "1" ] ); then
		return 0
	fi
	return 1
}

# ---------------- Main scheduling ----------------
daily_selection(){
	daily_log_reset
	local today_val t
	today_val=$(today)
	t=$(now_time)
	local have_today=1
	if [ -f "$STATE_DAY_FILE" ] && grep -qx "$today_val" "$STATE_DAY_FILE"; then
		have_today=0
	fi
	# Rebuild once per new day, but not before SELECT_TIME to match the 05:30 cycle.
	if [ $have_today -ne 0 ] && time_ge "$t" "$SELECT_TIME"; then
		reset_log
		stop_mpv
		clear_playlist_files
		build_playlist || true
		return
	fi
	# Safety: if playlist missing, try to build immediately (e.g., first boot mid-day or no prior build).
	if [ ! -s "$PLAYLIST_FILE" ]; then
		stop_mpv
		clear_playlist_files
		build_playlist || true
	fi
}

ensure_playlist_ready(){
	if [ ! -s "$PLAYLIST_FILE" ]; then
		build_playlist || true
	fi
}

main_loop(){
	while true; do
		local t
		t=$(now_time)
		daily_selection
		if is_play_window; then
			ensure_playlist_ready
			turn_screen_on
			if ! mpv_running; then start_mpv; fi
			mpv_send '["set", "pause", false]' || true
			mpv_send '["set", "fullscreen", true]' || true
		else
			# Off hours
			mpv_send '["set", "pause", true]' || true
			mpv_send '["set", "fullscreen", false]' || true
			turn_screen_off
		fi
		sleep 30
	done
}

# ---------------- Cleanup ----------------
cleanup(){
	log "Shutting down photo viewer"
	# Kill child processes
	[ -n "${MPV_PID:-}" ] && kill -9 "$MPV_PID" 2>/dev/null || true
	[ -n "${GESTURE_PID:-}" ] && kill -9 "$GESTURE_PID" 2>/dev/null || true
	[ -n "${AUTOADV_PID:-}" ] && kill -9 "$AUTOADV_PID" 2>/dev/null || true
	[ -n "${IDLE_PID:-}" ] && kill -9 "$IDLE_PID" 2>/dev/null || true
	# Ensure any python helpers spawned by this script are terminated
	if command -v pkill >/dev/null 2>&1; then
		pkill -P $$ -f "$PYTHON_BIN" 2>/dev/null || true
	else
		for pid in $(ps -o pid= --ppid $$ | tr -d ' '); do
			cmd=$(ps -p "$pid" -o args= 2>/dev/null || true)
			if printf '%s' "$cmd" | grep -q "$PYTHON_BIN"; then
				kill -9 "$pid" 2>/dev/null || true
			fi
		done
	fi
	# Clean up any zenity dialogs
	pkill -9 zenity 2>/dev/null || true
	# Remove socket
	rm -f "$IPC_SOCKET"
	log "Cleanup complete"
	exit 0
}

trap cleanup SIGINT SIGTERM

# ---------------- Startup ----------------
require_cmd sqlite3
require_cmd mpv
require_python
require_cmd shuf

reset_log
echo "$(today)" >"$LOG_DAY_FILE"
log "Photo viewer PID $$"

build_playlist || true
start_mpv
start_gestures

auto_advance_loop &
AUTOADV_PID=$!
log "Auto-advance pid=$AUTOADV_PID"

idle_watch &
IDLE_PID=$!
log "Idle watcher pid=$IDLE_PID"

main_loop
