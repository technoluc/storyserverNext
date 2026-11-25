#!/usr/bin/env bash
# Test-only, detail-triggered Nextory/HLS prewarming (metadata and playlists, no audio).
# Usage: bash nextory-detail-prewarm-test.sh apply|rollback
# Original v6 is NEVER modified or started.
set -euo pipefail
MODE="${1:-apply}"
TEST="${NEXTORY_TEST_DIR:-$HOME/nextory-abs-virtual-poc-test}"
ORIGINAL="${NEXTORY_ORIGINAL_DIR:-$HOME/nextory-abs-virtual-poc}"
PROJECT="nextory-abs-test"
SERVICE="nextory-abs-poc"
OFFLINE="${_NEXTORY_OFFLINE_VERIFY:-0}"
clear 2>/dev/null || true

echo '=== 1. VEILIGHEIDSCONTROLE ==='
if [ "$MODE" != 'apply' ] && [ "$MODE" != 'rollback' ]; then
  echo 'ERROR: Gebruik apply of rollback.'; exit 1
fi
for f in docker-compose.yml docker-compose.test.yml app/main.py app/nextory.py; do
  if [ ! -f "$TEST/$f" ]; then echo "ERROR: Testbestand ontbreekt: $f"; exit 1; fi
done
if [ ! -f "$ORIGINAL/app/nextory.py" ]; then
  echo 'ERROR: Origineel bronbestand ontbreekt.'; exit 1
fi
if [ "$OFFLINE" != '1' ]; then
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
  if ! NEXTORY_TEST="$TEST" NEXTORY_ORIGINAL="$ORIGINAL" python3 - <<'PY'
import json, os, subprocess, sys
from pathlib import Path
test = Path(os.environ['NEXTORY_TEST']).resolve(strict=True)
original = Path(os.environ['NEXTORY_ORIGINAL']).resolve(strict=True)
if test == original or original in test.parents or test in original.parents:
    sys.exit('ERROR: Test- en origineelpad overlappen.')
command = ['docker','compose','-p','nextory-abs-test','-f',str(test/'docker-compose.yml'),'-f',str(test/'docker-compose.test.yml'),'config','--format','json']
p = subprocess.run(command, cwd=test, capture_output=True, text=True)
if p.returncode:
    sys.exit('ERROR: Compose-configuratie kon niet gecontroleerd worden.')
try:
    cfg=json.loads(p.stdout)
    s=cfg['services']['nextory-abs-poc']
    assert cfg['name']=='nextory-abs-test'
    assert s['container_name']=='nextory-abs-poc-test'
    assert s['image']=='nextory-abs-poc-test:dev'
    assert not s.get('volumes_from') and not s.get('network_mode')
    b=s['build']; context=Path(b['context'] if isinstance(b,dict) else b).resolve(strict=True)
    assert context == test
    ports=s['ports']
    assert len(ports)==1 and str(ports[0]['published'])=='13378' and int(ports[0]['target'])==8000
    for m in s.get('volumes',[]):
        if m['type']=='bind':
            src=Path(m['source']).resolve()
            if src == original or original in src.parents:
                assert m.get('read_only') and m['target']=='/run/nextory'
            if not m.get('read_only'):
                assert src == test or test in src.parents
        elif m['type']=='volume':
            volume=cfg.get('volumes',{}).get(m.get('source'),{})
            assert not volume.get('external',False)
            assert volume.get('name','').startswith('nextory-abs-test_')
    for net in (s.get('networks') or {}):
        info=cfg.get('networks',{}).get(net,{})
        assert not info.get('external')
        assert not info.get('name') or info['name'].startswith('nextory-abs-test_')
except (AssertionError,KeyError,ValueError,TypeError,OSError):
    sys.exit('ERROR: Compose-isolatie niet aangetoond.')
print('COMPOSE_ISOLATION=PASS')
PY
  then echo '=== AFGEBROKEN ==='; exit 1; fi
else
  echo 'OFFLINE_VALIDATION=YES'
fi
printf 'MODE=%s\nORIGINAL=STOPPED_AND_UNMODIFIED\nPORT=13378\n' "$MODE"
echo

