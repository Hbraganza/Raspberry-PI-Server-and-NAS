#!/usr/bin/env python3
"""Weekly cron-friendly recursive detection script for Raspberry Pi.

Scans a root directory for image/video files, runs YOLO detection for
people and dogs, and stores metadata + detections in SQLite.

Manual test:
	python Detectionalgorithm.py --summary --debug

Example cron (weekly Sunday 02:30):
	30 2 * * 0 /usr/bin/python3 /path/to/Detectionalgorithm.py >> /var/log/detection.log 2>&1

All configuration is internal (no environment variables) for simplicity.
"""
import os
import sys
import hashlib
import json
import sqlite3
import time
import logging
import smtplib
from email.message import EmailMessage
from typing import List, Tuple, Optional

from ultralytics import YOLO  # Requires 'ultralytics' package
import cv2  # Requires 'opencv-python-headless'

# ------------------ Configuration Constants ------------------
DB_PATH: str = "share_detections.db"              # SQLite DB file
ROOT_SCAN_PATH: str = "scanning/path/to/directory"     # Root directory to recursively scan
MODEL_PATH: str = "yolo11m.pt"              # Use 'yolo11n.pt' for faster, lighter model
SUPPORTED_IMAGE_EXT = {".jpg", ".jpeg", ".png", ".bmp", ".webp", ".gif", ".heic"}
SUPPORTED_VIDEO_EXT = {".mp4", ".mov", ".avi", ".mpg", ".mpeg", ".wmv", ".3gp"}
TARGET_CLASSES = {"person", "dog"}
FRAME_SAMPLE_INTERVAL: int = 30             # Sample every Nth frame in videos
MIN_CONFIDENCE: float = 0.35                # Detection confidence threshold
LOG_PROGRESS_EVERY: int = 25                # Info log every N media files processed
MAX_VIDEO_FRAMES: Optional[int] = None      # Cap frames processed per video (None = no cap)
RETRY_MODEL_LOAD: int = 1                   # Retry count for model loading

# ------------------ Optional Email Alert Configuration ------------------
# Configure these to enable failure emails. Leave EMAIL_RECIPIENTS empty to disable.
EMAIL_RECIPIENTS: list[str] = []  # e.g., ["user@example.com", "admin@example.com"]
SMTP_HOST: str = ""              # e.g., "smtp.gmail.com"
SMTP_PORT: int = 587             # 587 for STARTTLS, 465 for implicit SSL
SMTP_STARTTLS: bool = True       # Use STARTTLS upgrade if True, else implicit SSL
SMTP_USERNAME: str = ""          # SMTP username (optional if server allows anonymous)
SMTP_PASSWORD: str = ""          # SMTP password or app password
EMAIL_SENDER: str = "noreply@example.com"  # From address in emails

# ------------------ Internal State ------------------
LOG_BUFFER: list[str] = []       # Accumulates log lines for potential email
DETECTION_ERRORS: list[str] = [] # Per-file detection failures

logger = logging.getLogger("detection")

class BufferingStdoutHandler(logging.Handler):
	def __init__(self, stream, level=logging.NOTSET):
		super().__init__(level)
		self.stream = stream
		self.formatter = logging.Formatter("%(asctime)s [%(levelname)s] %(message)s")

	def emit(self, record):
		try:
			msg = self.format(record)
			self.stream.write(msg + "\n")
			LOG_BUFFER.append(msg)
		except Exception:
			pass

def setup_logging(debug: bool) -> None:
	level = logging.DEBUG if debug else logging.INFO
	logger.setLevel(level)
	handler = BufferingStdoutHandler(sys.stdout, level)
	if not logger.handlers:
		logger.addHandler(handler)
	else:
		logger.handlers[:] = [handler]

# ------------------ Database ------------------
def connect_db() -> sqlite3.Connection:
	conn = sqlite3.connect(DB_PATH)
	conn.execute("PRAGMA journal_mode=WAL;")
	conn.execute("PRAGMA synchronous=NORMAL;")
	return conn

