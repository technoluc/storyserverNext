"""Temporary, provider-independent playback format controls for the test server."""
from __future__ import annotations

import copy
import logging
import time
from pathlib import Path
from uuid import uuid4, uuid5, NAMESPACE_URL
from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.responses import FileResponse, RedirectResponse, Response

MARKER = 'NEXTORY_FORMAT_CONTROL_V1'
ROOT = Path(__file__).with_name('format_control_media')
LIBRARY_ID = str(uuid5(NAMESPACE_URL, 'nextory-format-control:v1:library'))
FOLDER_ID = str(uuid5(NAMESPACE_URL, 'nextory-format-control:v1:folder'))
MODES = ('direct', 'ts', 'fmp4', 'virtual')
TITLES = dict(zip(MODES, ('A - Direct M4A', 'B - HLS MPEG-TS', 'C - HLS fMP4', 'D - Virtual Indexed M4A')))
DURATION = 36.0
LOG = logging.getLogger('uvicorn.error')
from .virtual_range import VirtualRange  # NEXTORY_VIRTUAL_RANGE_V1
VIRTUAL = VirtualRange(ROOT/'virtual')
_sessions = {}
SESSION_TTL = 3600
MAX_SESSIONS = 24


def _prune():
    now = time.monotonic()
    for sid, (_, created) in list(_sessions.items()):
        if now - created > SESSION_TTL:
            _sessions.pop(sid, None)


def is_session(sid):
    _prune()
    return sid in _sessions


def track(sid, index, req):
    if not is_session(sid) or index != 1:
        raise HTTPException(404, 'Control session unavailable')
    mode, _ = _sessions[sid]
    LOG.info('POC_FORMAT_CONTROL mode=%s event=track method=%s range=%d', mode, req.method, int('range' in req.headers))
    if mode == 'virtual':
        return VIRTUAL.response(req)
    if mode == 'direct':
        return FileResponse(ROOT/'control.m4a', media_type='audio/mp4', headers={'Cache-Control':'no-store'})
    return RedirectResponse(f'/hls/{sid}/output.m3u8', status_code=302, headers={'Cache-Control':'no-store'})


def sync(sid, close=False):
    if close:
        _sessions.pop(sid, None)
    return Response('OK', media_type='text/plain')


