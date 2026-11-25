"""Standalone Audiobookshelf-compatible Nextory virtual-book server, version 6.

Nextory catalogue discovery and live search are indexed. The iOS client requests separate
original HLS parts via AVQueuePlayer; no audiobook bytes are kept on disk.
"""
from __future__ import annotations

import asyncio
import base64
import hashlib
import hmac
import html
import json
import logging
import math
import os
import re
import secrets
import sqlite3
import tempfile
import time
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import quote
from uuid import NAMESPACE_URL, uuid5

from fastapi import Depends, FastAPI, HTTPException, Request, WebSocket, WebSocketDisconnect
from fastapi.concurrency import run_in_threadpool
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import HTMLResponse, RedirectResponse, Response, StreamingResponse
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from .hls_proxy import registry, rewrite_playlist
from .nextory import BookInfo, CONFIG_PATH, NextoryError, TrackPart, nextory
from .prewarm import PrewarmManager  # NEXTORY_DETAIL_PREWARM_V1
from .hls_delivery import build_resource_response  # HLS_FIRSTPLAY_SERVER_V1
from .hls_root import direct_media_playlist  # NEXTORY_HLS_DIRECT_MEDIA_V1
from .hls_book import BookPlanCache, book_ref, PLAY_TOTAL_BUDGET_SECONDS  # NEXTORY_SINGLE_PRESENTATION_V2
from .progress import listening_history, progress_store
from . import fixed_m4b  # NEXTORY_FIXED_M4B_V1
from .discovery import (CATEGORIES, COLLECTION_GROWTH, COLLECTION_INITIAL_TARGET, CatalogPreview,
                        CatalogIndex, NextoryError as DiscoveryError, REFRESH_SECONDS,
                        catalog_index, is_dutch, item_id_for, search_dutch_catalog)

COMPAT_VERSION = '2.25.0'  # Native iOS uses public/session direct-play route since 2.22.
USERNAME = os.getenv('TEST_USERNAME', 'test')
PASSWORD = os.getenv('TEST_PASSWORD', '')
if len(PASSWORD) < 12:
    raise RuntimeError('Set TEST_PASSWORD to a local server password of at least 12 characters')


def load_auth_secret(path: Path) -> str:
    configured = os.getenv('TEST_AUTH_SECRET')
    if configured is not None:
        secret = configured
    else:
        if not path.exists():
            # Publish a complete, private file before another process can read it.
            temporary = tempfile.NamedTemporaryFile(
                dir=path.parent, mode='w', encoding='ascii', delete=False)
            temporary_path = Path(temporary.name)
            try:
                with temporary:
                    temporary.write(secrets.token_urlsafe(48))
                try:
                    os.link(temporary_path, path)
                except FileExistsError:
                    pass
            finally:
                temporary_path.unlink()
        secret = path.read_text(encoding='ascii')
    if len(secret) < 32:
        raise RuntimeError('The server session signing secret must be at least 32 characters')
    return secret


SECRET = load_auth_secret(progress_store.path.with_name('auth-secret'))

LIBRARY_ID = str(uuid5(NAMESPACE_URL, 'nextory-abs-poc:library'))
FOLDER_ID = str(uuid5(NAMESPACE_URL, 'nextory-abs-poc:folder'))
USER_ID = str(uuid5(NAMESPACE_URL, 'nextory-abs-poc:user'))
STARTED_MS = 1795170000000

DISCOVERY_LIBS = {'new': str(uuid5(NAMESPACE_URL, 'nextory-abs-poc:library:new'))}
for _code, _title, _path in CATEGORIES:
    DISCOVERY_LIBS['category:' + _code] = str(uuid5(NAMESPACE_URL, 'nextory-abs-poc:library:category:' + _code))
# One visible Audiobookshelf library. The old v5 library IDs remain readable
# for mobile clients which still hold a cached selected-library identifier.
LIBRARY_TO_SHELF = {LIBRARY_ID: 'all'}
LEGACY_LIBRARY_IDS = frozenset(DISCOVERY_LIBS.values())
LIBRARY_NAMES = {LIBRARY_ID: 'Nextory'}
COLLECTION_SHELVES = [('new', 'Nieuw ontdekt'), *
                     [(f'category:{code}', title) for code, title, _ in CATEGORIES]]
COLLECTION_IDS = {shelf: str(uuid5(NAMESPACE_URL, 'nextory-abs-poc:collection:' + shelf))
                  for shelf, _ in COLLECTION_SHELVES}
COLLECTION_BY_ID = {cid: shelf for shelf, cid in COLLECTION_IDS.items()}
COLLECTION_NAMES = dict(COLLECTION_SHELVES)

app = FastAPI(title='Nextory Audiobookshelf Virtual Books', docs_url=None, redoc_url=None)
app.add_middleware(CORSMiddleware,
                   allow_origins=['capacitor://localhost', 'ionic://localhost',
                                  'http://localhost', 'http://127.0.0.1'],
                   allow_methods=['GET', 'POST', 'PATCH', 'OPTIONS'],
                   allow_headers=['Authorization', 'Content-Type', 'X-Return-Tokens'])
bearer = HTTPBearer(auto_error=False)
failed_logins = defaultdict(list)


@app.middleware('http')
async def security_headers(request: Request, call_next):
    started = time.perf_counter()
    response = await call_next(request)
    # Anonymous diagnostic timings: no passwords, session IDs, upstream URLs
    # or full paths are written to logs.
    path = request.url.path
    label = ('play-start' if path.startswith('/api/items/') and path.endswith('/play')
             else 'book-cover' if path.startswith('/api/items/') and path.endswith('/cover')
             else 'book-detail' if path.startswith('/api/items/') and path.count('/') == 3
             else 'track-entry' if path.startswith('/public/session/')
             else None)
    if label:
        logging.getLogger('uvicorn.error').info('POC_TIMING stage=%s status=%s elapsed_ms=%d',
                     label, response.status_code, int((time.perf_counter()-started)*1000))
    response.headers['X-Content-Type-Options'] = 'nosniff'
    response.headers['X-Robots-Tag'] = 'noindex, nofollow'
    response.headers['Referrer-Policy'] = 'no-referrer'
    if ((request.url.path.startswith('/api') and not request.url.path.endswith('/cover'))
            or request.url.path in {'/login', '/status'}):
        response.headers['Cache-Control'] = 'no-store'
    return response


def media_id_for(book_id: int) -> str:
    return str(uuid5(NAMESPACE_URL, f'nextory-abs-poc:media:{book_id}'))


def id_to_book(item_id: str) -> int:
    number = catalog_index.resolve_item(item_id)
    if number is not None:
        return number
    raise HTTPException(status_code=404, detail='Book not found in indexed Nextory catalog')


def _progress_json(book_id: int) -> dict | None:
    current = progress_store.get(book_id)
    if current is None:
        return None
    finished = current['currentTime'] >= current['duration']
    return {'id': media_id_for(book_id), 'libraryItemId': item_id_for(book_id),
            'episodeId': None, 'mediaItemId': media_id_for(book_id),
            'duration': current['duration'], 'currentTime': current['currentTime'],
            'progress': current['currentTime'] / current['duration'],
            'lastUpdate': current['lastUpdate'], 'isFinished': finished,
            'hideFromContinueListening': False, 'finishedAt': current['lastUpdate'] if finished else None,
            'startedAt': int(current.get('startedAt') or current['lastUpdate'])}  # AUDIOBOOTH_COMPAT_V1