def init_db(conn: sqlite3.Connection) -> None:
	logger.debug("Initializing database schema")
	conn.executescript(
		"""
		CREATE TABLE IF NOT EXISTS directories (
			id INTEGER PRIMARY KEY,
			path TEXT UNIQUE NOT NULL,
			parent_id INTEGER REFERENCES directories(id)
		);
		CREATE TABLE IF NOT EXISTS files (
			id INTEGER PRIMARY KEY,
			directory_id INTEGER NOT NULL REFERENCES directories(id),
			name TEXT NOT NULL,
			path TEXT UNIQUE NOT NULL,
			size INTEGER,
			mtime INTEGER,
			sha256 TEXT,
			media_type TEXT,
			processed_at INTEGER,
			UNIQUE(path)
		);
		CREATE TABLE IF NOT EXISTS detections (
			id INTEGER PRIMARY KEY,
			file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
			object_class TEXT NOT NULL,
			confidence REAL NOT NULL,
			frame_index INTEGER,
			bbox TEXT
		);
		CREATE INDEX IF NOT EXISTS idx_files_directory ON files(directory_id);
		CREATE INDEX IF NOT EXISTS idx_detections_file ON detections(file_id);
		"""
	)
	conn.commit()

# ------------------ Helpers ------------------
def sha256_file(path: str, block_size: int = 1 << 20) -> str:
	h = hashlib.sha256()
	with open(path, "rb") as f:
		for chunk in iter(lambda: f.read(block_size), b""):
			h.update(chunk)
	return h.hexdigest()

def classify_media(path: str) -> Optional[str]:
	ext = os.path.splitext(path)[1].lower()
	if ext in SUPPORTED_IMAGE_EXT:
		return "image"
	if ext in SUPPORTED_VIDEO_EXT:
		return "video"
	return None

_dir_cache = {}
def ensure_directory(conn: sqlite3.Connection, path: str) -> int:
	if path in _dir_cache:
		return _dir_cache[path]
	cur = conn.execute("SELECT id FROM directories WHERE path=?", (path,))
	row = cur.fetchone()
	if row:
		_dir_cache[path] = row[0]
		return row[0]
	parent = os.path.dirname(path)
	parent_id = ensure_directory(conn, parent) if parent and parent != path else None
	cur = conn.execute("INSERT INTO directories(path, parent_id) VALUES(?, ?)", (path, parent_id))
	conn.commit()
	_dir_cache[path] = cur.lastrowid
	return cur.lastrowid

def upsert_file(conn: sqlite3.Connection, directory_id: int, path: str) -> int:
	st = os.stat(path)
	sha = sha256_file(path)
	media_type = classify_media(path)
	cur = conn.execute("SELECT id, sha256, mtime FROM files WHERE path=?", (path,))
	row = cur.fetchone()
	if row:
		file_id, old_sha, old_mtime = row
		if old_sha != sha or old_mtime != int(st.st_mtime):
			logger.debug(f"File changed -> reset processed: {path}")
			conn.execute(
				"UPDATE files SET size=?, mtime=?, sha256=?, media_type=?, processed_at=NULL WHERE id=?",
				(st.st_size, int(st.st_mtime), sha, media_type, file_id),
			)
			conn.commit()
		return file_id
	cur = conn.execute(
		"INSERT INTO files(directory_id, name, path, size, mtime, sha256, media_type, processed_at) VALUES(?,?,?,?,?,?,?,NULL)",
		(directory_id, os.path.basename(path), path, st.st_size, int(st.st_mtime), sha, media_type),
	)
	conn.commit()
	logger.debug(f"New file record: {path}")
	return cur.lastrowid

def needs_processing(conn: sqlite3.Connection, file_id: int) -> bool:
	cur = conn.execute("SELECT processed_at FROM files WHERE id=?", (file_id,))
	row = cur.fetchone()
	return row[0] is None if row else True

# ------------------ Model & Detection ------------------
def load_model() -> YOLO:
	for attempt in range(RETRY_MODEL_LOAD + 1):
		try:
			logger.info(f"Loading YOLO model: {MODEL_PATH}")
			return YOLO(MODEL_PATH)
		except Exception as e:
			logger.error(f"Model load failed attempt {attempt+1}: {e}")
			if attempt == RETRY_MODEL_LOAD:
				raise
			time.sleep(2)

