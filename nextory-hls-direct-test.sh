#!/usr/bin/env bash
# Nextory v6 test-only A/B experiment. No edits to the original project.
# Usage: bash ~/nextory-abs-virtual-poc-test/nextory-hls-direct-test.sh apply
# Revert: bash ~/nextory-abs-virtual-poc-test/nextory-hls-direct-test.sh rollback

TEST="${NEXTORY_TEST_DIR:-$HOME/nextory-abs-virtual-poc-test}"
ORIGINAL="$HOME/nextory-abs-virtual-poc"
PROJECT="nextory-abs-test"
SERVICE="nextory-abs-poc"
MODE="${1:-apply}"

clear 2>/dev/null || true

echo "=== 1. VOORCONTROLE ==="
if [ "$MODE" != "apply" ] && [ "$MODE" != "rollback" ]; then
    echo "ERROR: Gebruik 'apply' of 'rollback'."
    exit 1
fi

if [ ! -f "$TEST/app/main.py" ] || [ ! -f "$TEST/docker-compose.test.yml" ]; then
    echo "ERROR: De testomgeving is niet compleet."
    exit 1
fi
if [ ! -f "$ORIGINAL/app/main.py" ]; then
    echo "ERROR: Originele v6-projectmap ontbreekt."
    exit 1
fi

# The offline mode is used solely for testing the patch logic against the v6 archive.
if [ "${_NEXTORY_OFFLINE_VERIFY:-0}" != "1" ]; then
    orig_state="$(docker inspect -f '{{.State.Running}}' nextory-abs-poc 2>/dev/null)"
    test_state="$(docker inspect -f '{{.State.Running}}' nextory-abs-poc-test 2>/dev/null)"
    test_project="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' nextory-abs-poc-test 2>/dev/null)"
    test_image="$(docker inspect -f '{{.Config.Image}}' nextory-abs-poc-test 2>/dev/null)"
    port_owner="$(docker ps --filter publish=13378 --format '{{.Names}}')"

    if [ "$orig_state" != "false" ]; then
        echo "ERROR: Originele container moet gestopt blijven."
        exit 1
    fi
    if [ "$test_project" != "$PROJECT" ] || [ "$test_image" != 'nextory-abs-poc-test:dev' ]; then
        echo "ERROR: De container hoort niet bij het verwachte testproject."
        exit 1
    fi
    if [ "$MODE" = "apply" ] && [ "$test_state" != "true" ]; then
        echo "ERROR: De testcontainer draait niet; eerst de bestaande testomgeving controleren."
        exit 1
    fi
    if [ "$test_state" = "true" ] && [ "$port_owner" != 'nextory-abs-poc-test' ]; then
        echo "ERROR: Poort 13378 heeft een onverwachte eigenaar."
        exit 1
    fi
    if [ "$test_state" != "true" ] && [ -n "$port_owner" ]; then
        echo "ERROR: Poort 13378 is al in gebruik."
        exit 1
    fi
fi

echo "ORIGINAL=UNCHANGED_AND_STOPPED"
echo "TEST_PROJECT=$PROJECT"
echo "PORT=13378"
echo "MODE=$MODE"

echo
echo "=== 2. TESTCODE AANPASSEN ==="
python3 - "$TEST" "$ORIGINAL" "$MODE" <<'PY'
import ast
import os
import shutil
import sys
from pathlib import Path

root = Path(sys.argv[1]).resolve(strict=True)
original = Path(sys.argv[2]).resolve(strict=True)
mode = sys.argv[3]
backup = root / '.hls-direct-baseline'

files = {
    'app/main.py': root / 'app/main.py',
    'tests/test_v6.py': root / 'tests/test_v6.py',
    'tests/test_contract.py': root / 'tests/test_contract.py',
}

def fail(message):
    raise SystemExit('ERROR: ' + message)

for name, path in files.items():
    if not path.is_file():
        fail('Testbestand ontbreekt: ' + name)
    if not path.is_relative_to(root) or path.is_symlink():
        fail('Testbestand wijst buiten testmap: ' + name)
    if path.resolve().is_relative_to(original):
        fail('Origineel bestand mag niet worden gewijzigd: ' + name)

if mode == 'rollback':
    if not backup.is_dir():
        fail('Er bestaat geen baseline om terug te zetten.')
    for name, path in files.items():
        source = backup / name
        if not source.is_file():
            fail('Baseline onvolledig: ' + name)
    for name, path in files.items():
        shutil.copy2(backup / name, path)
    print('BACKUP_RESTORED=YES')
    print('DIRECT_PLAYLIST=DISABLED')
    raise SystemExit(0)

if backup.exists():
    fail('Patch is eerder toegepast. Gebruik rollback, niet opnieuw apply.')

original_main = files['app/main.py'].read_text(encoding='utf-8')
original_v6 = files['tests/test_v6.py'].read_text(encoding='utf-8')
original_contract = files['tests/test_contract.py'].read_text(encoding='utf-8')

def replace_once(source, old, new, label):
    count = source.count(old)
    if count != 1:
        fail(f'{label}: verwacht exact 1 codefragment, gevonden {count}; niets gewijzigd')
    return source.replace(old, new, 1)

