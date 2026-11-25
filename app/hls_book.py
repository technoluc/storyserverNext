"""NEXTORY_SINGLE_PRESENTATION_V1: optional one-item HLS presentation.

Metadata-only composition for the isolated AudioBooth experiment. All provider
media and key bytes are still relayed by the original HLS resource endpoint.
Unsupported HLS features fail closed to the established multi-track path.
"""
from __future__ import annotations

import asyncio
import hashlib
import logging
import math
import re
import threading
import time
from collections import OrderedDict
from concurrent.futures import Future, ThreadPoolExecutor, TimeoutError as FutureTimeout
from dataclasses import dataclass
from urllib.parse import urljoin

from .nextory import TrackPart, NextoryError, safe_remote_url

LOG = logging.getLogger('uvicorn.error')
MAX_PART_BYTES = 2 * 1024 * 1024
MAX_BOOK_BYTES = 4 * 1024 * 1024
MAX_BOOK_SEGMENTS = 6000
PLAN_TTL_SECONDS = 120
MAX_PLANS = 2
MAX_PENDING_PLANS = 2  # one running, at most one queued
PLAY_WAIT_SECONDS = 8.0
PREPARE_WAIT_SECONDS = 60.0
PLAY_TOTAL_BUDGET_SECONDS = 8.5  # reserve time for JSON/rewrite before 10s client timeout


def book_ref(book_id):
    """Stable diagnostic correlation, without a title, session ID or URL."""
    return hashlib.sha256(f'nextory-book:{book_id}'.encode()).hexdigest()[:10]


def _signature(tracks):
    # compose() uses only source identity and title; measured starts/durations
    # are outputs, not inputs. Include the full signed source URI in-memory.
    return tuple((t.index, t.uri, t.title) for t in tracks)
_ATTR = re.compile(r'([A-Z0-9-]+)=("[^"\r\n]*"|[^,\r\n]+)(?:,|$)')
_HEX_IV = re.compile(r'0[xX][0-9A-Fa-f]{1,32}\Z')
_INT = re.compile(r'[0-9]{1,20}\Z')


class Unsupported(NextoryError):
    """Fixed, nonsecret reason why a source cannot be composed safely."""


@dataclass(frozen=True)
class Key:
    method: str
    uri: str
    iv: str | None
    keyformat: str | None
    keyformatversions: str | None

    def tag(self, sequence: int, output_sequence: int) -> str:
        # Preserve the source's effective IV under the new global sequence.
        # This does NOT decrypt, re-encrypt, retrieve or change any key/media.
        iv = self.iv
        if iv is None and self.method == 'AES-128' and sequence != output_sequence:
            iv = f'0x{sequence:032x}'
        elif iv is None and self.method != 'AES-128' and sequence != output_sequence:
            raise Unsupported('implicit_sample_aes_iv')
        line = f'#EXT-X-KEY:METHOD={self.method},URI="{self.uri}"'
        if iv is not None:
            line += ',IV=' + iv
        if self.keyformat is not None:
            line += ',KEYFORMAT=' + self.keyformat
        if self.keyformatversions is not None:
            line += ',KEYFORMATVERSIONS=' + self.keyformatversions
        return line


@dataclass(frozen=True)
class Segment:
    extinf: str
    duration: float
    uri: str
    sequence: int
    key: Key | None
    discontinuity: bool


@dataclass(frozen=True)
class Part:
    segments: tuple[Segment, ...]
    version: int
    target_duration: int
    duration: float


@dataclass(frozen=True)
class BookPlan:
    document: str
    chapters: tuple[TrackPart, ...]
    segment_count: int
    bytes: int


def _number(value: str, limit: int) -> int:
    if not _INT.fullmatch(value):
        raise Unsupported('invalid_integer_tag')
    result = int(value)
    if result > limit:
        raise Unsupported('integer_tag_limit')
    return result


