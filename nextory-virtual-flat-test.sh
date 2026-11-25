#!/usr/bin/env bash
# Synthetic ten-hour classic non-fragmented virtual M4A. No Nextory media.
# Alleen nextory-abs-poc-test; geen wijziging aan de originele v6 of AudioBooth.
# Gebruik: bash nextory-virtual-flat-test.sh apply|rollback
set -euo pipefail
MODE="${1:-apply}"
TEST="${NEXTORY_TEST_DIR:-$HOME/nextory-abs-virtual-poc-test}"
ORIGINAL="${NEXTORY_ORIGINAL_DIR:-$HOME/nextory-abs-virtual-poc}"
PROJECT='nextory-abs-test'
SERVICE='nextory-abs-poc'
OFFLINE="${_NEXTORY_OFFLINE_VERIFY:-0}"
clear 2>/dev/null || true

echo '=== 1. VEILIGHEIDSCONTROLE ==='
case "$MODE" in apply|rollback) ;; *) echo 'ERROR: Gebruik apply of rollback.'; exit 1;; esac
for f in docker-compose.yml docker-compose.test.yml app/main.py app/nextory.py app/hls_proxy.py app/prewarm.py app/hls_delivery.py app/hls_root.py app/hls_book.py; do
  if [ ! -f "$TEST/$f" ]; then echo "ERROR: Testbestand ontbreekt: $f"; exit 1; fi
done
if [ ! -f "$ORIGINAL/app/main.py" ]; then echo 'ERROR: Originele broncode ontbreekt.'; exit 1; fi
if [ "$OFFLINE" != 1 ]; then
  original_running="$(docker inspect -f '{{.State.Running}}' nextory-abs-poc 2>/dev/null || true)"
  test_running="$(docker inspect -f '{{.State.Running}}' nextory-abs-poc-test 2>/dev/null || true)"
  test_project="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' nextory-abs-poc-test 2>/dev/null || true)"
  test_image="$(docker inspect -f '{{.Config.Image}}' nextory-abs-poc-test 2>/dev/null || true)"
  port_owner="$(docker ps --filter publish=13378 --format '{{.Names}}')"
  if [ "$original_running" != false ] || \
     { [ "$MODE" = apply ] && [ "$test_running" != true ]; } || \
     [ "$test_project" != "$PROJECT" ] || [ "$test_image" != 'nextory-abs-poc-test:dev' ] || \
     { [ "$port_owner" != 'nextory-abs-poc-test' ] && { [ "$MODE" != rollback ] || [ -n "$port_owner" ]; }; }; then
    echo 'ERROR: Origineel/testomgeving/poort kan niet veilig worden bevestigd.'; exit 1
  fi
fi
NEXTORY_TEST="$TEST" NEXTORY_ORIGINAL="$ORIGINAL" NEXTORY_OFFLINE="$OFFLINE" python3 - <<'PY'
import json, os, subprocess, sys
from pathlib import Path
test = Path(os.environ['NEXTORY_TEST']).resolve(strict=True)
original = Path(os.environ['NEXTORY_ORIGINAL']).resolve(strict=True)
if test == original or original in test.parents or test in original.parents:
    sys.exit('ERROR: Test- en origineelpad overlappen.')
if os.environ['NEXTORY_OFFLINE'] == '1':
    print('OFFLINE_VALIDATION=YES')
else:
    cmd = ['docker','compose','-p','nextory-abs-test','-f',str(test/'docker-compose.yml'),
           '-f',str(test/'docker-compose.test.yml'),'config','--format','json']
    p = subprocess.run(cmd, cwd=test, capture_output=True, text=True)
    if p.returncode: sys.exit('ERROR: Compose-configuratie kon niet gecontroleerd worden.')
    try:
        cfg = json.loads(p.stdout)
        s = cfg['services']['nextory-abs-poc']
        assert cfg['name'] == 'nextory-abs-test'
        assert s['container_name'] == 'nextory-abs-poc-test'
        assert s['image'] == 'nextory-abs-poc-test:dev'
        b = s['build']
        context = Path(b['context'] if isinstance(b, dict) else b).resolve(strict=True)
        assert context == test
        assert not s.get('volumes_from') and not s.get('network_mode')
        ports = s['ports']
        assert len(ports) == 1 and str(ports[0]['published']) == '13378' and int(ports[0]['target']) == 8000
        for m in s.get('volumes', []):
            if m['type'] == 'bind':
                src = Path(m['source']).resolve()
                if src == original or original in src.parents:
                    assert m.get('read_only') and m['target'] == '/run/nextory'
                if not m.get('read_only'):
                    assert src == test or test in src.parents
            elif m['type'] == 'volume':
                volume = cfg.get('volumes',{}).get(m.get('source'),{})
                assert not volume.get('external', False)
                assert volume.get('name','').startswith('nextory-abs-test_')
        for net in (s.get('networks') or {}):
            info = cfg.get('networks',{}).get(net,{})
            assert not info.get('external')
            assert not info.get('name') or info['name'].startswith('nextory-abs-test_')
    except (AssertionError, KeyError, ValueError, TypeError, OSError):
        sys.exit('ERROR: Compose-isolatie niet aangetoond.')
    print('COMPOSE_ISOLATION=PASS')