echo '=== 2. PREWARM-PATCH OP TESTBRONCODE ==='
python3 - "$TEST" "$ORIGINAL" "$MODE" <<'PYINSTALL'
from __future__ import annotations

import ast
import os
import shutil
import sys
from pathlib import Path

TEST = Path(sys.argv[1]).resolve(strict=True)
ORIGINAL = Path(sys.argv[2]).resolve(strict=True)
MODE = sys.argv[3]
MAIN = TEST / 'app/main.py'
MODULE = TEST / 'app/prewarm.py'
ORIGINAL_MAIN = ORIGINAL / 'app/main.py'
BACKUP_ROOT = TEST / '.nextory-detail-prewarm-baseline'
BACKUP_MAIN = BACKUP_ROOT / 'main.py'
MARKER = 'NEXTORY_DETAIL_PREWARM_V1'

# PREWARM_SOURCE is substituted with the reviewed and unit-tested module.
PREWARM_SOURCE = '''"""NEXTORY_DETAIL_PREWARM_V1: bounded, metadata-only HLS prewarming.

Triggered only by the authenticated expanded book-detail endpoint. No media
segments, key bytes or audio files are fetched or stored by this module.
"""
from __future__ import annotations

import asyncio
import logging
import threading
import time
from concurrent.futures import Future, ThreadPoolExecutor
from dataclasses import dataclass
from typing import Callable

LOG = logging.getLogger('uvicorn.error')
PREWARM_TTL_SECONDS = 120  # Shorter than NextoryBackend's five-minute cache.
PREWARM_MAX_ACTIVE = 2
PREWARM_MAX_ENTRIES = 8


@dataclass
class _Entry:
    future: Future
    created: float
    completed: float | None = None


class PrewarmManager:
    """Single-flight work per book; never schedules work during catalog listing.

    `compute(book_id)` returns (BookInfo, tracks, book_ms, layout_ms).
    `peek(book_id)` returns a still-valid cached (BookInfo, tracks) or None.
    No provider calls occur during construction or when the service starts.
    """

    def __init__(self, compute: Callable, peek: Callable, *,
                 ttl_seconds: float = PREWARM_TTL_SECONDS,
                 max_active: int = PREWARM_MAX_ACTIVE,
                 max_entries: int = PREWARM_MAX_ENTRIES):
        self._compute = compute
        self._peek = peek
        self._ttl = ttl_seconds
        self._max_active = max_active
        self._max_entries = max_entries
        self._lock = threading.Lock()
        self._entries: dict[int, _Entry] = {}
        self._pool = ThreadPoolExecutor(max_workers=max_active, thread_name_prefix='nextory-warm')
        self._closed = False

    def _expire_locked(self, now: float) -> None:
        for book_id, entry in list(self._entries.items()):
            if not entry.future.done():
                continue
            if entry.completed is None:
                entry.completed = now
            if entry.future.cancelled() or entry.future.exception() is not None or now-entry.completed >= self._ttl:
                self._entries.pop(book_id, None)

    def _work(self, book_id: int):
        started = time.perf_counter()
        try:
            info, tracks, book_ms, layout_ms = self._compute(book_id)
            LOG.info('POC_PREWARM stage=prepare status=ready book_ms=%d layout_ms=%d tracks=%d total_ms=%d',
                     book_ms, layout_ms, len(tracks), int((time.perf_counter()-started)*1000))
            return info, tracks, book_ms, layout_ms
        except Exception as exc:
            # Never log provider exceptions: they may contain signed upstream URLs.
            LOG.warning('POC_PREWARM stage=prepare status=failed error_type=%s', type(exc).__name__)
            raise

    def _completed(self, book_id: int, entry: _Entry) -> None:
        with self._lock:
            if self._entries.get(book_id) is entry:
                entry.completed = time.monotonic()

    def schedule(self, book_id: int) -> str:
        """Nonblocking. Called only after authenticating and loading a book detail."""
        with self._lock:
            if self._closed:
                return 'closed'
            now = time.monotonic()
            self._expire_locked(now)
            existing = self._entries.get(book_id)
            if existing is not None:
                state = 'reuse' if existing.future.done() else 'inflight'
                LOG.info('POC_PREWARM stage=detail status=%s', state)
                return state
            active = sum(not entry.future.done() for entry in self._entries.values())
            if active >= self._max_active:
                LOG.info('POC_PREWARM stage=detail status=capacity')
                return 'capacity'
            if len(self._entries) >= self._max_entries:
                oldest = min((item for item in self._entries.items() if item[1].future.done()),
                             key=lambda item: item[1].completed or item[1].created, default=None)
                if oldest is None:
                    return 'capacity'
                self._entries.pop(oldest[0], None)
            future = self._pool.submit(self._work, book_id)
            entry = _Entry(future=future, created=now)
            self._entries[book_id] = entry
        future.add_done_callback(lambda _fut: self._completed(book_id, entry))
        LOG.info('POC_PREWARM stage=detail status=scheduled')
        return 'scheduled'

    def busy(self) -> bool:
        """Keep detail pages fast if any prewarm owns the backend HLS lock."""
        with self._lock:
            return any(not entry.future.done() for entry in self._entries.values())

    async def obtain(self, book_id: int) -> tuple[tuple, str, int]:
        """Play reuses the same work or falls back to the existing cold path."""
        with self._lock:
            self._expire_locked(time.monotonic())
            entry = self._entries.get(book_id)
        if entry is not None:
            state = 'hit' if entry.future.done() else 'wait'
            started = time.perf_counter()
            try:
                # shield: cancelled Play requests must not cancel the warm job.
                await asyncio.shield(asyncio.wrap_future(entry.future))
                # Backend owns signed-URI freshness; do not trust a stale future.
                cached = await asyncio.to_thread(self._peek, book_id)
                if cached is not None:
                    info, tracks = cached
                    waited = int((time.perf_counter()-started)*1000)
                    LOG.info('POC_PREWARM stage=play status=%s wait_ms=%d tracks=%d',
                             state, waited, len(tracks))
                    return (info, tracks, 0, 0), state, waited
                LOG.info('POC_PREWARM stage=play status=stale')
            except Exception as exc:
                LOG.warning('POC_PREWARM stage=play status=retry error_type=%s', type(exc).__name__)
            with self._lock:
                if self._entries.get(book_id) is entry:
                    self._entries.pop(book_id, None)
        started = time.perf_counter()
        data = await asyncio.to_thread(self._compute, book_id)
        elapsed = int((time.perf_counter()-started)*1000)
        LOG.info('POC_PREWARM stage=play status=miss elapsed_ms=%d tracks=%d',
                 elapsed, len(data[1]))
        return data, 'miss', elapsed

    def shutdown(self):
        with self._lock:
            self._closed = True
        self._pool.shutdown(wait=False, cancel_futures=True)
'''


