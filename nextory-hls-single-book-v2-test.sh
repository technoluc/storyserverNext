#!/usr/bin/env bash
# Single HLS v2: hoofdstukindeling en doorlopende playlist in een voorbereiding.
# Alleen nextory-abs-poc-test; geen wijziging aan de originele v6 of AudioBooth.
# Gebruik: bash nextory-hls-single-book-v2-test.sh apply|rollback
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

echo '=== 2. SINGLE HLS V2 OP TESTBRONCODE ==='
python3 - "$TEST" "$ORIGINAL" "$MODE" <<'PYCODE'
from __future__ import annotations
import ast
import os
import shutil
import sys
from pathlib import Path

MARKER = 'NEXTORY_SINGLE_PRESENTATION_V2'
FILES = ('main.py', 'nextory.py', 'hls_book.py')

def replace(src, old, new, label):
    if src.count(old) != 1:
        raise SystemExit('ERROR: Onverwachte v1-broncode bij '+label+'; niets overschrijven.')
    return src.replace(old, new, 1)


def patch_book(src):
    src = replace(src, 'import asyncio\n', 'import asyncio\nimport hashlib\n', 'book imports')
    src = replace(src, 'from concurrent.futures import Future, ThreadPoolExecutor\n', 'from concurrent.futures import Future, ThreadPoolExecutor, TimeoutError as FutureTimeout\n', 'future imports')
    src = replace(src, 'MAX_PLANS = 2\nPLAY_WAIT_SECONDS = 1.25', '''MAX_PLANS = 2
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
    return tuple((t.index, t.uri, t.title) for t in tracks)''', 'book constants')
    src = replace(src, '    """At most one composer running, two small metadata plans, short-lived."""', '    """NEXTORY_SINGLE_PRESENTATION_V2: one worker, one queued job, short-lived plans."""', 'book cache marker')
    src = replace(src, '    def _work(self, backend, tracks):\n', '    def _work(self, backend, book_id, tracks):\n        ref = book_ref(book_id)\n', 'worker identity')
    src = replace(src, "LOG.info('POC_HLS_BOOK stage=prepare status=fallback reason=%s', str(exc))", "LOG.info('POC_HLS_BOOK stage=prepare status=fallback book=%s reason=%s', ref, str(exc))", 'fallback identity')
    src = replace(src, "LOG.warning('POC_HLS_BOOK stage=prepare status=fallback reason=provider_%s', type(exc).__name__)", "LOG.warning('POC_HLS_BOOK stage=prepare status=fallback book=%s reason=provider_%s', ref, type(exc).__name__)", 'provider identity')
    src = replace(src, "'POC_HLS_BOOK stage=prepare status=ready chapters=%d segments=%d bytes=%d elapsed_ms=%d',\n                 len(plan.chapters)", "'POC_HLS_BOOK stage=prepare status=ready book=%s chapters=%d segments=%d bytes=%d elapsed_ms=%d',\n                 ref, len(plan.chapters)", 'ready identity')
    start = src.index('    def schedule(self, backend, book_id, tracks):\n')
    end = src.index('    def shutdown(self):\n', start)
    src = src[:start] + '''    def schedule(self, backend, book_id, tracks):
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

''' + src[end:]
    return src


def patch_nextory(src):
    anchor = '    def get_layout(self, book_id: int) -> tuple[TrackPart, ...]:\n'
    return replace(src, anchor, '''    def remember_composed_layout(self, info: BookInfo, tracks: tuple[TrackPart, ...]) -> bool:
        """NEXTORY_SINGLE_PRESENTATION_V2: publish the composed exact timeline.

        Only accept a still-current product generation. This avoids a second
        full manifest traversal and never substitutes stale signed source URLs.
        """
        with self._lock:
            current = self._books.get(info.book_id)
            if (current is None or current[0] is not info or
                    time.monotonic() - current[1] >= CACHE_SECONDS):
                return False
            if len(tracks) != len(info.parts) or not tracks:
                return False
            for index, (part, track) in enumerate(zip(info.parts, tracks), 1):
                if (track.index != index or track.uri != part['uri'] or
                        not math.isfinite(track.duration) or track.duration <= 0 or
                        not math.isfinite(track.start) or track.start < 0):
                    return False
            self._layouts[info.book_id] = (tracks, time.monotonic())
            return True

''' + anchor, 'publish composed layout')


