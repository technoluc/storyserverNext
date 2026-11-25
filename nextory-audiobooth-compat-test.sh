#!/usr/bin/env bash
# Isolated AudioBooth API compatibility and playback phase diagnostics.
# Apply:    bash ~/nextory-abs-virtual-poc-test/nextory-audiobooth-compat-test.sh apply
# Rollback: bash ~/nextory-abs-virtual-poc-test/nextory-audiobooth-compat-test.sh rollback
# Only the pre-existing test project is modified; original v6 stays untouched.
MODE="${1:-apply}"
TEST="${NEXTORY_TEST_DIR:-$HOME/nextory-abs-virtual-poc-test}"
ORIGINAL="${NEXTORY_ORIGINAL_DIR:-$HOME/nextory-abs-virtual-poc}"
PROJECT='nextory-abs-test'

clear 2>/dev/null || true
printf '=== 1. VEILIGHEIDSCONTROLE ===\n'
if [ "$MODE" != apply ] && [ "$MODE" != rollback ]; then
  echo 'ERROR: Kies apply of rollback.'; exit 1
fi
for f in docker-compose.yml docker-compose.test.yml app/main.py app/nextory.py app/progress.py; do
  if [ ! -f "$TEST/$f" ]; then echo "ERROR: Testbestand ontbreekt: $f"; exit 1; fi
done
for f in app/main.py app/nextory.py app/progress.py; do
  if [ ! -f "$ORIGINAL/$f" ]; then echo "ERROR: Origineel bronbestand ontbreekt: $f"; exit 1; fi
done
original_running="$(docker inspect -f '{{.State.Running}}' nextory-abs-poc 2>/dev/null)"
test_running="$(docker inspect -f '{{.State.Running}}' nextory-abs-poc-test 2>/dev/null)"
test_project="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' nextory-abs-poc-test 2>/dev/null)"
test_image="$(docker inspect -f '{{.Config.Image}}' nextory-abs-poc-test 2>/dev/null)"
port_owner="$(docker ps --filter publish=13378 --format '{{.Names}}')"
if [ "$original_running" != false ] || [ "$test_running" != true ] || [ "$test_project" != "$PROJECT" ] || [ "$test_image" != 'nextory-abs-poc-test:dev' ] || [ "$port_owner" != 'nextory-abs-poc-test' ]; then
  echo 'ERROR: Origineel/testproject/poort is niet veilig bevestigd.'; exit 1
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
    sys.exit('ERROR: Compose-configuratie kan niet gecontroleerd worden.')
try:
    config = json.loads(p.stdout)
    svc = config['services']['nextory-abs-poc']
    assert config['name'] == 'nextory-abs-test'
    assert svc['container_name'] == 'nextory-abs-poc-test'
    assert svc['image'] == 'nextory-abs-poc-test:dev'
    assert not svc.get('volumes_from') and not svc.get('network_mode')
    build = svc['build']
    context = Path(build['context'] if isinstance(build, dict) else build).resolve(strict=True)
    assert context == test
    ports = svc['ports']
    assert len(ports) == 1 and str(ports[0]['published']) == '13378' and int(ports[0]['target']) == 8000
    for m in svc.get('volumes', []):
        if m['type'] == 'bind':
            p = Path(m['source']).resolve()
            if p == original or original in p.parents:
                assert m.get('read_only') and m['target'] == '/run/nextory'
            if not m.get('read_only'):
                assert p == test or test in p.parents
        elif m['type'] == 'volume':
            vol = config.get('volumes', {}).get(m.get('source'), {})
            assert not vol.get('external', False)
            assert vol.get('name', '').startswith('nextory-abs-test_')
    for net in (svc.get('networks') or {}):
        cfg = config.get('networks', {}).get(net, {})
        assert not cfg.get('external') and (not cfg.get('name') or cfg['name'].startswith('nextory-abs-test_'))
except (KeyError, AssertionError, ValueError, TypeError, OSError):
    sys.exit('ERROR: Isolatiecontrole Compose mislukt.')
print('COMPOSE_ISOLATION=PASS')
PY
then
  echo '=== AFGEBROKEN ==='; exit 1
