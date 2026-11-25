#!/usr/bin/env bash
# Nextory v6: isolated test-only direct HLS manifest experiment.
# Run: bash ~/nextory-abs-virtual-poc-test/nextory-hls-direct-test-v2.sh apply
# Undo: bash ~/nextory-abs-virtual-poc-test/nextory-hls-direct-test-v2.sh rollback
# Only app/main.py changes. Tests are NOT required on the Docker host.

TEST="${NEXTORY_TEST_DIR:-$HOME/nextory-abs-virtual-poc-test}"
ORIGINAL="${NEXTORY_ORIGINAL_DIR:-$HOME/nextory-abs-virtual-poc}"
PROJECT='nextory-abs-test'
SERVICE='nextory-abs-poc'
MODE="${1:-apply}"

clear 2>/dev/null || true

echo '=== 1. VOORCONTROLE ==='

if [ "$MODE" != apply ] && [ "$MODE" != rollback ]; then
    echo 'ERROR: Gebruik apply of rollback.'
    exit 1
fi
if [ ! -f "$TEST/app/main.py" ] || [ ! -f "$TEST/docker-compose.yml" ] || [ ! -f "$TEST/docker-compose.test.yml" ]; then
    echo 'ERROR: Testmap, broncode of Compose-override ontbreekt.'
    exit 1
fi
if [ ! -f "$ORIGINAL/app/main.py" ]; then
    echo 'ERROR: Originele v6-broncode niet gevonden.'
    exit 1
fi

if [ "${_NEXTORY_OFFLINE_VERIFY:-0}" != 1 ]; then
    original_running="$(docker inspect -f '{{.State.Running}}' nextory-abs-poc 2>/dev/null)"
    test_project="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' nextory-abs-poc-test 2>/dev/null)"
    test_image="$(docker inspect -f '{{.Config.Image}}' nextory-abs-poc-test 2>/dev/null)"
    test_running="$(docker inspect -f '{{.State.Running}}' nextory-abs-poc-test 2>/dev/null)"
    port_owner="$(docker ps --filter publish=13378 --format '{{.Names}}')"

    if [ "$original_running" != false ]; then
        echo 'ERROR: De originele v6-container is niet gestopt.'
        exit 1
    fi
    if [ "$test_project" != "$PROJECT" ] || [ "$test_image" != 'nextory-abs-poc-test:dev' ]; then
        echo 'ERROR: Testcontainer hoort niet bij het verwachte geisoleerde project.'
        exit 1
    fi
    if [ "$MODE" = apply ] && [ "$test_running" != true ]; then
        echo 'ERROR: Testcontainer draait niet. Eerst de containerstatus controleren.'
        exit 1
    fi
    if [ "$test_running" = true ] && [ "$port_owner" != 'nextory-abs-poc-test' ]; then
        echo 'ERROR: Poort 13378 is niet uitsluitend van de testcontainer.'
        exit 1
    fi
    if [ "$test_running" != true ] && [ -n "$port_owner" ]; then
        echo 'ERROR: Poort 13378 is door een andere container bezet.'
        exit 1
    fi

    # Verify effective Compose contract without printing expanded environment secrets.
    if ! TEST_DIR="$TEST" ORIGINAL_DIR="$ORIGINAL" PROJECT_NAME="$PROJECT" \
      python3 - <<'PY'
import json
import os
import subprocess
import sys
from pathlib import Path

test = Path(os.environ['TEST_DIR']).resolve()
original = Path(os.environ['ORIGINAL_DIR']).resolve()
project = os.environ['PROJECT_NAME']
cmd = ['docker', 'compose', '-p', project, '-f', str(test/'docker-compose.yml'), '-f', str(test/'docker-compose.test.yml'), 'config', '--format', 'json']
r = subprocess.run(cmd, capture_output=True, text=True, cwd=str(test))
if r.returncode:
    sys.exit('ERROR: Effectieve Compose-configuratie is ongeldig (details niet afgedrukt).')
try:
    cfg = json.loads(r.stdout)
    svc = cfg['services']['nextory-abs-poc']
    assert cfg['name'] == project
    assert svc['container_name'] == 'nextory-abs-poc-test'
    assert svc['image'] == 'nextory-abs-poc-test:dev'
    ports = svc['ports']
    assert len(ports) == 1 and str(ports[0]['published']) == '13378' and int(ports[0]['target']) == 8000
    build = svc['build']
    buildpath = Path(build['context'] if isinstance(build, dict) else build).resolve()
    assert buildpath == test
    assert not svc.get('network_mode') and not svc.get('volumes_from')
    for m in svc.get('volumes', []):
        kind, src = m.get('type'), m.get('source')
        if kind == 'bind':
            assert src
            source = Path(src).resolve()
            if source == original or original in source.parents:
                assert m.get('read_only') is True and m.get('target') == '/run/nextory'
            if not m.get('read_only', False):
                assert source == test or test in source.parents
        elif kind == 'volume' and src:
            d = cfg.get('volumes', {}).get(src, {})
            assert not d.get('external') and d.get('name','').startswith(project+'_')
    for net in (svc.get('networks') or {}):
        d = cfg.get('networks',{}).get(net,{})
        assert not d.get('external')
        assert not d.get('name') or d['name'].startswith(project+'_')
except (KeyError, AssertionError, TypeError, ValueError):
    sys.exit('ERROR: Compose-isolatie niet aangetoond. Niets gewijzigd.')
print('ISOLATION=PASS')
PY
    then
        echo '=== PATCH AFGEBROKEN ==='
        exit 1
    fi
else
    echo 'OFFLINE_VERIFICATION=YES'
fi

echo 'ORIGINAL=STOPPED_AND_UNCHANGED'
echo "MODE=$MODE"
echo 'PORT=13378'
echo
echo '=== 2. ALLEEN APP/MAIN.PY AANPASSEN ==='

