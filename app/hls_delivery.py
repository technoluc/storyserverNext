"""HLS_FIRSTPLAY_SERVER_V1: bounded, verified HLS passthrough.

The provider's bytes are never modified, decrypted, transcoded or written to
persistent storage. Small audio segments and AES keys are read completely
before returning HTTP headers, so short/truncated upstream responses fail with
502 instead of a false 200. Large content falls back to streaming.
"""
from __future__ import annotations

import logging
import os
import re
import threading
import time

from fastapi import HTTPException
from fastapi.responses import Response, StreamingResponse

LOG = logging.getLogger('uvicorn.error')
MAX_BUFFERED_SEGMENT_BYTES = 2 * 1024 * 1024
MAX_BUFFERED_KEY_BYTES = 64
CHUNK_BYTES = 64 * 1024
_RANGE = re.compile(r'bytes=(\d*)-(\d*)\Z')
_BUFFER_SLOTS = threading.BoundedSemaphore(8)


def _content_type(upstream, kind: str, filename: str) -> str:
    value = upstream.headers.get('Content-Type', '').split(';', 1)[0].strip().lower()
    if kind == 'key':
        return 'application/octet-stream'
    if value and value not in {'application/octet-stream', 'binary/octet-stream'}:
        return value
    extension = filename.rsplit('.', 1)[-1].lower() if '.' in filename else ''
    return {
        'ts': 'video/mp2t', 'aac': 'audio/aac',
        'mp3': 'audio/mpeg', 'm4s': 'video/iso.segment',
        'mp4': 'audio/mp4',
    }.get(extension, 'application/octet-stream')


def _header_int(value: str | None) -> int | None:
    try:
        if value is not None and value.isdecimal():
            return int(value)
    except (TypeError, ValueError):
        pass
    return None


def _body_range(value: str | None, total: int):
    """Single HTTP byte-range only. None means leave provider response as-is."""
    if not value:
        return None
    match = _RANGE.fullmatch(value.strip())
    if not match or not (match.group(1) or match.group(2)) or total < 1:
        return None
    if match.group(1):
        start = int(match.group(1))
        end = int(match.group(2)) if match.group(2) else total - 1
        if end < start:
            return None
    else:
        suffix = int(match.group(2))
        if suffix == 0:
            return None
        start, end = max(0, total - suffix), total - 1
    if start >= total:
        return (None, None)
    return (start, min(end, total - 1))


def _stream_response(upstream, headers: dict, media_type: str, status: int,
                     started: float, prefix: tuple[bytes, ...] = (), iterator=None,
                     kind: str = 'segment'):
    """Fall back without losing prefetched bytes for oversized segment data."""
    if iterator is None:
        iterator = upstream.iter_content(chunk_size=CHUNK_BYTES)
    # requests.iter_content may transparently decompress; its upstream
    # Content-Length then no longer describes the yielded body.
    if upstream.headers.get('Content-Encoding', 'identity').lower() not in ('identity', ''):
        headers.pop('Content-Length', None)
    bytes_sent = 0

    def chunks():
        nonlocal bytes_sent
        finished = False
        try:
            for payload in prefix:
                if payload:
                    bytes_sent += len(payload)
                    yield payload
            for payload in iterator:
                if payload:
                    bytes_sent += len(payload)
                    yield payload
            finished = True
        finally:
            upstream.close()
            LOG.info('POC_HLS_DELIVERY kind=%s mode=stream status=%d complete=%d bytes=%d elapsed_ms=%d',
                     kind, status, int(finished), bytes_sent,
                     int((time.perf_counter() - started) * 1000))

    return StreamingResponse(chunks(), status_code=status, media_type=media_type,
                             headers=headers)