fi
printf 'ORIGINAL=STOPPED_AND_UNMODIFIED\nTEST=RUNNING\nPORT=13378\nMODE=%s\n' "$MODE"
printf '\n=== 2. CODE AANPASSEN ===\n'

if ! python3 - "$TEST" "$ORIGINAL" "$MODE" <<'PY'
from pathlib import Path
import ast, os, shutil, sys
root = Path(sys.argv[1]).resolve(strict=True)
orig = Path(sys.argv[2]).resolve(strict=True)
mode = sys.argv[3]
names = ('main.py', 'nextory.py', 'progress.py')
backup_dir = root / '.audiobooth-compat-baseline'
marker = 'AUDIOBOOTH_COMPAT_V1'

def fail(s): raise SystemExit('ERROR: ' + s)
if backup_dir.is_symlink(): fail('Backupmap is een symlink.')
if root == orig: fail('Testmap en originele map zijn gelijk.')
for name in names:
    a, b = root/'app'/name, orig/'app'/name
    if a.is_symlink() or b.is_symlink(): fail('Symlink bronbestand geweigerd.')
    if os.path.samefile(a,b): fail('Test en origineel delen dezelfde inode.')

if mode == 'rollback':
    if any(not (backup_dir/name).is_file() or (backup_dir/name).is_symlink() for name in names):
        fail('Geen volledige eerdere veilige backup voor rollback aanwezig.')
    live = {name: (root/'app'/name).read_text(encoding='utf-8') for name in names}
    if not all(marker in live[name] for name in names):
        fail('Onverwachte codeversie: rollback zou ongecontroleerd wijzigingen overschrijven.')
    code = {name: (backup_dir/name).read_text(encoding='utf-8') for name in names}
    if any(marker in code[name] for name in names):
        fail('Backup bevat al de compatibiliteitspatch.')
    print('RESTORE=PREVIOUS_TEST_SOURCE')
