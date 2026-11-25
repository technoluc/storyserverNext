#!/usr/bin/env bash
# Server-side AudioBooth A/B-test: een doorlopende HLS-track met bestaande hoofdstukken.
# Alleen nextory-abs-poc-test; geen wijziging aan de originele v6 of AudioBooth.
# Gebruik: bash nextory-hls-single-book-test.sh apply|rollback
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
for f in docker-compose.yml docker-compose.test.yml app/main.py app/nextory.py app/hls_proxy.py app/prewarm.py app/hls_delivery.py app/hls_root.py; do
  if [ ! -f "$TEST/$f" ]; then echo "ERROR: Testbestand ontbreekt: $f"; exit 1; fi
done
if [ ! -f "$ORIGINAL/app/main.py" ]; then echo 'ERROR: Originele broncode ontbreekt.'; exit 1; fi
if [ "$OFFLINE" != 1 ]; then
  original_running="$(docker inspect -f '{{.State.Running}}' nextory-abs-poc 2>/dev/null || true)"
  test_running="$(docker inspect -f '{{.State.Running}}' nextory-abs-poc-test 2>/dev/null || true)"
  test_project="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' nextory-abs-poc-test 2>/dev/null || true)"
  test_image="$(docker inspect -f '{{.Config.Image}}' nextory-abs-poc-test 2>/dev/null || true)"
  port_owner="$(docker ps --filter publish=13378 --format '{{.Names}}')"
  if [ "$original_running" != false ] || [ "$test_running" != true ] || \
     [ "$test_project" != "$PROJECT" ] || [ "$test_image" != 'nextory-abs-poc-test:dev' ] || \
     [ "$port_owner" != 'nextory-abs-poc-test' ]; then
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

echo '=== 2. SINGLE-TRACK HLS TEST ==='
python3 - "$TEST" "$ORIGINAL" "$MODE" <<'PYCODE'
from __future__ import annotations
import os
import shutil
import sys
from pathlib import Path
import ast

from pathlib import Path
import ast

MARKER = 'NEXTORY_SINGLE_PRESENTATION_V1'
FILES = ('main.py', 'nextory.py', 'hls_proxy.py')


def replace(text, old, new, label):
    if text.count(old) != 1:
        raise SystemExit('ERROR: Onverwachte broncode bij ' + label + '; niets overschrijven.')
    return text.replace(old, new, 1)