def build_resource_response(upstream, kind: str, filename: str,
                            method: str, client_range: str | None):
    """Runs in a FastAPI threadpool; does not block the asyncio event loop."""
    started = time.perf_counter()
    status = upstream.status_code
    if status not in (200, 206):
        upstream.close()
        raise HTTPException(status_code=502, detail='Nextory HLS media unavailable')
    media_type = _content_type(upstream, kind, filename)
    headers = {'Cache-Control': 'no-store'}
    for key in ('Content-Length', 'Content-Range', 'ETag', 'Last-Modified'):
        value = upstream.headers.get(key)
        if value:
            headers[key] = value
    # Advertising byte-range support when it is genuinely available (or when
    # we can serve local byte ranges from a complete small segment).
    if upstream.headers.get('Accept-Ranges', '').lower() == 'bytes' or status == 206:
        headers['Accept-Ranges'] = 'bytes'

    if method == 'HEAD':
        upstream.close()
        LOG.info('POC_HLS_DELIVERY kind=%s mode=head status=%d elapsed_ms=%d',
                 kind, status, int((time.perf_counter() - started) * 1000))
        return Response(content=b'', status_code=status, media_type=media_type, headers=headers)

    buffering = kind == 'key' or os.environ.get('NEXTORY_HLS_BUFFER_SMALL', '1') == '1'
    if not buffering:
        return _stream_response(upstream, headers, media_type, status, started, kind=kind)

    slot = False
    if kind == 'segment':
        slot = _BUFFER_SLOTS.acquire(blocking=False)
        if not slot:
            return _stream_response(upstream, headers, media_type, status, started,
                                    kind=kind)
    try:
        return _build_buffered_response(upstream, kind, media_type, status,
                                        headers, client_range, started)
    finally:
        if slot:
            _BUFFER_SLOTS.release()


def _build_buffered_response(upstream, kind, media_type, status, headers,
                             client_range, started):
    limit = MAX_BUFFERED_KEY_BYTES if kind == 'key' else MAX_BUFFERED_SEGMENT_BYTES
    declared_length = _header_int(upstream.headers.get('Content-Length'))
    if declared_length is not None and declared_length > limit:
        return _stream_response(upstream, headers, media_type, status, started, kind=kind)

    iterator = upstream.iter_content(chunk_size=CHUNK_BYTES)
    chunks = []
    total = 0
    try:
        for chunk in iterator:
            if not chunk:
                continue
            chunks.append(chunk)
            total += len(chunk)
            if total > limit:
                return _stream_response(upstream, headers, media_type, status, started,
                                        tuple(chunks), iterator, kind=kind)
        upstream.close()
    except Exception as exc:
        upstream.close()
        if isinstance(exc, HTTPException):
            raise
        LOG.warning('POC_HLS_DELIVERY kind=%s mode=buffer status=upstream_error error_type=%s',
                    kind, type(exc).__name__)
        raise HTTPException(status_code=502, detail='Incomplete upstream HLS media') from exc

    # requests.Response.iter_content may decode Content-Encoding. Do not keep
    # provider's encoded byte count as the downstream Content-Length.
    encoding = upstream.headers.get('Content-Encoding', 'identity').lower()
    if declared_length is not None and encoding in ('identity', '') and total != declared_length:
        LOG.warning('POC_HLS_DELIVERY kind=%s mode=buffer status=truncated declared=%d actual=%d',
                    kind, declared_length, total)
        raise HTTPException(status_code=502, detail='Incomplete upstream HLS media')

    if kind == 'key' and total != 16:
        # Some HLS methods use non-raw key resources. Preserve provider bytes.
        LOG.info('POC_HLS_DELIVERY kind=key mode=buffer key_bytes=%d', total)

    payload = b''.join(chunks)
    # Some CDNs ignore a client Range request and answer 200. For a complete
    # small response, honor a standard single range locally, to provide a
    # deterministic answer to AVFoundation's byte-range probes.
    if status == 200 and client_range:
        selected = _body_range(client_range, len(payload))
        if selected == (None, None):
            LOG.info('POC_HLS_DELIVERY kind=%s mode=buffer status=416 bytes=%d', kind, total)
            return Response(content=b'', status_code=416,
                            headers={'Content-Range': f'bytes */{total}',
                                     'Cache-Control': 'no-store'})
        if selected is not None:
            begin, end = selected
            payload = payload[begin:end + 1]
            status = 206
            headers['Content-Range'] = f'bytes {begin}-{end}/{total}'
            headers['Accept-Ranges'] = 'bytes'
    headers['Content-Length'] = str(len(payload))
    if status == 200:
        headers.pop('Content-Range', None)
    LOG.info('POC_HLS_DELIVERY kind=%s mode=buffer status=%d complete=1 bytes=%d elapsed_ms=%d range=%d',
             kind, status, len(payload), int((time.perf_counter() - started) * 1000),
             int(bool(client_range)))
    return Response(content=payload, status_code=status,
                    media_type=media_type, headers=headers)