main = replace_once(
    original_main,
    'async def public_track(session_id: str, track_index: int):',
    'async def public_track(session_id: str, track_index: int, req: Request):',
    'Track handler signature',
)
main = replace_once(
    main,
    "    return RedirectResponse(path, status_code=302,\n                            headers={'Cache-Control': 'no-store'})",
    "    # POC_DIRECT_PLAYLIST_EXPERIMENT: send HLS bytes directly instead of HTTP 302.\n"
    "    # Reuse the exact same manifest rewrite and Nextory proxy as /hls.\n"
    "    token = session.root_tokens.get(track_index)\n"
    "    if not token:\n"
    "        raise HTTPException(status_code=404, detail='Playback manifest unavailable')\n"
    "    logging.getLogger('uvicorn.error').info(\n"
    "        'PLAY_TEST track=%d manifest_delivery=direct_200', track_index)\n"
    "    return await hls_resource(session_id, token, 'stream.m3u8', req)",
    'Redirect-to-direct change',
)
main = replace_once(
    main,
    "        logging.info('POC_TIMING stage=%s status=%s elapsed_ms=%d',",
    "        logging.getLogger('uvicorn.error').info('POC_TIMING stage=%s status=%s elapsed_ms=%d',",
    'Timing logger correction',
)

test_v6 = replace_once(
    original_v6,
    "    assert r.status_code == 302, r.text\n"
    "    assert r.headers['location'].endswith('stream.m3u8')\n"
    "    playlist = client.get(r.headers['location'])\n"
    "    assert playlist.status_code == 200",
    "    assert r.status_code == 200, r.text\n"
    "    assert 'location' not in r.headers\n"
    "    assert r.headers['content-type'].startswith('application/vnd.apple.mpegurl')\n"
    "    playlist = r\n"
    "    head = client.head(f'/public/session/{sid}/track/1')\n"
    "    assert head.status_code == 200\n"
    "    assert head.content == b''\n"
    "    assert int(head.headers['content-length']) == len(r.content)",
    'v6 first-track test',
)

test_contract = replace_once(
    original_contract,
    "        assert resp.status_code == 302\n        playlist = client.get(f'/public/session/{sid}/track/{index}').text",
    "        assert resp.status_code == 200\n"
    "        assert 'location' not in resp.headers\n"
    "        assert resp.headers['content-type'].startswith('application/vnd.apple.mpegurl')\n"
    "        playlist = resp.text",
    'contract redirect test',
)
test_contract = replace_once(
    test_contract,
    "    assert reply.status_code == 302\n    new = registry.get(sid).resource",
    "    assert reply.status_code == 200\n    new = registry.get(sid).resource",
    'contract refresh test',
)
test_contract = replace_once(
    test_contract,
    "    assert 'signed-url=refreshed' not in reply.headers['location']",
    "    assert 'signed-url=refreshed' not in reply.text",
    'contract signed-url safety test',
)

# Validate all replacements before touching any source file.
for name, data in [('app/main.py', main), ('tests/test_v6.py', test_v6),
                   ('tests/test_contract.py', test_contract)]:
    ast.parse(data, filename=name)

try:
    backup.mkdir(mode=0o700)
    for name, path in files.items():
        dest = backup / name
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, dest)
    contents = {'app/main.py': main, 'tests/test_v6.py': test_v6,
                'tests/test_contract.py': test_contract}
    for name, path in files.items():
        path.write_text(contents[name], encoding='utf-8')
except Exception:
    for name, path in files.items():
        source = backup / name
        if source.is_file():
            shutil.copy2(source, path)
    raise

print('BACKUP_CREATED=.hls-direct-baseline')
print('DIRECT_PLAYLIST=ENABLED')
print('TIMING_LOGS=ENABLED')
print('SOURCE_SYNTAX=PASS')
PY
if [ "$?" -ne 0 ]; then
    echo
echo "=== PATCH AFGEBROKEN ==="
    echo "Origineel is niet gewijzigd. De testcontainer is niet herbouwd."
    exit 1
fi

if [ "${_NEXTORY_OFFLINE_VERIFY:-0}" = "1" ]; then
    echo "OFFLINE_PATCH_VERIFY=PASS"
    exit 0
fi

echo
echo "=== 3. ALLEEN TESTCONTAINER HERBOUWEN ==="
cd "$TEST" || exit 1

docker compose -p "$PROJECT" \
    -f docker-compose.yml \
    -f docker-compose.test.yml \
    up -d --build --no-deps "$SERVICE"
if [ "$?" -ne 0 ]; then
    echo "ERROR: Testcontainer kon niet worden herbouwd."
    echo "Het origineel is ongewijzigd; herstel zo nodig met rollback."
    exit 1
fi

echo
echo "=== 4. EINDCONTROLE ==="

docker inspect nextory-abs-poc \
    --format 'ORIGINAL_RUNNING={{.State.Running}}'
docker inspect nextory-abs-poc-test \
    --format 'TEST_RUNNING={{.State.Running}} HEALTH={{if .State.Health}}{{.State.Health.Status}}{{else}}unknown{{end}}'
docker ps --filter publish=13378 \
    --format 'PORT_13378_OWNER={{.Names}}'

echo
echo "=== 5. RESULTAAT ==="
if [ "$MODE" = "apply" ]; then
    echo "TEST_MODE=DIRECT_HLS_PLAYLIST"
    echo "PLAY_TEST_LOGS=ENABLED"
    echo "ROLLBACK=bash $TEST/nextory-hls-direct-test.sh rollback"
else
    echo "TEST_MODE=ORIGINAL_V6_REDIRECT"
fi