PY
printf 'MODE=%s\nORIGINAL=STOPPED_AND_UNMODIFIED\nPORT=13378\n' "$MODE"
echo

echo '=== 2. VIRTUAL CLASSIC M4A ==='
python3 - "$TEST" "$ORIGINAL" "$MODE" <<'PYCODE'
BASELINE_SHA = '9c3624d9ebc753fb124a9123cd24f389a302ad857442aa85047c90667f871099'
REQUIREMENTS = {'virtual_long.py': 'f5b4e85effad0dc66dff6a66476e5790b609c20626aa9b9cd7befeb3827f5849', 'virtual_range.py': '7967ca1ac90a4d932809748724f1f94f377950083831f79c7f993bf12546ddd0', 'format_control_media/long/init.bin': '0245a4f96f5d6ed7fc017d617331cdf9cdcdd1f11e27fde4d064dfea1223549d', 'format_control_media/long/sha256.json': 'cf6380dc92dfa0596caf1f04342cfdb7febb25c126a7f59cb6e81448c51206f0', 'format_control_media/long/tone-330.bin': '2d79c4b7bee164df2a9abe623eb65992e24ec788250488c23074a159f9272fee', 'format_control_media/long/tone-440.bin': '0857983d8ed57ccff8b2c437eb1ed61ce357d987cf32794601c77caeec6900cd', 'format_control_media/long/tone-550.bin': '65c1ad0f470b829f41fc5a30235d68b01f44b3ebcdb3b65271c565384d9b2399', 'format_control_media/long/tone-660.bin': 'c71d4b46779d52871469d00f9be275edd23395606a667f5a7e7e4bf42539411f', 'format_control_media/long/tone-770.bin': '9a14cecb11aaa5a3ba43e47ee5f59a16d20651fbaa661dbedc54f4f39043476b'}
CONTROL = '"""Temporary, provider-independent playback format controls for the test server."""\nfrom __future__ import annotations\n\nimport copy\nimport logging\nimport time\nfrom pathlib import Path\nfrom uuid import uuid4, uuid5, NAMESPACE_URL\nfrom datetime import datetime, timezone\n\nfrom fastapi import APIRouter, Depends, HTTPException, Request\nfrom fastapi.responses import FileResponse, RedirectResponse, Response\n\nMARKER = \'NEXTORY_FORMAT_CONTROL_V1\'\nROOT = Path(__file__).with_name(\'format_control_media\')\nLIBRARY_ID = str(uuid5(NAMESPACE_URL, \'nextory-format-control:v1:library\'))\nFOLDER_ID = str(uuid5(NAMESPACE_URL, \'nextory-format-control:v1:folder\'))\nMODES = (\'direct\', \'ts\', \'fmp4\', \'virtual\', \'long\', \'flat\')\nTITLES = dict(zip(MODES, (\'A - Direct M4A\', \'B - HLS MPEG-TS\', \'C - HLS fMP4\', \'D - Virtual Indexed M4A\', \'E - Virtual 10 Hour M4A\', \'F - Virtual Classic 10 Hour M4A\')))\nDURATION = 36.0\nLOG = logging.getLogger(\'uvicorn.error\')\nfrom .virtual_range import VirtualRange  # NEXTORY_VIRTUAL_RANGE_V1\nVIRTUAL = VirtualRange(ROOT/\'virtual\')\nfrom .virtual_long import LongVirtual  # NEXTORY_VIRTUAL_LONG_V1\nLONG = LongVirtual(ROOT/\'long\')\nfrom .virtual_flat import FlatVirtual  # NEXTORY_VIRTUAL_FLAT_V1\nFLAT = FlatVirtual(LONG)\n_sessions = {}\nSESSION_TTL = 3600\nMAX_SESSIONS = 24\n\n\ndef _prune():\n    now = time.monotonic()\n    for sid, (_, created) in list(_sessions.items()):\n        if now - created > SESSION_TTL:\n            _sessions.pop(sid, None)\n\n\ndef is_session(sid):\n    _prune()\n    return sid in _sessions\n\n\ndef track(sid, index, req):\n    if not is_session(sid) or index != 1:\n        raise HTTPException(404, \'Control session unavailable\')\n    mode, _ = _sessions[sid]\n    LOG.info(\'POC_FORMAT_CONTROL mode=%s event=track method=%s range=%d\', mode, req.method, int(\'range\' in req.headers))\n    if mode == \'flat\':\n        return FLAT.response(req)\n    if mode == \'long\':\n        return LONG.response(req)\n    if mode == \'virtual\':\n        return VIRTUAL.response(req)\n    if mode == \'direct\':\n        return FileResponse(ROOT/\'control.m4a\', media_type=\'audio/mp4\', headers={\'Cache-Control\':\'no-store\'})\n    return RedirectResponse(f\'/hls/{sid}/output.m3u8\', status_code=302, headers={\'Cache-Control\':\'no-store\'})\n\n\ndef sync(sid, close=False):\n    if close:\n        _sessions.pop(sid, None)\n    return Response(\'OK\', media_type=\'text/plain\')\n\n\ndef install(m):\n    """Register exact synthetic routes, before the normal variable routes.\n\n    The normal Nextory item/play routes, provider, registry and progress store\n    are untouched except for dispatching the independently scoped control sessions.\n    """\n    if LIBRARY_ID in m.LIBRARY_TO_SHELF:\n        raise RuntimeError(\'Control library already installed\')\n    if not (ROOT/\'control.m4a\').is_file():\n        raise RuntimeError(\'Control media missing\')\n    m.LIBRARY_TO_SHELF[LIBRARY_ID] = \'format-control\'\n    m.LIBRARY_NAMES[LIBRARY_ID] = \'Playback format test\'\n    old_library_json = m.library_json\n\n    def library_json(library_id=m.LIBRARY_ID):\n        data = old_library_json(library_id)\n        if library_id == LIBRARY_ID:\n            data[\'folders\'] = [{\'id\': FOLDER_ID, \'fullPath\': \'/virtual/format-control\', \'libraryId\': LIBRARY_ID}]\n        return data\n    m.library_json = library_json\n\n    router = APIRouter()\n    protected = [Depends(m.authenticated)]\n    books = {}\n    short_chapters = [{\'id\': i+1, \'start\': i*12.0, \'end\': (i+1)*12.0, \'title\': f\'Test chapter {i+1}\'} for i in range(3)]\n    for i, mode in enumerate(MODES):\n        size = FLAT.size if mode == \'flat\' else LONG.size if mode == \'long\' else VIRTUAL.size if mode == \'virtual\' else (ROOT/\'control.m4a\').stat().st_size\n        duration = FLAT.duration if mode == \'flat\' else LONG.duration if mode == \'long\' else DURATION\n        chapters = FLAT.chapters if mode == \'flat\' else LONG.chapters if mode == \'long\' else short_chapters\n        # Negative IDs are disjoint from real Nextory product IDs.\n        info = m.BookInfo(-91001-i, TITLES[mode], (\'Format control\',), (),\n                          (\'10 hours of on-demand synthetic AAC with a complete classic MP4 sample table. No Nextory media.\' if mode == \'flat\' else \'10 hours of on-demand synthetic AAC fragments; 5 different tones. No Nextory media.\' if mode == \'long\' else \'36 seconds of locally generated test audio. No Nextory media.\'),\n                          \'en\', \'\', None, None, None, None, None, None, (), ())\n        part = m.TrackPart(1, \'\', 0., duration, info.title)\n        data = m.item_json(info, (part,), expanded=True)\n        data[\'libraryId\'] = LIBRARY_ID\n        data[\'folderId\'] = FOLDER_ID\n        data[\'path\'] = \'/virtual/format-control/\'+mode\n        data[\'size\'] = size\n        media = data[\'media\']\n        media.update({\'size\': size, \'numChapters\': len(chapters), \'chapters\': copy.deepcopy(chapters)})\n        for af in media[\'audioFiles\'] + media[\'tracks\']:\n            af[\'metadata\'].update({\'filename\': \'control.m4a\', \'ext\': \'.m4a\', \'size\': size,\n                                   \'path\': data[\'path\']+\'/control.m4a\', \'relPath\': \'control.m4a\'})\n            af[\'bitRate\'] = 64000\n            af[\'codec\'] = \'aac\'\n            if \'mimeType\' in af:\n                af[\'mimeType\'] = \'audio/mp4\'\n        books[mode] = data\n\n    async def list_items(page: int=0, limit: int=20, minified: int=1):\n        if page < 0 or limit < 1 or limit > 100:\n            raise HTTPException(400, \'Invalid pagination\')\n        selected = list(books.values())[page*limit:(page+1)*limit]\n        return {\'results\': selected, \'total\': len(books), \'limit\': limit, \'page\': page, \'minified\': bool(minified)}\n\n    async def get_library(include: str=\'\'):\n        data = library_json(LIBRARY_ID)\n        if \'filterdata\' in include.split(\',\'):\n            return {\'library\': data, \'filterdata\': m.filter_data_previews([], len(books)), \'issues\':0, \'numUserPlaylists\':0}\n        return data\n\n    async def filters():\n        return m.filter_data_previews([], len(books))\n\n    async def home():\n        return [{\'id\':\'format-control-v1-home\',\'label\':\'Playback format test\',\'type\':\'book\',\'entities\':list(books.values()),\'total\':len(books)}]\n\n    async def empty_list(page: int=0, limit: int=20):\n        return {\'results\':[], \'total\':0, \'page\':page, \'limit\':limit, \'minified\':True, \'sortDesc\':False}\n\n    async def empty_authors():\n        return {\'authors\': []}\n\n    async def search(q: str=\'\'):\n        query=q.strip().casefold()\n        return {\'book\':[{\'libraryItem\':b, \'matchKey\':\'title\',\'matchText\':TITLES[mode]} for mode,b in books.items() if query and query in TITLES[mode].casefold()], \'authors\':[], \'series\':[], \'tags\':[], \'episodes\':[], \'podcast\':[], \'narrators\':[]}\n\n    base = \'/api/libraries/\'+LIBRARY_ID\n    for suffix, handler in [(\'\',get_library),(\'/items\',list_items),(\'/filterdata\',filters),(\'/personalized\',home),(\'/collections\',empty_list),(\'/series\',empty_list),(\'/authors\',empty_authors),(\'/search\',search)]:\n        router.add_api_route(base+suffix, handler, methods=[\'GET\'], dependencies=protected)\n\n    async def no_progress():\n        raise HTTPException(404, \'No saved control progress\')\n\n    async def no_write():\n        return Response(\'OK\', media_type=\'text/plain\')\n\n    async def history():\n        return {\'numPages\':0,\'page\':0,\'itemsPerPage\':10,\'sessions\':[]}\n\n    async def cover():\n        return FileResponse(ROOT/\'cover.jpg\', media_type=\'image/jpeg\')\n\n    def make_handlers(mode):\n        async def detail(expanded: int=0):\n            return books[mode]\n\n        async def play(req: Request):\n            try:\n                body = await req.json()\n            except (ValueError, TypeError):\n                body = {}\n            if not isinstance(body, dict):\n                body = {}\n            _prune()\n            while len(_sessions)>=MAX_SESSIONS:\n                _sessions.pop(next(iter(_sessions)))\n            sid = str(uuid4())\n            _sessions[sid] = (mode, time.monotonic())\n            data = copy.deepcopy(books[mode])\n            media = data[\'media\']\n            audio_track = copy.deepcopy(media[\'tracks\'][0])\n            audio_track[\'contentUrl\'] = f\'/public/session/{sid}/track/1\'\n            if mode in (\'ts\', \'fmp4\'):\n                audio_track[\'contentUrl\'] = f\'/hls/{sid}/output.m3u8\'\n                audio_track[\'mimeType\'] = \'application/vnd.apple.mpegurl\'\n                audio_track[\'metadata\'].update({\'filename\':\'output.m3u8\',\'ext\':\'.m3u8\',\'size\':0,\'path\':\'/virtual/format-control/output.m3u8\',\'relPath\':\'output.m3u8\'})\n            utc = datetime.now(timezone.utc)\n            now = int(time.time()*1000)\n            chapters = media[\'chapters\']\n            duration = FLAT.duration if mode == \'flat\' else LONG.duration if mode == \'long\' else DURATION\n            LOG.info(\'POC_FORMAT_CONTROL mode=%s event=play tracks=1 chapters=%d\', mode, len(chapters))\n            if mode == \'long\':\n                LOG.info(\'POC_VIRTUAL_LONG event=play stats=%s\', LONG.stats())\n            if mode == \'flat\':\n                LOG.info(\'POC_VIRTUAL_FLAT event=play stats=%s\', FLAT.stats())\n            return {\'id\':sid, \'userId\':m.USER_ID, \'libraryId\':LIBRARY_ID,\n                    \'libraryItemId\':data[\'id\'], \'bookId\':media[\'id\'], \'episodeId\':None, \'mediaType\':\'book\',\n                    \'mediaMetadata\':media[\'metadata\'], \'chapters\':copy.deepcopy(chapters),\n                    \'displayTitle\':TITLES[mode], \'displayAuthor\':\'Format control\',\n                    \'coverPath\':media[\'coverPath\'], \'duration\':duration, \'playMethod\':0 if mode in (\'direct\', \'virtual\', \'long\', \'flat\') else 2,\n                    \'mediaPlayer\':body.get(\'mediaPlayer\') or \'AVPlayer\', \'deviceInfo\':body.get(\'deviceInfo\') or {},\n                    \'serverVersion\':m.COMPAT_VERSION, \'date\':utc.strftime(\'%Y-%m-%d\'), \'dayOfWeek\':utc.strftime(\'%A\'),\n                    \'timeListening\':0.,\'startTime\':0.,\'currentTime\':0.,\'startedAt\':now,\'updatedAt\':now,\n                    \'audioTracks\':[audio_track], \'libraryItem\':data}\n        return detail, play\n\n    for mode, data in books.items():\n        iid = data[\'id\']\n        base = \'/api/items/\'+iid\n        detail, play = make_handlers(mode)\n        router.add_api_route(base, detail, methods=[\'GET\'], dependencies=protected)\n        router.add_api_route(base+\'/play\', play, methods=[\'POST\'], dependencies=protected)\n        router.add_api_route(base+\'/cover\', cover, methods=[\'GET\',\'HEAD\'])\n        router.add_api_route(\'/api/me/progress/\'+iid, no_progress, methods=[\'GET\'], dependencies=protected)\n        router.add_api_route(\'/api/me/progress/\'+iid, no_write, methods=[\'PATCH\',\'DELETE\'], dependencies=protected)\n        router.add_api_route(\'/api/me/item/listening-sessions/\'+iid, history, methods=[\'GET\'], dependencies=protected)\n\n    async def hls(sid: str, filename: str, req: Request):\n        if not is_session(sid):\n            raise HTTPException(404, \'Control session unavailable\')\n        mode, _ = _sessions[sid]\n        if mode not in (\'ts\',\'fmp4\') or filename not in {p.name for p in (ROOT/mode).iterdir() if p.is_file()}:\n            raise HTTPException(404, \'Control media unavailable\')\n        suffix = Path(filename).suffix\n        mime = {\'.m3u8\':\'application/vnd.apple.mpegurl\',\'.ts\':\'video/mp2t\',\'.mp4\':\'audio/mp4\',\'.m4s\':\'video/iso.segment\'}.get(suffix)\n        if mime is None:\n            raise HTTPException(404, \'Control media unavailable\')\n        LOG.info(\'POC_FORMAT_CONTROL mode=%s event=%s method=%s range=%d\', mode, \'playlist\' if suffix==\'.m3u8\' else \'segment\', req.method, int(\'range\' in req.headers))\n        return FileResponse(ROOT/mode/filename, media_type=mime, headers={\'Cache-Control\':\'no-store\'})\n\n    router.add_api_route(\'/hls/{sid}/{filename}\', hls, methods=[\'GET\',\'HEAD\'])\n\n    async def long_stats():\n        return LONG.stats()\n    router.add_api_route(\'/api/poc/format-control/long-stats\', long_stats, methods=[\'GET\'], dependencies=protected)\n    async def flat_stats():\n        return FLAT.stats()\n    router.add_api_route(\'/api/poc/format-control/flat-stats\', flat_stats, methods=[\'GET\'], dependencies=protected)\n    # Exact paths must precede generic library/item routes. Other routes remain unchanged.\n    previous_count = len(m.app.router.routes)\n    m.app.include_router(router)\n    routes = m.app.router.routes\n    routes[:] = routes[previous_count:]+routes[:previous_count]\n    LOG.info(\'POC_FORMAT_CONTROL status=ready titles=6 provider_calls=0\')\n'
HELPER = '"""Provider-independent, non-fragmented virtual M4A compatibility control.\n\nAll sample sizes are already known from E\'s five locally authored AAC templates.\nUse a conventional front-loaded moov and one mdat instead of sidx/moof/mfra.\nNo book audio, provider requests, remuxing of protected media, or full file.\n"""\nfrom __future__ import annotations\n\nimport asyncio\nimport bisect\nimport hashlib\nimport logging\nimport struct\nimport threading\nimport time\nfrom fastapi import Request\nfrom fastapi.responses import Response, StreamingResponse\nfrom .virtual_range import VirtualRange\nfrom .virtual_long import (\n    LongVirtual, SLOT_COUNT, TICKS, TIMESCALE, FREQUENCIES,\n    BURST_BYTES, RATE_BYTES, MAX_ACTIVE, box, boxes, child, top, init_for_duration,\n)\n\nLOG = logging.getLogger(\'uvicorn.error\')\nSAMPLES = 300\nSAMPLE_DURATION = 1024\nBLOCK = 65536\n\n\ndef replace_box(data, parent, target, replacement):\n    """Replace one exact child, rebuilding the parent length."""\n    if len(data) < 8 or data[4:8] != parent:\n        raise ValueError(\'Wrong MP4 parent\')\n    found = [(p,n) for p,n,t in boxes(data,8) if t == target]\n    if len(found) != 1:\n        raise ValueError(\'Missing or duplicate MP4 child\')\n    p,n = found[0]\n    return box(parent, data[8:p]+replacement+data[p+n:])\n\n\ndef get_child(data, name):\n    p,n = child(data,0,len(data),name)\n    return data[p:p+n]\n\n\ndef sample_table(templates, chapter_counts):\n    """Return true AAC access-unit sizes and mdat payloads, not estimates."""\n    payloads=[]; sizes=[]\n    for fragment,_,_ in templates:\n        m,n=top(fragment,b\'moof\')\n        t,tn=child(fragment,m,n,b\'traf\')\n        r,rn=child(fragment,t,tn,b\'trun\')\n        flags,count,offset=struct.unpack_from(\'>IIi\',fragment,r+8)\n        if flags!=0x201 or count!=SAMPLES or rn!=20+4*SAMPLES:\n            raise ValueError(\'Unexpected test AAC template\')\n        p,pn=top(fragment,b\'mdat\')\n        raw=fragment[p+8:p+pn]\n        lengths=struct.unpack_from(\'>300I\',fragment,r+20)\n        if sum(lengths)!=len(raw) or min(lengths)<=0 or offset!=p+8:\n            raise ValueError(\'Invalid sample sizes\')\n        payloads.append(raw)\n        sizes.append(fragment[r+20:r+20+4*SAMPLES])\n    size_table=b\'\'.join(s*count for s,count in zip(sizes,chapter_counts,strict=True))\n    return payloads,size_table\n\n\nclass LimitedFlatResponse(StreamingResponse):\n    def __init__(self, owner, iterator, **kwargs):\n        super().__init__(iterator, **kwargs)\n        self.owner=owner\n\n    async def __call__(self, scope, receive, send):\n        with self.owner._lock:\n            admitted=self.owner._active<MAX_ACTIVE\n            if admitted:\n                self.owner._active+=1\n        if not admitted:\n            await Response(status_code=503,headers={\'Retry-After\':\'1\'})(scope,receive,send)\n            return\n        try:\n            await super().__call__(scope,receive,send)\n        finally:\n            with self.owner._lock:\n                self.owner._active-=1\n\n\nclass FlatVirtual(VirtualRange):\n    def __init__(self, source: LongVirtual, *, rate=RATE_BYTES):\n        self.count=source.count\n        self.rate=rate\n        if not 1<=self.count<=SLOT_COUNT or rate<=0:\n            raise ValueError(\'Invalid virtual file limits\')\n        self.duration=source.duration\n        self.chapters=[dict(c) for c in source.chapters]\n        self.chapter_counts=[(i+1)*self.count//len(FREQUENCIES)-i*self.count//len(FREQUENCIES)\n                             for i in range(len(FREQUENCIES))]\n        self.payloads,sizes=sample_table(source.templates,self.chapter_counts)\n        self.chunk_types=[j for j,c in enumerate(self.chapter_counts) for _ in range(c)]\n        self.ends=[]; size=0\n        for j in self.chunk_types:\n            size+=len(self.payloads[j]); self.ends.append(size)\n        if len(self.ends)!=self.count or len(sizes)!=self.count*SAMPLES*4:\n            raise ValueError(\'Invalid sample table length\')\n        if size+8>=2**32:\n            raise ValueError(\'32-bit mdat exceeded\')\n        self.media_size=size\n        # All movie and track durations match the samples in the table.\n        ini=init_for_duration((source.root/\'init.bin\').read_bytes(),self.count)\n        p,n=top(ini,b\'moov\'); moov=ini[p:p+n]\n        trak=get_child(moov,b\'trak\'); mdia=get_child(trak,b\'mdia\')\n        minf=get_child(mdia,b\'minf\'); stbl=get_child(minf,b\'stbl\')\n        stsd=get_child(stbl,b\'stsd\')\n        stts=box(b\'stts\',struct.pack(\'>IIII\',0,1,self.count*SAMPLES,SAMPLE_DURATION))\n        stsc=box(b\'stsc\',struct.pack(\'>IIIII\',0,1,1,SAMPLES,1))\n        stsz=box(b\'stsz\',struct.pack(\'>III\',0,0,self.count*SAMPLES)+sizes)\n        stco=box(b\'stco\',struct.pack(\'>II\',0,self.count)+b\'\\0\'*(4*self.count))\n        new_stbl=box(b\'stbl\',stsd+stts+stsc+stsz+stco)\n        minf=replace_box(minf,b\'minf\',b\'stbl\',new_stbl)\n        mdia=replace_box(mdia,b\'mdia\',b\'minf\',minf)\n        trak=replace_box(trak,b\'trak\',b\'mdia\',mdia)\n        moov=replace_box(moov,b\'moov\',b\'trak\',trak)\n        # Remove fragment-only movie metadata. Keep the actual AAC sample description.\n        moov=replace_box(moov,b\'moov\',b\'mvex\',b\'\')\n        ftyp=box(b\'ftyp\',b\'M4A \'+struct.pack(\'>I\',512)+b\'M4A isommp42\')\n        header=bytearray(ftyp+moov+struct.pack(\'>I4s\',size+8,b\'mdat\'))\n        self.media_start=len(header)\n        # mdat is intentionally incomplete in the header buffer. Traverse moov only.\n        a,b=child(header,len(ftyp),len(moov),b\'trak\')\n        a,b=child(header,a,b,b\'mdia\'); a,b=child(header,a,b,b\'minf\')\n        a,b=child(header,a,b,b\'stbl\'); a,b=child(header,a,b,b\'stco\')\n        if b!=16+4*self.count:\n            raise ValueError(\'Invalid offset table\')\n        for i in range(self.count):\n            offset=self.media_start+(self.ends[i-1] if i else 0)\n            if offset>=2**32:\n                raise ValueError(\'32-bit chunk offset exceeded\')\n            struct.pack_into(\'>I\',header,a+16+4*i,offset)\n        self.header=bytes(header)\n        self.size=self.media_start+self.media_size\n        digest=hashlib.sha256(b\'flat-m4a-control-v1\\0\'+self.header+b\'\'.join(self.payloads)).hexdigest()\n        self.etag=\'"\'+digest+\'"\'\n        self._lock=threading.Lock()\n        self._requests=self._active=self._completed=self._aborted=0\n        self._sent=self._media_sent=self._header_sent=0\n        self._unique=set()\n        self._template_bytes=sum(map(len,self.payloads))\n\n    def piece(self,pos,end):\n        if not 0<=pos<=end<self.size:\n            raise ValueError(\'Invalid byte interval\')\n        if pos<self.media_start:\n            return self.header[pos:min(self.media_start,end+1,pos+BLOCK)],None\n        relative=pos-self.media_start\n        i=bisect.bisect_right(self.ends,relative)\n        previous=self.ends[i-1] if i else 0\n        off=relative-previous\n        data=self.payloads[self.chunk_types[i]]\n        return data[off:off+min(end-pos+1,BLOCK)],i\n\n    def stats(self):\n        with self._lock:\n            return {\'duration_seconds\':self.duration,\'virtual_bytes\':self.size,\n                    \'header_bytes\':self.media_start,\'media_bytes\':self.media_size,\n                    \'total_chunks\':self.count,\'template_payload_bytes\':self._template_bytes,\n                    \'unique_chunks\':len(self._unique),\'requests\':self._requests,\n                    \'body_bytes\':self._sent,\'header_body_bytes\':self._header_sent,\n                    \'media_body_bytes\':self._media_sent,\'active\':self._active,\n                    \'completed\':self._completed,\'aborted\':self._aborted,\n                    \'first_chunks\':sorted(self._unique)[:12],\n                    \'last_chunks\':sorted(self._unique)[-12:],\n                    \'source\':\'synthetic_aac_template_bank\',\'provider_calls\':0}\n\n    async def stream(self,start,end,rid):\n        sent=0; media_sent=0; next_log=1024*1024\n        media_start_time=None; first=last=None\n        try:\n            pos=start\n            while pos<=end:\n                if pos>=self.media_start:\n                    if media_start_time is None:\n                        media_start_time=time.monotonic()\n                    budget=BURST_BYTES+int((time.monotonic()-media_start_time)*self.rate)\n                    delay=(media_sent-budget)/self.rate\n                    if delay>0:\n                        await asyncio.sleep(delay)\n                data,i=self.piece(pos,end)\n                if not data:\n                    raise IOError(\'Empty virtual media slice\')\n                pos+=len(data); sent+=len(data)\n                if i is not None:\n                    if first is None:\n                        first=i\n                        LOG.info(\'POC_VIRTUAL_FLAT event=first_media request=%d chunk=%d time_seconds=%.1f\',rid,i,i*TICKS/TIMESCALE)\n                    last=i; media_sent+=len(data)\n                with self._lock:\n                    self._sent+=len(data)\n                    if i is None:\n                        self._header_sent+=len(data)\n                    else:\n                        self._media_sent+=len(data); self._unique.add(i)\n                yield data\n                if sent>=next_log:\n                    LOG.info(\'POC_VIRTUAL_FLAT event=progress request=%d bytes=%d media_bytes=%d last_chunk=%s\',rid,sent,media_sent,last)\n                    next_log=sent+1024*1024\n                await asyncio.sleep(0)\n        finally:\n            complete=int(sent==end-start+1)\n            with self._lock:\n                self._completed+=complete; self._aborted+=1-complete\n            LOG.info(\'POC_VIRTUAL_FLAT event=body request=%d bytes=%d media_bytes=%d first_chunk=%s last_chunk=%s complete=%d\',rid,sent,media_sent,first,last,complete)\n\n    def response(self,req: Request):\n        headers={\'Accept-Ranges\':\'bytes\',\'Cache-Control\':\'no-store\',\'ETag\':self.etag}\n        value=req.headers.get(\'range\') if req.method==\'GET\' else None\n        if req.headers.get(\'if-range\') not in (None,self.etag):\n            value=None\n        try:\n            start,end,partial=self.bounds(value)\n        except ValueError:\n            return Response(status_code=416,headers={**headers,\'Content-Range\':f\'bytes */{self.size}\'})\n        headers[\'Content-Length\']=str(end-start+1)\n        if partial:\n            headers[\'Content-Range\']=f\'bytes {start}-{end}/{self.size}\'\n        status=206 if partial else 200\n        with self._lock:\n            self._requests+=1; rid=self._requests\n        LOG.info(\'POC_VIRTUAL_FLAT event=response request=%d method=%s status=%d start=%d end=%d total=%d header_bytes=%d\',rid,req.method,status,start,end,self.size,self.media_start)\n        if req.method==\'HEAD\':\n            return Response(status_code=status,headers=headers,media_type=\'audio/mp4\')\n        return LimitedFlatResponse(self,self.stream(start,end,rid),status_code=status,headers=headers,media_type=\'audio/mp4\')\n'
import ast
import hashlib
import os
import shutil
import sys
from pathlib import Path