else:
    code = {name: (root/'app'/name).read_text(encoding='utf-8') for name in names}
    if all(marker in code[name] for name in names):
        print('PATCH=ALREADY_APPLIED')
        sys.exit(0)
    if any(marker in code[name] for name in names):
        fail('Slechts een deel van de patch is aanwezig.')
    previous_backup = any((backup_dir/name).exists() for name in names)
    if previous_backup:
        if any(not (backup_dir/name).is_file() or (backup_dir/name).is_symlink() for name in names):
            fail('Onvolledige of onveilige backupmap aangetroffen.')
        if any((backup_dir/name).read_text(encoding='utf-8') != code[name] for name in names):
            fail('Testcode wijkt af van backup terwijl patch ontbreekt; inspectie vereist.')

    def replace_once(name, old, new, label):
        if code[name].count(old) != 1:
            fail(f'{name} {label}: verwacht 1 match, gevonden {code[name].count(old)}.')
        code[name] = code[name].replace(old, new, 1)

    # 1. The iOS User.MediaProgress decoder requires a non-null startedAt (ms).
    replace_once('main.py',
        "'hideFromContinueListening': False, 'finishedAt': None, 'startedAt': None}",
        "'hideFromContinueListening': False, 'finishedAt': None,\n"
        "            'startedAt': int(current.get('startedAt') or current['lastUpdate'])}  # AUDIOBOOTH_COMPAT_V1",
        'progress startedAt')
    # 2. A missing progress entry must be a 404, not {}, per AudioBooth ProgressService.
    replace_once('main.py',
        "@app.get('/api/me/progress/{item_id}')\n"
        "async def get_progress(item_id: str, _: bool = Depends(authenticated)):\n"
        "    return _progress_json(id_to_book(item_id)) or {}\n",
        "@app.get('/api/me/progress/{item_id}')\n"
        "async def get_progress(item_id: str, _: bool = Depends(authenticated)):\n"
        "    result = _progress_json(id_to_book(item_id))\n"
        "    if result is None:\n"
        "        raise HTTPException(status_code=404, detail='No saved progress')\n"
        "    return result\n\n"
        "\n@app.patch('/api/me/progress/{item_id}')\n"
        "async def update_progress(item_id: str, req: Request, _: bool = Depends(authenticated)):\n"
        "    \"\"\"AUDIOBOOTH_COMPAT_V1: preserve play position sent by AudioBooth.\"\"\"\n"
        "    book_id = id_to_book(item_id)\n"
        "    try:\n"
        "        payload = await req.json()\n"
        "        if not isinstance(payload, dict):\n"
        "            raise ValueError('Invalid progress body')\n"
        "        previous = progress_store.get(book_id) or {}\n"
        "        raw_duration = payload.get('duration', previous.get('duration'))\n"
        "        raw_time = payload.get('currentTime', previous.get('currentTime'))\n"
        "        duration = float(raw_duration)\n"
        "        current_time = float(raw_time)\n"
        "        if not (math.isfinite(duration) and 0 < duration <= 7*24*3600\n"
        "                and math.isfinite(current_time) and 0 <= current_time <= duration + 1):\n"
        "            raise ValueError('Invalid progress times')\n"
        "        if payload.get('isFinished') is True:\n"
        "            current_time = duration\n"
        "        await run_in_threadpool(progress_store.update, book_id,\n"
        "                                current_time=min(current_time, duration), duration=duration)\n"
        "    except (ValueError, TypeError, OverflowError):\n"
        "        raise HTTPException(status_code=400, detail='Invalid progress update')\n"
        "    except OSError as exc:\n"
        "        raise HTTPException(status_code=503, detail='Progress store unavailable') from exc\n"
        "    return Response(content='OK', media_type='text/plain')\n", 
        'progress GET/PATCH')
    # 3. AudioBooth's ListeningStats needs days and today.
    replace_once('main.py',
        "@app.get('/api/me/listening-stats')\n"
        "async def listening_stats(_: bool = Depends(authenticated)):\n"
        "    return {'totalTime': 0, 'items': []}\n\n\n"
        "@app.get('/api/me/item/listening-sessions/{item_id}')\n"
        "async def listening_sessions(item_id: str, _: bool = Depends(authenticated)):\n"
        "    return []\n",
        "@app.get('/api/me/listening-stats')\n"
        "async def listening_stats(_: bool = Depends(authenticated)):\n"
        "    # AUDIOBOOTH_COMPAT_V1: honest placeholders until session history is implemented.\n"
        "    return {'totalTime': 0.0, 'today': 0.0, 'days': {}, 'items': {}}\n\n\n"
        "@app.get('/api/me/item/listening-sessions/{item_id}')\n"
        "async def listening_sessions(item_id: str, _: bool = Depends(authenticated)):\n"
        "    id_to_book(item_id)\n"
        "    return {'numPages': 0, 'page': 0, 'itemsPerPage': 10, 'sessions': []}\n",
        'listening stats/sessions')
    # 4. Stage timings for first play: book/provider vs HLS chapter layout.
    replace_once('main.py',
        "async def book_and_layout(item_id: str) -> tuple[BookInfo, tuple[TrackPart, ...]]:\n"
        "    book_id = id_to_book(item_id)\n"
        "    try:\n"
        "        info, tracks = await run_in_threadpool(lambda: (nextory.get_book(book_id), nextory.get_layout(book_id)))\n"
        "        return info, tracks\n"
        "    except NextoryError as exc:\n"
        "        raise HTTPException(status_code=503, detail=str(exc)) from exc\n",
        "async def book_and_layout(item_id: str) -> tuple[BookInfo, tuple[TrackPart, ...]]:\n"
        "    book_id = id_to_book(item_id)\n"
        "    def collect():\n"
        "        started = time.perf_counter()\n"
        "        info = nextory.get_book(book_id)\n"
        "        book_ms = int((time.perf_counter() - started) * 1000)\n"
        "        started = time.perf_counter()\n"
        "        tracks = nextory.get_layout(book_id)\n"
        "        layout_ms = int((time.perf_counter() - started) * 1000)\n"
        "        return info, tracks, book_ms, layout_ms\n"
        "    try:\n"
        "        info, tracks, book_ms, layout_ms = await run_in_threadpool(collect)\n"
        "        logging.getLogger('uvicorn.error').info(\n"
        "            'POC_PLAY_PHASE book_ms=%d layout_ms=%d tracks=%d',\n"
        "            book_ms, layout_ms, len(tracks))  # AUDIOBOOTH_COMPAT_V1\n"
        "        return info, tracks\n"
        "    except NextoryError as exc:\n"
        "        raise HTTPException(status_code=503, detail=str(exc)) from exc\n",
        'play phase timings')

    # 5. Record whether HLS durations needed all parts or only spot checks.
    source = code['nextory.py']
    marker_start = '    def get_layout(self, book_id: int) -> tuple[TrackPart, ...]:\n'
    marker_end = '    def remote_get(self, url: str, *, byte_range: str | None = None) -> requests.Response:\n'
    if source.count(marker_start) != 1 or source.count(marker_end) != 1:
        fail('nextory.py get_layout afbakening ontbreekt.')
    before, remaining = source.split(marker_start, 1)
    layout_body, after = remaining.split(marker_end, 1)
    if layout_body.count('self.first_part_duration(') != 4:
        fail('get_layout aantal first_part_duration-aanroepen onverwacht.')
    layout_body = layout_body.replace('self.first_part_duration(', 'measured_duration(')
    old = "            info = self.get_book(book_id)\n            parts = info.parts\n"
    new = ("            info = self.get_book(book_id)\n"
           "            parts = info.parts\n"
           "            started = time.perf_counter()\n"
           "            manifest_parts = 0\n"
           "            def measured_duration(url):\n"
           "                nonlocal manifest_parts\n"
           "                manifest_parts += 1\n"
           "                return self.first_part_duration(url)\n")
    if layout_body.count(old) != 1: fail('get_layout startfragment veranderd.')
    layout_body = layout_body.replace(old,new,1)
    old = "                if usable:\n                    starts = [round(s - starts[0], 3) for s in starts]"
    new = "                if usable:\n                    layout_mode = 'provider_starts'\n                    starts = [round(s - starts[0], 3) for s in starts]"
    if layout_body.count(old) != 1: fail('get_layout provider-start fragment veranderd.')
    layout_body = layout_body.replace(old,new,1)
    old = "                else:\n                    durations = [0.0] * len(parts)"
    new = "                else:\n                    layout_mode = 'manifest_fallback'\n                    durations = [0.0] * len(parts)"
    if layout_body.count(old) != 1: fail('get_layout fallback fragment veranderd.')
    layout_body = layout_body.replace(old,new,1)
    old = "            self._layouts[book_id] = (result, time.monotonic())\n            return result"
    new = ("            self._layouts[book_id] = (result, time.monotonic())\n"
           "            logging.getLogger('uvicorn.error').info(\n"
           "                'POC_LAYOUT mode=%s parts=%d sampled_parts=%d elapsed_ms=%d',\n"
           "                layout_mode, len(parts), manifest_parts,\n"
           "                int((time.perf_counter() - started)*1000))  # AUDIOBOOTH_COMPAT_V1\n"
           "            return result")
    if layout_body.count(old) != 1: fail('get_layout einde veranderd.')
    layout_body = layout_body.replace(old,new,1)
    code['nextory.py'] = before + marker_start + layout_body + marker_end + after

    # 6. Preserve a genuine progress start timestamp on future writes.
    replace_once('progress.py',
        "        with self._lock:\n            self._entries[str(book_id)] = value\n",
        "        with self._lock:\n"
        "            previous = self._entries.get(str(book_id)) or {}\n"
        "            first_seen = previous.get('startedAt') or previous.get('lastUpdate') or now\n"
        "            value['startedAt'] = int(first_seen)  # AUDIOBOOTH_COMPAT_V1\n"
        "            self._entries[str(book_id)] = value\n",
        'progress first timestamp')

    for name in names:
        try: ast.parse(code[name], filename=name)
        except SyntaxError as exc: fail(f'{name} syntaxcontrole mislukt: {exc}')
    if not previous_backup:
        backup_dir.mkdir(exist_ok=False)
        for name in names:
            shutil.copy2(root/'app'/name, backup_dir/name)
        print('BACKUP=CREATED')
    else:
        print('BACKUP=REUSED')
    print('BACKUP_PATH=.audiobooth-compat-baseline/{main,nextory,progress}.py')
    print('API_FIXES=STARTED_AT,LST_SESSIONS,LST_STATS,MISSING_PROGRESS,PATCH_PROGRESS')
    print('TIMING=POC_PLAY_PHASE,POC_LAYOUT')