def fail(message):
    raise SystemExit('ERROR: ' + message)


if MODE not in {'apply', 'rollback'}:
    fail('Gebruik apply of rollback.')
if TEST == ORIGINAL or TEST in ORIGINAL.parents or ORIGINAL in TEST.parents:
    fail('Test en origineel overlappen.')
if (MAIN.is_symlink() or ORIGINAL_MAIN.is_symlink() or MODULE.is_symlink() or
        BACKUP_ROOT.is_symlink() or BACKUP_MAIN.is_symlink()):
    fail('Symlink in een code- of backuppad.')
if not MAIN.is_file() or not ORIGINAL_MAIN.is_file():
    fail('Vereiste broncode ontbreekt.')
if os.path.samefile(MAIN, ORIGINAL_MAIN):
    fail('Test en origineel zijn hardlinked.')
if not (TEST/'app/nextory.py').is_file() or (TEST/'app/nextory.py').is_symlink():
    fail('Nextory-broncode ontbreekt of is een symlink.')
if os.path.samefile(TEST/'app/nextory.py', ORIGINAL/'app/nextory.py'):
    fail('Test en origineel delen Nextory-inode.')


def once(source: str, old: str, new: str, label: str) -> str:
    matches = source.count(old)
    if matches != 1:
        fail(f'Verwachte structuur gewijzigd in {label}: {matches} matches.')
    return source.replace(old, new, 1)


