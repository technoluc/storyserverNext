"""Nextory 7207495: real HLS-on-demand / Audiobookshelf iOS playback POC.

No local or generated audio. Only the first real audio package part is available
until the multi-part sync/seek experiment has succeeded.
"""

import asyncio
import base64
import hashlib
import hmac
import json
import os
import secrets
import time
from collections import defaultdict
from uuid import NAMESPACE_URL, uuid5

from fastapi import Depends, FastAPI, HTTPException, Request, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import HTMLResponse, RedirectResponse, Response, StreamingResponse
from fastapi.concurrency import run_in_threadpool
from datetime import datetime, timezone
import logging

from .nextory import CONFIG_PATH, NextoryError, nextory
from .hls_proxy import registry, rewrite_playlist
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer


# Report a pre-v2.26 server version to use the documented legacy bearer-token
# login flow. The real server still supported the same app API routes then.
COMPAT_VERSION = "2.25.0"
USERNAME = os.environ.get("TEST_USERNAME", "test")
PASSWORD = os.environ.get("TEST_PASSWORD", "")
SECRET = os.environ.get("TEST_AUTH_SECRET", "")
if len(PASSWORD) < 12 or len(SECRET) < 32:
    raise RuntimeError("Set TEST_PASSWORD (12+ chars) and TEST_AUTH_SECRET (32+ chars)")

LIBRARY_ID = str(uuid5(NAMESPACE_URL, "nextory-abs-poc:library"))
FOLDER_ID = str(uuid5(NAMESPACE_URL, "nextory-abs-poc:folder"))
BOOK_ID = "572c4427-e49a-579d-b5bb-0b24729778bf"
MEDIA_ID = str(uuid5(NAMESPACE_URL, "nextory-abs-poc:media:7207495"))
USER_ID = str(uuid5(NAMESPACE_URL, "nextory-abs-poc:user"))
NEXTORY_ID = 7207495
TITLE = "Hier gebeurt nooit iets : De veiligste plek om te wonen is een klein stadje. Toch?"
DURATION = 0.0  # Updated after the first real Nextory HLS media playlist is resolved.
LIVE_BOOK = None
STARTED_MS = 1795170000000

app = FastAPI(title="Nextory Audiobookshelf virtual-item POC", docs_url=None, redoc_url=None)
app.add_middleware(
    CORSMiddleware,
    allow_origins=["capacitor://localhost", "ionic://localhost", "http://localhost", "http://127.0.0.1"],
    allow_methods=["GET", "POST", "PATCH", "OPTIONS"],
    allow_headers=["Authorization", "Content-Type", "X-Return-Tokens"],
)
bearer = HTTPBearer(auto_error=False)
failed_logins = defaultdict(list)


@app.middleware("http")
async def security_headers(request: Request, call_next):
    response = await call_next(request)
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["X-Robots-Tag"] = "noindex, nofollow"
    response.headers["Referrer-Policy"] = "no-referrer"
    if request.url.path.startswith("/api") or request.url.path in {"/login", "/status"}:
        response.headers["Cache-Control"] = "no-store"
    return response


