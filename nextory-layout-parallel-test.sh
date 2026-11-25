#!/usr/bin/env bash
# Test-only parallel HLS chapter-duration probing for AudioBooth/Nextory.
# Usage: bash nextory-layout-parallel-test.sh apply|rollback
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

echo '=== 2. TESTBRONCODE AANPASSEN ==='
python3 - "$TEST" "$ORIGINAL" "$MODE" <<'PY'
import ast, os, shutil, sys
from pathlib import Path
root=Path(sys.argv[1]).resolve(strict=True)
orig=Path(sys.argv[2]).resolve(strict=True)
mode=sys.argv[3]
source_file=root/'app/nextory.py'
original_file=orig/'app/nextory.py'
backup=root/'.nextory-layout-parallel-baseline/nextory.py'
marker='NEXTORY_LAYOUT_PARALLEL_V1'

def fail(msg): raise SystemExit('ERROR: '+msg)
if source_file.is_symlink() or original_file.is_symlink() or os.path.samefile(source_file,original_file):
    fail('Symlink of gedeelde inode voor testbroncode.')
if root==orig or root in orig.parents or orig in root.parents:
    fail('Test- en originele map overlappen.')
if backup.is_symlink() or backup.parent.is_symlink():
    fail('Onveilige backup-locatie.')

def patch(src):
    if 'AUDIOBOOTH_COMPAT_V1' not in src or 'NEXTORY_AUTH_RETRY' not in src:
        fail('Compatibiliteitspatch of authenticatiepatch ontbreekt.')
    if 'MAX_MANIFEST_BYTES = 8 * 1024 * 1024' not in src:
        fail('8 MiB HLS-limiet ontbreekt; niets wijzigen.')
    if marker in src:
        fail('Parallelpatch is reeds aanwezig in de aangeleverde baseline.')
    def once(before, after, label):
        nonlocal src
        count=src.count(before)
        if count!=1:
            fail(f'{label}: verwacht 1 fragment, gevonden {count}.')
        src=src.replace(before,after,1)

    once('import io\nimport ipaddress\n',
         'import io\nimport ipaddress\nfrom concurrent.futures import ThreadPoolExecutor\n',
         'ThreadPoolExecutor import')
    once('        self._authed_at = 0.0\n        # Dedicated device identity',
         '        self._authed_at = 0.0\n'
         '        self._duration_worker = threading.local()  # NEXTORY_LAYOUT_PARALLEL_V1\n'
         '        # Dedicated device identity',
         'thread-local per-worker sessions')

    start='    def remote_get(self, url: str, *, byte_range: str | None = None) -> requests.Response:\n'
    worker='''    def _isolated_duration(self, url: str, api_headers: dict, api_cookies) -> float:
        """NEXTORY_LAYOUT_PARALLEL_V1: One independent HTTP session per worker.

        Parent holds _lock; worker MUST NEVER acquire _lock or call _ensure_login().
        OAuth/profile headers are copied only to that worker's private API session.
        No media bytes are downloaded, and no signed URLs are written to disk.
        """
        with requests.Session() as api, requests.Session() as public:
            api.headers.update(api_headers)
            api.cookies.update(api_cookies)
            self._duration_worker.api = api
            self._duration_worker.public = public
            try:
                return self.first_part_duration(url)
            finally:
                del self._duration_worker.api
                del self._duration_worker.public

'''
    once(start,worker+start,'worker helper')
    before='''            if host == 'api.nextory.com':
                self._ensure_login()
            session = self._api if host == 'api.nextory.com' else self._public
'''
    after='''            worker_api = getattr(self._duration_worker, 'api', None)
            worker_public = getattr(self._duration_worker, 'public', None)
            if host == 'api.nextory.com':
                if worker_api is None:
                    self._ensure_login()
                session = worker_api if worker_api is not None else self._api
            else:
                session = worker_public if worker_public is not None else self._public
'''
    once(before,after,'remote_get thread-specific session selection')
    before='''                    if len(parts) > 2:
                        # Keep the login/header lock re-entrant: media URLs may
                        # themselves be on api.nextory.com, so background worker
                        # threads here could deadlock on _ensure_login().
                        for i, part in enumerate(parts[1:-1], 1):
                            durations[i] = measured_duration(part['uri'])
'''
    after='''                    if len(parts) > 2:
                        # NEXTORY_LAYOUT_PARALLEL_V1: exact HLS durations, now
                        # fetched with isolated sessions and bounded concurrency.
                        # The _lock remains held; workers never call _ensure_login.
                        self._ensure_login()
                        api_headers = dict(self._api.headers)
                        api_cookies = self._api.cookies.copy()
                        urls = [part['uri'] for part in parts[1:-1]]
                        workers = min(4, len(urls))
                        parallel_started = time.perf_counter()
                        with ThreadPoolExecutor(max_workers=workers, thread_name_prefix='nextory-hls') as pool:
                            measured = list(pool.map(
                                lambda url: self._isolated_duration(url, api_headers, api_cookies), urls
                            ))
                        for i, duration in enumerate(measured, 1):
                            durations[i] = duration
                        manifest_parts += len(urls)
                        logging.getLogger('uvicorn.error').info(
                            'POC_LAYOUT_PARALLEL requests=%d workers=%d elapsed_ms=%d',
                            len(urls), workers, int((time.perf_counter()-parallel_started)*1000))
'''
    once(before,after,'sequential manifest fallback -> bounded parallel')
    ast.parse(src,filename='nextory.py')
    return src