def patch(source: str) -> str:
    if MARKER in source:
        fail('Baseline bevat de prewarmpatch al.')
    source = once(
        source,
        'from .nextory import BookInfo, CONFIG_PATH, NextoryError, TrackPart, nextory\n',
        'from .nextory import BookInfo, CONFIG_PATH, NextoryError, TrackPart, nextory\n'
        'from .prewarm import PrewarmManager  # NEXTORY_DETAIL_PREWARM_V1\n',
        'import prewarm',
    )
    source = once(
        source,
        "        except asyncio.CancelledError:\n            pass\n\n\ndef _collect_catalog()",
        "        except asyncio.CancelledError:\n            pass\n"
        "    prewarm_manager.shutdown()  # NEXTORY_DETAIL_PREWARM_V1\n\n\n"
        "def _collect_catalog()",
        'shutdown background pool',
    )
    old_block = '''async def book_and_layout(item_id: str) -> tuple[BookInfo, tuple[TrackPart, ...]]:
    book_id = id_to_book(item_id)
    def collect():
        started = time.perf_counter()
        info = nextory.get_book(book_id)
        book_ms = int((time.perf_counter() - started) * 1000)
        started = time.perf_counter()
        tracks = nextory.get_layout(book_id)
        layout_ms = int((time.perf_counter() - started) * 1000)
        return info, tracks, book_ms, layout_ms
    try:
        info, tracks, book_ms, layout_ms = await run_in_threadpool(collect)
        logging.getLogger('uvicorn.error').info(
            'POC_PLAY_PHASE book_ms=%d layout_ms=%d tracks=%d',
            book_ms, layout_ms, len(tracks))  # AUDIOBOOTH_COMPAT_V1
        return info, tracks
    except NextoryError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc
'''
    new_block = '''def _compute_book_and_layout(book_id: int) -> tuple[BookInfo, tuple[TrackPart, ...], int, int]:
    """NEXTORY_DETAIL_PREWARM_V1: common single computation for warm/cold play."""
    started = time.perf_counter()
    info = nextory.get_book(book_id)
    book_ms = int((time.perf_counter() - started) * 1000)
    started = time.perf_counter()
    tracks = nextory.get_layout(book_id)
    layout_ms = int((time.perf_counter() - started) * 1000)
    return info, tracks, book_ms, layout_ms


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
'''
    source = once(source, old_block, new_block, 'play layout sharing')
    source = once(
        source,
        "@app.get('/api/items/{item_id}')\n"
        "async def item(item_id: str, _: bool = Depends(authenticated)):\n",
        "@app.get('/api/items/{item_id}')\n"
        "async def item(item_id: str, expanded: int = 0, _: bool = Depends(authenticated)):\n",
        'detail-route expanded flag',
    )
    source = once(source, """    # After playback, reuse real full track metadata already in memory.
    try:
        cached = nextory.peek_book_and_layout(book_id)
    except AttributeError:
        cached = None
""", """    # After playback, reuse real full track metadata already in memory.
    # NEXTORY_DETAIL_PREWARM_V1: never block a book page on another HLS warmup.
    cached = None
    if not prewarm_manager.busy():
        try:
            cached = nextory.peek_book_and_layout(book_id)
        except AttributeError:
            pass
""", 'nonblocking book-detail peek')
    source = once(
        source,
        '''    if cached:
        info, tracks = cached
        return item_json(info, tracks, expanded=True)
    return preview_detail(preview)


@app.get('/api/items/{item_id}/cover')''',
        '''    if cached:
        info, tracks = cached
        result = item_json(info, tracks, expanded=True)
    else:
        result = preview_detail(preview)
    # NEXTORY_DETAIL_PREWARM_V1: schedule only after detail is ready.
    # Catalog/library listings and cover requests never call schedule().
    if expanded == 1:
        prewarm_manager.schedule(book_id)
    return result


@app.get('/api/items/{item_id}/cover')''',
        'details-only scheduling',
    )
    ast.parse(source, filename=str(MAIN))
    return source


