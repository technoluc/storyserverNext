#!/usr/bin/env bash
# Optionele server-side HLS A/B-test: sla de masterplaylist over als precies 1 simpele audiovariant bestaat.
# Alleen nextory-abs-poc-test; geen wijziging aan de originele v6 of AudioBooth.
# Gebruik: bash nextory-hls-direct-media-test.sh apply|rollback
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
for f in docker-compose.yml docker-compose.test.yml app/main.py app/nextory.py app/hls_proxy.py app/prewarm.py app/hls_delivery.py; do
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

echo '=== 2. HLS ROOT-OPTIMALISATIE ==='
python3 - "$TEST" "$ORIGINAL" "$MODE" <<'PY'
from __future__ import annotations
import ast
import os
import shutil
import sys
from pathlib import Path

test = Path(sys.argv[1]).resolve(strict=True)
original = Path(sys.argv[2]).resolve(strict=True)
mode = sys.argv[3]
main = test/'app/main.py'
helper = test/'app/hls_root.py'
original_main = original/'app/main.py'
backup_dir = test/'.nextory-hls-direct-media-baseline'
backup_main = backup_dir/'main.py'
marker = 'NEXTORY_HLS_DIRECT_MEDIA_V1'

helper_src = '''"""NEXTORY_HLS_DIRECT_MEDIA_V1: simplify single-variant HLS roots.

No audio fetched, decrypted, transcoded or stored. The original encrypted
media segments and keys are still relayed through the same existing proxy.
When a master is complex, retain the original response unchanged.
"""
from __future__ import annotations

from urllib.parse import urljoin

from .hls_proxy import rewrite_playlist
from .nextory import safe_remote_url


def direct_media_playlist(fetch_manifest, root_url, session):
    """Return (rewritten_text|None, reason, segment_count), safely.

    Only flatten VOD masters with precisely one variant and no extra
    renditions, session keys, variable imports or master-level start tags.
    All other masters use the unchanged HLS code path.
    """
    master, final_url = fetch_manifest(root_url)
    lines = [line.strip() for line in master.splitlines() if line.strip()]
    if not lines or lines[0] != '#EXTM3U':
        return None, 'invalid_master', 0
    if not any(line.startswith('#EXT-X-STREAM-INF:') for line in lines):
        return None, 'already_media', 0
    unsafe_tags = ('#EXT-X-MEDIA:', '#EXT-X-I-FRAME-STREAM-INF:',
                   '#EXT-X-SESSION-KEY:', '#EXT-X-DEFINE:', '#EXT-X-START:')
    if any(line.startswith(unsafe_tags) for line in lines):
        return None, 'complex_master', 0
    variants = []
    for index, line in enumerate(lines):
        if not line.startswith('#EXT-X-STREAM-INF:'):
            continue
        if index + 1 >= len(lines) or lines[index+1].startswith('#'):
            return None, 'invalid_variant', 0
        variants.append(lines[index+1])
    if len(variants) != 1:
        return None, 'multiple_variants', len(variants)
    child_url = safe_remote_url(urljoin(final_url, variants[0]))
    if child_url == root_url:
        return None, 'loop', 0
    media, media_url = fetch_manifest(child_url)
    lines = [line.strip() for line in media.splitlines() if line.strip()]
    if (not lines or lines[0] != '#EXTM3U'
        or not any(s.startswith('#EXTINF:') for s in lines)
        or not any(s.startswith('#EXT-X-TARGETDURATION:') for s in lines)
        or '#EXT-X-ENDLIST' not in lines
        or any(s.startswith(('#EXT-X-STREAM-INF:', '#EXT-X-MEDIA:')) for s in lines)):
        return None, 'unsupported_media', 0
    count = sum(s.startswith('#EXTINF:') for s in lines)
    return rewrite_playlist(media, media_url, session), 'direct_media', count
'''

old_import = 'from .hls_delivery import build_resource_response  # HLS_FIRSTPLAY_SERVER_V1\n'
new_import = old_import + 'from .hls_root import direct_media_playlist  # NEXTORY_HLS_DIRECT_MEDIA_V1\n'
old_entry = "    return await hls_resource(session_id, token, 'stream.m3u8', req)\n\n\n@app.api_route('/hls/{session_id}/{resource_token}/{filename}', methods=['GET', 'HEAD'])"
new_entry = '''    # NEXTORY_HLS_DIRECT_MEDIA_V1: avoid the extra master->variant hop when
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


@app.api_route('/hls/{session_id}/{resource_token}/{filename}', methods=['GET', 'HEAD'])'''

