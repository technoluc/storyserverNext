"""Tiny durable per-book listening progress store (no audio or provider tokens)."""
from __future__ import annotations
import json
import math
import os
import sqlite3
import tempfile
import threading
import time
from contextlib import closing, contextmanager
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


class ListeningHistory:
    """Persist playback attempts independently of audio and playback sessions."""

    def __init__(self, path: Path):
        self.path = path

    @contextmanager
    def _connection(self):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        with closing(sqlite3.connect(self.path, timeout=5)) as db, db:
            db.execute('''CREATE TABLE IF NOT EXISTS attempts (
                id TEXT UNIQUE NOT NULL, book_id INTEGER NOT NULL,
                payload TEXT NOT NULL)''')
            yield db

    def add(self, book_id: int, payload: dict):
        with self._connection() as db:
            db.execute('INSERT INTO attempts (id, book_id, payload) VALUES (?, ?, ?)',
                       (payload['id'], book_id, json.dumps(payload, ensure_ascii=False)))
            db.execute('''DELETE FROM attempts WHERE rowid < (
                SELECT rowid FROM attempts ORDER BY rowid DESC LIMIT 1 OFFSET 1999)''')

    def update(self, session_id: str, *, current_time: float, listened: float):
        with self._connection() as db:
            db.execute('BEGIN IMMEDIATE')
            row = db.execute('SELECT payload FROM attempts WHERE id = ?', (session_id,)).fetchone()
            if row:
                payload = json.loads(row[0])
                payload.update(currentTime=current_time, timeListening=listened,
                               updatedAt=int(time.time() * 1000))
                db.execute('UPDATE attempts SET payload = ? WHERE id = ?',
                           (json.dumps(payload, ensure_ascii=False), session_id))

    def page(self, page: int, size: int, book_id: int | None = None):
        where, args = (' WHERE book_id = ?', (book_id,)) if book_id is not None else ('', ())
        with self._connection() as db:
            total = db.execute('SELECT COUNT(*) FROM attempts' + where, args).fetchone()[0]
            rows = db.execute('SELECT payload FROM attempts' + where +
                              ' ORDER BY rowid DESC LIMIT ? OFFSET ?', (*args, size, page * size))
            return {'total': total, 'numPages': (total + size - 1) // size, 'page': page,
                    'itemsPerPage': size, 'sessions': [json.loads(row[0]) for row in rows]}

    def recent_books(self, limit: int):
        with self._connection() as db:
            return [row[0] for row in db.execute(
                'SELECT book_id FROM attempts GROUP BY book_id ORDER BY MAX(rowid) DESC LIMIT ?',
                (limit,))]


listening_history = ListeningHistory(STORE_PATH.with_name('listening-history.sqlite3'))
