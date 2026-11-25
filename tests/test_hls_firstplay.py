"""HLS_FIRSTPLAY_SERVER_V1 offline protocol tests, no provider connections."""
import os
import sys
from pathlib import Path

os.environ.setdefault('TEST_PASSWORD', 'local-test-password-123456')
os.environ.setdefault('TEST_AUTH_SECRET', 'test-only-secret-0123456789abcdefghijklmnopqrstuvwxyz')
os.environ['CATALOG_AUTOSYNC'] = '0'
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import pytest
from fastapi import HTTPException
from fastapi.responses import Response, StreamingResponse
from fastapi.testclient import TestClient
from fastapi import FastAPI

from app.hls_delivery import build_resource_response
from app.nextory import NextoryBackend, NextoryError


class Upstream:
    def __init__(self, payload: bytes, status=200, headers=None, *, chunks=None, url='https://cdn.example.org/audio.aac'):
        self.payload = payload
        self.status_code = status
        self.headers = headers or {'Content-Type': 'audio/aac', 'Content-Length': str(len(payload))}
        self.chunks = chunks
        self.url = url
        self.closed = False

    def iter_content(self, chunk_size=65536):
        if self.chunks is not None:
            yield from self.chunks
        else:
            for pos in range(0, len(self.payload), chunk_size):
                yield self.payload[pos:pos+chunk_size]

    def close(self):
        self.closed = True


class Raw:
    def __init__(self, data: bytes):
        self.data = data
    def read(self, count, decode_content=True):
        return self.data[:count]


class ManifestUpstream(Upstream):
    def __init__(self, text: bytes, url):
        super().__init__(text, headers={'Content-Length': str(len(text))}, url=url)
        self.raw = Raw(text)


def test_manifest_cache_from_prewarm_reused_by_play(monkeypatch):
    provider = NextoryBackend()
    url = 'https://cdn.example.org/playlist.m3u8?private=fake'
    document = b'#EXTM3U\n#EXTINF:5,\nsegment1.aac\n#EXT-X-ENDLIST\n'
    requests = []

    def fetch(link):
        requests.append(link)
        return ManifestUpstream(document, url)

    monkeypatch.setattr(provider, 'remote_get', fetch)
    first = provider.get_manifest(url)
    second = provider.get_manifest(url)
    assert first == second
    assert len(requests) == 1
    assert provider._manifest_cache_bytes == len(document)


def test_manifest_cache_expires_and_refetches(monkeypatch):
    provider = NextoryBackend()
    url = 'https://cdn.example.org/media.m3u8'
    document = b'#EXTM3U\n#EXTINF:3,\nx.aac\n'
    calls = []
    monkeypatch.setattr(provider, 'remote_get', lambda link: (calls.append(link) or ManifestUpstream(document, url)))
    provider.get_manifest(url)
    data, end_url, size, created = provider._manifest_cache[url]
    provider._manifest_cache[url] = (data, end_url, size, created - 999)
    provider.get_manifest(url)
    assert len(calls) == 2


def test_manifest_cache_bounds_and_no_oversized_cache(monkeypatch):
    import app.nextory as module
    provider = NextoryBackend()
    monkeypatch.setattr(module, 'MAX_MANIFEST_CACHE_ENTRIES', 2)
    for i in range(5):
        provider._manifest_cache_put(f'https://cdn.example.org/{i}', '#EXTM3U', 'https://cdn.example.org/z', 7)
    assert len(provider._manifest_cache) == 2
    assert provider._manifest_cache_bytes == 14
    provider._manifest_cache_put('https://cdn.example.org/massive', '#EXTM3U', 'url', 3*1024*1024)
    assert len(provider._manifest_cache) == 2


def test_buffered_segment_success_and_matching_length():
    source = Upstream(b'abc123')
    resp = build_resource_response(source, 'segment', 'stream.aac', 'GET', None)
    assert isinstance(resp, Response)
    assert resp.status_code == 200
    assert resp.body == b'abc123'
    assert resp.headers['content-length'] == '6'
    assert resp.headers['content-type'].startswith('audio/aac')
    assert source.closed


def test_buffered_valid_206_range_preserved():
    source = Upstream(b'abcd', status=206, headers={
        'Content-Length': '4', 'Content-Range': 'bytes 0-3/100', 'Content-Type': 'audio/aac'
    })
    resp = build_resource_response(source, 'segment', 'stream.aac', 'GET', 'bytes=0-3')
    assert resp.status_code == 206
    assert resp.body == b'abcd'
    assert resp.headers['content-range'] == 'bytes 0-3/100'
    assert resp.headers['accept-ranges'] == 'bytes'