for name in names:
    target = root/'app'/name
    try: ast.parse(code[name], filename=name)
    except SyntaxError: fail(f'{name} herstelde code bevat syntaxfout.')
    temp = target.with_name(target.name + '.audiobooth-tmp')
    temp.write_text(code[name], encoding='utf-8')
    os.chmod(temp, target.stat().st_mode & 0o777)
    os.replace(temp, target)
print('PYTHON_SYNTAX=PASS')
print('ORIGINAL=NOT_MODIFIED')
PY
then
  echo '=== CODEPATCH MISLUKT ==='; exit 1
fi

printf '\n=== 3. ALLEEN TESTCONTAINER HERBOUWEN ===\n'
if ! docker compose -p "$PROJECT" -f "$TEST/docker-compose.yml" -f "$TEST/docker-compose.test.yml" up -d --build --no-deps nextory-abs-poc; then
  echo 'ERROR: Testcontainer rebuild mislukt; gebruik rollback.'; exit 1
fi
printf '\n=== 4. EINDCONTROLE ===\n'
if ! docker exec -i nextory-abs-poc-test python - <<'PY'
import json
import urllib.request
from app import main
from app.nextory import NextoryBackend, MAX_MANIFEST_BYTES
paths = {(tuple(sorted(route.methods or ())), route.path)
         for route in main.app.routes if hasattr(route,'methods')}
