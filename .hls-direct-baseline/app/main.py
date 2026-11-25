"""Standalone Audiobookshelf-compatible Nextory virtual-book server, version 6.

Nextory catalogue discovery, live search, and pinned books are indexed. The iOS client requests separate
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
import time
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path
from uuid import NAMESPACE_URL, uuid5

from fastapi import Depends, FastAPI, HTTPException, Request, WebSocket, WebSocketDisconnect
from fastapi.concurrency import run_in_threadpool
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import HTMLResponse, RedirectResponse, Response, StreamingResponse
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from .hls_proxy import registry, rewrite_playlist
from .nextory import BookInfo, CONFIG_PATH, NextoryError, TrackPart, nextory
from .progress import progress_store
from .discovery import (CATEGORIES, CatalogPreview, CatalogIndex, NextoryError as DiscoveryError,
                        REFRESH_SECONDS, catalog_index)

COMPAT_VERSION = '2.25.0'  # Native iOS uses public/session direct-play route since 2.22.
USERNAME = os.getenv('TEST_USERNAME', 'test')
PASSWORD = os.getenv('TEST_PASSWORD', '')
SECRET = os.getenv('TEST_AUTH_SECRET', '')
BOOKS_FILE = Path(os.getenv('NEXTORY_BOOKS_FILE', '/run/nextory/book-ids.txt'))
if len(PASSWORD) < 12 or len(SECRET) < 32:
    raise RuntimeError('Set TEST_PASSWORD (12+ chars) and TEST_AUTH_SECRET (32+ chars)')

LIBRARY_ID = str(uuid5(NAMESPACE_URL, 'nextory-abs-poc:library'))
FOLDER_ID = str(uuid5(NAMESPACE_URL, 'nextory-abs-poc:folder'))
USER_ID = str(uuid5(NAMESPACE_URL, 'nextory-abs-poc:user'))
FIRST_NEXTORY_ID = 7207495
FIRST_BOOK_ID = '572c4427-e49a-579d-b5bb-0b24729778bf'  # Keep v3 item ID stable.
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
        logging.info('POC_TIMING stage=%s status=%s elapsed_ms=%d',
                     label, response.status_code, int((time.perf_counter()-started)*1000))
    response.headers['X-Content-Type-Options'] = 'nosniff'
    response.headers['X-Robots-Tag'] = 'noindex, nofollow'
    response.headers['Referrer-Policy'] = 'no-referrer'
    if ((request.url.path.startswith('/api') and not request.url.path.endswith('/cover'))
            or request.url.path in {'/login', '/status'}):
        response.headers['Cache-Control'] = 'no-store'
    return response


def configured_ids() -> tuple[int, ...]:
    """Re-read the bind-mounted file on every call; no container restart needed."""
    try:
        lines = BOOKS_FILE.read_text('utf-8').splitlines()
    except FileNotFoundError:
        return (FIRST_NEXTORY_ID,)
    except OSError as exc:
        raise NextoryError('Nextory book list is unreadable') from exc
    result = []
    for line in lines:
        text = line.split('#', 1)[0].strip()
        if not text:
            continue
        if not text.isascii() or not text.isdigit() or not 5 <= len(text) <= 12:
            raise NextoryError('Book list contains an invalid product ID')
        number = int(text)
        if number not in result:
            result.append(number)
        if len(result) > 25:
            raise NextoryError('Maximum 25 configured Nextory books in this test')
    return tuple(result)


def item_id_for(book_id: int) -> str:
    return FIRST_BOOK_ID if book_id == FIRST_NEXTORY_ID else str(
        uuid5(NAMESPACE_URL, f'nextory-abs-poc:item:{book_id}'))


def media_id_for(book_id: int) -> str:
    return str(uuid5(NAMESPACE_URL, f'nextory-abs-poc:media:{book_id}'))


def id_to_book(item_id: str) -> int:
    for number in configured_ids():
        if item_id_for(number) == item_id:
            return number
    number = catalog_index.resolve_item(item_id)
    if number is not None:
        return number
    raise HTTPException(status_code=404, detail='Book not found in indexed Nextory catalog')


def _progress_json(book_id: int) -> dict | None:
    current = progress_store.get(book_id)
    if current is None:
        return None
    return {'id': media_id_for(book_id), 'libraryItemId': item_id_for(book_id),
            'episodeId': None, 'mediaItemId': media_id_for(book_id),
            'duration': current['duration'], 'currentTime': current['currentTime'],
            'progress': current['currentTime'] / current['duration'],
            'lastUpdate': current['lastUpdate'], 'isFinished': False,
            'hideFromContinueListening': False, 'finishedAt': None, 'startedAt': None}


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
            'series': ([{'id': str(uuid5(NAMESPACE_URL, 'nextory-series:' + series)),
                        'name': series, 'sequence': info.series_order}] if series else []),
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


def _pinned_previews():
    """No extra external requests needed if a book already has a cached preview."""
    products = []
    for number in configured_ids():
        if catalog_index.has(number):
            continue
        try:
            if hasattr(nextory, 'get_product_preview'):
                item = nextory.get_product_preview(number)
            else:  # Offline protocol fixtures from v4.
                info = nextory.get_book(number)
                item = {'book_id': info.book_id, 'title': info.title,
                        'authors': info.authors, 'narrators': info.narrators,
                        'description': info.description, 'language': info.language,
                        'cover_url': info.cover_url, 'publisher': info.publisher,
                        'isbn': info.isbn, 'published_date': info.published_date,
                        'series_name': info.series_name, 'series_order': info.series_order,
                        'duration': None, 'subtitle': info.subtitle, 'genres': info.genres}
            if item:
                products.append(item)
        except NextoryError as exc:
            logging.warning('Previously pinned product %s unavailable: %s', number, exc)
    if products:
        catalog_index.upsert(products)


def _library_list(shelf: str, page: int, limit: int):
    if shelf == 'all':
        _pinned_previews()
    if shelf.startswith('category:'):
        try:
            catalog_index.ensure_category(shelf.split(':', 1)[1], page, limit)
        except NextoryError as exc:
            logging.warning('Category discovery unavailable (%s): %s', shelf, exc)
            # Keep last good indexed pages; report source error in status.
    return catalog_index.select(shelf, page, limit)


async def dynamic_listing(shelf: str, page: int = 0, limit: int = 20):
    return await run_in_threadpool(_library_list, shelf, page, limit)


async def _discovery_poller():
    # API work happens in a thread, never on the ASGI event loop.
    while True:
        try:
            await run_in_threadpool(catalog_index.refresh_recent)
        except (NextoryError, OSError, ValueError) as exc:
            logging.warning('Nextory catalog refresh failed (preserving last index): %s', exc)
        await asyncio.sleep(REFRESH_SECONDS)


@app.on_event('startup')
async def start_discovery():
    if os.getenv('CATALOG_AUTOSYNC', '1') == '1':
        app.state.catalog_task = asyncio.create_task(_discovery_poller())


@app.on_event('shutdown')
async def stop_discovery():
    task = getattr(app.state, 'catalog_task', None)
    if task:
        task.cancel()
        try:
            await task
        except asyncio.CancelledError:
            pass


def _collect_catalog() -> tuple[list[tuple[BookInfo, tuple[TrackPart, ...]]], dict[int, str]]:
    results, errors = [], {}
    for book_id in configured_ids():
        try:
            info = nextory.get_book(book_id)
            tracks = nextory.get_layout(book_id)
            results.append((info, tracks))
        except NextoryError as exc:
            errors[book_id] = str(exc)
            logging.warning('Catalog item %s temporarily unavailable: %s', book_id, exc)
    return results, errors


async def catalog():
    return await run_in_threadpool(_collect_catalog)


async def book_and_layout(item_id: str) -> tuple[BookInfo, tuple[TrackPart, ...]]:
    book_id = id_to_book(item_id)
    try:
        info, tracks = await run_in_threadpool(lambda: (nextory.get_book(book_id), nextory.get_layout(book_id)))
        return info, tracks
    except NextoryError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc


def filter_data_previews(previews: list[CatalogPreview], total: int) -> dict:
    """Build library filters from local metadata, never from audio manifests."""
    authors = sorted({a for p in previews for a in p.authors})
    return {'authors': [{'id': author_id(a), 'name': a} for a in authors],
            'genres': sorted({g for p in previews for g in p.genres}),
            'tags': [], 'series': [],
            'narrators': sorted({n for p in previews for n in p.narrators}),
            'languages': sorted({p.language for p in previews if p.language}),
            'publishers': sorted({p.publisher for p in previews if p.publisher}),
            'publishedDecades': [], 'bookCount': total,
            'authorCount': len(authors), 'seriesCount': 0, 'podcastCount': 0,
            'numIssues': 0, 'loadedAt': int(time.time() * 1000)}


def collection_json(shelf: str, books: list[dict], *, total: int = 0) -> dict:
    """Real Audiobookshelf Collection shape, with source-backed item previews."""
    return {'id': COLLECTION_IDS[shelf], 'libraryId': LIBRARY_ID, 'userId': USER_ID,
            'name': COLLECTION_NAMES[shelf], 'description': None,
            'books': books, 'numBooks': total,
            'lastUpdate': STARTED_MS, 'createdAt': STARTED_MS}


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
    meta['series'] = ([{'id': str(uuid5(NAMESPACE_URL, 'nextory-series:' + preview.series_name)),
                       'name': preview.series_name, 'sequence': preview.series_order}]
                      if preview.series_name else [])
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
    return await run_in_threadpool(catalog_index.select, 'all', 0, 4000)


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
    try:
        books = list(configured_ids())
    except NextoryError:
        books = []
    return {'status': 'ok', 'audioEnabled': CONFIG_PATH.is_file(),
            'mode': 'nextory-multiple-hls-tracks', 'configMounted': CONFIG_PATH.is_file(),
            'configuredBookIds': books}


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
@app.get('/api/me/items-in-progress')
async def progress(_: bool = Depends(authenticated)):
    return [p for n in progress_store.all() if (p := _progress_json(n))]


@app.get('/api/me/progress/{item_id}')
async def get_progress(item_id: str, _: bool = Depends(authenticated)):
    return _progress_json(id_to_book(item_id)) or {}


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
        try:
            _pinned_previews()
        except NextoryError as exc:
            logging.warning('Pinned Nextory previews unavailable: %s', exc)
        rows = []
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
        return [collection_json(shelf, [summary_item(p) for p in catalog_index.select(shelf, 0, 4)[0]],
                                total=catalog_index.select(shelf, 0, 1)[1])
                for shelf, _ in chosen]
    results = await run_in_threadpool(load)
    return {'results': results, 'total': len(COLLECTION_SHELVES),
            'page': page, 'limit': limit, 'minified': bool(minified), 'sortDesc': False}


@app.get('/api/collections')
async def all_collections(_: bool = Depends(authenticated)):
    def load():
        return [collection_json(shelf, [summary_item(p) for p in catalog_index.select(shelf, 0, 4)[0]],
                                total=catalog_index.select(shelf, 0, 1)[1])
                for shelf, _ in COLLECTION_SHELVES]
    return {'collections': await run_in_threadpool(load)}


@app.get('/api/collections/{collection_id}')
async def collection_detail(collection_id: str, _: bool = Depends(authenticated)):
    shelf = COLLECTION_BY_ID.get(collection_id)
    if shelf is None:
        raise HTTPException(status_code=404, detail='Collection not found')
    # The collection list is instant. Opening a specific category hydrates
    # only that category (and only its first metadata page).
    previews, count = await dynamic_listing(shelf, 0, 40)
    return collection_json(shelf, [summary_item(p) for p in previews], total=count)


@app.get('/api/libraries/{library_id}/authors')
async def authors(library_id: str, _: bool = Depends(authenticated)):
    shelf = check_library(library_id)
    summaries, _ = await lightweight_catalog()
    by_id = {p.book_id: p.authors for p in summaries}
    counts = {}
    for names in by_id.values():
        for name in names:
            counts[name] = counts.get(name, 0) + 1
    return {'authors': [{'id': author_id(name), 'name': name, 'numBooks': count}
                        for name, count in sorted(counts.items())]}


@app.get('/api/authors/{au_id}')
async def author(au_id: str, _: bool = Depends(authenticated)):
    summaries, _ = await lightweight_catalog()
    result = {p.book_id: summary_item(p) for p in summaries}
    for item in result.values():
        meta = item['media']['metadata']
        names = [x.strip() for x in meta.get('authorName', '').split(',') if x.strip()]
        if any(author_id(name) == au_id for name in names):
            name = next(name for name in names if author_id(name) == au_id)
            matching = [v for v in result.values() if name in
                        [x.strip() for x in v['media']['metadata'].get('authorName', '').split(',')]]
            return {'id': au_id, 'name': name, 'libraryItems': matching[:100]}
    raise HTTPException(status_code=404, detail='Author not found')


@app.get('/api/libraries/{library_id}/search')
async def search(library_id: str, q: str = '', _: bool = Depends(authenticated)):
    check_library(library_id)
    query = q.strip()
    if not query:
        return {'book': [], 'authors': [], 'series': [], 'tags': []}
    if len(query) > 100:
        raise HTTPException(status_code=400, detail='Search is too long')
    try:
        previews = await run_in_threadpool(nextory.search_catalog, query, 0, 30)
        if previews:
            await run_in_threadpool(catalog_index.upsert, previews)
        entries = [CatalogPreview.from_dict(p) for p in previews]
    except (NextoryError, AttributeError) as exc:
        logging.warning('Nextory live search unavailable: %s', exc)
        entries, _ = await dynamic_listing('all', 0, 1000)
        entries = [p for p in entries if query.casefold() in
                   (' '.join((p.title, *p.authors, p.series_name or ''))).casefold()][:30]
    return {'book': [{'libraryItem': summary_item(preview),
                      'matchKey': 'title', 'matchText': preview.title}
                     for preview in entries],
            'authors': [], 'series': [], 'tags': [], 'episodes': [], 'podcast': [],
            'narrators': []}


@app.get('/api/poc/discovery-status')
async def discovery_status(_: bool = Depends(authenticated)):
    return {'mode': 'dynamic-nextory-discovery',
            'visibleLibraries': 1, 'collections': len(COLLECTION_SHELVES),
            'fastMetadata': True, 'initialHlsRoundTripRemoved': True,
            'search': 'nextory-discovery-api',
            'categories': [code for code, _, _ in CATEGORIES],
            'automaticRefresh': os.getenv('CATALOG_AUTOSYNC', '1') == '1',
            **(await run_in_threadpool(catalog_index.statistics))}


@app.post('/api/poc/discovery-refresh')
async def discovery_refresh(_: bool = Depends(authenticated)):
    try:
        return await run_in_threadpool(catalog_index.refresh_recent)
    except NextoryError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc


@app.get('/api/poc/catalog-status')
async def catalog_status(_: bool = Depends(authenticated)):
    books, errors = await catalog()
    return {'configuredIds': configured_ids(),
            'books': [{'id': info.book_id, 'title': info.title,
                       'authors': info.authors, 'parts': len(tracks),
                       'duration': round(tracks[-1].start + tracks[-1].duration, 3)}
                      for info, tracks in books], 'errors': errors}


@app.get('/api/items/{item_id}')
async def item(item_id: str, _: bool = Depends(authenticated)):
    book_id = id_to_book(item_id)
    # The native iPhone detail page needs metadata and cover, not the complete
    # HLS timeline. Product/cover data is already indexed; defer HLS probes to Play.
    preview = await run_in_threadpool(catalog_index.lookup, book_id)
    if preview is None:
        try:
            mapped = await run_in_threadpool(nextory.get_product_preview, book_id)
            if not mapped:
                raise NextoryError('Nextory audiobook metadata unavailable')
            await run_in_threadpool(catalog_index.upsert, [mapped])
            preview = CatalogPreview.from_dict(mapped)
        except NextoryError as exc:
            raise HTTPException(status_code=503, detail=str(exc)) from exc
    # After playback, reuse real full track metadata already in memory.
    try:
        cached = nextory.peek_book_and_layout(book_id)
    except AttributeError:
        cached = None
    if cached:
        info, tracks = cached
        return item_json(info, tracks, expanded=True)
    return preview_detail(preview)


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
    info, tracks = await book_and_layout(item_id)
    try:
        body = await req.json()
    except (ValueError, TypeError):
        body = {}
    if not isinstance(body, dict):
        body = {}
    duration = round(tracks[-1].start + tracks[-1].duration, 3)
    previous = progress_store.get(info.book_id)
    start_time = (float(previous['currentTime']) if previous else 0.0)
    if start_time >= duration - 10:
        start_time = 0.0
    try:
        session = registry.create(book_id=info.book_id, title=info.title,
                                  tracks=tracks, user_id=USER_ID, current_time=start_time)
    except NextoryError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc
    now = int(time.time() * 1000)
    utc = datetime.now(timezone.utc)
    return {
        'id': session.id, 'userId': USER_ID, 'libraryId': LIBRARY_ID,
        'libraryItemId': item_id, 'bookId': media_id_for(info.book_id),
        'episodeId': None, 'mediaType': 'book',
        'mediaMetadata': metadata_json(info, True),
        'chapters': chapters_json(tracks),
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
                        for track in tracks],
        'libraryItem': item_json(info, tracks, expanded=True),
    }


@app.api_route('/public/session/{session_id}/track/{track_index}', methods=['GET', 'HEAD'])
async def public_track(session_id: str, track_index: int):
    session = registry.get(session_id)
    if not session or not 1 <= track_index <= len(session.tracks):
        raise HTTPException(status_code=404, detail='Playback session or track unavailable')
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
    return RedirectResponse(path, status_code=302,
                            headers={'Cache-Control': 'no-store'})


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
    content_type = upstream.headers.get('Content-Type', 'application/octet-stream').split(';', 1)[0]
    if resource.kind == 'key':
        content_type = 'application/octet-stream'
    elif content_type in {'', 'application/octet-stream'}:
        content_type = ('video/mp2t' if filename.endswith('.ts') else
                        'audio/aac' if filename.endswith('.aac') else 'application/octet-stream')
    headers = {'Cache-Control': 'no-store', 'Accept-Ranges': 'bytes'}
    for key in ('Content-Length', 'Content-Range', 'ETag', 'Last-Modified'):
        if value := upstream.headers.get(key):
            headers[key] = value
    if req.method == 'HEAD':
        upstream.close()
        return Response(content=b'', media_type=content_type,
                        status_code=upstream.status_code, headers=headers)

    def chunks():
        try:
            for chunk in upstream.iter_content(chunk_size=64 * 1024):
                if chunk:
                    yield chunk
        finally:
            upstream.close()
    return StreamingResponse(chunks(), media_type=content_type,
                             status_code=upstream.status_code, headers=headers)


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
    return Response(content='OK', media_type='text/plain')


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
    registry.close(session_id)
    return Response(content='OK', media_type='text/plain')


@app.get('/api/me/listening-stats')
async def listening_stats(_: bool = Depends(authenticated)):
    return {'totalTime': 0, 'items': []}


@app.get('/api/me/item/listening-sessions/{item_id}')
async def listening_sessions(item_id: str, _: bool = Depends(authenticated)):
    return []


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