def patch(src):
    for old, new, label in ((old_import,new_import,'import'),(old_entry,new_entry,'track entry')):
        if src.count(old)!=1:
            raise SystemExit(f'ERROR: Onverwachte bestaande code ({label}); niets overschrijven.')
        src=src.replace(old,new,1)
    ast.parse(src,filename='main.py')
    return src

if main.samefile(original_main):
    raise SystemExit('ERROR: Originele en testbroncode verwijzen naar hetzelfde bestand.')
current = main.read_text(encoding='utf-8')

if mode == 'rollback':
    if not backup_main.is_file():
        raise SystemExit('ERROR: Geen bestaande backup voor rollback.')
    baseline = backup_main.read_text(encoding='utf-8')
    if current != patch(baseline) or not helper.exists() or helper.read_text(encoding='utf-8') != helper_src:
        raise SystemExit('ERROR: Huidige patch wijkt af; rollback niet veilig zonder inspectie.')
    shutil.copy2(backup_main,main)
    helper.unlink()
    print('ROLLBACK=PASS')
    print('PREWARM=UNCHANGED')
    print('HLS_BUFFERING=UNCHANGED')
    print('ORIGINAL=NOT_MODIFIED')
    raise SystemExit(0)

ast.parse(helper_src,filename='hls_root.py')
if marker in current:
    if not backup_main.is_file() or current != patch(backup_main.read_text(encoding='utf-8')) or not helper.is_file() or helper.read_text(encoding='utf-8') != helper_src:
        raise SystemExit('ERROR: Eerdere patch wijkt af; niets overschrijven.')
    print('PATCH=ALREADY_APPLIED')
    raise SystemExit(0)
if helper.exists():
    raise SystemExit('ERROR: app/hls_root.py bestaat al; niets overschrijven.')
if backup_main.is_file() and backup_main.read_text(encoding='utf-8') != current:
    raise SystemExit('ERROR: Bestaande backup is niet van de huidige testcode.')
modified=patch(current)
if not backup_main.is_file():
    backup_dir.mkdir(mode=0o700,exist_ok=True)
    shutil.copy2(main,backup_main)
    os.chmod(backup_main,0o600)
    print('BACKUP=CREATED')
else:
    print('BACKUP=REUSED')
# Commit the new module before the importing main file. Restore on error.
tmp_helper=helper.with_name('hls_root.install-tmp')
tmp_main=main.with_name('main.py.hls-root-install-tmp')
try:
    tmp_helper.write_text(helper_src,encoding='utf-8')
    tmp_main.write_text(modified,encoding='utf-8')
    ast.parse(tmp_helper.read_text(encoding='utf-8'))
    ast.parse(tmp_main.read_text(encoding='utf-8'))
    os.chmod(tmp_main,main.stat().st_mode & 0o777)
    os.replace(tmp_helper,helper)
    os.replace(tmp_main,main)
except Exception:
    if marker in main.read_text(encoding='utf-8'):
        shutil.copy2(backup_main, main)
    if helper.is_file() and helper.read_text(encoding='utf-8') == helper_src:
        helper.unlink()
    raise
finally:
    tmp_main.unlink(missing_ok=True)
    tmp_helper.unlink(missing_ok=True)

print('HLS_ROOT=FLATTEN_SINGLE_VARIANT')
print('MEDIA_AND_KEY_BYTES=UNCHANGED')
print('PREWARM=UNCHANGED')
print('AUDIO_STORED_ON_DISK=NO')
print('PYTHON_SYNTAX=PASS')
print('ORIGINAL=NOT_MODIFIED')
PY

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
assert isinstance(main.prewarm_manager, PrewarmManager)
assert MAX_MANIFEST_BYTES == 8 * 1024 * 1024
assert hasattr(NextoryBackend, '_authenticated_get_json')
if sys.argv[1] == 'apply':
    from app.hls_root import direct_media_playlist
    assert callable(direct_media_playlist)
    print('HLS_ROOT=TEST_SINGLE_MEDIA_VARIANT')
else:
    assert 'NEXTORY_HLS_DIRECT_MEDIA_V1' not in inspect.getsource(main.public_track)
    print('HLS_ROOT=RESTORED_PREVIOUS')
print('PREWARM=PRESERVED')
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
  echo 'TEST: Open een niet-gecachet boek in AudioBooth, wacht tot prewarm gereed is, druk 1x Play.'
  echo 'LOGS: docker logs --since 10m nextory-abs-poc-test 2>&1 | grep -E "POC_HLS_ROOT|POC_PREWARM stage=play|POC_TIMING stage=play-start" | tail -35'
  echo 'ROLLBACK: bash ~/nextory-abs-virtual-poc-test/nextory-hls-direct-media-test.sh rollback'
else
  echo 'ROLLBACK=COMPLETE_AFTER_HEALTH_CHECK'
fi
echo '=== EINDE ==='