def test_provider_ignores_range_served_as_206_locally():
    source = Upstream(b'ABCDEFG')
    resp = build_resource_response(source, 'segment', 'stream.aac', 'GET', 'bytes=2-4')
    assert resp.status_code == 206
    assert resp.body == b'CDE'
    assert resp.headers['content-range'] == 'bytes 2-4/7'
    assert resp.headers['content-length'] == '3'


def test_invalid_range_returns_416_without_exposing_source_url():
    source = Upstream(b'abcdef')
    resp = build_resource_response(source, 'segment', 'stream.aac', 'GET', 'bytes=99-100')
    assert resp.status_code == 416
    assert resp.headers['content-range'] == 'bytes */6'


def test_truncated_body_fails_before_false_200():
    source = Upstream(b'12345', headers={'Content-Length':'6', 'Content-Type':'audio/aac'})
    with pytest.raises(HTTPException) as ex:
        build_resource_response(source, 'segment', 'stream.aac', 'GET', None)
    assert ex.value.status_code == 502
    assert source.closed


def test_broken_upstream_fails_before_headers():
    source = Upstream(b'', chunks=[b'ab'])
    def broken_iter(chunk_size=65536):
        yield b'ab'
        raise OSError('synthetic origin disconnected')
    source.iter_content = broken_iter
    with pytest.raises(HTTPException) as ex:
        build_resource_response(source, 'segment', 'stream.aac', 'GET', None)
    assert ex.value.status_code == 502
    assert source.closed


def test_encrypted_key_passthrough_16_bytes_no_decryption():
    raw = b'1234567890abcdef'
    source = Upstream(raw, headers={'Content-Length':'16','Content-Type':'application/octet-stream'})
    resp = build_resource_response(source, 'key', 'stream.bin', 'GET', None)
    assert resp.body == raw
    assert source.closed


def test_head_does_not_fetch_response_body():
    source = Upstream(b'ABC')
    def fail(*args, **kwargs):
        raise AssertionError('HEAD must not download the segment')
    source.iter_content = fail
    resp = build_resource_response(source, 'segment', 'stream.aac', 'HEAD', None)
    assert resp.status_code == 200
    assert resp.body == b''
    assert resp.headers['content-length'] == '3'
    assert source.closed


def test_large_segment_preserves_streaming_fallback():
    raw = b'Z' * (2*1024*1024+11)
    source = Upstream(raw)
    app = FastAPI()
    @app.get('/sample')
    def sample():
        return build_resource_response(source, 'segment', 'stream.aac', 'GET', None)
    response = TestClient(app).get('/sample')
    assert response.status_code == 200
    assert response.content == raw
    assert source.closed


def test_incomplete_provider_status_fails_closed():
    source = Upstream(b'auth failure', status=403)
    with pytest.raises(HTTPException) as ex:
        build_resource_response(source, 'segment', 'stream.aac', 'GET', None)
    assert ex.value.status_code == 502
    assert source.closed


def test_parallel_buffer_budget_falls_back_to_stream(monkeypatch):
    import app.hls_delivery as module
    class Busy:
        def acquire(self, blocking=False):
            return False
        def release(self):
            raise AssertionError('No slot acquired, so no release allowed')
    monkeypatch.setattr(module, '_BUFFER_SLOTS', Busy())
    source = Upstream(b'abc')
    response = build_resource_response(source, 'segment', 'stream.aac', 'GET', None)
    assert isinstance(response, StreamingResponse)
    assert not source.closed  # Closed only after streaming finishes.
    from fastapi import FastAPI
    app = FastAPI()
    @app.get('/stream')
    def stream():
        return response
    assert TestClient(app).get('/stream').content == b'abc'
    assert source.closed


def test_parallel_manifest_lookups_do_not_hold_network_lock(monkeypatch):
    from concurrent.futures import ThreadPoolExecutor
    import threading
    backend = NextoryBackend()
    barrier = threading.Barrier(4)
    document = b'#EXTM3U\n#EXTINF:3,\na.aac\n'
    def fetch(url):
        # Deadlocks if the shared cache lock is held over remote_get().
        barrier.wait(timeout=2)
        return ManifestUpstream(document, url)
    monkeypatch.setattr(backend, 'remote_get', fetch)
    urls = [f'https://cdn.example.org/media-{i}.m3u8' for i in range(4)]
    with ThreadPoolExecutor(max_workers=4) as pool:
        results = list(pool.map(backend.get_manifest, urls))
    assert len(results) == 4
    assert all(result[0].startswith('#EXTM3U') for result in results)