current = MAIN.read_text(encoding='utf-8')
if MODE == 'rollback':
    if not BACKUP_MAIN.is_file() or not MODULE.is_file():
        fail('Geen volledige prewarm-backup gevonden.')
    baseline = BACKUP_MAIN.read_text(encoding='utf-8')
    expected = patch(baseline)
    if current != expected or MODULE.read_text(encoding='utf-8') != PREWARM_SOURCE:
        fail('Broncode is na het toepassen gewijzigd; rollback geweigerd om werk te behouden.')
    ast.parse(baseline, filename='baseline main.py')
    tmp = MAIN.with_name('main.py.prewarm-rollback-tmp')
    try:
        tmp.write_text(baseline, encoding='utf-8')
        os.chmod(tmp, MAIN.stat().st_mode & 0o777)
        os.replace(tmp, MAIN)
        MODULE.unlink()
    finally:
        tmp.unlink(missing_ok=True)
    print('ROLLBACK=RESTORED_PREVIOUS_TEST_MAIN')
    print('MODULE=REMOVED')
    print('ORIGINAL=NOT_MODIFIED')
    raise SystemExit(0)

nextory_source = (TEST/'app/nextory.py').read_text(encoding='utf-8')
if ('NEXTORY_LAYOUT_PARALLEL_V1' not in nextory_source or
        'NEXTORY_AUTH_RETRY' not in nextory_source or
        'AUDIOBOOTH_COMPAT_V1' not in nextory_source or
        'MAX_MANIFEST_BYTES = 8 * 1024 * 1024' not in nextory_source):
    fail('De eerder geteste HLS/auth/compat-patches ontbreken; niets gewijzigd.')
if 'AUDIOBOOTH_COMPAT_V1' not in current or 'POC_DIRECT_PLAYLIST_EXPERIMENT' not in current:
    fail('De eerdere AudioBooth/direct-HLS patches ontbreken in main.py.')

ast.parse(PREWARM_SOURCE, filename='prewarm.py')
if MARKER in current:
    if (not BACKUP_MAIN.is_file() or current != patch(BACKUP_MAIN.read_text(encoding='utf-8'))
            or not MODULE.is_file() or MODULE.read_text(encoding='utf-8') != PREWARM_SOURCE):
        fail('Prewarmpatch is veranderd of incompleet; niets overschrijven.')
    print('PATCH=ALREADY_APPLIED')
    raise SystemExit(0)
if MODULE.exists():
    fail('app/prewarm.py bestaat al; niet overschrijven.')
if BACKUP_MAIN.exists() and BACKUP_MAIN.read_text(encoding='utf-8') != current:
    fail('Eerdere backup verschilt van huidige code.')

updated = patch(current)
if not BACKUP_MAIN.exists():
    BACKUP_ROOT.mkdir(mode=0o700, exist_ok=True)
    shutil.copy2(MAIN, BACKUP_MAIN)
    os.chmod(BACKUP_MAIN, 0o600)
    print('BACKUP=CREATED')
else:
    print('BACKUP=REUSED')

tmp_module = MODULE.with_name('prewarm.py.install-tmp')
tmp_main = MAIN.with_name('main.py.prewarm-install-tmp')
try:
    tmp_module.write_text(PREWARM_SOURCE, encoding='utf-8')
    tmp_main.write_text(updated, encoding='utf-8')
    os.chmod(tmp_main, MAIN.stat().st_mode & 0o777)
    ast.parse(tmp_module.read_text(encoding='utf-8'), filename=str(MODULE))
    ast.parse(tmp_main.read_text(encoding='utf-8'), filename=str(MAIN))
    os.replace(tmp_module, MODULE)
    os.replace(tmp_main, MAIN)
except Exception:
    # Do not leave an import referencing a missing module.
    if MODULE.is_file() and MODULE.read_text(encoding='utf-8') == PREWARM_SOURCE:
        MODULE.unlink()
    if MARKER in MAIN.read_text(encoding='utf-8'):
        shutil.copy2(BACKUP_MAIN, MAIN)
    raise
finally:
    tmp_main.unlink(missing_ok=True)
    tmp_module.unlink(missing_ok=True)

