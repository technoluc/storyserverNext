#!/usr/bin/env bash
# Isolated Nextory auth/401 recovery test. Original v6 remains untouched.
# Apply:    bash ~/nextory-abs-virtual-poc-test/nextory-auth-retry-test.sh apply
# Rollback: bash ~/nextory-abs-virtual-poc-test/nextory-auth-retry-test.sh rollback
TEST="${NEXTORY_TEST_DIR:-$HOME/nextory-abs-virtual-poc-test}"
ORIGINAL="${NEXTORY_ORIGINAL_DIR:-$HOME/nextory-abs-virtual-poc}"
PROJECT='nextory-abs-test'
MODE="${1:-apply}"

clear 2>/dev/null || true

echo '=== 1. VEILIGHEIDSCONTROLE ==='
if [ "$MODE" != apply ] && [ "$MODE" != rollback ]; then
    echo 'ERROR: Kies apply of rollback.'
    exit 1
fi
if [ ! -f "$TEST/docker-compose.yml" ] || [ ! -f "$TEST/docker-compose.test.yml" ] || [ ! -f "$TEST/app/nextory.py" ] || [ ! -f "$ORIGINAL/app/nextory.py" ]; then
    echo 'ERROR: Vereiste broncode of Compose-configuratie ontbreekt.'
    exit 1
fi
if [ "${_NEXTORY_OFFLINE_VERIFY:-0}" != 1 ]; then
    original_running="$(docker inspect -f '{{.State.Running}}' nextory-abs-poc 2>/dev/null)"
    test_project="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' nextory-abs-poc-test 2>/dev/null)"
    test_image="$(docker inspect -f '{{.Config.Image}}' nextory-abs-poc-test 2>/dev/null)"
    test_running="$(docker inspect -f '{{.State.Running}}' nextory-abs-poc-test 2>/dev/null)"
    port_owner="$(docker ps --filter publish=13378 --format '{{.Names}}')"
    if [ "$original_running" != false ] || [ "$test_project" != "$PROJECT" ] || [ "$test_image" != 'nextory-abs-poc-test:dev' ]; then
        echo 'ERROR: Origineel gestopt / testproject / image niet bevestigd.'
        exit 1
    fi
    if [ "$MODE" = apply ] && [ "$test_running" != true ]; then
        echo 'ERROR: Testcontainer draait niet.'
        exit 1
    fi
    if [ "$test_running" = true ] && [ "$port_owner" != 'nextory-abs-poc-test' ]; then
        echo 'ERROR: Poort 13378 wordt niet uitsluitend door de testcontainer gebruikt.'
        exit 1
    fi
    if [ "$test_running" != true ] && [ -n "$port_owner" ]; then
        echo 'ERROR: Poort 13378 is elders in gebruik.'
        exit 1
    fi
    # Validate effective Compose configuration without displaying tokens or env.
    if ! TEST_DIR="$TEST" ORIGINAL_DIR="$ORIGINAL" PROJECT_NAME="$PROJECT" python3 - <<'PY'
import json, os, subprocess, sys
from pathlib import Path
T = Path(os.environ['TEST_DIR']).resolve()
O = Path(os.environ['ORIGINAL_DIR']).resolve()
project = os.environ['PROJECT_NAME']
cmd = ['docker','compose','-p',project,'-f',str(T/'docker-compose.yml'),'-f',str(T/'docker-compose.test.yml'),'config','--format','json']
r = subprocess.run(cmd, capture_output=True, text=True, cwd=str(T))
if r.returncode:
    sys.exit('ERROR: Compose-config is ongeldig.')