def fail(s):
    raise SystemExit('ERROR: '+s)


def sha(b):
    return hashlib.sha256(b).hexdigest()


test, original = (Path(p).resolve(strict=True) for p in sys.argv[1:3])
mode=sys.argv[3]
app=test/'app'; control=app/'format_control.py'; helper=app/'virtual_flat.py'
backup=test/'.nextory-virtual-flat-baseline.py'
if test==original or test in original.parents or original in test.parents:
    fail('Test/original paths overlap')
for p in (app,control,helper,backup,app/'format_control_media',app/'format_control_media/long'):
    if p.is_symlink(): fail('Symlink in install path')
if (original/'app/format_control.py').exists() or (original/'app/virtual_flat.py').exists():
    fail('Unexpected format control in original')
if not control.is_file() or 'NEXTORY_FORMAT_CONTROL_V1' not in (app/'main.py').read_text():
    fail('Playback format test A-E is required')
for name,digest in REQUIREMENTS.items():
    p=app/name
    if p.is_symlink() or not p.is_file() or sha(p.read_bytes())!=digest:
        fail('Unexpected E dependency: '+name)
for src in (CONTROL,HELPER):
    ast.parse(src);compile(src,'<virtual-flat>','exec')
modified=CONTROL.encode('utf-8');module=HELPER.encode('utf-8')
current=control.read_bytes()
if sha(current)!=BASELINE_SHA and current!=modified:
    fail('Unexpected format control version; no source files changed')