print('PREWARM=DETAIL_ONLY_EXPANDED_1')
print('CACHE_TTL_SECONDS=120')
print('MAX_ACTIVE_BOOKS=2')
print('MAX_CACHE_ENTRIES=8')
print('AUDIO_BYTES_DOWNLOADED=NONE_BY_PREWARM')
print('HLS_WORKERS=4_PRESERVED')
print('PYTHON_SYNTAX=PASS')
print('ORIGINAL=NOT_MODIFIED')

PYINSTALL

echo
if [ "$OFFLINE" = 1 ]; then
  echo '=== 3. OFFLINE-VERIFICATIE ==='
  echo 'TEST_SOURCE_PATCH=PASS'
  exit 0
fi

echo '=== 3. ALLEEN TESTCONTAINER HERBOUWEN ==='
docker compose -p "$PROJECT" -f "$TEST/docker-compose.yml" -f "$TEST/docker-compose.test.yml" \
  up -d --build --no-deps "$SERVICE"
echo

echo '=== 4. WACHTEN OP /HEALTH ==='
READY=0
for _ in $(seq 1 20); do
  if docker exec nextory-abs-poc-test python -c 'import urllib.request; assert urllib.request.urlopen("http://127.0.0.1:8000/health", timeout=3).status == 200' >/dev/null 2>&1; then
    READY=1
    break
  fi
  sleep 2
done
if [ "$READY" != 1 ]; then
  echo 'ERROR: Testcontainer reageert niet op /health. Geen automatische rollback; inspecteer eerst de toestand.'
  docker logs --tail 25 nextory-abs-poc-test 2>&1 | grep -E 'ERROR|Exception|Traceback|startup' | tail -12 || true
  exit 1
fi

echo '=== 5. PATCH EN ISOLATIE VERIFIEREN ==='
docker exec -i nextory-abs-poc-test python - "$MODE" <<'PYVERIFY'
import inspect, sys
from app import main
from app.nextory import MAX_MANIFEST_BYTES, NextoryBackend
assert MAX_MANIFEST_BYTES == 8 * 1024 * 1024
assert 'NEXTORY_LAYOUT_PARALLEL_V1' in inspect.getsource(NextoryBackend.get_layout)
assert hasattr(NextoryBackend, '_authenticated_get_json')
if sys.argv[1] == 'apply':
    from app.prewarm import PrewarmManager
    assert isinstance(main.prewarm_manager, PrewarmManager)
    assert any(r.path == '/api/items/{item_id}' and 'GET' in r.methods for r in main.app.routes)
    print('PREWARM=ENABLED_DETAIL_ONLY')
else:
    assert not hasattr(main, 'prewarm_manager')
    print('PREWARM=DISABLED_AFTER_ROLLBACK')
print('HLS_LIMIT_BYTES=' + str(MAX_MANIFEST_BYTES))
print('AUTH_RETRY=PRESERVED')
print('LAYOUT_PARALLEL=PRESERVED')
PYVERIFY
docker inspect nextory-abs-poc-test --format 'TEST_RUNNING={{.State.Running}} HEALTH={{if .State.Health}}{{.State.Health.Status}}{{else}}unknown{{end}}'
docker inspect nextory-abs-poc --format 'ORIGINAL_RUNNING={{.State.Running}}'
docker ps --filter publish=13378 --format 'PORT_13378_OWNER={{.Names}}'
echo

echo '=== 6. VERVOLG ==='
if [ "$MODE" = 'apply' ]; then
  echo 'TEST: Open een boekdetailpagina in AudioBooth, wacht enkele seconden en druk daarna Play.'
  echo 'LOGS: docker logs --since 10m nextory-abs-poc-test 2>&1 | grep -E "POC_PREWARM|POC_PLAY_PHASE|POC_TIMING stage=play-start" | tail -30'
  echo 'ROLLBACK: bash ~/nextory-abs-virtual-poc-test/nextory-detail-prewarm-test.sh rollback'
else
  echo 'ROLLBACK=TEST_ONLY_COMPLETED'
fi
echo '=== EINDE ==='