try:
    cfg = json.loads(r.stdout)
    s = cfg['services']['nextory-abs-poc']
    assert cfg.get('name') == project
    assert s.get('container_name') == 'nextory-abs-poc-test'
    assert s.get('image') == 'nextory-abs-poc-test:dev'
    ps = s['ports']
    assert len(ps)==1 and str(ps[0]['published'])=='13378' and int(ps[0]['target'])==8000
    b = s['build']; ctx = Path(b['context'] if isinstance(b,dict) else b).resolve()
    assert ctx == T
    assert not s.get('network_mode') and not s.get('volumes_from')
    for m in s.get('volumes',[]):
        source = m.get('source')
        if m.get('type') == 'bind':
            assert source
            p = Path(source).resolve()
            if p == O or O in p.parents:
                assert m.get('read_only') and m.get('target') == '/run/nextory'
            if not m.get('read_only',False):
                assert p == T or T in p.parents
        elif m.get('type') == 'volume' and source:
            v = cfg.get('volumes',{}).get(source,{})
            assert not v.get('external') and v.get('name','').startswith(project+'_')
    for net in (s.get('networks') or {}):
        n=cfg.get('networks',{}).get(net,{})
        assert not n.get('external')
        assert not n.get('name') or n['name'].startswith(project+'_')
except (KeyError, AssertionError, ValueError, TypeError):
    sys.exit('ERROR: Geisoleerde Compose-config niet bevestigd.')
print('COMPOSE_ISOLATION=PASS')
PY
    then
        echo '=== PATCH AFGEBROKEN ==='
        exit 1
    fi
else
    echo 'OFFLINE_VERIFICATION=YES'
fi

echo 'ORIGINAL=UNCHANGED_AND_STOPPED'
echo "MODE=$MODE"
echo 'PORT=13378'
echo
echo '=== 2. TESTBRONCODE AANPASSEN ==='

python3 - "$TEST" "$ORIGINAL" "$MODE" <<'PY'
import ast
import os
import shutil
import sys
from pathlib import Path

root = Path(sys.argv[1]).resolve(strict=True)
original = Path(sys.argv[2]).resolve(strict=True)
mode = sys.argv[3]
source_file = root / 'app/nextory.py'
original_file = original / 'app/nextory.py'
backup = root / '.nextory-auth-baseline' / 'nextory.py'
marker = 'NEXTORY_AUTH_RETRY'

def fail(message):
    raise SystemExit('ERROR: ' + message)

if source_file.is_symlink() or original_file.is_symlink() or not source_file.is_file():
    fail('Ongeldig testbronbestand of symlink.')
if os.path.samefile(source_file, original_file):
    fail('Test en origineel delen dezelfde inode.')
if backup.is_symlink() or backup.parent.is_symlink():
    fail('Backup is een symlink.')

def patch(source):
    def replace_once(before, after, label):
        nonlocal source
        count = source.count(before)
        if count != 1:
            fail(f'{label}: verwacht 1 codefragment, gevonden {count}.')
        source = source.replace(before, after, 1)

    replace_once('import io\nimport ipaddress\n',
                 'import io\nimport ipaddress\nimport logging\n', 'Logging import')
    replace_once('        self._authed_at = 0.0\n        self._books:',
                 '        self._authed_at = 0.0\n'
                 '        # Dedicated device identity for this test backend instance.\n'
                 '        self._device_id = str(uuid.uuid4())\n'
                 '        self._books:', 'Backend device identity')
    replace_once("'X-Device-Id': str(uuid.uuid3(uuid.NAMESPACE_DNS, 'audiobook-dl')),\n",
                 "'X-Device-Id': self._device_id,\n", 'Device header')
    helper = '''    def _authenticated_get_json(self, url: str, label: str) -> dict:
        """NEXTORY_AUTH_RETRY: on HTTP 401 refresh profile auth exactly once.

        Caller holds the backend RLock so no concurrent request can replace
        the shared requests.Session credentials while we retry.
        """
        self._ensure_login()
        try:
            response = self._api.get(url, timeout=(8, 18), allow_redirects=False)
            if response.status_code == 401:
                response.close()
                logging.getLogger('uvicorn.error').warning(
                    'NEXTORY_AUTH_RETRY endpoint=%s initial_status=401', label)
                self._authed_at = 0.0
                self._api.cookies.clear()
                self._ensure_login()
                response = self._api.get(url, timeout=(8, 18), allow_redirects=False)
                logging.getLogger('uvicorn.error').info(
                    'NEXTORY_AUTH_RETRY endpoint=%s final_status=%d', label, response.status_code)
            return self._checked_json(response, label)
        except requests.RequestException as exc:
            raise NextoryError(
                f'Nextory {label} network error ({type(exc).__name__})'
            ) from exc

'''
    replace_once('    def get_book(self, book_id: int) -> BookInfo:\n',
                 helper+'    def get_book(self, book_id: int) -> BookInfo:\n', '401 retry helper')
    replace_once('''                info = self._checked_json(self._api.get(
                    f'{prefix}/discovery/v1/product/{book_id}',
                    timeout=(8, 18), allow_redirects=False), 'product')''',
                 '''                info = self._authenticated_get_json(
                    f'{prefix}/discovery/v1/product/{book_id}', 'product')''', 'Product request')
    replace_once('''                audio = self._checked_json(self._api.get(
                    f'{prefix}/reader/books/{quote(str(format_id), safe="")}/packages/audio',
                    timeout=(8, 18), allow_redirects=False), 'audio package')''',
                 '''                audio = self._authenticated_get_json(
                    f'{prefix}/reader/books/{quote(str(format_id), safe="")}/packages/audio',
                    'audio package')''', 'Audio package request')
    ast.parse(source,filename=str(source_file))
    compile(source, str(source_file), 'exec')
    return source