def _attributes(value: str) -> dict[str, str]:
    pos = 0
    result: dict[str, str] = {}
    while pos < len(value):
        match = _ATTR.match(value, pos)
        if match is None or match.group(1) in result:
            raise Unsupported('invalid_key_attributes')
        result[match.group(1)] = match.group(2)
        pos = match.end()
    if not result:
        raise Unsupported('missing_key_attributes')
    return result


def _key(value: str, base_url: str) -> Key | None:
    attrs = _attributes(value)
    method = attrs.get('METHOD')
    if method == 'NONE' and set(attrs) == {'METHOD'}:
        return None
    # The original proxy relays the provider's identity key URL unchanged.
    # Do not attempt DRM conversions or accept alternate key formats.
    if method not in {'AES-128', 'SAMPLE-AES'}:
        raise Unsupported('unsupported_key_method')
    if set(attrs) - {'METHOD', 'URI', 'IV', 'KEYFORMAT', 'KEYFORMATVERSIONS'}:
        raise Unsupported('unsupported_key_attributes')
    if attrs.get('KEYFORMAT') not in (None, '"identity"'):
        raise Unsupported('unsupported_keyformat')
    if attrs.get('KEYFORMATVERSIONS') not in (None, '"1"'):
        raise Unsupported('unsupported_keyformatversions')
    raw_uri = attrs.get('URI', '')
    if len(raw_uri) < 3 or not raw_uri.startswith('"') or not raw_uri.endswith('"'):
        raise Unsupported('invalid_key_uri')
    uri = urljoin(base_url, raw_uri[1:-1])
    if '"' in uri or '\r' in uri or '\n' in uri or len(uri) > 8192:
        raise Unsupported('invalid_key_uri')
    iv = attrs.get('IV')
    if iv is not None and not _HEX_IV.fullmatch(iv):
        raise Unsupported('invalid_key_iv')
    return Key(method, uri, iv, attrs.get('KEYFORMAT'), attrs.get('KEYFORMATVERSIONS'))


def _lines(document: str) -> list[str]:
    if len(document.encode('utf-8')) > MAX_PART_BYTES:
        raise Unsupported('part_manifest_limit')
    lines = [line.strip() for line in document.splitlines() if line.strip()]
    if not lines or lines[0] != '#EXTM3U':
        raise Unsupported('invalid_manifest')
    return lines


def read_part(fetch_manifest, track: TrackPart) -> Part:
    """Read one simple VOD part, resolving a single unambiguous master variant."""
    url = track.uri
    visited = set()
    for _ in range(4):
        if url in visited:
            raise Unsupported('manifest_loop')
        visited.add(url)
        document, final_url = fetch_manifest(url)
        lines = _lines(document)
        if not any(line.startswith('#EXT-X-STREAM-INF:') for line in lines):
            return parse_media(lines, final_url)
        unsafe = ('#EXT-X-MEDIA:', '#EXT-X-I-FRAME-STREAM-INF:',
                  '#EXT-X-SESSION-KEY:', '#EXT-X-DEFINE:', '#EXT-X-START:',
                  '#EXT-X-CONTENT-STEERING:')
        if any(line.startswith(unsafe) for line in lines):
            raise Unsupported('complex_master')
        variants = []
        for i, line in enumerate(lines):
            if line.startswith('#EXT-X-STREAM-INF:'):
                if i + 1 == len(lines) or lines[i+1].startswith('#'):
                    raise Unsupported('invalid_variant')
                variants.append(lines[i+1])
            elif line.startswith('#EXT-X-') and not line.startswith((
                    '#EXT-X-VERSION:', '#EXT-X-INDEPENDENT-SEGMENTS')):
                raise Unsupported('unsupported_master_tag')
        if len(variants) != 1:
            raise Unsupported('multiple_variants')
        url = safe_remote_url(urljoin(final_url, variants[0]))
    raise Unsupported('manifest_depth')


