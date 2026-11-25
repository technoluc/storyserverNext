#!/bin/sh
set -eu
cd "$(dirname "$0")"
if [ ! -f .env ]; then
    echo 'Run sh setup.sh first.'
    exit 1
fi
# Use values from local file in the shell, never echo the password.
set -a
. ./.env
set +a
clear
printf '=== 1. CONTAINER ===\n'
docker compose ps
printf '\n=== 2. HEALTH / STATUS ===\n'
BASE="http://127.0.0.1:${PORT:-13378}"
python3 - "$BASE" <<'PY'
import json,sys,urllib.request
base=sys.argv[1]
for path in ('/health','/ping','/status'):
    try:
        with urllib.request.urlopen(base+path,timeout=5) as r:
            data=json.load(r)
            print(f'{path} HTTP={r.status} RESULT={"PASS" if r.status==200 else "FAIL"}')
            if path=='/status':
                print('SERVER_VERSION=',data.get('serverVersion'))
    except Exception as e:
        print(f'{path} RESULT=FAIL TYPE={type(e).__name__}')
PY
printf '\n=== 3. CONTAINER LOG (LAST 20) ===\n'
docker compose logs --no-color --tail=20
printf '\n=== 4. LOGIN / AUTHORIZE CONTRACT ===\n'
python3 - "$BASE" <<'PYCODE'
import json,os,sys,urllib.request,urllib.error
base=sys.argv[1]
def req(path, method='GET', data=None, headers=None):
    body=json.dumps(data).encode() if data is not None else None
    h={'Content-Type':'application/json', **(headers or {})}
    with urllib.request.urlopen(urllib.request.Request(base+path,data=body,headers=h,method=method),timeout=5) as r:
        return json.load(r)
try:
    payload=req('/login','POST',{'username':os.environ.get('TEST_USERNAME','test'), 'password':os.environ['TEST_PASSWORD']})
    user=payload.get('user',{})
    access=user.get('accessToken') or user.get('token')
    assert access, 'login token missing'
    assert user.get('refreshToken'), 'refresh token missing'
    print('LOGIN=PASS')
    print('TOKEN_FIELDS=PASS')
    settings=payload.get('serverSettings',{})
    mandatory=('version','bookshelfView','homeBookshelfView','timeZone','dateFormat','timeFormat')
    assert all(key in settings for key in mandatory), 'server settings incomplete'
    print('SERVER_SETTINGS=PASS')
    h={'Authorization':'Bearer '+access}
    auth=req('/api/authorize','POST',{},h)
    assert auth.get('user',{}).get('token'), 'authorize token missing'
    print('AUTHORIZE=PASS')
    libraries=req('/api/libraries','GET',headers=h)
    assert len(libraries.get('libraries',[]))==1, 'library not returned'
    print('LIBRARY=PASS')
except Exception as exc:
    print('POC_CONTRACT=FAIL',type(exc).__name__,str(exc)[:120])
    sys.exit(1)
PYCODE
printf '\n=== END ===\n' 