def b64(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode('ascii').rstrip('=')


def make_token(kind: str = 'access') -> str:
    now = int(time.time())
    header = b64(b'{"alg":"HS256","typ":"JWT"}')
    payload = b64(json.dumps({'sub': USER_ID, 'iat': now,
                              'exp': now + (86400 if kind == 'access' else 14 * 86400),
                              'kind': kind, 'jti': secrets.token_hex(8)},
                             separators=(',', ':')).encode())
    signature = b64(hmac.new(SECRET.encode(), f'{header}.{payload}'.encode(),
                             hashlib.sha256).digest())
    return f'{header}.{payload}.{signature}'


def check_token(token: str, kind: str = 'access') -> bool:
    try:
        head, body, signature = token.split('.')
        expected = b64(hmac.new(SECRET.encode(), f'{head}.{body}'.encode(),
                                hashlib.sha256).digest())
        if not hmac.compare_digest(expected, signature):
            return False
        payload = json.loads(base64.urlsafe_b64decode(body + '=' * (-len(body) % 4)))
        return (payload.get('sub') == USER_ID and payload.get('kind') == kind and
                isinstance(payload.get('exp'), int) and payload['exp'] > time.time())
    except (ValueError, KeyError, UnicodeError, TypeError):
        return False


def authenticated(credentials: HTTPAuthorizationCredentials | None = Depends(bearer)) -> bool:
    if credentials is None or not check_token(credentials.credentials):
        raise HTTPException(status_code=401, detail='Authentication required')
    return True


def user_json(token: str | None = None) -> dict:
    progress = [_progress_json(n) for n in progress_store.all()]
    return {
        'id': USER_ID, 'username': USERNAME, 'email': None,
        'type': 'user', 'token': token, 'isOldToken': False,
        'mediaProgress': [p for p in progress if p],
        'seriesHideFromContinueListening': [], 'bookmarks': [],
        'isActive': True, 'isLocked': False, 'lastSeen': None,
        'createdAt': STARTED_MS, 'librariesAccessible': list(LIBRARY_TO_SHELF),
        'itemTagsSelected': [], 'hasOpenIDLink': False,
        'permissions': {'accessAllLibraries': True, 'download': False,
                        'update': False, 'delete': False, 'upload': False, 'create': False}
    }


def server_settings() -> dict:
    # Keep the v3 app-compatible serialization; never publish provider tokens.
    return {
        'id': 'server-settings', 'version': COMPAT_VERSION, 'buildNumber': 0,
        'language': 'nl-nl', 'timeZone': 'UTC',
        'scannerFindCovers': False, 'scannerCoverProvider': 'google',
        'scannerParseSubtitle': False, 'scannerPreferMatchedMetadata': False,
        'scannerDisableWatcher': True, 'storeCoverWithItem': False,
        'storeMetadataWithItem': False, 'metadataFileFormat': 'json',
        'rateLimitLoginRequests': 8, 'rateLimitLoginWindow': 300000,
        'allowIframe': False, 'allowedOrigins': [], 'backupPath': '/nonexistent',
        'backupSchedule': False, 'backupsToKeep': 2, 'maxBackupSize': 1,
        'loggerDailyLogsToKeep': 7, 'loggerScannerLogsToKeep': 2,
        'homeBookshelfView': 1, 'bookshelfView': 1,
        'podcastEpisodeSchedule': '0 * * * *', 'sortingIgnorePrefix': False,
        'sortingPrefixes': ['the', 'a'], 'chromecastEnabled': False,
        'dateFormat': 'dd/MM/yyyy', 'timeFormat': 'HH:mm', 'logLevel': 2,
        'authLoginCustomMessage': None, 'authActiveAuthMethods': ['local'],
        'authOpenIDIssuerURL': None, 'authOpenIDAuthorizationURL': None,
        'authOpenIDTokenURL': None, 'authOpenIDUserInfoURL': None,
        'authOpenIDJwksURL': None, 'authOpenIDLogoutURL': None,
        'authOpenIDTokenSigningAlgorithm': 'RS256',
        'authOpenIDButtonText': 'Login with OpenID',
        'authOpenIDAutoLaunch': False, 'authOpenIDAutoRegister': False,
        'authOpenIDMatchExistingBy': None,
        'authFormData': {'authOpenIDEnabled': False},
    }


def login_payload(token: str) -> dict:
    user = user_json(token)
    user['accessToken'] = token
    return {'user': user, 'userDefaultLibraryId': LIBRARY_ID,
            'serverSettings': server_settings(), 'ereaderDevices': [],
            'Source': 'virtual-poc'}


def library_json(library_id: str = LIBRARY_ID) -> dict:
    return {
        'id': library_id, 'name': LIBRARY_NAMES.get(library_id, 'Nextory'),
        'displayOrder': list(LIBRARY_TO_SHELF).index(library_id) + 1,
        'icon': 'database', 'mediaType': 'book', 'provider': 'google',
        'folders': [{'id': FOLDER_ID, 'fullPath': '/virtual/nextory',
                     'libraryId': library_id}],
        'settings': {'coverAspectRatio': 0, 'audiobooksOnly': True, 'bookshelfView': 0},
        'lastScan': None, 'lastScanVersion': None,
        'createdAt': STARTED_MS, 'lastUpdate': STARTED_MS,
    }


def author_id(name: str) -> str:
    return str(uuid5(NAMESPACE_URL, 'nextory-author:' + name))


def series_id(name: str) -> str:
    return str(uuid5(NAMESPACE_URL, 'nextory-series:' + name))


def strip_html(source: str) -> str:
    return html.unescape(re.sub(r'<[^>]+>', ' ', source)).strip()


def metadata_json(info: BookInfo, expanded: bool) -> dict:
    authors = ', '.join(info.authors)
    series = info.series_name
    year = info.published_date[:4] if info.published_date and info.published_date[:4].isdigit() else None
    result = {
        'title': info.title, 'titleIgnorePrefix': info.title,
        'subtitle': info.subtitle, 'authorName': authors, 'authorNameLF': authors,
        'narratorName': ', '.join(info.narrators), 'seriesName': series or '',
        'genres': list(info.genres), 'publishedYear': year,
        'publishedDate': info.published_date, 'publisher': info.publisher,
        'description': info.description, 'isbn': info.isbn, 'asin': None,
        'language': info.language, 'explicit': False, 'abridged': False,
    }
    if expanded:
        result.update({
            'authors': [{'id': author_id(a), 'name': a} for a in info.authors],
            'narrators': list(info.narrators),
            'series': series_metadata(series, info.series_order),
            'descriptionPlain': strip_html(info.description),
        })
    return result


def audio_file(info: BookInfo, track: TrackPart) -> dict:
    filename = f'nextory-{info.book_id}-part-{track.index}.m3u8'
    return {
        'ino': f'virtual-{info.book_id}-{track.index}', 'index': track.index,
        'addedAt': STARTED_MS, 'updatedAt': STARTED_MS,
        'duration': track.duration, 'bitRate': 0, 'codec': 'aac',
        'channels': 2, 'exclude': False,
        'metadata': {'filename': filename, 'ext': '.m3u8', 'size': 0,
                     'path': f'/virtual/nextory/{info.book_id}/{filename}',
                     'relPath': filename, 'mtimeMs': STARTED_MS},
    }


def chapters_json(tracks: tuple[TrackPart, ...]) -> list[dict]:
    # Nextory package start_at values are real boundaries. "Audiodeel N" is an
    # honest section label, NOT a fabricated claim of chapter-title metadata.
    return [{'id': track.index, 'start': track.start,
             'end': round(track.start + track.duration, 3), 'title': track.title}
            for track in tracks]


def item_json(info: BookInfo, tracks: tuple[TrackPart, ...], expanded: bool = False) -> dict:
    item_id = item_id_for(info.book_id)
    duration = round(tracks[-1].start + tracks[-1].duration, 3)
    files = [audio_file(info, t) for t in tracks]
    media = {
        'id': media_id_for(info.book_id), 'metadata': metadata_json(info, expanded),
        'coverPath': f'/api/items/{item_id}/cover', 'tags': [],
        'numTracks': len(tracks), 'numAudioFiles': len(tracks),
        'numChapters': len(tracks), 'duration': duration, 'size': 0,
        'ebookFormat': None,
    }
    if expanded:
        media.update({
            'libraryItemId': item_id, 'audioFiles': files,
            'chapters': chapters_json(tracks), 'ebookFile': None,
            'tracks': [dict(af, title=tracks[i].title,
                            startOffset=tracks[i].start,
                            mimeType='application/vnd.apple.mpegurl',
                            contentUrl=f'/api/items/{item_id}/file/{af["ino"]}')
                       for i, af in enumerate(files)],
        })
    entry = {
        'id': item_id, 'ino': f'nextory-{info.book_id}', 'oldLibraryItemId': None,
        'libraryId': LIBRARY_ID, 'folderId': FOLDER_ID,
        'path': f'/virtual/nextory/{info.book_id}', 'relPath': str(info.book_id),
        'isFile': False, 'mtimeMs': STARTED_MS, 'ctimeMs': STARTED_MS,
        'birthtimeMs': STARTED_MS, 'addedAt': STARTED_MS, 'updatedAt': STARTED_MS,
        'isMissing': False, 'isInvalid': False, 'mediaType': 'book',
        'media': media, 'numFiles': len(tracks), 'size': 0,
    }
    if expanded:
        entry.update({'lastScan': None, 'scanVersion': None, 'libraryFiles': []})
    return entry


def summary_item(preview: CatalogPreview) -> dict:
    """Fast Audiobookshelf minified item; full tracks only fetched on detail/play."""
    book_id = preview.book_id
    item_id = item_id_for(book_id)
    authors = ', '.join(preview.authors)
    year = (preview.published_date[:4] if preview.published_date and
            preview.published_date[:4].isdigit() else None)
    meta = {'title': preview.title, 'titleIgnorePrefix': preview.title,
            'subtitle': preview.subtitle, 'authorName': authors,
            'authorNameLF': authors, 'narratorName': ', '.join(preview.narrators),
            'seriesName': preview.series_name or '',
            'series': series_metadata(preview.series_name, preview.series_order),
            'genres': list(preview.genres), 'publishedYear': year,
            'publishedDate': preview.published_date, 'publisher': preview.publisher,
            'description': preview.description, 'isbn': preview.isbn, 'asin': None,
            'language': preview.language, 'explicit': False, 'abridged': False}
    # One metadata-only virtual track advertises streamability to the native
    # collection card. POST /play replaces this with the actual 34/86/.. tracks.
    media = {'id': media_id_for(book_id), 'metadata': meta,
             'coverPath': f'/api/items/{item_id}/cover',
             'tags': [], 'numTracks': 1, 'numAudioFiles': 1, 'numChapters': 0,
             'duration': preview.duration or 0, 'size': 0, 'ebookFormat': None,
             'tracks': [{'index': 1, 'startOffset': 0, 'duration': preview.duration or 0,
                         'title': preview.title, 'mimeType': 'application/vnd.apple.mpegurl',
                         'contentUrl': None}]}
    return {'id': item_id, 'ino': f'nextory-{book_id}',
            'oldLibraryItemId': None, 'libraryId': LIBRARY_ID, 'folderId': FOLDER_ID,
            'path': f'/virtual/nextory/{book_id}', 'relPath': str(book_id),
            'isFile': False, 'mtimeMs': STARTED_MS, 'ctimeMs': STARTED_MS,
            'birthtimeMs': STARTED_MS, 'addedAt': STARTED_MS,
            'updatedAt': STARTED_MS, 'isMissing': False, 'isInvalid': False,
            'mediaType': 'book', 'media': media, 'numFiles': 1, 'size': 0}


def _prepare_category(shelf: str, page: int, limit: int):
    if shelf.startswith('category:'):
        try:
            catalog_index.ensure_category(shelf.split(':', 1)[1], page, limit)
        except NextoryError as exc:
            logging.warning('Category discovery unavailable (%s): %s', shelf, exc)
            # Keep last good indexed pages; report source error in status.


def _library_list(shelf: str, page: int, limit: int):
    # Browsing is always local; it must not initiate upstream account activity.
    return catalog_index.select(shelf, page, limit)


async def dynamic_listing(shelf: str, page: int = 0, limit: int = 20):
    return await run_in_threadpool(_library_list, shelf, page, limit)


def _collection_listing(shelf: str, page: int, limit: int | None):
    return catalog_index.select(shelf, page, limit) if limit is not None else catalog_index.select(shelf, 0, -1)


async def _discovery_poller():
    # API work happens in a thread, never on the ASGI event loop.
    while True:
        try:
            await run_in_threadpool(catalog_index.refresh_recent)
        except (NextoryError, OSError, ValueError) as exc:
            logging.warning('Nextory catalog refresh failed (preserving last index): %s', exc)
            await asyncio.sleep(60)
        else:
            await asyncio.sleep(REFRESH_SECONDS)


async def _collection_poller():
    logger = logging.getLogger('uvicorn.error')
    while True:
        filled = False
        for key, _, _ in CATEGORIES:
            try:
                result = await run_in_threadpool(catalog_index.fill_next_category_page, key)
            except (NextoryError, OSError, ValueError, sqlite3.Error) as exc:
                logger.warning('Dutch collection sync failed category=%s error=%s', key, type(exc).__name__)
                await asyncio.sleep(15)
                continue
            if result is not None:
                filled = True
                logger.info('POC_CATALOG category=%s source_page=%d indexed=%d', key, *result)
                await asyncio.sleep(15)
        if not filled:
            await asyncio.sleep(60)


@app.on_event('startup')
async def start_discovery():
    if os.getenv('CATALOG_AUTOSYNC', '0') == '1':
        app.state.catalog_task = asyncio.create_task(_discovery_poller())
        app.state.collection_task = asyncio.create_task(_collection_poller())


@app.on_event('shutdown')
async def stop_discovery():
    tasks = [task for name in ('catalog_task', 'collection_task')
             if (task := getattr(app.state, name, None)) is not None]
    for task in tasks:
        task.cancel()
    await asyncio.gather(*tasks, return_exceptions=True)
    prewarm_manager.shutdown()  # NEXTORY_DETAIL_PREWARM_V1
    book_plan_cache.shutdown()  # NEXTORY_SINGLE_PRESENTATION_V1


def _compute_book_and_layout(book_id: int) -> tuple[BookInfo, tuple[TrackPart, ...], int, int]:
    """NEXTORY_DETAIL_PREWARM_V1: common single computation for warm/cold play."""
    started = time.perf_counter()
    info = nextory.get_book(book_id)
    book_ms = int((time.perf_counter() - started) * 1000)
    started = time.perf_counter()
    # NEXTORY_SINGLE_PRESENTATION_V2: compose from source parts before asking
    # for the legacy layout. The manifest traversal yields both products.
    remember = getattr(nextory, 'remember_composed_layout', None)
    if len(info.parts) > 1 and callable(remember):
        seeds = tuple(TrackPart(i+1, p['uri'], 0., 0.,
                                p['title'].strip() if isinstance(p.get('title'), str) and p['title'].strip()
                                else f'Audiodeel {i + 1}')
                      for i, p in enumerate(info.parts))
        plan, reason = book_plan_cache.prepare(nextory, book_id, seeds)
        if plan is not None and remember(info, plan.chapters):
            layout_ms = int((time.perf_counter() - started) * 1000)
            logging.getLogger('uvicorn.error').info(
                'POC_HLS_BOOK stage=layout mode=single_pass book=%s chapters=%d elapsed_ms=%d',
                book_ref(book_id), len(plan.chapters), layout_ms)
            return info, plan.chapters, book_ms, layout_ms
    # A provider with unsupported playlists still has the existing layout path.
    tracks = nextory.get_layout(book_id)
    layout_ms = int((time.perf_counter() - started) * 1000)
    book_plan_cache.schedule(nextory, book_id, tracks)
    return info, tracks, book_ms, layout_ms


book_plan_cache = BookPlanCache()


prewarm_manager = PrewarmManager(
    _compute_book_and_layout,
    lambda book_id: nextory.peek_book_and_layout(book_id),
)


async def book_and_layout(item_id: str) -> tuple[BookInfo, tuple[TrackPart, ...]]:
    book_id = id_to_book(item_id)
    try:
        (info, tracks, book_ms, layout_ms), source, waited = await prewarm_manager.obtain(book_id)
        logging.getLogger('uvicorn.error').info(
            'POC_PLAY_PHASE book_ms=%d layout_ms=%d tracks=%d source=%s wait_ms=%d',
            book_ms, layout_ms, len(tracks), source, waited)  # AUDIOBOOTH_COMPAT_V1
        return info, tracks
    except NextoryError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc


def filter_data_previews(previews: list[CatalogPreview], total: int) -> dict:
    """Build library filters from local metadata, never from audio manifests."""
    authors = sorted({a for p in previews for a in p.authors})
    narrators = sorted({n for p in previews for n in p.narrators})
    series = sorted({p.series_name for p in previews if p.series_name})
    return {'authors': [{'id': author_id(a), 'name': a} for a in authors],
            'genres': sorted({g for p in previews for g in p.genres}),
            'tags': [], 'series': [{'id': series_id(name), 'name': name} for name in series],
            'narrators': narrators,
            'languages': sorted({p.language for p in previews if p.language}),
            'publishers': sorted({p.publisher for p in previews if p.publisher}),
            'publishedDecades': [], 'bookCount': total,
            'authorCount': len(authors), 'narratorCount': len(narrators),
            'seriesCount': len(series), 'podcastCount': 0,
            'numIssues': 0, 'loadedAt': int(time.time() * 1000)}


def collection_json(shelf: str, books: list[dict], *, total: int = 0) -> dict:
    """Real Audiobookshelf Collection shape, with source-backed item previews."""
    return {'id': COLLECTION_IDS[shelf], 'libraryId': LIBRARY_ID, 'userId': USER_ID,
            'name': COLLECTION_NAMES[shelf], 'description': None,
            'books': books, 'numBooks': total,
            'lastUpdate': STARTED_MS, 'createdAt': STARTED_MS}


def indexed_collection(shelf: str) -> dict:
    previews, count = catalog_index.select(shelf, 0, -1)
    return collection_json(shelf, [summary_item(p) for p in previews], total=count)


def preview_detail(preview: CatalogPreview) -> dict:
    """Native iOS-compatible expanded item. Full tracks are fetched on Play.

    A single *virtual preview track* only advertises that this audiobook is
    playable; it contains no media URL, no audio, and no invented chapter data.
    """
    entry = summary_item(preview)
    m = entry['media']
    meta = m['metadata']
    meta['authors'] = [{'id': author_id(a), 'name': a} for a in preview.authors]
    meta['narrators'] = list(preview.narrators)
    meta['descriptionPlain'] = strip_html(preview.description)
    m['chapters'] = []  # Precise boundaries come in the playback session.
    m['numChapters'] = 0
    m['audioFiles'] = []
    m['ebookFile'] = None
    m['libraryItemId'] = entry['id']
    entry.update({'lastScan': None, 'scanVersion': None, 'libraryFiles': []})
    return entry


async def lightweight_catalog():
    """Only the SQLite metadata index; no Nextory HLS layout measurement."""
    return await run_in_threadpool(catalog_index.select, 'all', 0, -1)


def filter_data(books: list[tuple[BookInfo, tuple[TrackPart, ...]]]) -> dict:
    names = sorted({a for info, _ in books for a in info.authors})
    return {
        'authors': [{'id': author_id(name), 'name': name} for name in names],
        'genres': sorted({g for info, _ in books for g in info.genres}),
        'tags': [], 'series': [],
        'narrators': sorted({n for info, _ in books for n in info.narrators}),
        'languages': sorted({info.language for info, _ in books if info.language}),
        'publishers': sorted({info.publisher for info, _ in books if info.publisher}),
        'publishedDecades': [], 'bookCount': len(books), 'authorCount': len(names),
        'seriesCount': 0, 'podcastCount': 0, 'numIssues': 0,
        'loadedAt': int(time.time() * 1000),
    }


@app.get('/', response_class=HTMLResponse)
async def index():
    return HTMLResponse('''<!doctype html><html lang="nl"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Nextory Virtual ABS</title><body style="font:16px system-ui;max-width:720px;margin:40px auto;padding:15px">
<h1>Nextory Virtual Audiobookshelf</h1><p>On-demand Nextory audiobooks, live catalogue search, automatic discovery and categories.</p>
<p>The catalogue is refreshed automatically; search or browse genres in the iOS app. No manual add-book command needed.</p>
<p>No local audiobook storage. Use only on a trusted network.</p></body></html>''')


@app.get('/health')
@app.get('/healthcheck')
async def health():
    config_mounted = CONFIG_PATH.is_file()
    try:
        nextory._credentials()
    except NextoryError:
        audio_enabled = False
    else:
        audio_enabled = True
    return {'status': 'ok', 'audioEnabled': audio_enabled,
            'mode': 'nextory-multiple-hls-tracks', 'configMounted': config_mounted}


@app.get('/ping')
async def ping():
    return {'success': True}


@app.get('/status')
async def status():
    return {'app': 'audiobookshelf', 'serverVersion': COMPAT_VERSION,
            'isInit': True, 'language': 'nl-nl', 'authMethods': ['local'],
            'authFormData': {'authOpenIDEnabled': False}}


@app.post('/login')
async def login(req: Request):
    ip = req.client.host if req.client else 'unknown'
    now = time.monotonic()
    failed_logins[ip] = [t for t in failed_logins[ip] if now - t < 300]
    if len(failed_logins[ip]) >= 8:
        raise HTTPException(status_code=429, detail='Too many login attempts')
    try:
        body = await req.json()
    except (ValueError, TypeError):
        body = {}
    if not isinstance(body, dict):
        body = {}
    given_name = str(body.get('username') or '')
    given_password = str(body.get('password') or '')
    if not (hmac.compare_digest(given_name, USERNAME) and
            hmac.compare_digest(given_password, PASSWORD)):
        failed_logins[ip].append(now)
        raise HTTPException(status_code=401, detail='Invalid credentials')
    failed_logins.pop(ip, None)
    token = make_token()
    result = login_payload(token)
    result['user']['refreshToken'] = make_token('refresh')
    return result


@app.post('/api/authorize')
async def authorize(req: Request, _: bool = Depends(authenticated)):
    return login_payload(req.headers['authorization'].split(' ', 1)[-1])


@app.get('/api/me')
async def me(req: Request, _: bool = Depends(authenticated)):
    return user_json(req.headers['authorization'].split(' ', 1)[-1])


@app.post('/auth/refresh')
async def refresh(req: Request):
    token = req.headers.get('x-refresh-token') or req.cookies.get('refresh_token', '')
    if not token or not check_token(token, 'refresh'):
        raise HTTPException(status_code=401, detail='Invalid refresh token')
    result = login_payload(make_token())
    result['user']['refreshToken'] = make_token('refresh')
    return result


@app.get('/api/me/progress')
async def progress(_: bool = Depends(authenticated)):
    return [p for n in progress_store.all() if (p := _progress_json(n))]


def items_in_progress(limit: int):
    rows = sorted(progress_store.all().items(),
                  key=lambda row: row[1]['lastUpdate'], reverse=True)
    items = []
    for book_id, saved in rows:
        if not 0 < saved['currentTime'] < saved['duration']:
            continue
        preview = catalog_index.lookup(book_id)
        if preview:
            item = summary_item(preview)
            item['media']['duration'] = saved['duration']
            item['progressLastUpdate'] = saved['lastUpdate']
            items.append(item)
            if len(items) == limit:
                break
    return items


@app.get('/api/me/items-in-progress')
async def continue_listening(limit: int = 25, _: bool = Depends(authenticated)):
    return await run_in_threadpool(items_in_progress, max(1, min(limit, 100)))


@app.get('/api/me/progress/{item_id}')
async def get_progress(item_id: str, _: bool = Depends(authenticated)):
    result = _progress_json(id_to_book(item_id))
    if result is None:
        raise HTTPException(status_code=404, detail='No saved progress')
    return result


@app.patch('/api/me/progress/{item_id}')
async def update_progress(item_id: str, req: Request, _: bool = Depends(authenticated)):
    """AUDIOBOOTH_COMPAT_V1: preserve play position sent by AudioBooth."""
    book_id = id_to_book(item_id)
    try:
        payload = await req.json()
        if not isinstance(payload, dict):
            raise ValueError('Invalid progress body')
        previous = progress_store.get(book_id) or {}
        raw_duration = payload.get('duration', previous.get('duration'))
        raw_time = payload.get('currentTime', previous.get('currentTime'))
        duration = float(raw_duration)
        current_time = float(raw_time)
        if not (math.isfinite(duration) and 0 < duration <= 7*24*3600
                and math.isfinite(current_time) and 0 <= current_time <= duration + 1):
            raise ValueError('Invalid progress times')
        if payload.get('isFinished') is True:
            current_time = duration
        await run_in_threadpool(progress_store.update, book_id,
                                current_time=min(current_time, duration), duration=duration)
    except (ValueError, TypeError, OverflowError):
        raise HTTPException(status_code=400, detail='Invalid progress update')
    except OSError as exc:
        raise HTTPException(status_code=503, detail='Progress store unavailable') from exc
    return Response(content='OK', media_type='text/plain')


@app.get('/api/libraries')
async def libraries(_: bool = Depends(authenticated)):
    return {'libraries': [library_json(lib_id) for lib_id in LIBRARY_TO_SHELF]}


def check_library(library_id: str) -> str:
    if library_id == LIBRARY_ID or library_id in LEGACY_LIBRARY_IDS:
        return 'all'
    raise HTTPException(status_code=404, detail='Library not found')


@app.get('/api/libraries/{library_id}')
async def library(library_id: str, include: str = '', _: bool = Depends(authenticated)):
    shelf = check_library(library_id)
    if 'filterdata' in include.split(','):
        previews, count = await lightweight_catalog()
        result = filter_data_previews(previews, count)
        return {'library': library_json(LIBRARY_ID), 'filterdata': result,
                'issues': 0, 'numUserPlaylists': 0}
    return library_json(LIBRARY_ID)


@app.get('/api/libraries/{library_id}/filterdata')
async def library_filters(library_id: str, _: bool = Depends(authenticated)):
    shelf = check_library(library_id)
    previews, count = await lightweight_catalog()
    return filter_data_previews(previews, count)


@app.get('/api/libraries/{library_id}/personalized')
async def personalized(library_id: str, _: bool = Depends(authenticated)):
    check_library(library_id)
    # The home screen must never wait for full audiobook layouts or category
    # website scans. All rows are satisfied by the existing metadata index.
    def from_index():
        rows = []
        saved = items_in_progress(12)
        if saved:
            rows.append({'id': 'continue-listening', 'label': 'Continue Listening',
                         'labelStringKey': 'LabelContinueListening', 'type': 'book',
                         'entities': saved, 'total': len(saved)})
        try:
            recent = [summary_item(preview) for book_id in listening_history.recent_books(12)
                      if (preview := catalog_index.lookup(book_id))]
        except (OSError, sqlite3.Error):
            recent = []
        if recent:
            rows.append({'id': 'nextory-recent-playback', 'label': 'Recent getest',
                         'type': 'book', 'entities': recent, 'total': len(recent)})
        for shelf, label in [('new', 'Nieuw ontdekt'),
                             ('all', 'Alle ontdekte luisterboeken')]:
            previews, count = catalog_index.select(shelf, 0, 12)
            if previews:
                rows.append({'id': 'nextory-home-' + shelf, 'label': label,
                             'type': 'book',
                             'entities': [summary_item(p) for p in previews],
                             'total': count})
        return rows
    return await run_in_threadpool(from_index)


@app.get('/api/libraries/{library_id}/items')
async def items(library_id: str, page: int = 0, limit: int = 20,
                minified: int = 1, _: bool = Depends(authenticated)):
    shelf = check_library(library_id)
    if page < 0 or page > 10000 or limit < 1 or limit > 100:
        raise HTTPException(status_code=400, detail='Invalid pagination')
    # All 21 former virtual libraries now share one single indexed library.
    # No HLS layouts are touched when browsing the library grid.
    previews, count = await dynamic_listing('all', page, limit)
    selected = [summary_item(p) for p in previews]
    return {'results': selected, 'total': count, 'limit': limit,
            'page': page, 'minified': minified == 1}


@app.get('/api/libraries/{library_id}/collections')
async def collections(library_id: str, page: int = 0, limit: int = 20,
                      minified: int = 1, _: bool = Depends(authenticated)):
    check_library(library_id)
    if not 0 <= page <= 100 or not 1 <= limit <= 100:
        raise HTTPException(status_code=400, detail='Invalid collection pagination')
    chosen = COLLECTION_SHELVES[page * limit:(page + 1) * limit]
    def load():
        return [indexed_collection(shelf) for shelf, _ in chosen]
    results = await run_in_threadpool(load)
    return {'results': results, 'total': len(COLLECTION_SHELVES),
            'page': page, 'limit': limit, 'minified': bool(minified), 'sortDesc': False}


@app.get('/api/collections')
async def all_collections(_: bool = Depends(authenticated)):
    def load():
        return [indexed_collection(shelf) for shelf, _ in COLLECTION_SHELVES]
    return {'collections': await run_in_threadpool(load)}


@app.get('/api/collections/{collection_id}')
async def collection_detail(collection_id: str, page: int = 0, limit: int | None = None,
                            _: bool = Depends(authenticated)):
    shelf = COLLECTION_BY_ID.get(collection_id)
    if shelf is None:
        raise HTTPException(status_code=404, detail='Collection not found')
    if not 0 <= page <= 10000 or (limit is not None and not 1 <= limit <= 200):
        raise HTTPException(status_code=400, detail='Invalid collection pagination')
    previews, count = await run_in_threadpool(_collection_listing, shelf, page, limit)
    result = collection_json(shelf, [summary_item(p) for p in previews], total=count)
    if limit is not None:
        result.update(page=page, limit=limit)
    return result


def book_counts(previews, field):
    counts = {}
    for preview in previews:
        for name in set(getattr(preview, field)):
            counts[name] = counts.get(name, 0) + 1
    return counts


def catalog_page(page: int, limit: int, sort: str, desc: bool, minified: bool):
    if not 0 <= page <= 10000 or not 0 <= limit <= 200:
        raise HTTPException(status_code=400, detail='Invalid catalog pagination')
    return {'page': page, 'limit': limit, 'sortBy': sort, 'sortDesc': desc, 'minified': minified}


@app.get('/api/libraries/{library_id}/authors')
async def authors(library_id: str, page: int = 0, limit: int = 0, sort: str = 'name',
                  desc: bool = False, minified: bool = False, _: bool = Depends(authenticated)):
    check_library(library_id)
    params = catalog_page(page, limit, sort, desc, minified)
    summaries, _ = await lightweight_catalog()
    counts = book_counts(summaries, 'authors')
    names = sorted(counts, key=lambda name: (counts[name], name.casefold()) if sort == 'numBooks'
                   else name.casefold(), reverse=desc)
    chosen = names[page * limit:(page + 1) * limit] if limit else names
    results = [{'id': author_id(name), 'name': name, 'numBooks': counts[name],
                'libraryId': LIBRARY_ID, 'lastFirst': name} for name in chosen]
    return {**params, 'results': results, 'total': len(names)} if limit else {'authors': results}


@app.get('/api/libraries/{library_id}/narrators')
async def narrators(library_id: str, _: bool = Depends(authenticated)):
    check_library(library_id)
    summaries, _ = await lightweight_catalog()
    counts = book_counts(summaries, 'narrators')
    return {'narrators': [{'id': quote(base64.b64encode(name.encode()).decode('ascii'), safe=''),
                           'name': name, 'numBooks': counts[name]}
                          for name in sorted(counts, key=str.casefold)]}


def series_groups(previews):
    groups = defaultdict(list)
    for preview in previews:
        if preview.series_name:
            groups[preview.series_name].append(preview)
    return groups


def series_metadata(name, order):
    if not name:
        return []
    return [{'id': series_id(name), 'name': name, 'sequence': str(order) if order is not None else None}]


def series_json(name, group):
    books = []
    for preview in sorted(group, key=lambda p: (p.series_order is None, p.series_order or 0,
                                                p.title.casefold())):
        item = summary_item(preview)
        sequence = str(preview.series_order) if preview.series_order is not None else None
        item['sequence'] = sequence
        books.append(item)
    return {'id': series_id(name), 'name': name, 'libraryId': LIBRARY_ID,
            'description': None, 'books': books, 'numBooks': len(books),
            'addedAt': STARTED_MS, 'updatedAt': STARTED_MS,
            'totalDuration': sum(p.duration or 0 for p in group)}


@app.get('/api/libraries/{library_id}/series')
async def library_series(library_id: str, page: int = 0, limit: int = 0, sort: str = 'name',
                         desc: bool = False, minified: bool = False, _: bool = Depends(authenticated)):
    check_library(library_id)
    params = catalog_page(page, limit, sort, desc, minified)
    summaries, _ = await lightweight_catalog()
    groups = series_groups(summaries)
    names = sorted(groups, key=lambda name: (len(groups[name]), name.casefold()) if sort == 'numBooks'
                   else name.casefold(), reverse=desc)
    chosen = names[page * limit:(page + 1) * limit] if limit else names
    return {**params, 'total': len(names), 'results': [series_json(name, groups[name]) for name in chosen]}


@app.get('/api/libraries/{library_id}/series/{identifier}')
async def library_series_detail(library_id: str, identifier: str, _: bool = Depends(authenticated)):
    check_library(library_id)
    return await series_detail(identifier, _)


@app.get('/api/series/{identifier}')
async def series_detail(identifier: str, _: bool = Depends(authenticated)):
    summaries, _ = await lightweight_catalog()
    for name, group in series_groups(summaries).items():
        if series_id(name) == identifier:
            return series_json(name, group)
    raise HTTPException(status_code=404, detail='Series not found')


@app.get('/api/libraries/{library_id}/stats')
async def library_stats(library_id: str, _: bool = Depends(authenticated)):
    check_library(library_id)
    previews, total = await lightweight_catalog()
    data = filter_data_previews(previews, total)
    author_counts = book_counts(previews, 'authors')
    genre_counts = book_counts(previews, 'genres')
    return {'totalItems': total, 'totalAuthors': data['authorCount'],
            'totalNarrators': data['narratorCount'], 'totalSeries': data['seriesCount'],
            'totalGenres': len(genre_counts), 'totalSize': 0,
            'totalDuration': sum(p.duration or 0 for p in previews), 'numAudioTracks': total,
            'authorsWithCount': [{'id': author_id(name), 'name': name, 'count': n}
                                 for name, n in sorted(author_counts.items(), key=lambda row: -row[1])[:10]],
            'genresWithCount': [{'genre': name, 'count': n} for name, n in genre_counts.items()],
            'largestItems': [], 'longestItems': []}


@app.get('/api/authors/{au_id}')
async def author(au_id: str, _: bool = Depends(authenticated)):
    summaries, _ = await lightweight_catalog()
    name = next((n for n in book_counts(summaries, 'authors') if author_id(n) == au_id), None)
    if name:
        matching = [summary_item(preview) for preview in summaries if name in preview.authors]
        return {'id': au_id, 'name': name, 'numBooks': len(matching), 'libraryItems': matching[:100]}
    raise HTTPException(status_code=404, detail='Author not found')


@app.get('/api/libraries/{library_id}/search')
async def search(library_id: str, q: str = '', _: bool = Depends(authenticated)):
    check_library(library_id)
    query = q.strip()
    if not query:
        return {'book': [], 'authors': [], 'series': [], 'tags': []}
    if len(query) > 100:
        raise HTTPException(status_code=400, detail='Search is too long')
    entries, _ = await lightweight_catalog()
    entries = [p for p in entries if query.casefold() in
               (' '.join((p.title, *p.authors, p.series_name or ''))).casefold()][:30]
    if os.getenv('CATALOG_LIVE_SEARCH', '0') == '1':
        try:
            previews = await run_in_threadpool(search_dutch_catalog, query)
            if previews:
                await run_in_threadpool(catalog_index.upsert, previews)
                entries = [CatalogPreview.from_dict(p) for p in previews]
        except (NextoryError, AttributeError) as exc:
            logging.warning('Nextory live search unavailable: %s', exc)
    return {'book': [{'libraryItem': summary_item(preview),
                      'matchKey': 'title', 'matchText': preview.title}
                     for preview in entries],
            'authors': [], 'series': [], 'tags': [], 'episodes': [], 'podcast': [],
            'narrators': []}


@app.get('/api/poc/discovery-status')
@app.get('/api/poc/catalog-status')
async def discovery_status(_: bool = Depends(authenticated)):
    return {'mode': 'dynamic-nextory-discovery',
            'visibleLibraries': 1, 'collections': len(COLLECTION_SHELVES),
            'fastMetadata': True, 'initialHlsRoundTripRemoved': True,
            'search': 'nextory-discovery-api' if os.getenv('CATALOG_LIVE_SEARCH', '0') == '1' else 'local-index',
            'categories': [code for code, _, _ in CATEGORIES],
            'automaticRefresh': os.getenv('CATALOG_AUTOSYNC', '0') == '1',
            'automaticCollectionFill': os.getenv('CATALOG_AUTOSYNC', '0') == '1',
            **(await run_in_threadpool(catalog_index.statistics))}


@app.post('/api/poc/discovery-refresh')
async def discovery_refresh(_: bool = Depends(authenticated)):
    try:
        return await run_in_threadpool(catalog_index.refresh_recent)
    except NextoryError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc


@app.get('/api/items/{item_id}')
async def item(item_id: str, expanded: int = 0, _: bool = Depends(authenticated)):
    book_id = id_to_book(item_id)
    # The native iPhone detail page needs metadata and cover, not the complete
    # HLS timeline. Product/cover data is already indexed; defer HLS probes to Play.
    preview = await run_in_threadpool(catalog_index.lookup, book_id)
    if preview is None:
        try:
            mapped = await run_in_threadpool(nextory.get_product_preview, book_id)
            if not mapped or not is_dutch(mapped.get('language')):
                raise NextoryError('Nextory audiobook metadata unavailable')
            await run_in_threadpool(catalog_index.upsert, [mapped])
            preview = CatalogPreview.from_dict(mapped)
        except NextoryError as exc:
            raise HTTPException(status_code=503, detail=str(exc)) from exc
    # After playback, reuse real full track metadata already in memory.
    # NEXTORY_DETAIL_PREWARM_V1: never block a book page on another HLS warmup.
    cached = None
    if not prewarm_manager.busy():
        try:
            cached = nextory.peek_book_and_layout(book_id)
        except AttributeError:
            pass
    if cached:
        info, tracks = cached
        # Catalog details are shared by clients. In all-book mode, choose
        # the virtual presentation only in the client-specific play response.
        if fixed_m4b.enabled(book_id, allow_all=False):
            try:
                parts = fixed_m4b.timeline(tracks)
                header, packets, samples = fixed_m4b.make_index(parts[-1].end)
                duration = round(samples / fixed_m4b.RATE, 3)
                candidate = (TrackPart(1, tracks[0].uri, 0., duration, info.title),)
                result = item_json(info, candidate, expanded=True)
                result['media']['chapters'] = chapters_json(tracks)
                result['media']['numChapters'] = len(tracks)
                fixed_m4b.patch_item(result, fixed_m4b.Metadata(len(header)+packets*fixed_m4b.PACKET_BYTES, duration))
            except fixed_m4b.MediaError:
                result = item_json(info, tracks, expanded=True)
        else:
            result = item_json(info, tracks, expanded=True)
    else:
        result = preview_detail(preview)
    # NEXTORY_DETAIL_PREWARM_V1: schedule only after detail is ready.
    # Catalog/library listings and cover requests never call schedule().
    if expanded == 1 and os.getenv('NEXTORY_DETAIL_PREWARM', '0') == '1':
        logging.getLogger('uvicorn.error').info('POC_HLS_BOOK stage=detail book=%s', book_ref(book_id))
        prewarm_manager.schedule(book_id)
        if cached:
            book_plan_cache.schedule(nextory, book_id, cached[1])
    return result


@app.get('/api/items/{item_id}/cover')
async def cover(item_id: str):
    book_id = id_to_book(item_id)
    try:
        preview = await run_in_threadpool(catalog_index.lookup, book_id)
        # Function uses provider validation and a 1-hour in-memory JPEG cache.
        jpeg = await run_in_threadpool(nextory.get_cover_jpeg, book_id,
                                       preview.cover_url if preview else None)
    except NextoryError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc
    return Response(jpeg, media_type='image/jpeg',
                    headers={'Cache-Control': 'public, max-age=900'})


@app.post('/api/items/{item_id}/play')
async def play(item_id: str, req: Request, _: bool = Depends(authenticated)):
    started = time.monotonic()
    try:
        body = await req.json()
    except (ValueError, TypeError):
        body = {}
    if not isinstance(body, dict):
        body = {}
    # NEXTORY_SINGLE_PRESENTATION_V1: this isolated A/B affects AudioBooth only.
    device = body.get('deviceInfo')
    device = device if isinstance(device, dict) else {}
    client_name = str(device.get('clientName') or '').lower()
    is_audiobooth = 'audiobooth' in client_name
    book_id = id_to_book(item_id)
    ref = book_ref(book_id)
    if is_audiobooth:
        try:
            info, tracks = await asyncio.wait_for(book_and_layout(item_id),
                max(0., PLAY_TOTAL_BUDGET_SECONDS - (time.monotonic() - started)))
        except asyncio.TimeoutError:
            logging.getLogger('uvicorn.error').info(
                'POC_HLS_BOOK stage=play mode=pending book=%s reason=layout_timeout', ref)
            raise HTTPException(status_code=503, detail='Book preparation is still running; reopen details and retry') from None
    else:
        info, tracks = await book_and_layout(item_id)
    if not tracks:
        raise HTTPException(status_code=503, detail='Book has no playable tracks')
    chapters = tracks
    playback_tracks = tracks
    reason = 'other_client' if not is_audiobooth else 'not_multiple_parts'
    previous = progress_store.get(info.book_id)
    previous_time = (float(previous['currentTime']) if previous else 0.0)
    duration = round(tracks[-1].start + tracks[-1].duration, 3)
    start_time = previous_time if previous_time < duration - 10 else 0.0
    session = None
    engine = None
    if is_audiobooth and fixed_m4b.enabled(book_id):
        try:
            # The internal source tracks are retained. AudioBooth sees only
            # one classic M4B track, using the same existing playback session.
            session = registry.create(book_id=info.book_id, title=info.title,
                                      tracks=tracks, user_id=USER_ID, current_time=start_time)
            engine = fixed_m4b.FixedM4B(tracks, fixed_m4b.LocalPlaybackSource(session))
            session.fixed_m4b = engine
        except fixed_m4b.MediaError as exc:
            if session is not None:
                registry.close(session.id)
            session = None
            engine = None
            logging.getLogger('uvicorn.error').info(
                'POC_FIXED_M4B event=fallback book=%s reason=%s', ref, str(exc))
        except NextoryError as exc:
            if session is not None:
                registry.close(session.id)
            raise HTTPException(status_code=503, detail=str(exc)) from exc
        except Exception:
            if session is not None:
                registry.close(session.id)
            raise
        else:
            duration = round(engine.duration, 3)
            session.duration = duration
            playback_tracks = (TrackPart(1, tracks[0].uri, 0., duration, info.title),)
            logging.getLogger('uvicorn.error').info(
                'POC_FIXED_M4B event=play book=%s chapters=%d audio_tracks=1 duration=%.3f header_bytes=%d virtual_bytes=%d chunks=%d',
                ref, len(chapters), duration, engine.media_start, engine.size, engine.chunk_count)
    plan = None
    if session is None and is_audiobooth and len(tracks) > 1:
        plan, reason = await book_plan_cache.obtain(nextory, info.book_id, tracks,
            timeout=max(0., PLAY_TOTAL_BUDGET_SECONDS - (time.monotonic() - started)))
        if plan is None and reason in {'plan_pending', 'capacity', 'generation_pending', 'closed'}:
            logging.getLogger('uvicorn.error').info(
                'POC_HLS_BOOK stage=play mode=pending book=%s reason=%s', ref, reason)
            raise HTTPException(status_code=503, detail='Book preparation is still running; reopen details and retry')
    if plan is not None:
        full_duration = round(plan.chapters[-1].start + plan.chapters[-1].duration, 3)
        candidate = (TrackPart(1, tracks[0].uri, 0.0, full_duration, info.title),)
        candidate_start = previous_time if previous_time < full_duration - 10 else 0.0
        try:
            session = registry.create(book_id=info.book_id, title=info.title,
                                      tracks=candidate, user_id=USER_ID,
                                      current_time=candidate_start, book_presentation=True)
            # Rewrite every original key/segment URI via the same session-scoped
            # proxy before advertising the new one-track playback contract.
            payload = await run_in_threadpool(rewrite_playlist, plan.document,
                                              tracks[0].uri, session)
            session.book_playlist = payload.encode('utf-8')
            session.book_playlist_segments = plan.segment_count
        except Exception as exc:
            if session is not None:
                registry.close(session.id)
            session = None
            reason = 'rewrite_' + type(exc).__name__
        else:
            chapters = plan.chapters
            playback_tracks = candidate
            duration = full_duration
            start_time = candidate_start
            logging.getLogger('uvicorn.error').info(
                'POC_HLS_BOOK stage=play mode=single_track book=%s chapters=%d audio_tracks=1 segments=%d',
                ref, len(chapters), plan.segment_count)
    if session is None:
        try:
            session = registry.create(book_id=info.book_id, title=info.title,
                                      tracks=tracks, user_id=USER_ID, current_time=start_time)
        except NextoryError as exc:
            raise HTTPException(status_code=503, detail=str(exc)) from exc
        logging.getLogger('uvicorn.error').info(
            'POC_HLS_BOOK stage=play mode=parts book=%s reason=%s audio_tracks=%d', ref, reason, len(tracks))
    library_item = item_json(info, playback_tracks, expanded=True)
    library_item['media']['chapters'] = chapters_json(chapters)
    library_item['media']['numChapters'] = len(chapters)
    now = int(time.time() * 1000)
    utc = datetime.now(timezone.utc)
    result = {
        'id': session.id, 'userId': USER_ID, 'libraryId': LIBRARY_ID,
        'libraryItemId': item_id, 'bookId': media_id_for(info.book_id),
        'episodeId': None, 'mediaType': 'book',
        'mediaMetadata': metadata_json(info, True),
        'chapters': chapters_json(chapters),
        'displayTitle': info.title, 'displayAuthor': ', '.join(info.authors),
        'coverPath': f'/api/items/{item_id}/cover', 'duration': duration,
        'playMethod': 0, 'mediaPlayer': body.get('mediaPlayer') or 'AVPlayer',
        'deviceInfo': body.get('deviceInfo') or {},
        'serverVersion': COMPAT_VERSION, 'date': utc.strftime('%Y-%m-%d'),
        'dayOfWeek': utc.strftime('%A'), 'timeListening': 0.0,
        'startTime': start_time, 'currentTime': start_time,
        'startedAt': now, 'updatedAt': now,
        'audioTracks': [dict(audio_file(info, track), title=track.title,
                             startOffset=track.start, duration=track.duration,
                             mimeType='application/vnd.apple.mpegurl',
                             contentUrl=f'/public/session/{session.id}/track/{track.index}')
                        for track in playback_tracks],
        'libraryItem': library_item,
    }
    if engine is not None:
        fixed_m4b.patch_payload(result, engine)
    history = {key: result[key] for key in (
        'id', 'userId', 'libraryId', 'libraryItemId', 'bookId', 'episodeId', 'mediaType',
        'mediaMetadata', 'displayTitle', 'displayAuthor', 'coverPath', 'duration',
        'playMethod', 'date', 'dayOfWeek', 'startTime', 'currentTime', 'timeListening',
        'startedAt', 'updatedAt')}
    history.update(createdAt=now, playbackFormat='m4b' if engine is not None else 'hls',
                   bookRef=ref)
    try:
        await run_in_threadpool(listening_history.add, info.book_id, history)
    except (OSError, sqlite3.Error):
        logging.warning('Could not save playback history')
    return result


@app.api_route('/public/session/{session_id}/track/{track_index}', methods=['GET', 'HEAD'])
@app.api_route('/public/session/{session_id}/track/{track_index}.m3u8', methods=['GET', 'HEAD'])
async def public_track(session_id: str, track_index: int, req: Request):
    session = registry.get(session_id)
    if not session or not 1 <= track_index <= len(session.tracks):
        raise HTTPException(status_code=404, detail='Playback session or track unavailable')
    if session.fixed_m4b is not None and not req.url.path.endswith('.m3u8'):
        if track_index != 1:
            raise HTTPException(status_code=404, detail='Virtual track unavailable')
        return await session.fixed_m4b.response(req)
    # NEXTORY_SINGLE_PRESENTATION_V1: single logical book item.
    if session.book_playlist is not None:
        # NEXTORY_NAMED_HLS_URL
        if not req.url.path.endswith('.m3u8'):
            location = req.url.path + '.m3u8'
            if req.url.query:
                location += '?' + req.url.query
            logging.getLogger('uvicorn.error').info(
                'POC_HLS_URL mode=redirect_m3u8 status=302')
            return Response(
                status_code=302,
                headers={
                    'Location': location,
                    'Cache-Control': 'no-store'
                }
            )
        logging.getLogger('uvicorn.error').info(
            'POC_HLS_URL mode=named_m3u8 status=200')
        payload = session.book_playlist
        logging.getLogger('uvicorn.error').info(
            'POC_HLS_BOOK stage=root mode=single_track book=%s segments=%d bytes=%d',
            book_ref(session.book_id), session.book_playlist_segments, len(payload))
        return Response(content=b'' if req.method == 'HEAD' else payload,
                        media_type='application/vnd.apple.mpegurl',
                        headers={'Content-Length': str(len(payload)),
                                 'Cache-Control': 'no-store',
                                 'Access-Control-Allow-Origin': '*'})
    # Critical for first-press playback: never block the *first* HLS request
    # on an additional Nextory product/login roundtrip. The session has the
    # signed track URL from the successful POST /play already. Refresh only
    # after the backend's 5-minute product cache has expired.
    if time.monotonic() - session.created > 300:
        try:
            info = await run_in_threadpool(nextory.get_book, session.book_id)
            if track_index > len(info.parts):
                raise NextoryError('Nextory package changed track count')
            session.set_track_root(track_index, info.parts[track_index - 1]['uri'])
        except NextoryError as exc:
            logging.warning('Nextory track URL refresh failed: %s', exc)
            raise HTTPException(status_code=503, detail=str(exc)) from exc
    path = session.root_uri(track_index)
    if not path:
        raise HTTPException(status_code=404, detail='Playback track no longer available')
    # POC_DIRECT_PLAYLIST_EXPERIMENT: HLS manifest body, no 302 redirect.
    token = session.root_tokens.get(track_index)
    if not token:
        raise HTTPException(status_code=404, detail='Playback manifest unavailable')
    logging.getLogger('uvicorn.error').info(
        'PLAY_TEST track=%d manifest_delivery=direct_200', track_index)
    # NEXTORY_HLS_DIRECT_MEDIA_V1: avoid the extra master->variant hop when
    # there is exactly one simple media playlist; do not change segment/key bytes.
    root = session.resource(token)
    if root is not None:
        root_started = time.perf_counter()
        try:
            rewritten, reason, count = await run_in_threadpool(
                direct_media_playlist, nextory.get_manifest, root.url, session)
        except NextoryError:
            rewritten, reason, count = None, 'provider_error', 0
        if rewritten is not None:
            payload = rewritten.encode('utf-8')
            logging.getLogger('uvicorn.error').info(
                'POC_HLS_ROOT mode=direct_media segments=%d elapsed_ms=%d',
                count, int((time.perf_counter()-root_started)*1000))
            return Response(content=b'' if req.method == 'HEAD' else payload,
                            media_type='application/vnd.apple.mpegurl',
                            headers={'Content-Length': str(len(payload)),
                                     'Cache-Control': 'no-store',
                                     'Access-Control-Allow-Origin': '*'})
        logging.getLogger('uvicorn.error').info(
            'POC_HLS_ROOT mode=master reason=%s elapsed_ms=%d',
            reason, int((time.perf_counter()-root_started)*1000))
    return await hls_resource(session_id, token, 'stream.m3u8', req)


@app.api_route('/hls/{session_id}/{resource_token}/{filename}', methods=['GET', 'HEAD'])
async def hls_resource(session_id: str, resource_token: str, filename: str, req: Request):
    session = registry.get(session_id)
    resource = session.resource(resource_token) if session else None
    if not resource:
        raise HTTPException(status_code=404, detail='HLS resource missing or expired')
    if resource.kind == 'manifest':
        try:
            document, final_url = await run_in_threadpool(nextory.get_manifest, resource.url)
            playlist = rewrite_playlist(document, final_url, session)
        except NextoryError as exc:
            logging.warning('HLS playlist unavailable: %s', exc)
            raise HTTPException(status_code=502, detail=str(exc)) from exc
        payload = playlist.encode('utf-8')
        # HLS_FIRSTPLAY_SERVER_V1: anonymous HLS semantics, never URLs/tokens.
        logging.getLogger('uvicorn.error').info(
            'POC_HLS_MANIFEST kind=%s segments=%d endlist=%d encrypted=%d maps=%d bytes=%d',
            'master' if '#EXT-X-STREAM-INF:' in document else 'media',
            document.count('#EXTINF:'), int('#EXT-X-ENDLIST' in document),
            int('#EXT-X-KEY:' in document), int('#EXT-X-MAP:' in document), len(payload))
        return Response(content=b'' if req.method == 'HEAD' else payload,
                        media_type='application/vnd.apple.mpegurl',
                        headers={'Content-Length': str(len(payload)),
                                 'Cache-Control': 'no-store',
                                 'Access-Control-Allow-Origin': '*'})
    try:
        upstream = await run_in_threadpool(
            nextory.remote_get, resource.url, byte_range=req.headers.get('range'))
    except NextoryError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    if upstream.status_code not in (200, 206):
        status = upstream.status_code
        upstream.close()
        raise HTTPException(status_code=502, detail=f'Nextory HLS resource HTTP {status}')
    # HLS_FIRSTPLAY_SERVER_V1: verify delivery for small segments before 200;
    # preserve streaming for large segments. Never put media on disk.
    return await run_in_threadpool(
        build_resource_response, upstream, resource.kind, filename,
        req.method, req.headers.get('range'))


@app.post('/api/session/{session_id}/sync')
async def sync_session(session_id: str, req: Request, _: bool = Depends(authenticated)):
    session = registry.get(session_id)
    if not session:
        raise HTTPException(status_code=404, detail='Playback session unavailable')
    try:
        data = await req.json()
        current = float(data.get('currentTime', session.current_time))
        listened = float(data.get('timeListened', 0.0))
        if not (math.isfinite(current) and 0 <= current <= session.duration + 1 and
                math.isfinite(listened) and 0 <= listened <= 3600):
            raise ValueError('Bad progress time')
        session.current_time = min(current, session.duration)
        session.time_listening += listened
        await run_in_threadpool(progress_store.update, session.book_id,
                                current_time=session.current_time, duration=session.duration)
    except (ValueError, TypeError, AttributeError):
        raise HTTPException(status_code=400, detail='Invalid playback progress')
    except OSError as exc:
        logging.error('Failed to persist audiobook progress: %s', type(exc).__name__)
        raise HTTPException(status_code=503, detail='Progress store not writable') from exc
    await save_history_position(session)
    return Response(content='OK', media_type='text/plain')


async def save_history_position(session):
    try:
        await run_in_threadpool(listening_history.update, session.id,
                                current_time=session.current_time, listened=session.time_listening)
    except (OSError, sqlite3.Error):
        logging.warning('Could not update playback history')


@app.post('/api/session/{session_id}/close')
async def close_session(session_id: str, req: Request, _: bool = Depends(authenticated)):
    session = registry.get(session_id)
    if session:
        try:
            data = await req.json()
            if isinstance(data, dict) and isinstance(data.get('currentTime'), (int, float)):
                current = float(data['currentTime'])
                if math.isfinite(current) and 0 <= current <= session.duration:
                    session.current_time = current
                    await run_in_threadpool(progress_store.update, session.book_id,
                                            current_time=current, duration=session.duration)
        except (ValueError, TypeError, OSError):
            pass  # Last successful /sync already persisted progress.
        await save_history_position(session)
    registry.close(session_id)
    return Response(content='OK', media_type='text/plain')


@app.get('/api/me/listening-stats')
async def listening_stats(_: bool = Depends(authenticated)):
    # AUDIOBOOTH_COMPAT_V1: honest placeholders until session history is implemented.
    return {'totalTime': 0.0, 'today': 0.0, 'days': {}, 'items': {}}


async def history_page(page: int, items_per_page: int, book_id: int | None = None):
    if not 0 <= page <= 10000 or not 1 <= items_per_page <= 100:
        raise HTTPException(status_code=400, detail='Invalid history pagination')
    try:
        return await run_in_threadpool(listening_history.page, page, items_per_page, book_id)
    except (OSError, sqlite3.Error) as exc:
        raise HTTPException(status_code=503, detail='Playback history unavailable') from exc


@app.get('/api/sessions')
async def all_listening_sessions(page: int = 0, itemsPerPage: int = 10,
                                 _: bool = Depends(authenticated)):
    return await history_page(page, itemsPerPage)


@app.get('/api/me/item/listening-sessions/{item_id}')
async def listening_sessions(item_id: str, page: int = 0, itemsPerPage: int = 10,
                             _: bool = Depends(authenticated)):
    return await history_page(page, itemsPerPage, id_to_book(item_id))


@app.get('/api/items/{item_id}/file/{file_id}')
async def virtual_file(item_id: str, file_id: str, _: bool = Depends(authenticated)):
    raise HTTPException(status_code=404, detail='Virtual files require a playback session')


@app.websocket('/socket.io/')
@app.websocket('/socket.io')
async def socket_io_v4(ws: WebSocket):
    origin = ws.headers.get('origin')
    allowed = {'capacitor://localhost', 'ionic://localhost',
               'http://localhost', 'http://127.0.0.1'}
    additional = os.getenv('TEST_ALLOWED_ORIGIN', '').strip()
    if additional:
        allowed.add(additional)
    if origin and origin not in allowed:
        await ws.close(code=1008)
        return
    if ws.query_params.get('EIO') != '4' or ws.query_params.get('transport') != 'websocket':
        await ws.close(code=1003)
        return
    await ws.accept()
    sid = secrets.token_urlsafe(16)
    await ws.send_text('0' + json.dumps({
        'sid': sid, 'upgrades': [], 'pingInterval': 25000,
        'pingTimeout': 20000, 'maxPayload': 1000000}, separators=(',', ':')))
    namespace_connected = False
    authenticated_socket = False
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
                await ws.send_text('2')
                last_ping = time.monotonic()
                ping_pending = True
                continue
            if packet == '3':
                ping_pending = False
            elif packet == '2':
                await ws.send_text('3')
            elif packet.startswith('40'):
                namespace_connected = True
                await ws.send_text('40' + json.dumps({'sid': sid}))
            elif packet.startswith('42') and namespace_connected:
                try:
                    event = json.loads(packet[2:])
                except ValueError:
                    continue
                if isinstance(event, list) and len(event) > 1 and event[0] == 'auth':
                    authenticated_socket = isinstance(event[1], str) and check_token(event[1])
                    if authenticated_socket:
                        await ws.send_text('42' + json.dumps(['init', {'userId': USER_ID}],
                                                           separators=(',', ':')))
                    else:
                        await ws.send_text('42' + json.dumps(['auth_failed', {'message': 'Invalid token'}]))
                elif not authenticated_socket:
                    await ws.send_text('42' + json.dumps(['auth_failed', {'message': 'Auth required'}]))
            elif packet in {'41', '1'}:
                break
    except (WebSocketDisconnect, RuntimeError):
        pass
