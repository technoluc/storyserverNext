"""Tiny durable per-book listening progress store (no audio or provider tokens)."""
from __future__ import annotations
import json
import math
import os
import tempfile
import threading
import time
from pathlib import Path

STORE_PATH = Path(os.environ.get('PROGRESS_FILE', '/state/progress.json'))

class ProgressStore:
    def __init__(self, path: Path = STORE_PATH):
        self.path = path
        self._lock = threading.RLock()
        self._entries: dict[str, dict] = {}
        self._load()

    def _load(self):
        with self._lock:
            try:
                data = json.loads(self.path.read_text(encoding='utf-8'))
                if isinstance(data, dict):
                    self._entries = {str(key): v for key, v in data.items()
                                     if isinstance(v, dict) and str(key).isdigit()}
            except FileNotFoundError:
                return
            except (OSError, ValueError):
                raise RuntimeError('Invalid or unreadable progress store; refusing to overwrite')

    def get(self, book_id: int) -> dict | None:
        with self._lock:
            entry = self._entries.get(str(book_id))
            return dict(entry) if entry is not None else None

    def all(self) -> dict[int, dict]:
        with self._lock:
            return {int(key): dict(value) for key, value in self._entries.items()}

    def update(self, book_id: int, *, current_time: float, duration: float) -> dict:
        if not all(math.isfinite(v) for v in (current_time, duration)) or duration <= 0:
            raise ValueError('Invalid playback progress time')
        now = int(time.time() * 1000)
        value = {'currentTime': round(max(0, min(current_time, duration)), 3),
                 'duration': round(duration, 3), 'lastUpdate': now}
        with self._lock:
            previous = self._entries.get(str(book_id)) or {}
            first_seen = previous.get('startedAt') or previous.get('lastUpdate') or now
            value['startedAt'] = int(first_seen)  # AUDIOBOOTH_COMPAT_V1
            self._entries[str(book_id)] = value
            self.path.parent.mkdir(parents=True, exist_ok=True)
            temp_name = None
            try:
                fd, temp_name = tempfile.mkstemp(prefix='.progress-', dir=self.path.parent)
                with os.fdopen(fd, 'w', encoding='utf-8') as handle:
                    os.chmod(temp_name, 0o600)
                    json.dump(self._entries, handle, ensure_ascii=False, separators=(',', ':'))
                    handle.flush()
                    os.fsync(handle.fileno())
                os.replace(temp_name, self.path)
            finally:
                if temp_name is not None and os.path.exists(temp_name):
                    os.unlink(temp_name)
            return dict(value)

progress_store = ProgressStore()