def detect_on_image(model: YOLO, path: str) -> List[Tuple[str, float, list]]:
	res = model(path, verbose=False)[0]
	out = []
	for box in res.boxes:
		cls_name = model.names[int(box.cls)]
		conf = float(box.conf)
		if cls_name in TARGET_CLASSES and conf >= MIN_CONFIDENCE:
			out.append((cls_name, conf, box.xyxy[0].tolist()))
	logger.debug(f"Image {len(out)} detections: {path}")
	return out

def detect_on_video(model: YOLO, path: str) -> List[Tuple[str, float, int, list]]:
	"""Detect only a single instance per target class in a video.

	Scans sampled frames until each class in TARGET_CLASSES has at least one
	detection (or video ends). Keeps the highest-confidence bbox per class.
	Early-exits once all target classes have been found to avoid unnecessary
	processing of long videos.
	"""
	cap = cv2.VideoCapture(path)
	best: dict[str, Tuple[str, float, int, list]] = {}
	frame_index = 0
	while True:
		ok, frame = cap.read()
		if not ok:
			break
		if MAX_VIDEO_FRAMES is not None and frame_index >= MAX_VIDEO_FRAMES:
			logger.debug("Reached max video frame cap")
			break
		# Sample frame
		if frame_index % FRAME_SAMPLE_INTERVAL == 0:
			tmp_path = f"/tmp/_frame_{os.getpid()}_{frame_index}.jpg"
			cv2.imwrite(tmp_path, frame)
			res = model(tmp_path, verbose=False)[0]
			for box in res.boxes:
				cls_name = model.names[int(box.cls)]
				if cls_name not in TARGET_CLASSES:
					continue
				conf = float(box.conf)
				if conf < MIN_CONFIDENCE:
					continue
				bbox = box.xyxy[0].tolist()
				prev = best.get(cls_name)
				# Replace only if new detection has higher confidence
				if prev is None or conf > prev[1]:
					best[cls_name] = (cls_name, conf, frame_index, bbox)
			# Early exit if all target classes found
			if len(best) == len(TARGET_CLASSES):
				logger.debug("Early exit: all target classes detected in video")
				try:
					os.remove(tmp_path)
				except OSError:
					pass
				break
			try:
				os.remove(tmp_path)
			except OSError:
				pass
		frame_index += 1
	cap.release()
	detections = list(best.values())
	logger.debug(f"Video per-class detections {len(detections)}: {path}")
	return detections

def store_detections(conn: sqlite3.Connection, file_id: int, detections) -> None:
	conn.execute("DELETE FROM detections WHERE file_id=?", (file_id,))
	rows = []
	now = int(time.time())
	for det in detections:
		if len(det) == 3:  # image tuple
			cls_name, conf, bbox = det
			frame_idx = None
		else:              # video tuple
			cls_name, conf, frame_idx, bbox = det
		rows.append((file_id, cls_name, conf, frame_idx, json.dumps(bbox)))
	if rows:
		conn.executemany(
			"INSERT INTO detections(file_id, object_class, confidence, frame_index, bbox) VALUES(?,?,?,?,?)",
			rows,
		)
	conn.execute("UPDATE files SET processed_at=? WHERE id=?", (now, file_id))
	conn.commit()
	logger.debug(f"Stored {len(rows)} detections for file_id={file_id}")

def scan(root: str, conn: sqlite3.Connection, model: YOLO) -> None:
	logger.info(f"Starting scan of root: {root}")
	media_count = 0
	for dirpath, _, filenames in os.walk(root):
		dir_id = ensure_directory(conn, dirpath)
		for name in filenames:
			path = os.path.join(dirpath, name)
			media_type = classify_media(path)
			if not media_type:
				continue
			media_count += 1
			if media_count % LOG_PROGRESS_EVERY == 0:
				logger.info(f"Progress: {media_count} media files encountered")
			file_id = upsert_file(conn, dir_id, path)
			if not needs_processing(conn, file_id):
				logger.debug(f"Skip already processed: {path}")
				continue
			logger.debug(f"Processing {media_type}: {path}")
			try:
				if media_type == "image":
					dets_raw = detect_on_image(model, path)
					dets = [(c, conf, b) for (c, conf, b) in dets_raw]
				else:
					dets_raw = detect_on_video(model, path)
					dets = [(c, conf, fi, b) for (c, conf, fi, b) in dets_raw]
				store_detections(conn, file_id, dets)
			except Exception as e:
					err_msg = f"Detection failure {path}: {e}"
					logger.error(err_msg)
					DETECTION_ERRORS.append(err_msg)
	logger.info(f"Scan complete. Media files seen: {media_count}")