if backup.exists() and (not backup.is_file() or sha(backup.read_bytes())!=BASELINE_SHA):
    fail('Backup integrity mismatch')


def atomic_control(data):
    tmp=control.with_name('.virtual-flat-control.tmp')
    if tmp.exists() or tmp.is_symlink(): fail('Unexpected temporary file')
    try:
        with tmp.open('xb') as f: f.write(data)
        tmp.chmod(control.stat().st_mode & 0o777)
        os.replace(tmp,control)
    finally:
        tmp.unlink(missing_ok=True)


if mode=='rollback':
    if current!=modified or not backup.is_file() or not helper.is_file() or helper.read_bytes()!=module:
        fail('Exact installed F version not confirmed; rollback stopped')
    atomic_control(backup.read_bytes())
    helper.unlink()
    print('F_REMOVED=YES ABCDE_PRESERVED=YES')
elif mode=='apply':
    if current==modified:
        if not backup.is_file() or not helper.is_file() or helper.read_bytes()!=module:
            fail('Existing F install does not match')
        print('VIRTUAL_FLAT=ALREADY_ENABLED')
    else:
        if helper.exists(): fail('Unexpected existing F helper')
        if not backup.exists(): shutil.copy2(control,backup)
        try:
            with helper.open('xb') as f: f.write(module)
            helper.chmod(0o644)
            atomic_control(modified)
        except BaseException:
            helper.unlink(missing_ok=True)
            raise
        print('VIRTUAL_FLAT=ENABLED')
    print('FIXTURE=F_VIRTUAL_CLASSIC_10_HOUR_M4A')