def patch_main(src):
    src = replace(src,
        'from .hls_root import direct_media_playlist  # NEXTORY_HLS_DIRECT_MEDIA_V1\n',
        'from .hls_root import direct_media_playlist  # NEXTORY_HLS_DIRECT_MEDIA_V1\n'
        'from .hls_book import BookPlanCache  # NEXTORY_SINGLE_PRESENTATION_V1\n', 'imports')
    src = replace(src,
        '    prewarm_manager.shutdown()  # NEXTORY_DETAIL_PREWARM_V1\n',
        '    prewarm_manager.shutdown()  # NEXTORY_DETAIL_PREWARM_V1\n'
        '    book_plan_cache.shutdown()  # NEXTORY_SINGLE_PRESENTATION_V1\n', 'shutdown')
    src = replace(src,
        '    return info, tracks, book_ms, layout_ms\n\n\nprewarm_manager = PrewarmManager(',
        '    # Prepare the one-item playlist independently; never block details on it.\n'
        '    book_plan_cache.schedule(nextory, book_id, tracks)\n'
        '    return info, tracks, book_ms, layout_ms\n\n\n'
        'book_plan_cache = BookPlanCache()\n\n\nprewarm_manager = PrewarmManager(', 'warm hook')
    src = replace(src,
        '    if expanded == 1:\n        prewarm_manager.schedule(book_id)\n    return result\n',
        '    if expanded == 1:\n        prewarm_manager.schedule(book_id)\n'
        '        if cached:\n            book_plan_cache.schedule(nextory, book_id, cached[1])\n'
        '    return result\n', 'detail hook')
    old = '''    if not isinstance(body, dict):
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
'''
    new = '''    if not isinstance(body, dict):
        body = {}
    # NEXTORY_SINGLE_PRESENTATION_V1: this isolated A/B affects AudioBooth only.
    device = body.get('deviceInfo')
    device = device if isinstance(device, dict) else {}
    client_name = str(device.get('clientName') or '').lower()
    is_audiobooth = 'audiobooth' in client_name
    chapters = tracks
    playback_tracks = tracks
    plan = None
    reason = 'other_client' if not is_audiobooth else 'not_multiple_parts'
    if is_audiobooth and len(tracks) > 1:
        plan, reason = await book_plan_cache.obtain(nextory, info.book_id, tracks)
    previous = progress_store.get(info.book_id)
    previous_time = (float(previous['currentTime']) if previous else 0.0)
    duration = round(tracks[-1].start + tracks[-1].duration, 3)
    start_time = previous_time if previous_time < duration - 10 else 0.0
    session = None
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
                'POC_HLS_BOOK stage=play mode=single_track chapters=%d audio_tracks=1 segments=%d',
                len(chapters), plan.segment_count)
    if session is None:
        try:
            session = registry.create(book_id=info.book_id, title=info.title,
                                      tracks=tracks, user_id=USER_ID, current_time=start_time)
        except NextoryError as exc:
            raise HTTPException(status_code=503, detail=str(exc)) from exc
        logging.getLogger('uvicorn.error').info(
            'POC_HLS_BOOK stage=play mode=parts reason=%s audio_tracks=%d', reason, len(tracks))
    library_item = item_json(info, playback_tracks, expanded=True)
    library_item['media']['chapters'] = chapters_json(chapters)
    library_item['media']['numChapters'] = len(chapters)
    now = int(time.time() * 1000)
'''
    src = replace(src, old, new, 'play-session preparation')
    # Replace only the scoped play handler, not item_json elsewhere.
    start = src.index("@app.post('/api/items/{item_id}/play')")
    end = src.index("@app.api_route('/public/session/{session_id}/track/{track_index}'", start)
    before, section, after = src[:start], src[start:end], src[end:]
    section = replace(section, "'chapters': chapters_json(tracks),", "'chapters': chapters_json(chapters),", 'session chapters')
    section = replace(section, "                        for track in tracks],\n        'libraryItem': item_json(info, tracks, expanded=True),", "                        for track in playback_tracks],\n        'libraryItem': library_item,", 'session tracks')
    src = before + section + after
    src = replace(src,
        "        raise HTTPException(status_code=404, detail='Playback session or track unavailable')\n"
        "    # Critical for first-press playback:",
        "        raise HTTPException(status_code=404, detail='Playback session or track unavailable')\n"
        "    # NEXTORY_SINGLE_PRESENTATION_V1: single logical book item.\n"
        "    if session.book_playlist is not None:\n"
        "        payload = session.book_playlist\n"
        "        logging.getLogger('uvicorn.error').info(\n"
        "            'POC_HLS_BOOK stage=root mode=single_track segments=%d bytes=%d',\n"
        "            session.book_playlist_segments, len(payload))\n"
        "        return Response(content=b'' if req.method == 'HEAD' else payload,\n"
        "                        media_type='application/vnd.apple.mpegurl',\n"
        "                        headers={'Content-Length': str(len(payload)),\n"
        "                                 'Cache-Control': 'no-store',\n"
        "                                 'Access-Control-Allow-Origin': '*'})\n"
        "    # Critical for first-press playback:", 'single track endpoint')
    return src


def patch_nextory(src):
    old = '    def _isolated_duration(self, url: str, api_headers: dict, api_cookies) -> float:\n'
    new = '''    def read_part_playlists(self, tracks, reader):
        """NEXTORY_SINGLE_PRESENTATION_V1: bounded, isolated manifest-only reads.

        No network calls are made under the backend lock except auth itself.
        Process at most four documents in a batch to bound retained memory.
        """
        with self._lock:
            self._ensure_login()
            api_headers = dict(self._api.headers)
            api_cookies = self._api.cookies.copy()

        def read_one(track):
            with requests.Session() as api, requests.Session() as public:
                api.headers.update(api_headers)
                api.cookies.update(api_cookies)
                self._duration_worker.api = api
                self._duration_worker.public = public
                try:
                    return reader(self.get_manifest, track)
                finally:
                    del self._duration_worker.api
                    del self._duration_worker.public

        with ThreadPoolExecutor(max_workers=min(4, len(tracks)),
                                thread_name_prefix='nextory-hls-book') as pool:
            for start in range(0, len(tracks), 4):
                yield from pool.map(read_one, tracks[start:start + 4])

''' + old
    return replace(src, old, new, 'isolated playlist reader')