def install(m):
    """Register exact synthetic routes, before the normal variable routes.

    The normal Nextory item/play routes, provider, registry and progress store
    are untouched except for dispatching the independently scoped control sessions.
    """
    if LIBRARY_ID in m.LIBRARY_TO_SHELF:
        raise RuntimeError('Control library already installed')
    if not (ROOT/'control.m4a').is_file():
        raise RuntimeError('Control media missing')
    m.LIBRARY_TO_SHELF[LIBRARY_ID] = 'format-control'
    m.LIBRARY_NAMES[LIBRARY_ID] = 'Playback format test'
    old_library_json = m.library_json

    def library_json(library_id=m.LIBRARY_ID):
        data = old_library_json(library_id)
        if library_id == LIBRARY_ID:
            data['folders'] = [{'id': FOLDER_ID, 'fullPath': '/virtual/format-control', 'libraryId': LIBRARY_ID}]
        return data
    m.library_json = library_json

    router = APIRouter()
    protected = [Depends(m.authenticated)]
    books = {}
    chapters = [{'id': i+1, 'start': i*12.0, 'end': (i+1)*12.0, 'title': f'Test chapter {i+1}'} for i in range(3)]
    for i, mode in enumerate(MODES):
        size = VIRTUAL.size if mode == 'virtual' else (ROOT/'control.m4a').stat().st_size
        # Negative IDs are disjoint from real Nextory product IDs.
        info = m.BookInfo(-91001-i, TITLES[mode], ('Format control',), (),
                          '36 seconds of locally generated test audio. No Nextory media.',
                          'en', '', None, None, None, None, None, None, (), ())
        part = m.TrackPart(1, '', 0., DURATION, info.title)
        data = m.item_json(info, (part,), expanded=True)
        data['libraryId'] = LIBRARY_ID
        data['folderId'] = FOLDER_ID
        data['path'] = '/virtual/format-control/'+mode
        data['size'] = size
        media = data['media']
        media.update({'size': size, 'numChapters': len(chapters), 'chapters': copy.deepcopy(chapters)})
        for af in media['audioFiles'] + media['tracks']:
            af['metadata'].update({'filename': 'control.m4a', 'ext': '.m4a', 'size': size,
                                   'path': data['path']+'/control.m4a', 'relPath': 'control.m4a'})
            af['bitRate'] = 64000
            af['codec'] = 'aac'
            if 'mimeType' in af:
                af['mimeType'] = 'audio/mp4'
        books[mode] = data

    async def list_items(page: int=0, limit: int=20, minified: int=1):
        if page < 0 or limit < 1 or limit > 100:
            raise HTTPException(400, 'Invalid pagination')
        selected = list(books.values())[page*limit:(page+1)*limit]
        return {'results': selected, 'total': len(books), 'limit': limit, 'page': page, 'minified': bool(minified)}

    async def get_library(include: str=''):
        data = library_json(LIBRARY_ID)
        if 'filterdata' in include.split(','):
            return {'library': data, 'filterdata': m.filter_data_previews([], len(books)), 'issues':0, 'numUserPlaylists':0}
        return data

    async def filters():
        return m.filter_data_previews([], len(books))

    async def home():
        return [{'id':'format-control-v1-home','label':'Playback format test','type':'book','entities':list(books.values()),'total':len(books)}]

    async def empty_list(page: int=0, limit: int=20):
        return {'results':[], 'total':0, 'page':page, 'limit':limit, 'minified':True, 'sortDesc':False}

    async def empty_authors():
        return {'authors': []}

    async def search(q: str=''):
        query=q.strip().casefold()
        return {'book':[{'libraryItem':b, 'matchKey':'title','matchText':TITLES[mode]} for mode,b in books.items() if query and query in TITLES[mode].casefold()], 'authors':[], 'series':[], 'tags':[], 'episodes':[], 'podcast':[], 'narrators':[]}

    base = '/api/libraries/'+LIBRARY_ID
    for suffix, handler in [('',get_library),('/items',list_items),('/filterdata',filters),('/personalized',home),('/collections',empty_list),('/series',empty_list),('/authors',empty_authors),('/search',search)]:
        router.add_api_route(base+suffix, handler, methods=['GET'], dependencies=protected)

    async def no_progress():
        raise HTTPException(404, 'No saved control progress')

    async def no_write():
        return Response('OK', media_type='text/plain')

    async def history():
        return {'numPages':0,'page':0,'itemsPerPage':10,'sessions':[]}

    async def cover():
        return FileResponse(ROOT/'cover.jpg', media_type='image/jpeg')

    def make_handlers(mode):
        async def detail(expanded: int=0):
            return books[mode]

        async def play(req: Request):
            try:
                body = await req.json()
            except (ValueError, TypeError):
                body = {}
            if not isinstance(body, dict):
                body = {}
            _prune()
            while len(_sessions)>=MAX_SESSIONS:
                _sessions.pop(next(iter(_sessions)))
            sid = str(uuid4())
            _sessions[sid] = (mode, time.monotonic())
            data = copy.deepcopy(books[mode])
            media = data['media']
            audio_track = copy.deepcopy(media['tracks'][0])
            audio_track['contentUrl'] = f'/public/session/{sid}/track/1'
            if mode in ('ts', 'fmp4'):
                audio_track['contentUrl'] = f'/hls/{sid}/output.m3u8'
                audio_track['mimeType'] = 'application/vnd.apple.mpegurl'
                audio_track['metadata'].update({'filename':'output.m3u8','ext':'.m3u8','size':0,'path':'/virtual/format-control/output.m3u8','relPath':'output.m3u8'})
            utc = datetime.now(timezone.utc)
            now = int(time.time()*1000)
            LOG.info('POC_FORMAT_CONTROL mode=%s event=play tracks=1 chapters=3', mode)
            return {'id':sid, 'userId':m.USER_ID, 'libraryId':LIBRARY_ID,
                    'libraryItemId':data['id'], 'bookId':media['id'], 'episodeId':None, 'mediaType':'book',
                    'mediaMetadata':media['metadata'], 'chapters':copy.deepcopy(chapters),
                    'displayTitle':TITLES[mode], 'displayAuthor':'Format control',
                    'coverPath':media['coverPath'], 'duration':DURATION, 'playMethod':0 if mode in ('direct', 'virtual') else 2,
                    'mediaPlayer':body.get('mediaPlayer') or 'AVPlayer', 'deviceInfo':body.get('deviceInfo') or {},
                    'serverVersion':m.COMPAT_VERSION, 'date':utc.strftime('%Y-%m-%d'), 'dayOfWeek':utc.strftime('%A'),
                    'timeListening':0.,'startTime':0.,'currentTime':0.,'startedAt':now,'updatedAt':now,
                    'audioTracks':[audio_track], 'libraryItem':data}
        return detail, play

    for mode, data in books.items():
        iid = data['id']
        base = '/api/items/'+iid
        detail, play = make_handlers(mode)
        router.add_api_route(base, detail, methods=['GET'], dependencies=protected)
        router.add_api_route(base+'/play', play, methods=['POST'], dependencies=protected)
        router.add_api_route(base+'/cover', cover, methods=['GET','HEAD'])
        router.add_api_route('/api/me/progress/'+iid, no_progress, methods=['GET'], dependencies=protected)
        router.add_api_route('/api/me/progress/'+iid, no_write, methods=['PATCH','DELETE'], dependencies=protected)
        router.add_api_route('/api/me/item/listening-sessions/'+iid, history, methods=['GET'], dependencies=protected)

    async def hls(sid: str, filename: str, req: Request):
        if not is_session(sid):
            raise HTTPException(404, 'Control session unavailable')
        mode, _ = _sessions[sid]
        if mode not in ('ts','fmp4') or filename not in {p.name for p in (ROOT/mode).iterdir() if p.is_file()}:
            raise HTTPException(404, 'Control media unavailable')
        suffix = Path(filename).suffix
        mime = {'.m3u8':'application/vnd.apple.mpegurl','.ts':'video/mp2t','.mp4':'audio/mp4','.m4s':'video/iso.segment'}.get(suffix)
        if mime is None:
            raise HTTPException(404, 'Control media unavailable')
        LOG.info('POC_FORMAT_CONTROL mode=%s event=%s method=%s range=%d', mode, 'playlist' if suffix=='.m3u8' else 'segment', req.method, int('range' in req.headers))
        return FileResponse(ROOT/mode/filename, media_type=mime, headers={'Cache-Control':'no-store'})

    router.add_api_route('/hls/{sid}/{filename}', hls, methods=['GET','HEAD'])
    # Exact paths must precede generic library/item routes. Other routes remain unchanged.
    previous_count = len(m.app.router.routes)
    m.app.include_router(router)
    routes = m.app.router.routes
    routes[:] = routes[previous_count:]+routes[:previous_count]
    LOG.info('POC_FORMAT_CONTROL status=ready titles=4 provider_calls=0')
