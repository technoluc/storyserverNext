"""Short-lived HLS playlist rewriting and byte-for-byte encrypted media passthrough.

Remote signed URLs and keys never appear in our public playlists or logs.
No audio or encryption keys are persisted, decoded, decrypted or transcoded.
"""

from __future__ import annotations

import re
import secrets
import threading
import time
from dataclasses import dataclass, field
from urllib.parse import urljoin, urlparse
from uuid import uuid4

from .nextory import NextoryError, safe_remote_url

SESSION_TTL_SECONDS = 60 * 60
MAX_RESOURCES_PER_SESSION = 5000
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
    duration: float
    title: str
    first_uri: str
    user_id: str
    resource_map: dict[str, Resource] = field(default_factory=dict)
    root_resource_token: str | None = None
    current_time: float = 0.0
    time_listening: float = 0.0
    closed: bool = False
    _lock: threading.Lock = field(default_factory=threading.Lock)

    def register(self, url: str, kind: str) -> str:
        safe_remote_url(url)
        if kind not in {"manifest", "segment", "key"}:
            raise ValueError("Unsupported resource kind")
        with self._lock:
            if len(self.resource_map) >= MAX_RESOURCES_PER_SESSION:
                raise NextoryError("Too many HLS resource entries")
            token = secrets.token_urlsafe(18)
            self.resource_map[token] = Resource(url=url, kind=kind)
            return token

    def resource(self, token: str) -> Resource | None:
        with self._lock:
            return self.resource_map.get(token)

    def public_uri(self, token: str, kind: str, url: str) -> str:
        extension = ".m3u8" if kind == "manifest" else ".bin" if kind == "key" else ".aac"
        if kind == "segment":
            suffix = urlparse(url).path.lower().rsplit(".", 1)
            if len(suffix) == 2 and suffix[-1] in {"aac", "ts", "m4s", "mp4", "mp3"}:
                extension = "." + suffix[-1]
        return f"/hls/{self.id}/{token}/stream{extension}"


class Registry:
    def __init__(self):
        self._sessions: dict[str, Playback] = {}
        self._lock = threading.RLock()

    def create(self, *, duration: float, title: str, source_uri: str, user_id: str) -> Playback:
        with self._lock:
            self.cleanup()
            if len(self._sessions) >= MAX_SESSIONS:
                raise NextoryError("Too many active playback sessions")
            session = Playback(
                id=str(uuid4()), created=time.monotonic(), duration=duration,
                title=title, first_uri=source_uri, user_id=user_id,
            )
            session.root_resource_token = session.register(source_uri, "manifest")
            self._sessions[session.id] = session
            return session

    def get(self, session_id: str) -> Playback | None:
        with self._lock:
            session = self._sessions.get(session_id)
            if not session or session.closed or time.monotonic() - session.created > SESSION_TTL_SECONDS:
                return None
            return session

    def close(self, session_id: str) -> None:
        with self._lock:
            session = self._sessions.pop(session_id, None)
            if session:
                session.closed = True
                session.resource_map.clear()

    def cleanup(self) -> None:
        now = time.monotonic()
        for sid, ses in list(self._sessions.items()):
            if ses.closed or now - ses.created > SESSION_TTL_SECONDS:
                ses.resource_map.clear()
                self._sessions.pop(sid, None)


registry = Registry()


def rewrite_playlist(document: str, base_url: str, session: Playback) -> str:
    """Rewrite all URIs, including HLS AES-128 key references, to local paths.

    No key bytes are inspected or modified. Native AVPlayer performs the
    normal standard HLS handling. Unknown key methods are passed through;
    protected DRM streams may remain unplayable and are NOT bypassed.
    """
    lines = document.splitlines()
    if not lines or lines[0].strip() != "#EXTM3U":
        raise NextoryError("Invalid HLS playlist")
    is_master = any(x.startswith("#EXT-X-STREAM-INF:") or x.startswith("#EXT-X-MEDIA:") for x in lines)
    out = []
    for line in lines:
        if line.startswith("#") and 'URI="' in line:
            if line.startswith(("#EXT-X-KEY:", "#EXT-X-SESSION-KEY:")):
                kind = "key"
            elif line.startswith(("#EXT-X-MEDIA:", "#EXT-X-I-FRAME-STREAM-INF:", "#EXT-X-RENDITION-REPORT:")):
                kind = "manifest"
            else:
                kind = "segment"

            def repl(match):
                remote = urljoin(base_url, match.group(1))
                token = session.register(remote, kind)
                return f'URI="{session.public_uri(token, kind, remote)}"'

            out.append(URI_ATTR_RE.sub(repl, line))
        elif line and not line.startswith("#"):
            remote = urljoin(base_url, line.strip())
            kind = "manifest" if is_master else "segment"
            token = session.register(remote, kind)
            out.append(session.public_uri(token, kind, remote))
        else:
            out.append(line)
    return "\n".join(out) + "\n"