def patch_proxy(src):
    src = replace(src, '    closed: bool = False\n',
                  '    closed: bool = False\n'
                  '    book_playlist: bytes | None = None  # NEXTORY_SINGLE_PRESENTATION_V1\n'
                  '    book_playlist_segments: int = 0\n', 'session book playlist')
    src = replace(src, '            self.root_tokens.clear()\n',
                  '            self.root_tokens.clear()\n'
                  '            self.book_playlist = None\n'
                  '            self.book_playlist_segments = 0\n', 'session cleanup')
    src = replace(src, '               user_id: str, current_time: float = 0.0) -> Playback:\n',
                  '               user_id: str, current_time: float = 0.0,\n'
                  '               book_presentation: bool = False) -> Playback:\n', 'registry argument')
    src = replace(src, "            if len(self._sessions) >= MAX_SESSIONS:\n"
                       "                raise NextoryError('Too many playback sessions')\n",
                  "            if len(self._sessions) >= MAX_SESSIONS:\n"
                  "                raise NextoryError('Too many playback sessions')\n"
                  "            if book_presentation and sum(s.book_playlist is not None for s in self._sessions.values()) >= 4:\n"
                  "                raise NextoryError('Single presentation capacity reached')\n", 'registry capacity')
    src = replace(src, '                               current_time=max(0.0, min(current_time, duration)))\n',
                  '                               current_time=max(0.0, min(current_time, duration)),\n'
                  '                               book_playlist=b"" if book_presentation else None)\n', 'registry reservation')
    return src


PATCHERS = {'main.py': patch_main, 'nextory.py': patch_nextory, 'hls_proxy.py': patch_proxy}


def patch_sources(sources):
    result = {name: PATCHERS[name](src) for name, src in sources.items()}
    for name, text in result.items():
        ast.parse(text, filename=name)
    return result