else:
    fail('Unsupported mode')
print('NEXTORY_PROVIDER_AND_AUDIO=UNCHANGED')
print('E_TEMPLATES_REUSED=YES')
print('PYTHON_SYNTAX=PASS')

PYCODE
echo
if [ "$OFFLINE" = 1 ]; then
  echo '=== 3. OFFLINE VERIFICATIE ==='
  echo 'SOURCE_PATCH=PASS'
  exit 0
fi

echo '=== 3. ALLEEN TESTCONTAINER HERBOUWEN ==='
docker compose -p "$PROJECT" -f "$TEST/docker-compose.yml" -f "$TEST/docker-compose.test.yml" \
  up -d --build --no-deps "$SERVICE"
echo
echo '=== 4. WACHTEN OP /HEALTH ==='
READY=0
for _ in $(seq 1 20); do
  if docker exec nextory-abs-poc-test python -c 'import urllib.request; assert urllib.request.urlopen("http://127.0.0.1:8000/health",timeout=3).status==200' >/dev/null 2>&1; then
    READY=1; break
  fi
  sleep 2
done
if [ "$READY" != 1 ]; then
  echo 'ERROR: Testcontainer reageert niet op /health. Geen automatische rollback: inspecteer eerst de toestand.'
  docker logs --tail 25 nextory-abs-poc-test 2>&1 | grep -E 'ERROR|Exception|Traceback|startup' | tail -12 || true
  exit 1
