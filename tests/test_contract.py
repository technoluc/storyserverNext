"""Offline contract + HLS passthrough tests. No fabricated or copyrighted audio."""

import json
import os
import sys
from pathlib import Path
from urllib.parse import urlparse

import pytest
from fastapi.testclient import TestClient

os.environ.setdefault("TEST_PASSWORD", "local-test-password-123456")
os.environ.setdefault("TEST_AUTH_SECRET", "test-only-secret-0123456789abcdefghijklmnopqrstuvwxyz")
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app import main
from app.hls_proxy import registry, rewrite_playlist
from app.nextory import BookInfo, NextoryError

BOOK_ID = main.BOOK_ID
LIBRARY_ID = main.LIBRARY_ID
client = TestClient(main.app)


@pytest.fixture(autouse=True)
def reset_registry():
    registry._sessions.clear()
    main.DURATION = 0.0
    main.LIVE_BOOK = None
    yield
    registry._sessions.clear()


def auth():
    response = client.post("/login", json={"username": "test", "password": "local-test-password-123456"})
    assert response.status_code == 200
    token = response.json()["user"]["accessToken"]
    return {"Authorization": "Bearer " + token}


def make_book():
    return BookInfo(
        title=main.TITLE,
        authors=["Author from provider metadata"],
        narrators=["Narrator from provider metadata"],
        description="Description from provider metadata",
        language="nl",
        cover_url="https://cdn.example.org/book.jpg",
        parts=[{"start_at": 0, "uri": "https://cdn.example.org/real-part/master.m3u8?auth=provider-signed-url"}],
    )


def stub_remote(monkeypatch):
    import app.hls_proxy as hp
    monkeypatch.setattr(hp, "safe_remote_url", lambda u: u)
    monkeypatch.setattr(main.nextory, "get_book", make_book)
    monkeypatch.setattr(main.nextory, "first_part_duration", lambda u: 123.5)
    monkeypatch.setattr(main.nextory, "get_manifest", lambda u: (
        "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-KEY:METHOD=AES-128,URI=\"/audio/key?secret=urltoken\"\n#EXTINF:10.0,\nsegment0.aac?secret=urltoken\n#EXTINF:10.0,\nsegment1.aac?secret=urltoken\n#EXT-X-ENDLIST\n",
        "https://cdn.example.org/real-part/media.m3u8?secret=manifest-token",
    ))



def test_status_and_login():
    assert client.get("/ping").json() == {"success": True}
    assert client.get("/status").json()["serverVersion"] == "2.25.0"
    assert client.post("/login", json={"username": "test", "password": "wrong"}).status_code == 401
    assert client.get("/api/libraries").status_code == 401
    h = auth()
    assert client.post("/api/authorize", headers=h).status_code == 200
    assert client.get("/api/libraries", headers=h).json()["libraries"][0]["id"] == LIBRARY_ID


def test_virtual_book_unmodified_id():
    h = auth()
    item = client.get(f"/api/items/{BOOK_ID}?expanded=1", headers=h).json()
    assert item["media"]["metadata"]["title"] == main.TITLE
    assert item["media"]["numTracks"] == 1
    assert item["isInvalid"] is False
    assert len(item["media"]["tracks"]) == 1
    assert item["media"]["tracks"][0]["metadata"]["ext"] == ".m3u8"
    assert client.post(f"/api/items/{BOOK_ID}/play").status_code == 401


def test_playback_session_and_directplay_url(monkeypatch):
    stub_remote(monkeypatch)
    h = auth()
    r = client.post(f"/api/items/{BOOK_ID}/play", headers=h, json={"mediaPlayer": "AVPlayer"})
    assert r.status_code == 200, r.text
    sess = r.json()
    assert sess["id"] != BOOK_ID and len(sess["id"]) == 36
    assert sess["libraryItemId"] == BOOK_ID
    assert sess["bookId"] == main.MEDIA_ID
    assert sess["playMethod"] == 0
    assert sess["duration"] == 123.5
    assert sess["timeListening"] == 0.0
    assert sess["currentTime"] == 0.0
    assert sess["audioTracks"][0]["duration"] == sess["duration"]
    assert sess["audioTracks"][0]["mimeType"] == "application/vnd.apple.mpegurl"
    path = f"/public/session/{sess['id']}/track/1"
    redirect = client.get(path, follow_redirects=False)
    assert redirect.status_code == 302
    assert redirect.headers["location"].endswith(".m3u8")
    assert "/hls/" in redirect.headers["location"]
    assert client.get(f"/public/session/{sess['id']}/track/2").status_code == 404


def test_manifest_rewriting_hides_remote_keys_and_media_urls(monkeypatch):
    stub_remote(monkeypatch)
    h = auth()
    play_resp = client.post(f"/api/items/{BOOK_ID}/play", headers=h)
    assert play_resp.status_code == 200, play_resp.text
    session = play_resp.json()
    r = client.get(f"/public/session/{session['id']}/track/1")
    assert r.status_code == 200, r.text
    assert r.headers["content-type"].startswith("application/vnd.apple.mpegurl")
    assert r.text.startswith("#EXTM3U")
    assert "https://cdn.example.org" not in r.text
    assert "urltoken" not in r.text
    assert "METHOD=AES-128" in r.text
    assert 'URI="/hls/' in r.text
    assert r.text.count("/hls/") == 3