def parse_media(lines: list[str], base_url: str) -> Part:
    segments: list[Segment] = []
    version = 3
    target_duration = None
    sequence = 0
    pending_duration = None
    pending_extinf = None
    current_key = None
    discontinuity = False
    seen_end = False
    singleton_tags = set()
    for line in lines[1:]:
        if seen_end:
            if line.startswith('#') and not line.startswith('#EXT'):
                continue
            raise Unsupported('content_after_endlist')
        if line.startswith('#EXT-X-VERSION:'):
            if 'version' in singleton_tags or segments:
                raise Unsupported('duplicate_or_late_version')
            singleton_tags.add('version')
            version = max(3, _number(line.split(':', 1)[1], 20))
        elif line.startswith('#EXT-X-TARGETDURATION:'):
            if 'target' in singleton_tags or segments:
                raise Unsupported('duplicate_or_late_target')
            singleton_tags.add('target')
            target_duration = _number(line.split(':', 1)[1], 3600)
            if target_duration == 0:
                raise Unsupported('invalid_target_duration')
        elif line.startswith('#EXT-X-MEDIA-SEQUENCE:'):
            if 'sequence' in singleton_tags or segments or pending_extinf is not None:
                raise Unsupported('duplicate_or_late_sequence')
            singleton_tags.add('sequence')
            sequence = _number(line.split(':', 1)[1], 2**64-1)
        elif line.startswith('#EXT-X-DISCONTINUITY-SEQUENCE:'):
            # A closed standalone VOD may have a nonzero discontinuity base;
            # keep the discontinuity locations, not the old rendition number.
            if 'disc_sequence' in singleton_tags or segments:
                raise Unsupported('duplicate_or_late_discontinuity_sequence')
            singleton_tags.add('disc_sequence')
            _number(line.split(':', 1)[1], 2**64-1)
        elif line.startswith('#EXT-X-PLAYLIST-TYPE:'):
            if line != '#EXT-X-PLAYLIST-TYPE:VOD':
                raise Unsupported('not_vod')
        elif line.startswith('#EXT-X-KEY:'):
            if pending_extinf is not None:
                raise Unsupported('key_after_extinf')
            current_key = _key(line.split(':', 1)[1], base_url)
            if current_key is not None and (current_key.keyformat is not None or current_key.method == 'SAMPLE-AES'):
                version = max(5, version)
        elif line == '#EXT-X-DISCONTINUITY':
            if pending_extinf is not None:
                raise Unsupported('discontinuity_after_extinf')
            discontinuity = True
        elif line.startswith('#EXTINF:'):
            if pending_extinf is not None:
                raise Unsupported('missing_segment_uri')
            try:
                duration = float(line.split(':', 1)[1].split(',', 1)[0])
            except (ValueError, OverflowError):
                raise Unsupported('invalid_segment_duration') from None
            if not math.isfinite(duration) or not 0 < duration <= 3600:
                raise Unsupported('invalid_segment_duration')
            pending_duration = duration
            pending_extinf = line
        elif line == '#EXT-X-ENDLIST':
            if pending_extinf is not None:
                raise Unsupported('missing_segment_uri')
            seen_end = True
        elif line.startswith('#EXT-X-ALLOW-CACHE:') or line == '#EXT-X-INDEPENDENT-SEGMENTS':
            # Do not advertise independence unless proven across the new book.
            continue
        elif line.startswith('#EXT'):
            # BYTERANGE, MAP, START, DATERANGE, GAP, LL-HLS, alternate key
            # formats and all unfamiliar features are deliberately not flattened.
            tag = line.split(':', 1)[0]
            safe_tag = re.sub('[^A-Z0-9_-]', '', tag.lstrip('#'))[:48]
            raise Unsupported('unsupported_tag_' + safe_tag.lower())
        elif line.startswith('#'):
            continue
        else:
            if pending_extinf is None or pending_duration is None:
                raise Unsupported('segment_without_extinf')
            uri = urljoin(base_url, line)
            if len(uri) > 8192 or '"' in uri or '\n' in uri or '\r' in uri:
                raise Unsupported('invalid_segment_uri')
            if sequence + len(segments) >= 2**64:
                raise Unsupported('sequence_overflow')
            segments.append(Segment(pending_extinf, pending_duration, uri,
                                    sequence + len(segments), current_key, discontinuity))
            if len(segments) > MAX_BOOK_SEGMENTS:
                raise Unsupported('segment_limit')
            pending_extinf = pending_duration = None
            discontinuity = False
    if not seen_end or not segments or not target_duration:
        raise Unsupported('incomplete_vod')
    if any(math.floor(s.duration + 0.5) > target_duration for s in segments):
        raise Unsupported('target_duration_mismatch')
    return Part(tuple(segments), version, target_duration,
                math.fsum(s.duration for s in segments))


