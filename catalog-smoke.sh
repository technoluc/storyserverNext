#!/bin/sh
# Contract smoke for live metadata discovery: requests ZERO audio bytes.
set -eu
cd "$(dirname "$0")"
if [ ! -f .env ]; then echo 'ERROR: Missing .env'; exit 1; fi
set -a
. ./.env
set +a
clear 2>/dev/null || true
printf '=== 1. V6 DISCOVERY AND COLLECTION ENDPOINTS ===\n'
python3 - <<'PY'
import json, os, sys, time, urllib.error, urllib.parse, urllib.request
base = 'http://127.0.0.1:' + os.getenv('PORT', '13378')
def get(path, method='GET', data=None, token=None, timeout=40):
    req = urllib.request.Request(base + path,
          data=json.dumps(data).encode() if data is not None else None,
          headers={'Content-Type':'application/json',
                   **({'Authorization':'Bearer ' + token} if token else {})},
          method=method)
    with urllib.request.urlopen(req, timeout=timeout) as result:
        return json.load(result)
try:
    health = get('/health')
    assert health.get('status') == 'ok' and health.get('configMounted')
    login = get('/login', 'POST', {'username':os.environ.get('TEST_USERNAME','test'),
                                    'password':os.environ['TEST_PASSWORD']})
    token=login['user']['accessToken']
    libraries = get('/api/libraries', token=token)['libraries']
    assert len(libraries) == 1, 'Expected exactly one visible Nextory library'
    print('LIBRARY_CHOOSER=ONE_NEXTORY_LIBRARY')
    cols = get('/api/libraries/' + libraries[0]['id'] + '/collections?limit=50', token=token)
    assert cols['total']==20 and len(cols['results'])==20
    assert any(x['name']=='Nieuw ontdekt' for x in cols['results'])
    assert any(x['name']=='Misdaad' for x in cols['results'])
    print('CATEGORY_COLLECTIONS=20')
    status = get('/api/poc/discovery-status', token=token)
    assert status.get('mode') == 'dynamic-nextory-discovery'
    print('AUTOMATIC_REFRESH=' + ('ENABLED' if status['automaticRefresh'] else 'DISABLED'))
    print('REFRESH_INTERVAL_SECONDS=' + str(status['refreshSeconds']))
    print('INDEXED_METADATA_BOOKS=' + str(status['indexedAudiobooks']))
    if status.get('lastError'):
        print('RECENT_CATALOG_WARNING=' + str(status['lastError'])[:130])
    primary = libraries[0]['id']
    term = urllib.parse.quote('Harry Potter')
    result = get('/api/libraries/' + primary + '/search?q=' + term,
                 token=token, timeout=65)
    books = result.get('book') or []
    assert books, 'No live Nextory audiobook search results; inspect Nextory API access'
    first = books[0]['libraryItem']
    assert first['media']['metadata']['title'] and first['id']
    print('LIVE_NEXTORY_SEARCH=PASS')
    print('SEARCH_RESULTS=' + str(len(books)))
    print('EXAMPLE_TITLE=' + first['media']['metadata']['title'][:90].replace('\n',' '))
    print('AUDIO_DOWNLOADED=FALSE (metadata only)')
    print('PUBLIC_CATEGORY_SITE=NOT_TESTED_BY_THIS_SMOKE')
except urllib.error.HTTPError as error:
    print('HTTP_ERROR=' + str(error.code))
    try:
        reason = json.loads(error.read()).get('detail')
        if reason: print('REASON=' + str(reason)[:150])
    except Exception: pass
    sys.exit(1)
except Exception as error:
    print('CATALOG_SMOKE=FAIL TYPE=' + type(error).__name__)
    print('DETAIL=' + str(error)[:130])
    sys.exit(1)
PY
printf '\n=== 2. FINISHED ===\n'