HELPER = '"""NEXTORY_SINGLE_PRESENTATION_V1: optional one-item HLS presentation.\n\nMetadata-only composition for the isolated AudioBooth experiment. All provider\nmedia and key bytes are still relayed by the original HLS resource endpoint.\nUnsupported HLS features fail closed to the established multi-track path.\n"""\nfrom __future__ import annotations\n\nimport asyncio\nimport logging\nimport math\nimport re\nimport threading\nimport time\nfrom collections import OrderedDict\nfrom concurrent.futures import Future, ThreadPoolExecutor\nfrom dataclasses import dataclass\nfrom urllib.parse import urljoin\n\nfrom .nextory import TrackPart, NextoryError, safe_remote_url\n\nLOG = logging.getLogger(\'uvicorn.error\')\nMAX_PART_BYTES = 2 * 1024 * 1024\nMAX_BOOK_BYTES = 4 * 1024 * 1024\nMAX_BOOK_SEGMENTS = 6000\nPLAN_TTL_SECONDS = 120\nMAX_PLANS = 2\nPLAY_WAIT_SECONDS = 1.25\n_ATTR = re.compile(r\'([A-Z0-9-]+)=("[^"\\r\\n]*"|[^,\\r\\n]+)(?:,|$)\')\n_HEX_IV = re.compile(r\'0[xX][0-9A-Fa-f]{1,32}\\Z\')\n_INT = re.compile(r\'[0-9]{1,20}\\Z\')\n\n\nclass Unsupported(NextoryError):\n    """Fixed, nonsecret reason why a source cannot be composed safely."""\n\n\n@dataclass(frozen=True)\nclass Key:\n    method: str\n    uri: str\n    iv: str | None\n    keyformat: str | None\n    keyformatversions: str | None\n\n    def tag(self, sequence: int, output_sequence: int) -> str:\n        # Preserve the source\'s effective IV under the new global sequence.\n        # This does NOT decrypt, re-encrypt, retrieve or change any key/media.\n        iv = self.iv\n        if iv is None and self.method == \'AES-128\' and sequence != output_sequence:\n            iv = f\'0x{sequence:032x}\'\n        elif iv is None and self.method != \'AES-128\' and sequence != output_sequence:\n            raise Unsupported(\'implicit_sample_aes_iv\')\n        line = f\'#EXT-X-KEY:METHOD={self.method},URI="{self.uri}"\'\n        if iv is not None:\n            line += \',IV=\' + iv\n        if self.keyformat is not None:\n            line += \',KEYFORMAT=\' + self.keyformat\n        if self.keyformatversions is not None:\n            line += \',KEYFORMATVERSIONS=\' + self.keyformatversions\n        return line\n\n\n@dataclass(frozen=True)\nclass Segment:\n    extinf: str\n    duration: float\n    uri: str\n    sequence: int\n    key: Key | None\n    discontinuity: bool\n\n\n@dataclass(frozen=True)\nclass Part:\n    segments: tuple[Segment, ...]\n    version: int\n    target_duration: int\n    duration: float\n\n\n@dataclass(frozen=True)\nclass BookPlan:\n    document: str\n    chapters: tuple[TrackPart, ...]\n    segment_count: int\n    bytes: int\n\n\ndef _number(value: str, limit: int) -> int:\n    if not _INT.fullmatch(value):\n        raise Unsupported(\'invalid_integer_tag\')\n    result = int(value)\n    if result > limit:\n        raise Unsupported(\'integer_tag_limit\')\n    return result\n\n\ndef _attributes(value: str) -> dict[str, str]:\n    pos = 0\n    result: dict[str, str] = {}\n    while pos < len(value):\n        match = _ATTR.match(value, pos)\n        if match is None or match.group(1) in result:\n            raise Unsupported(\'invalid_key_attributes\')\n        result[match.group(1)] = match.group(2)\n        pos = match.end()\n    if not result:\n        raise Unsupported(\'missing_key_attributes\')\n    return result\n\n\ndef _key(value: str, base_url: str) -> Key | None:\n    attrs = _attributes(value)\n    method = attrs.get(\'METHOD\')\n    if method == \'NONE\' and set(attrs) == {\'METHOD\'}:\n        return None\n    # The original proxy relays the provider\'s identity key URL unchanged.\n    # Do not attempt DRM conversions or accept alternate key formats.\n    if method not in {\'AES-128\', \'SAMPLE-AES\'}:\n        raise Unsupported(\'unsupported_key_method\')\n    if set(attrs) - {\'METHOD\', \'URI\', \'IV\', \'KEYFORMAT\', \'KEYFORMATVERSIONS\'}:\n        raise Unsupported(\'unsupported_key_attributes\')\n    if attrs.get(\'KEYFORMAT\') not in (None, \'"identity"\'):\n        raise Unsupported(\'unsupported_keyformat\')\n    if attrs.get(\'KEYFORMATVERSIONS\') not in (None, \'"1"\'):\n        raise Unsupported(\'unsupported_keyformatversions\')\n    raw_uri = attrs.get(\'URI\', \'\')\n    if len(raw_uri) < 3 or not raw_uri.startswith(\'"\') or not raw_uri.endswith(\'"\'):\n        raise Unsupported(\'invalid_key_uri\')\n    uri = urljoin(base_url, raw_uri[1:-1])\n    if \'"\' in uri or \'\\r\' in uri or \'\\n\' in uri or len(uri) > 8192:\n        raise Unsupported(\'invalid_key_uri\')\n    iv = attrs.get(\'IV\')\n    if iv is not None and not _HEX_IV.fullmatch(iv):\n        raise Unsupported(\'invalid_key_iv\')\n    return Key(method, uri, iv, attrs.get(\'KEYFORMAT\'), attrs.get(\'KEYFORMATVERSIONS\'))\n\n\ndef _lines(document: str) -> list[str]:\n    if len(document.encode(\'utf-8\')) > MAX_PART_BYTES:\n        raise Unsupported(\'part_manifest_limit\')\n    lines = [line.strip() for line in document.splitlines() if line.strip()]\n    if not lines or lines[0] != \'#EXTM3U\':\n        raise Unsupported(\'invalid_manifest\')\n    return lines\n\n\ndef read_part(fetch_manifest, track: TrackPart) -> Part:\n    """Read one simple VOD part, resolving a single unambiguous master variant."""\n    url = track.uri\n    visited = set()\n    for _ in range(4):\n        if url in visited:\n            raise Unsupported(\'manifest_loop\')\n        visited.add(url)\n        document, final_url = fetch_manifest(url)\n        lines = _lines(document)\n        if not any(line.startswith(\'#EXT-X-STREAM-INF:\') for line in lines):\n            return parse_media(lines, final_url)\n        unsafe = (\'#EXT-X-MEDIA:\', \'#EXT-X-I-FRAME-STREAM-INF:\',\n                  \'#EXT-X-SESSION-KEY:\', \'#EXT-X-DEFINE:\', \'#EXT-X-START:\',\n                  \'#EXT-X-CONTENT-STEERING:\')\n        if any(line.startswith(unsafe) for line in lines):\n            raise Unsupported(\'complex_master\')\n        variants = []\n        for i, line in enumerate(lines):\n            if line.startswith(\'#EXT-X-STREAM-INF:\'):\n                if i + 1 == len(lines) or lines[i+1].startswith(\'#\'):\n                    raise Unsupported(\'invalid_variant\')\n                variants.append(lines[i+1])\n            elif line.startswith(\'#EXT-X-\') and not line.startswith((\n                    \'#EXT-X-VERSION:\', \'#EXT-X-INDEPENDENT-SEGMENTS\')):\n                raise Unsupported(\'unsupported_master_tag\')\n        if len(variants) != 1:\n            raise Unsupported(\'multiple_variants\')\n        url = safe_remote_url(urljoin(final_url, variants[0]))\n    raise Unsupported(\'manifest_depth\')\n\n\ndef parse_media(lines: list[str], base_url: str) -> Part:\n    segments: list[Segment] = []\n    version = 3\n    target_duration = None\n    sequence = 0\n    pending_duration = None\n    pending_extinf = None\n    current_key = None\n    discontinuity = False\n    seen_end = False\n    singleton_tags = set()\n    for line in lines[1:]:\n        if seen_end:\n            if line.startswith(\'#\') and not line.startswith(\'#EXT\'):\n                continue\n            raise Unsupported(\'content_after_endlist\')\n        if line.startswith(\'#EXT-X-VERSION:\'):\n            if \'version\' in singleton_tags or segments:\n                raise Unsupported(\'duplicate_or_late_version\')\n            singleton_tags.add(\'version\')\n            version = max(3, _number(line.split(\':\', 1)[1], 20))\n        elif line.startswith(\'#EXT-X-TARGETDURATION:\'):\n            if \'target\' in singleton_tags or segments:\n                raise Unsupported(\'duplicate_or_late_target\')\n            singleton_tags.add(\'target\')\n            target_duration = _number(line.split(\':\', 1)[1], 3600)\n            if target_duration == 0:\n                raise Unsupported(\'invalid_target_duration\')\n        elif line.startswith(\'#EXT-X-MEDIA-SEQUENCE:\'):\n            if \'sequence\' in singleton_tags or segments or pending_extinf is not None:\n                raise Unsupported(\'duplicate_or_late_sequence\')\n            singleton_tags.add(\'sequence\')\n            sequence = _number(line.split(\':\', 1)[1], 2**64-1)\n        elif line.startswith(\'#EXT-X-DISCONTINUITY-SEQUENCE:\'):\n            # A closed standalone VOD may have a nonzero discontinuity base;\n            # keep the discontinuity locations, not the old rendition number.\n            if \'disc_sequence\' in singleton_tags or segments:\n                raise Unsupported(\'duplicate_or_late_discontinuity_sequence\')\n            singleton_tags.add(\'disc_sequence\')\n            _number(line.split(\':\', 1)[1], 2**64-1)\n        elif line.startswith(\'#EXT-X-PLAYLIST-TYPE:\'):\n            if line != \'#EXT-X-PLAYLIST-TYPE:VOD\':\n                raise Unsupported(\'not_vod\')\n        elif line.startswith(\'#EXT-X-KEY:\'):\n            if pending_extinf is not None:\n                raise Unsupported(\'key_after_extinf\')\n            current_key = _key(line.split(\':\', 1)[1], base_url)\n            if current_key is not None and (current_key.keyformat is not None or current_key.method == \'SAMPLE-AES\'):\n                version = max(5, version)\n        elif line == \'#EXT-X-DISCONTINUITY\':\n            if pending_extinf is not None:\n                raise Unsupported(\'discontinuity_after_extinf\')\n            discontinuity = True\n        elif line.startswith(\'#EXTINF:\'):\n            if pending_extinf is not None:\n                raise Unsupported(\'missing_segment_uri\')\n            try:\n                duration = float(line.split(\':\', 1)[1].split(\',\', 1)[0])\n            except (ValueError, OverflowError):\n                raise Unsupported(\'invalid_segment_duration\') from None\n            if not math.isfinite(duration) or not 0 < duration <= 3600:\n                raise Unsupported(\'invalid_segment_duration\')\n            pending_duration = duration\n            pending_extinf = line\n        elif line == \'#EXT-X-ENDLIST\':\n            if pending_extinf is not None:\n                raise Unsupported(\'missing_segment_uri\')\n            seen_end = True\n        elif line.startswith(\'#EXT-X-ALLOW-CACHE:\') or line == \'#EXT-X-INDEPENDENT-SEGMENTS\':\n            # Do not advertise independence unless proven across the new book.\n            continue\n        elif line.startswith(\'#EXT\'):\n            # BYTERANGE, MAP, START, DATERANGE, GAP, LL-HLS, alternate key\n            # formats and all unfamiliar features are deliberately not flattened.\n            tag = line.split(\':\', 1)[0]\n            safe_tag = re.sub(\'[^A-Z0-9_-]\', \'\', tag.lstrip(\'#\'))[:48]\n            raise Unsupported(\'unsupported_tag_\' + safe_tag.lower())\n        elif line.startswith(\'#\'):\n            continue\n        else:\n            if pending_extinf is None or pending_duration is None:\n                raise Unsupported(\'segment_without_extinf\')\n            uri = urljoin(base_url, line)\n            if len(uri) > 8192 or \'"\' in uri or \'\\n\' in uri or \'\\r\' in uri:\n                raise Unsupported(\'invalid_segment_uri\')\n            if sequence + len(segments) >= 2**64:\n                raise Unsupported(\'sequence_overflow\')\n            segments.append(Segment(pending_extinf, pending_duration, uri,\n                                    sequence + len(segments), current_key, discontinuity))\n            if len(segments) > MAX_BOOK_SEGMENTS:\n                raise Unsupported(\'segment_limit\')\n            pending_extinf = pending_duration = None\n            discontinuity = False\n    if not seen_end or not segments or not target_duration:\n        raise Unsupported(\'incomplete_vod\')\n    if any(math.floor(s.duration + 0.5) > target_duration for s in segments):\n        raise Unsupported(\'target_duration_mismatch\')\n    return Part(tuple(segments), version, target_duration,\n                math.fsum(s.duration for s in segments))\n\n\ndef compose(backend, tracks: tuple[TrackPart, ...]) -> BookPlan:\n    if not 2 <= len(tracks) <= 256:\n        raise Unsupported(\'not_multiple_parts\')\n    if [track.index for track in tracks] != list(range(1, len(tracks)+1)):\n        raise Unsupported(\'nonsequential_parts\')\n    body: list[str] = []\n    output_seq = 0\n    prev_key = None\n    chapters: list[TrackPart] = []\n    start = 0.0\n    version = 3\n    target = 0\n    total_bytes = 0\n    # read_part_playlists provides isolated provider sessions and bounded batches.\n    parts = backend.read_part_playlists(tracks, read_part)\n    try:\n        for track, part in zip(tracks, parts, strict=True):\n            version = max(version, part.version)\n            target = max(target, part.target_duration)\n            for index, seg in enumerate(part.segments):\n                if output_seq >= MAX_BOOK_SEGMENTS:\n                    raise Unsupported(\'book_segment_limit\')\n                if (index == 0 and output_seq > 0) or seg.discontinuity:\n                    body.append(\'#EXT-X-DISCONTINUITY\')\n                    total_bytes += 21\n                tag = seg.key.tag(seg.sequence, output_seq) if seg.key else None\n                if tag != prev_key or (index == 0 and tag is not None):\n                    line = tag or \'#EXT-X-KEY:METHOD=NONE\'\n                    body.append(line)\n                    total_bytes += len(line.encode(\'utf-8\'))+1\n                    prev_key = tag\n                body.extend((seg.extinf, seg.uri))\n                total_bytes += len(seg.extinf.encode(\'utf-8\')) + len(seg.uri.encode(\'utf-8\')) + 2\n                if total_bytes > MAX_BOOK_BYTES:\n                    raise Unsupported(\'book_manifest_limit\')\n                output_seq += 1\n            chapters.append(TrackPart(track.index, track.uri, round(start, 3),\n                                      round(part.duration, 3), track.title))\n            start += part.duration\n    finally:\n        close = getattr(parts, \'close\', None)\n        if close:\n            close()\n    if len(chapters) != len(tracks) or start <= 0:\n        raise Unsupported(\'missing_parts\')\n    header = [\'#EXTM3U\', f\'#EXT-X-VERSION:{version}\',\n              f\'#EXT-X-TARGETDURATION:{target}\', \'#EXT-X-MEDIA-SEQUENCE:0\',\n              \'#EXT-X-PLAYLIST-TYPE:VOD\']\n    document = \'\\n\'.join(header + body + [\'#EXT-X-ENDLIST\', \'\'])\n    size = len(document.encode(\'utf-8\'))\n    if size > MAX_BOOK_BYTES:\n        raise Unsupported(\'book_manifest_limit\')\n    return BookPlan(document, tuple(chapters), output_seq, size)\n\n\n@dataclass\nclass _Entry:\n    backend: object\n    tracks: tuple[TrackPart, ...]\n    future: Future\n    created: float\n    completed: float | None = None\n\n\nclass BookPlanCache:\n    """At most one composer running, two small metadata plans, short-lived."""\n    def __init__(self, ttl=PLAN_TTL_SECONDS, wait=PLAY_WAIT_SECONDS):\n        self._ttl = ttl\n        self._wait = wait\n        self._pool = ThreadPoolExecutor(max_workers=1, thread_name_prefix=\'nextory-book-hls\')\n        self._lock = threading.Lock()\n        self._entries: OrderedDict[int, _Entry] = OrderedDict()\n        self._closed = False\n\n    def _prune_locked(self):\n        now = time.monotonic()\n        for book_id, entry in list(self._entries.items()):\n            if entry.future.done():\n                if entry.completed is None:\n                    entry.completed = now\n                if now - entry.completed >= self._ttl:\n                    self._entries.pop(book_id, None)\n\n    def _work(self, backend, tracks):\n        started = time.perf_counter()\n        try:\n            plan = compose(backend, tracks)\n        except Unsupported as exc:\n            LOG.info(\'POC_HLS_BOOK stage=prepare status=fallback reason=%s\', str(exc))\n            return None, str(exc)\n        except Exception as exc:\n            LOG.warning(\'POC_HLS_BOOK stage=prepare status=fallback reason=provider_%s\', type(exc).__name__)\n            return None, \'provider_error\'\n        LOG.info(\'POC_HLS_BOOK stage=prepare status=ready chapters=%d segments=%d bytes=%d elapsed_ms=%d\',\n                 len(plan.chapters), plan.segment_count, plan.bytes,\n                 int((time.perf_counter()-started)*1000))\n        return plan, \'ready\'\n\n    def _done(self, book_id, entry):\n        with self._lock:\n            if self._entries.get(book_id) is entry:\n                entry.completed = time.monotonic()\n\n    def schedule(self, backend, book_id, tracks):\n        if len(tracks) < 2 or not callable(getattr(backend, \'read_part_playlists\', None)):\n            return \'not_applicable\'\n        with self._lock:\n            if self._closed:\n                return \'closed\'\n            self._prune_locked()\n            existing = self._entries.get(book_id)\n            if existing and existing.backend is backend and existing.tracks == tracks:\n                self._entries.move_to_end(book_id)\n                return \'ready\' if existing.future.done() else \'inflight\'\n            if any(not e.future.done() for e in self._entries.values()):\n                LOG.info(\'POC_HLS_BOOK stage=prepare status=capacity\')\n                return \'capacity\'\n            self._entries.pop(book_id, None)\n            while len(self._entries) >= MAX_PLANS:\n                self._entries.popitem(last=False)\n            future = self._pool.submit(self._work, backend, tracks)\n            entry = _Entry(backend, tracks, future, time.monotonic())\n            self._entries[book_id] = entry\n        future.add_done_callback(lambda _: self._done(book_id, entry))\n        LOG.info(\'POC_HLS_BOOK stage=prepare status=scheduled chapters=%d\', len(tracks))\n        return \'scheduled\'\n\n    async def obtain(self, backend, book_id, tracks):\n        state = self.schedule(backend, book_id, tracks)\n        with self._lock:\n            self._prune_locked()\n            entry = self._entries.get(book_id)\n            if entry is None or entry.backend is not backend or entry.tracks != tracks:\n                return None, state\n            future = entry.future\n        try:\n            return await asyncio.wait_for(asyncio.shield(asyncio.wrap_future(future)), self._wait)\n        except asyncio.TimeoutError:\n            return None, \'plan_pending\'\n        except Exception:\n            return None, \'plan_failed\'\n\n    def shutdown(self):\n        with self._lock:\n            self._closed = True\n        self._pool.shutdown(wait=False, cancel_futures=True)\n'