def compose(backend, tracks: tuple[TrackPart, ...]) -> BookPlan:
    if not 2 <= len(tracks) <= 256:
        raise Unsupported('not_multiple_parts')
    if [track.index for track in tracks] != list(range(1, len(tracks)+1)):
        raise Unsupported('nonsequential_parts')
    body: list[str] = []
    output_seq = 0
    prev_key = None
    chapters: list[TrackPart] = []
    start = 0.0
    version = 3
    target = 0
    total_bytes = 0
    # read_part_playlists provides isolated provider sessions and bounded batches.
    parts = backend.read_part_playlists(tracks, read_part)
    try:
        for track, part in zip(tracks, parts, strict=True):
            version = max(version, part.version)
            target = max(target, part.target_duration)
            for index, seg in enumerate(part.segments):
                if output_seq >= MAX_BOOK_SEGMENTS:
                    raise Unsupported('book_segment_limit')
                if (index == 0 and output_seq > 0) or seg.discontinuity:
                    body.append('#EXT-X-DISCONTINUITY')
                    total_bytes += 21
                tag = seg.key.tag(seg.sequence, output_seq) if seg.key else None
                if tag != prev_key or (index == 0 and tag is not None):
                    line = tag or '#EXT-X-KEY:METHOD=NONE'
                    body.append(line)
                    total_bytes += len(line.encode('utf-8'))+1
                    prev_key = tag
                body.extend((seg.extinf, seg.uri))
                total_bytes += len(seg.extinf.encode('utf-8')) + len(seg.uri.encode('utf-8')) + 2
                if total_bytes > MAX_BOOK_BYTES:
                    raise Unsupported('book_manifest_limit')
                output_seq += 1
            chapters.append(TrackPart(track.index, track.uri, round(start, 3),
                                      round(part.duration, 3), track.title))
            start += part.duration
    finally:
        close = getattr(parts, 'close', None)
        if close:
            close()
    if len(chapters) != len(tracks) or start <= 0:
        raise Unsupported('missing_parts')
    header = ['#EXTM3U', f'#EXT-X-VERSION:{version}',
              f'#EXT-X-TARGETDURATION:{target}', '#EXT-X-MEDIA-SEQUENCE:0',
              '#EXT-X-PLAYLIST-TYPE:VOD']
    document = '\n'.join(header + body + ['#EXT-X-ENDLIST', ''])
    size = len(document.encode('utf-8'))
    if size > MAX_BOOK_BYTES:
        raise Unsupported('book_manifest_limit')
    return BookPlan(document, tuple(chapters), output_seq, size)


@dataclass
class _Entry:
    backend: object
    tracks: tuple[TrackPart, ...]
    future: Future
    created: float
    completed: float | None = None