current = source_file.read_text(encoding='utf-8')
if mode == 'rollback':
    if not backup.is_file():
        fail('Geen baseline-back-up gevonden.')
    baseline = backup.read_text(encoding='utf-8')
    if current != patch(baseline) and current != baseline:
        fail('Onverwachte wijzigingen in testbroncode; handmatig beoordelen.')
    ast.parse(baseline)
    shutil.copy2(backup, source_file)
    print('BACKUP=RESTORED')
    print('AUTH_RETRY=DISABLED')
    raise SystemExit(0)

if marker in current:
    if not backup.is_file() or current != patch(backup.read_text(encoding='utf-8')):
        fail('Al gepatcht maar baseline ontbreekt of wijkt af.')
    print('PATCH=ALREADY_APPLIED')
    raise SystemExit(0)

if backup.is_file():
    baseline = backup.read_text(encoding='utf-8')
    if current != baseline:
        fail('Testbroncode wijkt af van bewaarde baseline.')
else:
    baseline = current
    if source_file.read_bytes() != original_file.read_bytes():
        fail('Test nextory.py wijkt al af van origineel; wijziging geweigerd.')

patched = patch(baseline)
if not backup.exists():
    backup.parent.mkdir(parents=True,exist_ok=True, mode=0o700)
    shutil.copy2(source_file, backup)
    os.chmod(backup, 0o600)
source_file.write_text(patched, encoding='utf-8')
print('BACKUP=.nextory-auth-baseline/nextory.py')
print('AUTH_RETRY=ONCE_ON_401')
print('DEVICE_ID=UNIQUE_FOR_TEST_INSTANCE')
print('ORIGINAL=NOT_MODIFIED')
print('PYTHON_SYNTAX=PASS')
PY

if [ "$?" -ne 0 ]; then
    echo '=== PATCH AFGEBROKEN ==='
    echo 'Geen Docker-rebuild uitgevoerd.'
    exit 1
fi

if [ "${_NEXTORY_OFFLINE_VERIFY:-0}" = 1 ]; then
    echo 'OFFLINE_PATCH_VERIFY=PASS'
    exit 0
fi

echo
echo '=== 3. ALLEEN TESTCONTAINER HERBOUWEN ==='
cd "$TEST" || exit 1
docker compose -p "$PROJECT" -f docker-compose.yml -f docker-compose.test.yml \
    up -d --build --no-deps nextory-abs-poc
if [ "$?" -ne 0 ]; then
    echo 'ERROR: Testrebuild mislukt. Rollback blijft beschikbaar.'
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
echo 'Controleer met dezelfde iPhone-app of een eerste Play-aanvraag HTTP 200 wordt.'
echo 'Bij fout: docker logs --since 5m nextory-abs-poc-test 2>&1 | grep -E "NEXTORY_AUTH_RETRY|POC_TIMING stage=play-start"'