test = Path(sys.argv[1]).resolve(strict=True)
original = Path(sys.argv[2]).resolve(strict=True)
mode = sys.argv[3]
appdir = test/'app'
backup = test/'.nextory-hls-single-book-baseline'
helper = appdir/'hls_book.py'
for name in FILES:
    path = appdir/name
    if path.is_symlink() or path.samefile(original/'app'/name):
        sys.exit('ERROR: Test- en originele broncode overlappen.')
if helper.is_symlink():
    sys.exit('ERROR: Helper is een symlink.')
current = {name: (appdir/name).read_text(encoding='utf-8') for name in FILES}
backup_exists = all((backup/name).is_file() for name in FILES)
if backup.exists() and not backup_exists:
    sys.exit('ERROR: Onvolledige backup; niets overschrijven.')
if backup_exists:
    baseline = {name: (backup/name).read_text(encoding='utf-8') for name in FILES}
    modified = patch_sources(baseline)
else:
    baseline = current
    if any(MARKER in text for text in current.values()):
        sys.exit('ERROR: Patch aanwezig zonder complete backup.')
    modified = patch_sources(baseline)

ast.parse(HELPER,filename='hls_book.py')
applied = current == modified and helper.is_file() and helper.read_text(encoding='utf-8') == HELPER
clean = current == baseline and not helper.exists()
if mode == 'rollback':
    if not backup_exists or not applied:
        sys.exit('ERROR: Exacte vorige patchtoestand niet aangetoond; rollback afgebroken.')
    for name in FILES:
        shutil.copy2(backup/name, appdir/name)
    helper.unlink()
    print('ROLLBACK=PASS')
    print('PREWARM=UNCHANGED')
    print('DIRECT_MEDIA=UNCHANGED')
    print('AUDIO_AND_KEYS=UNCHANGED')
    print('ORIGINAL=NOT_MODIFIED')
    raise SystemExit(0)