class BookPlanCache:
    """NEXTORY_SINGLE_PRESENTATION_V2: one worker, one queued job, short-lived plans."""
    def __init__(self, ttl=PLAN_TTL_SECONDS, wait=PLAY_WAIT_SECONDS):
        self._ttl = ttl
        self._wait = wait
        self._pool = ThreadPoolExecutor(max_workers=1, thread_name_prefix='nextory-book-hls')
        self._lock = threading.Lock()
        self._entries: OrderedDict[int, _Entry] = OrderedDict()
        self._closed = False

    def _prune_locked(self):
        now = time.monotonic()
        for book_id, entry in list(self._entries.items()):
            if entry.future.done():
                if entry.completed is None:
                    entry.completed = now
                if now - entry.completed >= self._ttl:
                    self._entries.pop(book_id, None)

    def _work(self, backend, book_id, tracks):
        ref = book_ref(book_id)
        started = time.perf_counter()
        try:
            plan = compose(backend, tracks)
        except Unsupported as exc:
            LOG.info('POC_HLS_BOOK stage=prepare status=fallback book=%s reason=%s', ref, str(exc))
            return None, str(exc)
        except Exception as exc:
            LOG.warning('POC_HLS_BOOK stage=prepare status=fallback book=%s reason=provider_%s', ref, type(exc).__name__)
            return None, 'provider_error'
        LOG.info('POC_HLS_BOOK stage=prepare status=ready book=%s chapters=%d segments=%d bytes=%d elapsed_ms=%d',
                 ref, len(plan.chapters), plan.segment_count, plan.bytes,
                 int((time.perf_counter()-started)*1000))
        return plan, 'ready'

    def _done(self, book_id, entry):
        with self._lock:
            if self._entries.get(book_id) is entry:
                entry.completed = time.monotonic()

    def schedule(self, backend, book_id, tracks):
        if len(tracks) < 2 or not callable(getattr(backend, 'read_part_playlists', None)):
            return 'not_applicable'
        with self._lock:
            if self._closed:
                return 'closed'
            self._prune_locked()
            existing = self._entries.get(book_id)
            if existing and existing.backend is backend and _signature(existing.tracks) == _signature(tracks):
                self._entries.move_to_end(book_id)
                return 'cached' if existing.future.done() else 'inflight'
            # A changed signed URL must never reuse an earlier plan, and we do
            # not drop a running job just to schedule a different generation.
            if existing and not existing.future.done():
                return 'generation_pending'
            active = sum(not e.future.done() for e in self._entries.values())
            if active >= MAX_PENDING_PLANS:
                LOG.info('POC_HLS_BOOK stage=prepare status=capacity book=%s', book_ref(book_id))
                return 'capacity'
            self._entries.pop(book_id, None)
            while len(self._entries) >= MAX_PLANS:
                victim = next((key for key, val in self._entries.items() if val.future.done()), None)
                if victim is None:
                    return 'capacity'
                self._entries.pop(victim)
            future = self._pool.submit(self._work, backend, book_id, tracks)
            entry = _Entry(backend, tracks, future, time.monotonic())
            self._entries[book_id] = entry
        future.add_done_callback(lambda _: self._done(book_id, entry))
        LOG.info('POC_HLS_BOOK stage=prepare status=scheduled book=%s chapters=%d queued=%d',
                 book_ref(book_id), len(tracks), int(active > 0))
        return 'scheduled'

    def _future_for(self, backend, book_id, tracks):
        state = self.schedule(backend, book_id, tracks)
        with self._lock:
            self._prune_locked()
            entry = self._entries.get(book_id)
            if entry is None or entry.backend is not backend or _signature(entry.tracks) != _signature(tracks):
                return None, state
            return entry.future, state

    def prepare(self, backend, book_id, tracks):
        """Background prewarm: produce exact chapters and playlist in one pass."""
        future, state = self._future_for(backend, book_id, tracks)
        if future is None:
            return None, state
        try:
            return future.result(timeout=PREPARE_WAIT_SECONDS)
        except FutureTimeout:
            return None, 'plan_pending'
        except Exception:
            return None, 'plan_failed'

    async def obtain(self, backend, book_id, tracks, timeout=None):
        future, state = self._future_for(backend, book_id, tracks)
        if future is None:
            return None, state
        # A ready future needs no waiting budget. Shield pending work from a
        # cancelled client so opening the details again can reuse it.
        if future.done():
            try:
                return future.result()
            except Exception:
                return None, 'plan_failed'
        budget = self._wait if timeout is None else min(self._wait, max(0., timeout))
        try:
            return await asyncio.wait_for(asyncio.shield(asyncio.wrap_future(future)), budget)
        except asyncio.TimeoutError:
            return None, 'plan_pending'
        except Exception:
            return None, 'plan_failed'

    def shutdown(self):
        with self._lock:
            self._closed = True
        self._pool.shutdown(wait=False, cancel_futures=True)
