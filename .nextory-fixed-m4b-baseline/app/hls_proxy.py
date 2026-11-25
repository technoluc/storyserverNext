"""Short-lived, session-scoped HLS playlist rewriting and encrypted passthrough.

Provider URLs and AES-128 key references are replaced with opaque local paths;
raw segment/key bytes are streamed without decoding, modifying or caching.
"""
from __future__ import annotations

import re
import secrets
import threading
import time
from dataclasses import dataclass, field
from urllib.parse import urljoin, urlparse
from uuid import uuid4

from .nextory import NextoryError, TrackPart, safe_remote_url

SESSION_IDLE_TTL_SECONDS = 2 * 3600
SESSION_ABSOLUTE_TTL_SECONDS = 36 * 3600
MAX_RESOURCES_PER_SESSION = 12000
MAX_SESSIONS = 30
URI_ATTR_RE = re.compile(r'URI="([^"]+)"')


@dataclass(frozen=True)
class Resource:
    url: str
    kind: str


@dataclass
class Playback:
    id: str
    created: float
    last_used: float
    book_id: int
    title: str
    duration: float
    tracks: tuple[TrackPart, ...]
    user_id: str
    resource_map: dict[str, Resource] = field(default_factory=dict)
    resource_index: dict[tuple[str, str], str] = field(default_factory=dict)
    root_tokens: dict[int, str] = field(default_factory=dict)
    current_time: float = 0.0
    time_listening: float = 0.0
    closed: bool = False
    book_playlist: bytes | None = None  # NEXTORY_SINGLE_PRESENTATION_V1
    book_playlist_segments: int = 0
    _lock: threading.RLock = field(default_factory=threading.RLock)

    def register(self, url: str, kind: str) -> str:
        safe_remote_url(url)
        if kind not in {'manifest', 'segment', 'key'}:
            raise ValueError('Unsupported HLS resource type')
        with self._lock:
            existing = self.resource_index.get((kind, url))
            if existing:
                return existing
            if len(self.resource_map) >= MAX_RESOURCES_PER_SESSION:
                raise NextoryError('Too many HLS resources')
            token = secrets.token_urlsafe(18)
            self.resource_map[token] = Resource(url, kind)
            self.resource_index[(kind, url)] = token
            return token

    def resource(self, token: str) -> Resource | None:
        with self._lock:
            return self.resource_map.get(token)

    def public_uri(self, token: str, kind: str, url: str) -> str:
        extension = '.m3u8' if kind == 'manifest' else '.bin' if kind == 'key' else '.aac'
        if kind == 'segment':
            suffix = urlparse(url).path.lower().rsplit('.', 1)
            if len(suffix) == 2 and suffix[-1] in {'aac', 'ts', 'm4s', 'mp4', 'mp3'}:
                extension = '.' + suffix[-1]
        return f'/hls/{self.id}/{token}/stream{extension}'

    def set_track_root(self, track_index: int, url: str) -> None:
        if not 1 <= track_index <= len(self.tracks):
            raise NextoryError('Invalid track index')
        token = self.register(url, 'manifest')
        with self._lock:
            self.root_tokens[track_index] = token

    def root_uri(self, track_index: int) -> str | None:
        if not 1 <= track_index <= len(self.tracks):
            return None
        with self._lock:
            token = self.root_tokens.get(track_index)
            resource = self.resource_map.get(token) if token else None
            if not resource:
                return None
            return self.public_uri(token, 'manifest', resource.url)

    def clear(self):
        with self._lock:
            self.closed = True
            self.resource_map.clear()
            self.resource_index.clear()
            self.root_tokens.clear()
            self.book_playlist = None
            self.book_playlist_segments = 0


class Registry:
    def __init__(self):
        self._sessions: dict[str, Playback] = {}
        self._lock = threading.RLock()

    def create(self, *, book_id: int, title: str, tracks: tuple[TrackPart, ...],
               user_id: str, current_time: float = 0.0,
               book_presentation: bool = False) -> Playback:
        if not tracks or len(tracks) > 256:
            raise NextoryError('Invalid whole-book track list')
        with self._lock:
            self.cleanup()
            if len(self._sessions) >= MAX_SESSIONS:
                raise NextoryError('Too many playback sessions')
            if book_presentation and sum(s.book_playlist is not None for s in self._sessions.values()) >= 4:
                raise NextoryError('Single presentation capacity reached')
            duration = round(tracks[-1].start + tracks[-1].duration, 3)
            now = time.monotonic()
            session = Playback(id=str(uuid4()), created=now, last_used=now,
                               book_id=book_id, title=title, duration=duration,
                               tracks=tracks, user_id=user_id,
                               current_time=max(0.0, min(current_time, duration)),
                               book_playlist=b"" if book_presentation else None)
            for track in tracks:
                session.root_tokens[track.index] = session.register(track.uri, 'manifest')
            self._sessions[session.id] = session
            return session

    def get(self, session_id: str) -> Playback | None:
        with self._lock:
            session = self._sessions.get(session_id)
            if not session or session.closed:
                return None
            now = time.monotonic()
            if (now - session.last_used > SESSION_IDLE_TTL_SECONDS or
                    now - session.created > SESSION_ABSOLUTE_TTL_SECONDS):
                session.clear()
                self._sessions.pop(session_id, None)
                return None
            session.last_used = now
            return session

    def close(self, session_id: str):
        with self._lock:
            session = self._sessions.pop(session_id, None)
            if session:
                session.clear()

    def cleanup(self):
        now = time.monotonic()
        for sid, session in list(self._sessions.items()):
            if (session.closed or now - session.last_used > SESSION_IDLE_TTL_SECONDS or
                    now - session.created > SESSION_ABSOLUTE_TTL_SECONDS):
                session.clear()
                self._sessions.pop(sid, None)


registry = Registry()


def rewrite_playlist(document: str, base_url: str, session: Playback) -> str:
    """Rewrite nested playlists, media URLs and standard AES-128 key references.

    All encryption/DRM remains in the original source format. This routine does
    not fetch or inspect keys and will not circumvent protected streams.
    """
    lines = document.splitlines()
    if not lines or lines[0].strip() != '#EXTM3U':
        raise NextoryError('Invalid HLS playlist')
    is_master = any(s.startswith(('#EXT-X-STREAM-INF:', '#EXT-X-MEDIA:')) for s in lines)
    output = []
    for line in lines:
        if line.startswith('#') and 'URI="' in line:
            if line.startswith(('#EXT-X-KEY:', '#EXT-X-SESSION-KEY:')):
                kind = 'key'
            elif line.startswith(('#EXT-X-MEDIA:', '#EXT-X-I-FRAME-STREAM-INF:', '#EXT-X-RENDITION-REPORT:')):
                kind = 'manifest'
            else:
                kind = 'segment'

            def replace_uri(match):
                remote = urljoin(base_url, match.group(1))
                token = session.register(remote, kind)
                return f'URI="{session.public_uri(token, kind, remote)}"'

            output.append(URI_ATTR_RE.sub(replace_uri, line))
        elif line and not line.startswith('#'):
            remote = urljoin(base_url, line.strip())
            kind = 'manifest' if is_master else 'segment'
            token = session.register(remote, kind)
            output.append(session.public_uri(token, kind, remote))
        else:
            output.append(line)
    return '\n'.join(output) + '\n'