if applied:
    print('PATCH=ALREADY_APPLIED')
    raise SystemExit(0)
if not clean:
    sys.exit('ERROR: Huidige broncode wijkt af van de exacte baseline; niets overschrijven.')
if not backup_exists:
    backup.mkdir(mode=0o700, exist_ok=False)
    for name in FILES:
        shutil.copy2(appdir/name, backup/name)
        # Backup directory is private; preserve original source file modes.
    print('BACKUP=CREATED')
else:
    print('BACKUP=REUSED')
temps = []
try:
    for name, source in {**modified, 'hls_book.py': HELPER}.items():
        target = appdir/name
        tmp = appdir/(name+'.single-book-install-tmp')
        with tmp.open('x', encoding='utf-8') as f:
            f.write(source)
        temps.append(tmp)
        ast.parse(tmp.read_text(encoding='utf-8'),filename=name)
        os.chmod(tmp, target.stat().st_mode & 0o777 if target.exists() else 0o644)
    for name in ('hls_book.py', 'hls_proxy.py', 'nextory.py', 'main.py'):
        os.replace(appdir/(name+'.single-book-install-tmp'), appdir/name)
except Exception:
    for name in FILES:
        shutil.copy2(backup/name, appdir/name)
    if helper.is_file() and helper.read_text(encoding='utf-8') == HELPER:
        helper.unlink()
    raise