assert (('PATCH',),'/api/me/progress/{item_id}') in paths
assert hasattr(NextoryBackend,'_authenticated_get_json')
assert MAX_MANIFEST_BYTES >= 8*1024*1024
headers = {'Authorization':'Bearer '+main.make_token()}
item_id = main.item_id_for(main.configured_ids()[0])
def get(path):
    req = urllib.request.Request('http://127.0.0.1:8000'+path,headers=headers)
    with urllib.request.urlopen(req,timeout=5) as response:
        assert response.status == 200
        return json.load(response)
stats = get('/api/me/listening-stats')
assert all(key in stats for key in ('totalTime','today','days','items'))
assert isinstance(stats['days'],dict) and isinstance(stats['items'],dict)
sessions = get('/api/me/item/listening-sessions/'+item_id)
assert isinstance(sessions,dict) and all(k in sessions for k in ('sessions','numPages','page','itemsPerPage'))
print('API_COMPAT_SMOKE=PASS')
print('AUTH_RETRY=PRESERVED')
print('HLS_LIMIT_BYTES='+str(MAX_MANIFEST_BYTES))
PY
then
  echo 'ERROR: Testcontainer is niet gereed / endpointcontrole mislukt.'
  exit 1
fi
docker inspect nextory-abs-poc-test --format 'TEST_RUNNING={{.State.Running}} HEALTH={{if .State.Health}}{{.State.Health.Status}}{{else}}unknown{{end}}'
docker inspect nextory-abs-poc --format 'ORIGINAL_RUNNING={{.State.Running}}'
docker ps --filter publish=13378 --format 'PORT_13378_OWNER={{.Names}}'
echo
if [ "$MODE" = apply ]; then
  echo 'TEST: Start in AudioBooth een nog niet eerder afgespeeld boek.'
  echo 'LOGS: docker logs --since 5m nextory-abs-poc-test 2>&1 | grep -E "POC_PLAY_PHASE|POC_LAYOUT|POC_TIMING stage=play-start" | tail -15'
  echo 'ROLLBACK: bash ~/nextory-abs-virtual-poc-test/nextory-audiobooth-compat-test.sh rollback'
else
  echo 'ROLLBACK_COMPLETED=TEST_ONLY'
fi
echo '=== EINDE ==='