python3 - "$TEST" "$ORIGINAL" "$MODE" <<'PY'
import ast
import os
import shutil
import sys
from pathlib import Path

root = Path(sys.argv[1]).resolve(strict=True)
original = Path(sys.argv[2]).resolve(strict=True)
mode = sys.argv[3]
main = root / 'app/main.py'
original_main = original / 'app/main.py'
backup = root / '.hls-direct-baseline' / 'app/main.py'
marker = 'POC_DIRECT_PLAYLIST_EXPERIMENT'

def fail(msg):
    raise SystemExit('ERROR: ' + msg)

if not main.is_file() or main.is_symlink() or main.resolve().is_relative_to(original):
    fail('Ongeldig doelbestand: app/main.py')
if os.path.samefile(main, original_main):
    fail('Testbestand en origineel zijn hetzelfde bestand (hardlink).')
if backup.is_symlink() or backup.parent.is_symlink():
    fail('Baseline is een symlink; bewerking geweigerd.')

if mode == 'rollback':
    if not backup.is_file():
        fail('Geen patch-back-up gevonden; niets terug te zetten.')
    baseline = backup.read_bytes()
    ast.parse(baseline.decode('utf-8'), filename='app/main.py baseline')
    shutil.copy2(backup, main)
    print('BACKUP_RESTORED=YES')
    print('DIRECT_PLAYLIST=DISABLED')
    raise SystemExit(0)

source = main.read_text(encoding='utf-8')
if backup.exists():
    original_source = backup.read_text(encoding='utf-8')
    if marker in source and marker not in original_source:
        print('PATCH=ALREADY_APPLIED')
        print('BACKUP=FOUND')
        raise SystemExit(0)
    if source != original_source:
        fail('Er bestaan onverwachte wijzigingen naast een eerdere baseline.')
else:
    original_source = source


def replace_once(content, before, after, description):
    n = content.count(before)
    if n != 1:
        fail(f'{description}: verwacht exact 1 codefragment, gevonden {n}. Niets gewijzigd.')
    return content.replace(before, after, 1)

patched = replace_once(
    source,
    'async def public_track(session_id: str, track_index: int):',
    'async def public_track(session_id: str, track_index: int, req: Request):',
    'Public track signature',
)
patched = replace_once(
    patched,
    "    return RedirectResponse(path, status_code=302,\n                            headers={'Cache-Control': 'no-store'})",
    "    # POC_DIRECT_PLAYLIST_EXPERIMENT: HLS manifest body, no 302 redirect.\n"
    "    token = session.root_tokens.get(track_index)\n"
    "    if not token:\n"
    "        raise HTTPException(status_code=404, detail='Playback manifest unavailable')\n"
    "    logging.getLogger('uvicorn.error').info(\n"
    "        'PLAY_TEST track=%d manifest_delivery=direct_200', track_index)\n"
    "    return await hls_resource(session_id, token, 'stream.m3u8', req)",
    'Direct playlist response',
)
patched = replace_once(
    patched,
    "        logging.info('POC_TIMING stage=%s status=%s elapsed_ms=%d',",
    "        logging.getLogger('uvicorn.error').info('POC_TIMING stage=%s status=%s elapsed_ms=%d',",
    'Timing log visibility',
)

# Fully validate before any live source change.
ast.parse(patched, filename=str(main))
compile(patched, str(main), 'exec')

if not backup.exists():
    backup.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    shutil.copy2(main, backup)
    os.chmod(backup, 0o600)
try:
    main.write_text(patched, encoding='utf-8')
except Exception:
    shutil.copy2(backup, main)
    raise

print('BACKUP_CREATED_OR_REUSED=.hls-direct-baseline/app/main.py')
print('DIRECT_PLAYLIST=ENABLED')
print('TIMING_LOGS=ENABLED')
print('PYTHON_SYNTAX=PASS')
print('TEST_FILES_REQUIRED=NO')
PY
if [ "$?" -ne 0 ]; then
    echo
echo '=== PATCH AFGEBROKEN ==='
    echo 'Origineel is niet gewijzigd. Testcontainer is niet herbouwd.'
    exit 1
fi

if [ "${_NEXTORY_OFFLINE_VERIFY:-0}" = 1 ]; then
    echo 'OFFLINE_PATCH_VERIFY=PASS'
    exit 0
fi

echo
echo '=== 3. ALLEEN TESTCONTAINER HERBOUWEN ==='
cd "$TEST" || exit 1

docker compose -p "$PROJECT" \
    -f docker-compose.yml \
    -f docker-compose.test.yml \
    up -d --build --no-deps "$SERVICE"
if [ "$?" -ne 0 ]; then
    echo 'ERROR: Testcontainer kon niet worden herbouwd.'
    echo 'Herstel met: bash nextory-hls-direct-test-v2.sh rollback'
    exit 1
fi

echo
echo '=== 4. EINDCONTROLE ==='
docker inspect nextory-abs-poc --format 'ORIGINAL_RUNNING={{.State.Running}}'
docker inspect nextory-abs-poc-test \
    --format 'TEST_RUNNING={{.State.Running}} HEALTH={{if .State.Health}}{{.State.Health.Status}}{{else}}unknown{{end}}'
docker ps --filter publish=13378 --format 'PORT_13378_OWNER={{.Names}}'

echo
echo '=== EINDE ==='
if [ "$MODE" = apply ]; then
    echo 'TEST_MODE=DIRECT_HLS_PLAYLIST'
    echo "ROLLBACK=bash $TEST/nextory-hls-direct-test-v2.sh rollback"
else
    echo 'TEST_MODE=ORIGINAL_V6_REDIRECT'
fi