finally:
    for tmp in temps:
        tmp.unlink(missing_ok=True)
print('SINGLE_HLS=EXPERIMENT_AUDIOBOOTH_ONLY')
print('SOURCE_CHAPTERS=PRESERVED')
print('AUDIO_AND_KEYS=UNCHANGED')
print('PREWARM=PRESERVED')
print('MAX_PREPARE_BOOKS=1')
print('MAX_PLAN_CACHE=2')
print('MAX_SINGLE_SESSIONS=4')
print('PYTHON_SYNTAX=PASS')
print('ORIGINAL=NOT_MODIFIED')
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

echo '=== 5. PATCH EN ISOLATIE VERIFIEREN ==='
docker exec -i nextory-abs-poc-test python - "$MODE" <<'PY'
import inspect, sys
from app import main
from app.nextory import MAX_MANIFEST_BYTES, NextoryBackend
from app.prewarm import PrewarmManager
from app.hls_root import direct_media_playlist
assert isinstance(main.prewarm_manager, PrewarmManager)
assert MAX_MANIFEST_BYTES == 8 * 1024 * 1024
assert hasattr(NextoryBackend, '_authenticated_get_json')
if sys.argv[1] == 'apply':
    from app.hls_book import BookPlanCache
    assert isinstance(main.book_plan_cache, BookPlanCache)
    assert hasattr(NextoryBackend, 'read_part_playlists')
    assert 'NEXTORY_SINGLE_PRESENTATION_V1' in inspect.getsource(main.public_track)
    print('SINGLE_HLS=AVAILABLE_AUDIOBOOTH_ONLY')