def b64(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode("ascii").rstrip("=")


def make_token(kind: str = "access") -> str:
    # JWT-formatted HMAC-SHA256 bearer token; it is only valid for this POC.
    now = int(time.time())
    head = b64(b'{"alg":"HS256","typ":"JWT"}')
    body = b64(json.dumps({"sub": USER_ID, "iat": now, "exp": now + (86400 if kind == "access" else 14 * 86400), "kind": kind, "jti": secrets.token_hex(8)}, separators=(",", ":")).encode())
    signature = b64(hmac.new(SECRET.encode(), f"{head}.{body}".encode(), hashlib.sha256).digest())
    return f"{head}.{body}.{signature}"


def check_token(token: str, kind: str = "access") -> bool:
    try:
        head, body, signature = token.split(".")
        expected = b64(hmac.new(SECRET.encode(), f"{head}.{body}".encode(), hashlib.sha256).digest())
        if not hmac.compare_digest(expected, signature):
            return False
        header = json.loads(base64.urlsafe_b64decode(head + "=="))
        claims = json.loads(base64.urlsafe_b64decode(body + "=="))
        return (header.get("alg") == "HS256" and claims.get("sub") == USER_ID
                and claims.get("kind", "access") == kind
                and isinstance(claims.get("exp"), int) and claims["exp"] > time.time())
    except (ValueError, TypeError, UnicodeDecodeError, json.JSONDecodeError):
        return False


def authenticated(credentials: HTTPAuthorizationCredentials | None = Depends(bearer)) -> bool:
    if credentials is None or not check_token(credentials.credentials):
        raise HTTPException(status_code=401, detail="Authentication required")
    return True


def user_json(token: str | None = None) -> dict:
    user = {
        "id": USER_ID, "username": USERNAME, "email": None,
        "type": "user", "token": token, "isOldToken": False,
        "mediaProgress": [], "seriesHideFromContinueListening": [], "bookmarks": [],
        "isActive": True, "isLocked": False, "lastSeen": None,
        "createdAt": STARTED_MS, "librariesAccessible": [LIBRARY_ID],
        "itemTagsSelected": [], "hasOpenIDLink": False,
        "permissions": {"accessAllLibraries": True, "download": False, "update": False,
                        "delete": False, "upload": False, "create": False},
    }
    return user


def server_settings() -> dict:
    # Same field names and primitive types as Audiobookshelf
    # ServerSettings.toJSONForBrowser; all values are inert test data.
    return {
        "id": "server-settings", "version": COMPAT_VERSION, "buildNumber": 0,
        "language": "nl-nl", "timeZone": "UTC",
        "scannerFindCovers": False, "scannerCoverProvider": "google",
        "scannerParseSubtitle": False, "scannerPreferMatchedMetadata": False,
        "scannerDisableWatcher": True, "storeCoverWithItem": False,
        "storeMetadataWithItem": False, "metadataFileFormat": "json",
        "rateLimitLoginRequests": 8, "rateLimitLoginWindow": 300000,
        "allowIframe": False, "allowedOrigins": [],
        "backupPath": "/nonexistent", "backupSchedule": False,
        "backupsToKeep": 2, "maxBackupSize": 1,
        "loggerDailyLogsToKeep": 7, "loggerScannerLogsToKeep": 2,
        "homeBookshelfView": 1, "bookshelfView": 1,
        "podcastEpisodeSchedule": "0 * * * *",
        "sortingIgnorePrefix": False, "sortingPrefixes": ["the", "a"],
        "chromecastEnabled": False, "dateFormat": "dd/MM/yyyy", "timeFormat": "HH:mm",
        "logLevel": 2, "authLoginCustomMessage": None,
        "authActiveAuthMethods": ["local"],
        "authOpenIDIssuerURL": None, "authOpenIDAuthorizationURL": None,
        "authOpenIDTokenURL": None, "authOpenIDUserInfoURL": None,
        "authOpenIDJwksURL": None, "authOpenIDLogoutURL": None,
        "authOpenIDTokenSigningAlgorithm": "RS256",
        "authOpenIDButtonText": "Login with OpenID",
        "authOpenIDAutoLaunch": False, "authOpenIDAutoRegister": False,
        "authOpenIDMatchExistingBy": None,
        "authFormData": {"authOpenIDEnabled": False},
    }


def login_payload(token: str) -> dict:
    user = user_json(token)
    user["accessToken"] = token
    return {
        "user": user, "userDefaultLibraryId": LIBRARY_ID,
        "serverSettings": server_settings(), "ereaderDevices": [],
        "Source": "virtual-poc",
    }


def library_json() -> dict:
    return {
        "id": LIBRARY_ID, "name": "Nextory - Virtual POC", "displayOrder": 1,
        "icon": "database", "mediaType": "book", "provider": "google",
        "folders": [{"id": FOLDER_ID, "fullPath": "/virtual/nextory", "libraryId": LIBRARY_ID}],
        "settings": {"coverAspectRatio": 0, "audiobooksOnly": True, "bookshelfView": 0},
        "lastScan": None, "lastScanVersion": None,
        "createdAt": STARTED_MS, "lastUpdate": STARTED_MS,
    }


def metadata_json(expanded: bool) -> dict:
    actual_title = LIVE_BOOK.title if LIVE_BOOK else TITLE
    authors = LIVE_BOOK.authors if LIVE_BOOK else []
    narrators = LIVE_BOOK.narrators if LIVE_BOOK else []
    description = LIVE_BOOK.description if LIVE_BOOK else "Nextory-boek 7207495. Originele audiobron wordt op aanvraag geopend."
    metadata = {
        "title": actual_title, "titleIgnorePrefix": actual_title, "subtitle": None,
        "authorName": ", ".join(authors), "authorNameLF": ", ".join(authors),
        "narratorName": ", ".join(narrators), "seriesName": "",
        "genres": [], "publishedYear": None, "publishedDate": None,
        "publisher": None, "description": description,
        "isbn": None, "asin": None, "language": LIVE_BOOK.language if LIVE_BOOK else "nl",
        "explicit": False, "abridged": False,
    }
    if expanded:
        metadata.update({"authors": [{"id": str(uuid5(NAMESPACE_URL, "nextory-author:" + a)), "name": a} for a in authors],
                         "narrators": narrators, "series": [],
                         "descriptionPlain": metadata["description"]})
    return metadata


def audio_file() -> dict:
    return {
        "ino": "virtual-track-1", "index": 1, "addedAt": STARTED_MS,
        "updatedAt": STARTED_MS, "duration": DURATION, "bitRate": 0,
        "codec": "aac", "channels": 2, "exclude": False,
        "metadata": {
            "filename": "nextory-7207495-part-1.m3u8", "ext": ".m3u8", "size": 0,
            "path": "/virtual/nextory/7207495/nextory-7207495-part-1.m3u8",
            "relPath": "nextory-7207495-part-1.m3u8", "mtimeMs": STARTED_MS,
        },
    }


def item_json(expanded: bool = False) -> dict:
    base_media = {
        "id": MEDIA_ID, "metadata": metadata_json(expanded),
        "coverPath": "/api/items/" + BOOK_ID + "/cover",
        "tags": ["POC"], "numTracks": 1, "numAudioFiles": 1,
        "numChapters": 0, "duration": DURATION, "size": 0,
        "ebookFormat": None,
    }
    if expanded:
        track = audio_file()
        track.update({"title": LIVE_BOOK.title if LIVE_BOOK else TITLE, "startOffset": 0.0,
                      "mimeType": "application/vnd.apple.mpegurl",
                      "contentUrl": "/api/items/" + BOOK_ID + "/file/virtual-track-1"})
        base_media.update({
            "libraryItemId": BOOK_ID,
            "audioFiles": [audio_file()], "chapters": [], "ebookFile": None,
            "tracks": [track],
        })

    obj = {
        "id": BOOK_ID, "ino": "nextory-7207495", "oldLibraryItemId": None,
        "libraryId": LIBRARY_ID, "folderId": FOLDER_ID,
        "path": "/virtual/nextory/7207495", "relPath": "7207495",
        "isFile": False, "mtimeMs": STARTED_MS, "ctimeMs": STARTED_MS,
        "birthtimeMs": STARTED_MS, "addedAt": STARTED_MS,
        "updatedAt": STARTED_MS, "isMissing": False, "isInvalid": False,
        "mediaType": "book", "media": base_media,
        "numFiles": 1, "size": 0,
    }
    if expanded:
        obj.update({"lastScan": None, "scanVersion": None, "libraryFiles": []})
    return obj


def filter_data() -> dict:
    return {"authors": [], "genres": [], "tags": ["POC"],
            "series": [], "narrators": [], "languages": ["nl"], "publishers": [],
            "publishedDecades": [], "bookCount": 1, "authorCount": 0,
            "seriesCount": 0, "podcastCount": 0, "numIssues": 0,
            "loadedAt": int(time.time() * 1000)}


def item_page(page: int, limit: int, minified: bool) -> dict:
    return {"results": [item_json(expanded=not minified)] if page == 0 else [],
            "total": 1, "limit": limit, "page": page, "minified": minified}


@app.get("/", response_class=HTMLResponse)
async def index():
    return HTMLResponse("""<!doctype html><html lang='nl'><meta name='viewport' content='width=device-width,initial-scale=1'>
<title>Nextory Virtual POC</title><body style='font:16px system-ui;max-width:720px;margin:40px auto;padding:15px'>
<h1>Nextory Virtual Audiobookshelf POC</h1><p>Eén echt Nextory-boek (7207495), versleutelde HLS on demand, geen audiokopie.</p>
<p>De officiële Audiobookshelf-app kan verbinding proberen te maken via ditzelfde adres.</p>
<p>Beveilig de server met HTTPS als je buiten het lokale netwerk test.</p><a href='/status'>Serverstatus</a></body></html>""")


@app.get("/health")
@app.get("/healthcheck")
async def health():
    return {"status": "ok", "virtualBook": BOOK_ID, "audioEnabled": CONFIG_PATH.is_file(),
            "mode": "nextory-hls-passthrough-first-part", "configMounted": CONFIG_PATH.is_file()}


@app.get("/ping")
async def ping():
    return {"success": True}


@app.get("/status")
async def status():
    return {"app": "audiobookshelf", "serverVersion": COMPAT_VERSION,
            "isInit": True, "language": "nl-nl", "authMethods": ["local"],
            "authFormData": {"authOpenIDEnabled": False}}


@app.post("/login")
async def login(req: Request):
    ip = req.client.host if req.client else "unknown"
    now = time.monotonic()
    failed_logins[ip] = [x for x in failed_logins[ip] if now - x < 300]
    if len(failed_logins[ip]) >= 8:
        raise HTTPException(status_code=429, detail="Too many login attempts")
    try:
        body = await req.json()
    except (ValueError, json.JSONDecodeError):
        body = {}
    if not isinstance(body, dict):
        body = {}
    provided_name = str(body.get("username") or "")
    provided_pass = str(body.get("password") or "")
    if not (hmac.compare_digest(provided_name, USERNAME) and
            hmac.compare_digest(provided_pass, PASSWORD)):
        failed_logins[ip].append(now)
        raise HTTPException(status_code=401, detail="Invalid credentials")
    failed_logins.pop(ip, None)
    access = make_token()
    payload = login_payload(access)
    payload["user"]["refreshToken"] = make_token("refresh")
    return payload


@app.post("/api/authorize")
async def authorize(req: Request, _: bool = Depends(authenticated)):
    token = req.headers["authorization"].split(" ", 1)[-1]
    return login_payload(token)


@app.get("/api/me")
async def me(req: Request, _: bool = Depends(authenticated)):
    token = req.headers["authorization"].split(" ", 1)[-1]
    return user_json(token)


@app.post("/auth/refresh")
async def refresh(req: Request):
    token = req.headers.get("x-refresh-token", "") or req.cookies.get("refresh_token", "")
    if not token or not check_token(token, "refresh"):
        raise HTTPException(status_code=401, detail="Invalid refresh token")
    result = login_payload(make_token())
    result["user"]["refreshToken"] = make_token("refresh")
    return result


@app.get("/api/me/progress")
@app.get("/api/me/items-in-progress")
async def progress(_: bool = Depends(authenticated)):
    return []


@app.get("/api/libraries")
async def libraries(_: bool = Depends(authenticated)):
    return {"libraries": [library_json()]}


def check_library(library_id: str):
    if library_id != LIBRARY_ID:
        raise HTTPException(status_code=404, detail="Library not found")


@app.get("/api/libraries/{library_id}")
async def library(library_id: str, include: str = "", _: bool = Depends(authenticated)):
    check_library(library_id)
    if "filterdata" in include.split(","):
        return {"library": library_json(), "filterdata": filter_data(),
                "issues": 0, "numUserPlaylists": 0}
    return library_json()


@app.get("/api/libraries/{library_id}/filterdata")
async def library_filters(library_id: str, _: bool = Depends(authenticated)):
    check_library(library_id)
    return filter_data()


@app.get("/api/libraries/{library_id}/personalized")
async def personalized(library_id: str, _: bool = Depends(authenticated)):
    check_library(library_id)
    return [{"id": "recently-added", "label": "Recently Added",
             "labelStringKey": "LabelRecentlyAdded", "type": "book",
             "entities": [item_json()], "total": 1}]


@app.get("/api/libraries/{library_id}/items")
async def items(library_id: str, page: int = 0, limit: int = 20,
                minified: int = 1, _: bool = Depends(authenticated)):
    check_library(library_id)
    if page < 0 or limit < 1 or limit > 1000:
        raise HTTPException(status_code=400, detail="Invalid pagination")
    return item_page(page, limit, minified == 1)


@app.get("/api/libraries/{library_id}/search")
async def search(library_id: str, q: str = "", _: bool = Depends(authenticated)):
    check_library(library_id)
    return {"book": [{"libraryItem": item_json(), "matchKey": "title", "matchText": TITLE}]
            if q.casefold() in TITLE.casefold() and q else [],
            "authors": [], "series": [], "tags": []}


@app.get("/api/items/{item_id}")
async def item(item_id: str, _: bool = Depends(authenticated)):
    if item_id != BOOK_ID:
        raise HTTPException(status_code=404, detail="Book not found")
    return item_json(expanded=True)


@app.get("/api/items/{item_id}/cover")
async def cover(item_id: str):
    if item_id != BOOK_ID:
        raise HTTPException(status_code=404, detail="Book not found")
    try:
        jpeg = await run_in_threadpool(nextory.get_cover_jpeg)
    except NextoryError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc
    return Response(jpeg, media_type="image/jpeg", headers={"Cache-Control": "public, max-age=900"})


@app.post("/api/items/{item_id}/play")
async def play(item_id: str, req: Request, _: bool = Depends(authenticated)):
    """Start a direct-play session backed by the real first Nextory HLS part."""
    global DURATION, LIVE_BOOK
    if item_id != BOOK_ID:
        raise HTTPException(status_code=404, detail="Book not found")
    try:
        info = await run_in_threadpool(nextory.get_book)
        first_uri = info.parts[0]["uri"]
        duration = await run_in_threadpool(nextory.first_part_duration, first_uri)
        if duration <= 0:
            raise NextoryError("First Nextory audio part has no duration")
        try:
            payload = await req.json()
        except (ValueError, TypeError):
            payload = {}
        if not isinstance(payload, dict):
            payload = {}
        session = registry.create(duration=duration, title=info.title,
                                  source_uri=first_uri, user_id=USER_ID)
        DURATION, LIVE_BOOK = round(duration, 3), info
    except NextoryError as exc:
        logging.warning("Nextory playback unavailable: %s", exc)
        raise HTTPException(status_code=503, detail=str(exc)) from exc

    now = int(time.time() * 1000)
    utc = datetime.now(timezone.utc)
    track = audio_file()
    track.update({
        "index": 1, "startOffset": 0.0, "duration": DURATION,
        "title": info.title, "mimeType": "application/vnd.apple.mpegurl",
        "contentUrl": f"/public/session/{session.id}/track/1",
    })
    return {
        "id": session.id, "userId": USER_ID, "libraryId": LIBRARY_ID,
        "libraryItemId": BOOK_ID, "bookId": MEDIA_ID, "episodeId": None,
        "mediaType": "book", "mediaMetadata": metadata_json(True),
        "chapters": [], "displayTitle": info.title,
        "displayAuthor": ", ".join(info.authors),
        "coverPath": f"/api/items/{BOOK_ID}/cover",
        "duration": DURATION, "playMethod": 0,
        "mediaPlayer": payload.get("mediaPlayer") or "AVPlayer",
        "deviceInfo": payload.get("deviceInfo") or {},
        "serverVersion": COMPAT_VERSION, "date": utc.strftime("%Y-%m-%d"),
        "dayOfWeek": utc.strftime("%A"), "timeListening": 0.0,
        "startTime": 0.0, "currentTime": 0.0,
        "startedAt": now, "updatedAt": now,
        "audioTracks": [track], "libraryItem": item_json(expanded=True),
    }


@app.api_route("/public/session/{session_id}/track/{track_index}", methods=["GET", "HEAD"])
async def public_track(session_id: str, track_index: int):
    session = registry.get(session_id)
    if not session or track_index != 1 or not session.root_resource_token:
        raise HTTPException(status_code=404, detail="Playback session not found")
    url = session.public_uri(session.root_resource_token, "manifest", session.first_uri)
    return RedirectResponse(url, status_code=302, headers={"Cache-Control": "no-store"})


@app.api_route("/hls/{session_id}/{resource_token}/{filename}", methods=["GET", "HEAD"])
async def hls_resource(session_id: str, resource_token: str, filename: str, req: Request):
    """Never return a raw Nextory URL or key in the public response."""
    session = registry.get(session_id)
    resource = session.resource(resource_token) if session else None
    if not resource:
        raise HTTPException(status_code=404, detail="HLS resource not found or expired")
    if resource.kind == "manifest":
        try:
            body, final_url = await run_in_threadpool(nextory.get_manifest, resource.url)
            rewritten = rewrite_playlist(body, final_url, session)
        except NextoryError as exc:
            logging.warning("HLS playlist unavailable: %s", exc)
            raise HTTPException(status_code=502, detail=str(exc)) from exc
        data = rewritten.encode("utf-8")
        return Response(content=b"" if req.method == "HEAD" else data,
                        media_type="application/vnd.apple.mpegurl", headers={
                            "Content-Length": str(len(data)), "Cache-Control": "no-store",
                            "Access-Control-Allow-Origin": "*",
                        })

    # Video/audio segments and AES-128 keys are not interpreted or decrypted.
    try:
        upstream = await run_in_threadpool(
            nextory.remote_get, resource.url, byte_range=req.headers.get("range"))
    except NextoryError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    if upstream.status_code not in (200, 206):
        code = upstream.status_code
        upstream.close()
        raise HTTPException(status_code=502, detail=f"Nextory HLS resource HTTP {code}")

    media_type = upstream.headers.get("Content-Type", "application/octet-stream").split(";", 1)[0]
    if resource.kind == "key":
        media_type = "application/octet-stream"
    elif media_type in {"application/octet-stream", ""}:
        media_type = "video/mp2t" if filename.endswith(".ts") else "audio/aac" if filename.endswith(".aac") else "application/octet-stream"
    safe_headers = {"Cache-Control": "no-store", "Accept-Ranges": "bytes"}
    for key in ("Content-Length", "Content-Range", "ETag", "Last-Modified"):
        val = upstream.headers.get(key)
        if val:
            safe_headers[key] = val

    if req.method == "HEAD":
        upstream.close()
        return Response(content=b"", media_type=media_type, status_code=upstream.status_code,
                        headers=safe_headers)

    def stream_chunks():
        # streaming: no file is written; memory use is bounded to a single chunk.
        try:
            for chunk in upstream.iter_content(chunk_size=64 * 1024):
                if chunk:
                    yield chunk
        finally:
            upstream.close()

    return StreamingResponse(stream_chunks(), status_code=upstream.status_code,
                             media_type=media_type, headers=safe_headers)


@app.post("/api/session/{session_id}/sync")
async def sync_session(session_id: str, req: Request, _: bool = Depends(authenticated)):
    session = registry.get(session_id)
    if not session:
        raise HTTPException(status_code=404, detail="Playback session not found")
    try:
        data = await req.json()
        current = float(data.get("currentTime", session.current_time))
        listened = float(data.get("timeListened", 0.0))
        if current >= 0 and current < session.duration + 1:
            session.current_time = min(current, session.duration)
        if 0 <= listened <= 3600:
            session.time_listening += listened
    except (ValueError, TypeError, AttributeError):
        raise HTTPException(status_code=400, detail="Invalid progress")
    return Response(content="OK", media_type="text/plain")


@app.post("/api/session/{session_id}/close")
async def close_session(session_id: str, req: Request, _: bool = Depends(authenticated)):
    registry.close(session_id)
    return Response(content="OK", media_type="text/plain")


@app.get("/api/me/listening-stats")
async def listening_stats(_: bool = Depends(authenticated)):
    return {"totalTime": 0, "items": []}


@app.get("/api/me/item/listening-sessions/{item_id}")
async def listening_sessions(item_id: str, _: bool = Depends(authenticated)):
    return []


@app.get("/api/items/{item_id}/file/{file_id}")
async def file(item_id: str, file_id: str, _: bool = Depends(authenticated)):
    raise HTTPException(status_code=404, detail="Virtual file is served by session HLS URL")


@app.websocket("/socket.io/")
@app.websocket("/socket.io")
async def socket_io_v4(ws: WebSocket):
    """Minimal Engine.IO v4 / Socket.IO default-namespace handshake.

    The mobile client uses WebSocket transport exclusively. Not a generic
    Socket.IO implementation, only connect + auth + init are supported.
    """
    origin = ws.headers.get("origin")
    allowed = {"capacitor://localhost", "ionic://localhost", "http://localhost", "http://127.0.0.1"}
    extra_origin = os.environ.get("TEST_ALLOWED_ORIGIN", "").strip()
    if extra_origin:
        allowed.add(extra_origin)
    if origin and origin not in allowed:
        await ws.close(code=1008)
        return
    if ws.query_params.get("EIO") != "4" or ws.query_params.get("transport") != "websocket":
        await ws.close(code=1003)
        return
    await ws.accept()
    sid = secrets.token_urlsafe(16)
    await ws.send_text('0' + json.dumps({"sid": sid, "upgrades": [],
                                        "pingInterval": 25000, "pingTimeout": 20000,
                                        "maxPayload": 1000000}, separators=(",", ":")))
    namespace_connected = False
    is_authenticated = False
    last_ping = time.monotonic()
    ping_pending = False
    try:
        while True:
            delay = 20 if ping_pending else max(0.1, 25 - (time.monotonic() - last_ping))
            try:
                packet = await asyncio.wait_for(ws.receive_text(), timeout=delay)
            except asyncio.TimeoutError:
                if ping_pending:
                    await ws.close(code=1001)
                    break
                await ws.send_text("2")
                last_ping = time.monotonic()
                ping_pending = True
                continue
            if packet == "3":
                ping_pending = False
            elif packet == "2":
                await ws.send_text("3")
            elif packet.startswith("40"):
                namespace_connected = True
                await ws.send_text('40' + json.dumps({"sid": sid}))
            elif packet.startswith("42") and namespace_connected:
                try:
                    event = json.loads(packet[2:])
                except (ValueError, json.JSONDecodeError):
                    continue
                if isinstance(event, list) and len(event) > 1 and event[0] == "auth":
                    is_authenticated = isinstance(event[1], str) and check_token(event[1])
                    if is_authenticated:
                        await ws.send_text('42' + json.dumps(["init", {"userId": USER_ID}], separators=(",", ":")))
                    else:
                        await ws.send_text('42' + json.dumps(["auth_failed", {"message": "Invalid token"}]))
                elif not is_authenticated:
                    await ws.send_text('42' + json.dumps(["auth_failed", {"message": "Auth required"}]))
            elif packet in {"41", "1"}:
                break
    except (WebSocketDisconnect, RuntimeError):
        pass