current=source_file.read_text(encoding='utf-8')
if mode=='rollback':
    if not backup.is_file(): fail('Baseline ontbreekt; niets terugdraaien.')
    baseline=backup.read_text(encoding='utf-8')
    expected=patch(baseline)
    if current != expected:
        fail('Testcode is na de parallelpatch gewijzigd; ongecontroleerde rollback geweigerd.')
    updated=baseline
    print('RESTORE=PREVIOUS_TEST_SOURCE')
else:
    if marker in current:
        if not backup.is_file() or current != patch(backup.read_text(encoding='utf-8')):
            fail('Parallelpatch aanwezig, maar backup/inhoud wijkt af.')
        print('PATCH=ALREADY_APPLIED')
        sys.exit(0)
    updated=patch(current)
    if backup.exists():
        if backup.read_text(encoding='utf-8') != current:
            fail('Eerdere backup verschilt; handmatige inspectie vereist.')
        print('BACKUP=REUSED')
    else:
        backup.parent.mkdir(exist_ok=True)
        shutil.copy2(source_file,backup)
        print('BACKUP=CREATED')
    print('WORKERS_MAX=4')
    print('AUDIO_STREAM=UNCHANGED')

ast.parse(updated,filename=str(source_file))
tmp=source_file.with_name(source_file.name+'.layout-parallel-tmp')
tmp.write_text(updated,encoding='utf-8')
os.chmod(tmp, source_file.stat().st_mode & 0o777)
os.replace(tmp,source_file)
print('PYTHON_SYNTAX=PASS')
print('ORIGINAL=NOT_MODIFIED')
PY

echo
if [ "$OFFLINE" = 1 ]; then
  echo '=== 3. OFFLINE-PATCHCONTROLE ==='
  echo 'OFFLINE_PATCH_VERIFY=PASS'
  exit 0
fi

echo '=== 3. ALLEEN TESTCONTAINER HERBOUWEN ==='
docker compose -p "$PROJECT" -f "$TEST/docker-compose.yml" -f "$TEST/docker-compose.test.yml" \
  up -d --build --no-deps "$SERVICE"
echo

echo '=== 4. WACHTEN OP ECHTE HEALTHCHECK ==='
# Unlike the previous script, use the actual /health endpoint, not /status/health.
READY=0
for _ in $(seq 1 20); do
  if docker exec nextory-abs-poc-test python -c 'import urllib.request; assert urllib.request.urlopen("http://127.0.0.1:8000/health", timeout=3).status==200' >/dev/null 2>&1; then
    READY=1
    break
  fi
  sleep 2
done
if [ "$READY" != 1 ]; then
  echo 'ERROR: Testserver niet klaar. Testbroncode en backup zijn behouden voor diagnose.'
  docker logs --tail 25 nextory-abs-poc-test 2>&1 | grep -E 'ERROR|Exception|Traceback|startup|Uvicorn' | tail -12 || true
  echo "ROLLBACK: bash '$TEST/nextory-layout-parallel-test.sh' rollback"
  exit 1
fi

echo '=== 5. VERSIE EN ISOLATIE BEVESTIGEN ==='
docker exec nextory-abs-poc-test python -c '
from app.nextory import NextoryBackend, MAX_MANIFEST_BYTES
from app import main
import inspect
source=inspect.getsource(NextoryBackend.get_layout)
assert "NEXTORY_LAYOUT_PARALLEL_V1" in source
assert MAX_MANIFEST_BYTES >= 8 * 1024 * 1024
assert hasattr(NextoryBackend, "_authenticated_get_json")
print("HLS_LIMIT_BYTES="+str(MAX_MANIFEST_BYTES))
print("AUTH_RETRY=PRESERVED")
print("LAYOUT_PARALLEL="+("ENABLED" if "NEXTORY_LAYOUT_PARALLEL_V1" in source else "DISABLED"))
print("API_COMPAT="+("AVAILABLE" if any(getattr(r,"path","")=="/api/me/listening-stats" for r in main.app.routes) else "MISSING"))
'
docker inspect nextory-abs-poc-test --format 'TEST_RUNNING={{.State.Running}} HEALTH={{if .State.Health}}{{.State.Health.Status}}{{else}}unknown{{end}}'
docker inspect nextory-abs-poc --format 'ORIGINAL_RUNNING={{.State.Running}}'
docker ps --filter publish=13378 --format 'PORT_13378_OWNER={{.Names}}'
echo
echo '=== 6. VERVOLG ==='
if [ "$MODE" = apply ]; then
  echo 'TEST: Open een nieuw (niet-gecachet) boek in AudioBooth en druk Play.'
  echo 'LOGS: docker logs --since 10m nextory-abs-poc-test 2>&1 | grep -E "POC_LAYOUT_PARALLEL|POC_LAYOUT |POC_PLAY_PHASE|POC_TIMING stage=play-start" | tail -20'
else
  echo 'ROLLBACK=TEST_ONLY_COMPLETED'
fi
echo '=== EINDE ==='
