"""NEXTORY_DETAIL_PREWARM_V1: bounded, metadata-only HLS prewarming.

Triggered only by the authenticated expanded book-detail endpoint. No media
segments, key bytes or audio files are fetched or stored by this module.
"""
from __future__ import annotations

import asyncio
import logging
import threading
import time
from concurrent.futures import Future, ThreadPoolExecutor
from dataclasses import dataclass
from typing import Callable

LOG = logging.getLogger('uvicorn.error')
PREWARM_TTL_SECONDS = 120  # Shorter than NextoryBackend's five-minute cache.
PREWARM_MAX_ACTIVE = 2
PREWARM_MAX_ENTRIES = 8


@dataclass
class _Entry:
    future: Future
    created: float
    completed: float | None = None


class PrewarmManager:
    """Single-flight work per book; never schedules work during catalog listing.

    `compute(book_id)` returns (BookInfo, tracks, book_ms, layout_ms).
    `peek(book_id)` returns a still-valid cached (BookInfo, tracks) or None.
    No provider calls occur during construction or when the service starts.
    """

    def __init__(self, compute: Callable, peek: Callable, *,
                 ttl_seconds: float = PREWARM_TTL_SECONDS,
                 max_active: int = PREWARM_MAX_ACTIVE,
                 max_entries: int = PREWARM_MAX_ENTRIES):
        self._compute = compute
        self._peek = peek
        self._ttl = ttl_seconds
        self._max_active = max_active
        self._max_entries = max_entries
        self._lock = threading.Lock()
        self._entries: dict[int, _Entry] = {}
        self._pool = ThreadPoolExecutor(max_workers=max_active, thread_name_prefix='nextory-warm')
        self._closed = False

    def _expire_locked(self, now: float) -> None:
        for book_id, entry in list(self._entries.items()):
            if not entry.future.done():
                continue
            if entry.completed is None:
                entry.completed = now
            if entry.future.cancelled() or entry.future.exception() is not None or now-entry.completed >= self._ttl:
                self._entries.pop(book_id, None)

    def _work(self, book_id: int):
        started = time.perf_counter()
        try:
            info, tracks, book_ms, layout_ms = self._compute(book_id)
            LOG.info('POC_PREWARM stage=prepare status=ready book_ms=%d layout_ms=%d tracks=%d total_ms=%d',
                     book_ms, layout_ms, len(tracks), int((time.perf_counter()-started)*1000))
            return info, tracks, book_ms, layout_ms
        except Exception as exc:
            # Never log provider exceptions: they may contain signed upstream URLs.
            LOG.warning('POC_PREWARM stage=prepare status=failed error_type=%s', type(exc).__name__)
            raise

    def _completed(self, book_id: int, entry: _Entry) -> None:
        with self._lock:
            if self._entries.get(book_id) is entry:
                entry.completed = time.monotonic()

    def schedule(self, book_id: int) -> str:
        """Nonblocking. Called only after authenticating and loading a book detail."""
        with self._lock:
            if self._closed:
                return 'closed'
            now = time.monotonic()
            self._expire_locked(now)
            existing = self._entries.get(book_id)
            if existing is not None:
                state = 'reuse' if existing.future.done() else 'inflight'
                LOG.info('POC_PREWARM stage=detail status=%s', state)
                return state
            active = sum(not entry.future.done() for entry in self._entries.values())
            if active >= self._max_active:
                LOG.info('POC_PREWARM stage=detail status=capacity')
                return 'capacity'
            if len(self._entries) >= self._max_entries:
                oldest = min((item for item in self._entries.items() if item[1].future.done()),
                             key=lambda item: item[1].completed or item[1].created, default=None)
                if oldest is None:
                    return 'capacity'
                self._entries.pop(oldest[0], None)
            future = self._pool.submit(self._work, book_id)
            entry = _Entry(future=future, created=now)
            self._entries[book_id] = entry
        future.add_done_callback(lambda _fut: self._completed(book_id, entry))
        LOG.info('POC_PREWARM stage=detail status=scheduled')
        return 'scheduled'

    def busy(self) -> bool:
        """Keep detail pages fast if any prewarm owns the backend HLS lock."""
        with self._lock:
            return any(not entry.future.done() for entry in self._entries.values())

    async def obtain(self, book_id: int) -> tuple[tuple, str, int]:
        """Play reuses the same work or falls back to the existing cold path."""
        with self._lock:
            self._expire_locked(time.monotonic())
            entry = self._entries.get(book_id)
        if entry is not None:
            state = 'hit' if entry.future.done() else 'wait'
            started = time.perf_counter()
            try:
                # shield: cancelled Play requests must not cancel the warm job.
                await asyncio.shield(asyncio.wrap_future(entry.future))
                # Backend owns signed-URI freshness; do not trust a stale future.
                cached = await asyncio.to_thread(self._peek, book_id)
                if cached is not None:
                    info, tracks = cached
                    waited = int((time.perf_counter()-started)*1000)
                    LOG.info('POC_PREWARM stage=play status=%s wait_ms=%d tracks=%d',
                             state, waited, len(tracks))
                    return (info, tracks, 0, 0), state, waited
                LOG.info('POC_PREWARM stage=play status=stale')
            except Exception as exc:
                LOG.warning('POC_PREWARM stage=play status=retry error_type=%s', type(exc).__name__)
            with self._lock:
                if self._entries.get(book_id) is entry:
                    self._entries.pop(book_id, None)
        started = time.perf_counter()
        data = await asyncio.to_thread(self._compute, book_id)
        elapsed = int((time.perf_counter()-started)*1000)
        LOG.info('POC_PREWARM stage=play status=miss elapsed_ms=%d tracks=%d',
                 elapsed, len(data[1]))
        return data, 'miss', elapsed

    def shutdown(self):
        with self._lock:
            self._closed = True
        self._pool.shutdown(wait=False, cancel_futures=True)