def patch_main(src):
    src = replace(src, 'from .hls_book import BookPlanCache  # NEXTORY_SINGLE_PRESENTATION_V1', 'from .hls_book import BookPlanCache, book_ref, PLAY_TOTAL_BUDGET_SECONDS  # NEXTORY_SINGLE_PRESENTATION_V2', 'main imports')
    old = '''    started = time.perf_counter()
    tracks = nextory.get_layout(book_id)
    layout_ms = int((time.perf_counter() - started) * 1000)
    # Prepare the one-item playlist independently; never block details on it.
    book_plan_cache.schedule(nextory, book_id, tracks)
    return info, tracks, book_ms, layout_ms'''
    new = '''    started = time.perf_counter()
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
    return info, tracks, book_ms, layout_ms'''
    src = replace(src, old, new, 'single traversal')
    src = replace(src, '''    if expanded == 1:
        prewarm_manager.schedule(book_id)
        if cached:
            book_plan_cache.schedule(nextory, book_id, cached[1])''', '''    if expanded == 1:
        logging.getLogger('uvicorn.error').info('POC_HLS_BOOK stage=detail book=%s', book_ref(book_id))
        prewarm_manager.schedule(book_id)
        if cached:
            book_plan_cache.schedule(nextory, book_id, cached[1])''', 'detail correlation')
    src = replace(src, '''    info, tracks = await book_and_layout(item_id)
    try:
        body = await req.json()''', '''    started = time.monotonic()
    try:
        body = await req.json()''', 'start playback budget')
    src = replace(src, '''    is_audiobooth = 'audiobooth' in client_name
    chapters = tracks''', '''    is_audiobooth = 'audiobooth' in client_name
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
    chapters = tracks''', 'play deadline')
    src = replace(src, '''        plan, reason = await book_plan_cache.obtain(nextory, info.book_id, tracks)''', '''        plan, reason = await book_plan_cache.obtain(nextory, info.book_id, tracks,
            timeout=max(0., PLAY_TOTAL_BUDGET_SECONDS - (time.monotonic() - started)))
        # Never silently call a timing/capacity fallback a one-track test.
        # Genuine incompatible VODs retain the original multi-part contract.
        if plan is None and reason in {'plan_pending', 'capacity', 'generation_pending', 'closed'}:
            logging.getLogger('uvicorn.error').info(
                'POC_HLS_BOOK stage=play mode=pending book=%s reason=%s', ref, reason)
            raise HTTPException(status_code=503, detail='Book preparation is still running; reopen details and retry')''', 'explicit pending')
    src = replace(src, "'POC_HLS_BOOK stage=play mode=single_track chapters=%d audio_tracks=1 segments=%d',\n                len(chapters)", "'POC_HLS_BOOK stage=play mode=single_track book=%s chapters=%d audio_tracks=1 segments=%d',\n                ref, len(chapters)", 'play correlation')
    src = replace(src, "'POC_HLS_BOOK stage=play mode=parts reason=%s audio_tracks=%d', reason, len(tracks))", "'POC_HLS_BOOK stage=play mode=parts book=%s reason=%s audio_tracks=%d', ref, reason, len(tracks))", 'parts correlation')
    src = replace(src, "'POC_HLS_BOOK stage=root mode=single_track segments=%d bytes=%d',\n            session.book_playlist_segments", "'POC_HLS_BOOK stage=root mode=single_track book=%s segments=%d bytes=%d',\n            book_ref(session.book_id), session.book_playlist_segments", 'root correlation')
    return src

PATCHERS = {'main.py': patch_main, 'nextory.py': patch_nextory, 'hls_book.py': patch_book}

def patch_sources(sources):
    if not all('NEXTORY_SINGLE_PRESENTATION_V1' in sources[name] for name in FILES):
        raise SystemExit('ERROR: Single HLS v1 vereist.')
    return {name: PATCHERS[name](sources[name]) for name in FILES}


test = Path(sys.argv[1]).resolve(strict=True)
original = Path(sys.argv[2]).resolve(strict=True)
mode = sys.argv[3]
appdir = test/'app'
backup = test/'.nextory-hls-single-book-v2-baseline'
if appdir.is_symlink() or backup.is_symlink():
    sys.exit('ERROR: Broncode of backupmap is een symlink.')
for name in FILES:
    path = appdir/name
    orig = original/'app'/name
    if path.is_symlink() or (orig.exists() and path.samefile(orig)):
        sys.exit('ERROR: Test- en originele broncode overlappen.')
current = {n: (appdir/n).read_text(encoding='utf-8') for n in FILES}
backup_exists = all((backup/n).is_file() and not (backup/n).is_symlink() for n in FILES)
if backup.exists() and not backup_exists:
    sys.exit('ERROR: Onvolledige backup; niets overschrijven.')
if backup_exists:
    baseline = {n: (backup/n).read_text(encoding='utf-8') for n in FILES}
else:
    baseline = current
    if any(MARKER in s for s in current.values()):
        sys.exit('ERROR: v2 aanwezig zonder volledige backup.')
modified = patch_sources(baseline)
for n, s in modified.items():
    ast.parse(s, filename=n)
clean = current == baseline
applied = current == modified
if not clean and not applied:
    sys.exit('ERROR: Broncode wijkt af van gecontroleerde v1/v2; niets overschrijven.')