else:
    assert not hasattr(main, 'book_plan_cache')
    print('SINGLE_HLS=RESTORED_PREVIOUS')
print('PREWARM=PRESERVED')
print('DIRECT_MEDIA=PRESERVED')
print('HLS_LIMIT_BYTES=' + str(MAX_MANIFEST_BYTES))
print('AUTH_RETRY=PRESERVED')
print('LAYOUT_PARALLEL=PRESERVED')
PY
docker inspect nextory-abs-poc-test --format 'TEST_RUNNING={{.State.Running}} HEALTH={{if .State.Health}}{{.State.Health.Status}}{{else}}unknown{{end}}'
docker inspect nextory-abs-poc --format 'ORIGINAL_RUNNING={{.State.Running}}'
docker ps --filter publish=13378 --format 'PORT_13378_OWNER={{.Names}}'
echo
echo '=== 6. VERVOLG ==='
if [ "$MODE" = 'apply' ]; then
  echo 'TEST: Open een nieuw boek en wacht op POC_HLS_BOOK stage=prepare status=ready. Druk eenmaal Play.'
  echo 'LOGS: docker logs --since 10m nextory-abs-poc-test 2>&1 | grep -E "POC_HLS_BOOK|POC_PREWARM stage=play|POC_TIMING stage=play-start" | tail -40'
  echo 'ROLLBACK: bash ~/nextory-abs-virtual-poc-test/nextory-hls-single-book-test.sh rollback'
else
  echo 'ROLLBACK=COMPLETE_AFTER_HEALTH_CHECK'
fi
echo '=== EINDE ==='