def test_sync_close_and_expiry(monkeypatch):
    stub_remote(monkeypatch)
    h = auth()
    play_resp = client.post(f"/api/items/{BOOK_ID}/play", headers=h)
    assert play_resp.status_code == 200, play_resp.text
    sess = play_resp.json()
    sid = sess["id"]
    assert client.post(f"/api/session/{sid}/sync", headers=h, json={"currentTime": 43.75, "timeListened": 12.0}).status_code == 200
    assert registry.get(sid).current_time == 43.75
    assert client.post(f"/api/session/{sid}/close", headers=h, json={}).status_code == 200
    assert client.get(f"/public/session/{sid}/track/1").status_code == 404


def test_rewrite_master_variant_and_media_tag(monkeypatch):
    import app.hls_proxy as hp
    monkeypatch.setattr(hp, "safe_remote_url", lambda u: u)
    session = registry.create(duration=35, title=main.TITLE,
                              source_uri="https://cdn.example.org/master.m3u8", user_id=main.USER_ID)
    original = '#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",URI="alternative.m3u8"\n#EXT-X-STREAM-INF:BANDWIDTH=128000\nprimary.m3u8\n'
    transformed = rewrite_playlist(original, "https://cdn.example.org/master.m3u8", session)
    assert "alternative.m3u8" not in transformed
    assert "primary.m3u8" not in transformed
    assert transformed.count(".m3u8") == 2
    assert len(session.resource_map) == 3  # root + audio rendition + variant


def test_manifest_rejects_unknown_format(monkeypatch):
    import app.hls_proxy as hp
    monkeypatch.setattr(hp, "safe_remote_url", lambda u: u)
    session = registry.create(duration=35, title=main.TITLE,
                              source_uri="https://cdn.example.org/master.m3u8", user_id=main.USER_ID)
    with pytest.raises(NextoryError):
        rewrite_playlist("#NOTHLS\nsecret", "https://cdn.example.org/master.m3u8", session)


def test_websocket_auth():
    h = auth()
    with client.websocket_connect("/socket.io/?EIO=4&transport=websocket",
                                  headers={"origin": "capacitor://localhost"}) as ws:
        assert ws.receive_text().startswith("0")
        ws.send_text("40")
        assert ws.receive_text().startswith("40")
        ws.send_text('42' + json.dumps(["auth", h["Authorization"].split()[1]]))
        assert json.loads(ws.receive_text()[2:])[0] == "init"
        ws.send_text("41")


def test_encrypted_segment_range_is_passthrough(monkeypatch):
    """Only the HTTP transport is stubbed; no playable test audio is generated."""
    stub_remote(monkeypatch)
    h = auth()
    session = client.post(f"/api/items/{BOOK_ID}/play", headers=h).json()
    sid = session["id"]
    playlist = client.get(f"/public/session/{sid}/track/1").text
    segment_path = next(line for line in playlist.splitlines() if line.startswith("/hls/") and line.endswith(".aac"))
    observed = {}

    class NonAudioResponse:
        status_code = 206
        headers = {"Content-Type": "audio/aac", "Content-Range": "bytes 0-3/100", "Content-Length": "4"}
        def iter_content(self, chunk_size=65536):
            yield bytes((0, 1, 2, 3))  # Not actual or synthesized audio.
        def close(self):
            observed["closed"] = True

    def remote_get(url, byte_range=None):
        observed["range"] = byte_range
        observed["url"] = url
        return NonAudioResponse()

    monkeypatch.setattr(main.nextory, "remote_get", remote_get)
    response = client.get(segment_path, headers={"Range": "bytes=0-3"})
    assert response.status_code == 206
    assert response.content == bytes((0, 1, 2, 3))
    assert response.headers["content-range"] == "bytes 0-3/100"
    assert observed["range"] == "bytes=0-3"
    assert observed["closed"] is True
    assert "secret=urltoken" in observed["url"]  # private proxy, not client response
    assert "urltoken" not in segment_path


def test_hls_expires_and_play_without_config_returns_safe_error(monkeypatch):
    stub_remote(monkeypatch)
    h = auth()
    sess = client.post(f"/api/items/{BOOK_ID}/play", headers=h).json()
    sid = sess["id"]
    registry.get(sid).created -= 3700
    assert client.get(f"/public/session/{sid}/track/1").status_code == 404
    monkeypatch.setattr(main.nextory, "get_book", lambda: (_ for _ in ()).throw(NextoryError("Config not mounted")))
    result = client.post(f"/api/items/{BOOK_ID}/play", headers=h)
    assert result.status_code == 503
    assert result.json()["detail"] == "Config not mounted"