if mode == 'rollback':
    if not backup_exists or not applied:
        sys.exit('ERROR: Exacte v2-toestand niet aangetoond; rollback afgebroken.')
    for name in FILES:
        shutil.copy2(backup/name, appdir/name)
    print('ROLLBACK=PASS')
    print('RESTORED=SINGLE_HLS_V1')
    print('ORIGINAL=NOT_MODIFIED')
    raise SystemExit(0)
if applied:
    print('PATCH=ALREADY_APPLIED')
    raise SystemExit(0)
if not backup_exists:
    backup.mkdir(mode=0o700, exist_ok=False)
    for name in FILES:
        shutil.copy2(appdir/name, backup/name)
    print('BACKUP=CREATED')
else:
    print('BACKUP=REUSED')
temps=[]
try:
    for name, source in modified.items():
        target=appdir/name
        tmp=appdir/(name+'.single-book-v2-install-tmp')
        with tmp.open('x', encoding='utf-8') as f:
            f.write(source)
        temps.append(tmp)
        ast.parse(tmp.read_text(encoding='utf-8'), filename=name)
        os.chmod(tmp, target.stat().st_mode & 0o777)
    for name in FILES:
        os.replace(appdir/(name+'.single-book-v2-install-tmp'),appdir/name)
except Exception:
    for name in FILES:
        shutil.copy2(backup/name,appdir/name)
    raise
finally:
    for tmp in temps:
        tmp.unlink(missing_ok=True)
print('SINGLE_HLS_V2=ENABLED_AUDIOBOOTH_ONLY')
print('SINGLE_PASS=CHAPTERS_AND_PLAYLIST')
print('BOOK_LOG_CORRELATION=ENABLED')
print('PLAN_CACHE_ENTRIES=2')
print('PLAN_WORKERS=1_WITH_ONE_QUEUED')
print('PLAY_WAIT_BUDGET_SECONDS=8.5_TOTAL_PREPARATION')
print('PENDING=HTTP_503_INSTEAD_OF_SILENT_PARTS')
print('AUDIO_AND_KEYS=UNCHANGED')
print('PREWARM_PRESERVED=YES')
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
import inspect,sys
from app import main,hls_book
from app.nextory import MAX_MANIFEST_BYTES, NextoryBackend
from app.prewarm import PrewarmManager
assert isinstance(main.prewarm_manager,PrewarmManager)
assert MAX_MANIFEST_BYTES==8*1024*1024
assert hasattr(NextoryBackend,'_authenticated_get_json')
assert isinstance(main.book_plan_cache,hls_book.BookPlanCache)
assert 'NEXTORY_SINGLE_PRESENTATION_V1' in inspect.getsource(main.public_track)
if sys.argv[1]=='apply':
    assert hasattr(NextoryBackend,'remember_composed_layout')
    assert hls_book.PLAY_WAIT_SECONDS==8.0
    assert hls_book.PLAY_TOTAL_BUDGET_SECONDS==8.5
    assert hls_book.MAX_PENDING_PLANS==2
    assert 'NEXTORY_SINGLE_PRESENTATION_V2' in inspect.getsource(main._compute_book_and_layout)
    print('SINGLE_HLS_V2=AVAILABLE')
else:
    assert not hasattr(NextoryBackend,'remember_composed_layout')
    assert hls_book.PLAY_WAIT_SECONDS==1.25
    print('SINGLE_HLS_V1=RESTORED')
print('PREWARM=PRESERVED')
print('HLS_LIMIT_BYTES='+str(MAX_MANIFEST_BYTES))
print('AUTH_RETRY=PRESERVED')
print('LAYOUT_PARALLEL=PRESERVED')
PY
docker inspect nextory-abs-poc-test --format 'TEST_RUNNING={{.State.Running}} HEALTH={{if .State.Health}}{{.State.Health.Status}}{{else}}unknown{{end}}'
docker inspect nextory-abs-poc --format 'ORIGINAL_RUNNING={{.State.Running}}'
docker ps --filter publish=13378 --format 'PORT_13378_OWNER={{.Names}}'
echo
echo '=== 6. VERVOLG ==='
if [ "$MODE" = 'apply' ]; then
  echo 'TEST: Open een ander boekdetail dan de oude afspeelsessie; wacht op status=ready EN stage=layout mode=single_pass voor hetzelfde book=.'
  echo 'TEST: Druk eenmaal op Play; bewijs is stage=play mode=single_track audio_tracks=1 EN stage=root mode=single_track voor hetzelfde book=.'
  echo 'LOGS: docker logs --since 10m nextory-abs-poc-test 2>&1 | grep -E "POC_HLS_BOOK|POC_PREWARM stage=play|POC_TIMING stage=play-start" | tail -50'
  echo 'ROLLBACK: bash ~/nextory-abs-virtual-poc-test/nextory-hls-single-book-v2-test.sh rollback'
else
  echo 'ROLLBACK=COMPLETE_AFTER_HEALTH_CHECK'
fi
echo '=== EINDE ==='