fi

echo '=== 5. CONTROLEREN ==='
docker exec -i nextory-abs-poc-test python - "$MODE" <<'PYVERIFY'
import json,sys,urllib.request
from app import main,format_control as fc
base='http://127.0.0.1:8000'
headers={'Authorization':'Bearer '+main.make_token()}
req=urllib.request.Request(base+'/api/libraries/'+fc.LIBRARY_ID+'/items',headers=headers)
with urllib.request.urlopen(req,timeout=5) as r:
    books=json.load(r)
assert books['total']==(6 if sys.argv[1]=='apply' else 5)
if sys.argv[1]=='apply':
    from app.virtual_flat import FlatVirtual
    assert isinstance(fc.FLAT,FlatVirtual)
    with urllib.request.urlopen(urllib.request.Request(base+'/api/poc/format-control/flat-stats',headers=headers),timeout=5) as r:
        stats=json.load(r)
    assert stats['duration_seconds']==36000 and stats['total_chunks']==5625
    print('F_AVAILABLE=YES DURATION_SECONDS=36000')
    print('VIRTUAL_BYTES='+str(stats['virtual_bytes']))
    print('HEADER_BYTES='+str(stats['header_bytes']))
    print('UNIQUE_CHUNKS='+str(stats['unique_chunks']))
    print('TEMPLATE_PAYLOAD_BYTES='+str(stats['template_payload_bytes']))
else:
    assert not hasattr(fc,'FLAT')
    print('F_REMOVED=YES')
assert hasattr(fc,'LONG') and hasattr(fc,'VIRTUAL')
print('ABCDE_PRESERVED=YES')
PYVERIFY
docker inspect nextory-abs-poc-test --format 'TEST_RUNNING={{.State.Running}} HEALTH={{if .State.Health}}{{.State.Health.Status}}{{else}}unknown{{end}}'
docker inspect nextory-abs-poc --format 'ORIGINAL_RUNNING={{.State.Running}}'
echo '=== EINDE ==='