def diff_untracked(root: str, conn: sqlite3.Connection) -> List[str]:
	missing = []
	for dirpath, _, filenames in os.walk(root):
		for name in filenames:
			path = os.path.join(dirpath, name)
			if classify_media(path):
				cur = conn.execute("SELECT 1 FROM files WHERE path=?", (path,))
				if not cur.fetchone():
					missing.append(path)
	return missing

def summarize(conn: sqlite3.Connection) -> None:
	logger.info("Summary (top 10 files by detection count):")
	cur = conn.execute(
		"SELECT f.path, COUNT(d.id) AS cnt FROM files f LEFT JOIN detections d ON f.id=d.file_id GROUP BY f.id ORDER BY cnt DESC LIMIT 10"
	)
	for path, cnt in cur.fetchall():
		print(f"{cnt}\t{path}")

def parse_args(argv: List[str]):
	import argparse
	p = argparse.ArgumentParser(description="Recursive YOLO people/dog detection (cron-friendly)")
	p.add_argument("--diff", action="store_true", help="Show media files not yet tracked")
	p.add_argument("--summary", action="store_true", help="Print detection summary")
	p.add_argument("--debug", action="store_true", help="Enable debug logging")
	return p.parse_args(argv)

def send_failure_email(subject: str, body: str) -> None:
	if not EMAIL_RECIPIENTS or not SMTP_HOST:
		return
	try:
		msg = EmailMessage()
		msg["Subject"] = subject
		msg["From"] = EMAIL_SENDER
		msg["To"] = ", ".join(EMAIL_RECIPIENTS)
		msg.set_content(body)
		if SMTP_STARTTLS:
			with smtplib.SMTP(SMTP_HOST, SMTP_PORT, timeout=30) as s:
				s.ehlo()
				s.starttls()
				s.ehlo()
				if SMTP_USERNAME:
					s.login(SMTP_USERNAME, SMTP_PASSWORD)
				s.send_message(msg)
		else:
			with smtplib.SMTP_SSL(SMTP_HOST, SMTP_PORT, timeout=30) as s:
				if SMTP_USERNAME:
					s.login(SMTP_USERNAME, SMTP_PASSWORD)
				s.send_message(msg)
		logger.info("Failure email dispatched")
	except Exception as e:
		logger.error(f"Failed to send failure email: {e}")

def main(argv: List[str]) -> int:
	args = parse_args(argv)
	setup_logging(args.debug)
	conn = connect_db()
	init_db(conn)
	exit_code = 0
	model = None
	try:
		model = load_model()
	except Exception as e:
		logger.critical(f"Model load failed: {e}")
		exit_code = 2
	if model and exit_code == 0:
		try:
			if args.diff:
				missing = diff_untracked(ROOT_SCAN_PATH, conn)
				if missing:
					print("Untracked media files:")
					for p in missing:
						print(p)
				else:
					print("No untracked media files.")
			scan(ROOT_SCAN_PATH, conn, model)
			if args.summary:
				summarize(conn)
		except Exception as e:
			unhandled = f"Unhandled exception during scan: {e}"
			logger.critical(unhandled)
			DETECTION_ERRORS.append(unhandled)
			exit_code = 3
	conn.close()
	if exit_code != 0 or DETECTION_ERRORS:
		subject = f"Detection Script Failure (exit={exit_code} errors={len(DETECTION_ERRORS)})"
		body_sections = [
			f"Exit Code: {exit_code}",
			f"Root Path: {ROOT_SCAN_PATH}",
			f"Total Detection Errors: {len(DETECTION_ERRORS)}",
			"\n-- Recent Log (up to 500 lines) --",
			*LOG_BUFFER[-500:],
		]
		if DETECTION_ERRORS:
			body_sections.append("\n-- Error Details --")
			body_sections.extend(DETECTION_ERRORS)
		send_failure_email(subject, "\n".join(body_sections))
	return exit_code

if __name__ == "__main__":
	raise SystemExit(main(sys.argv[1:]))