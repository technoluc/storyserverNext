#!/bin/sh
# Verify virtual-book metadata, ALL HLS tracks, and first+last playlist.
# Deliberately fetches NO audio segments or AES keys.
set -eu
cd "$(dirname "$0")"
if [ ! -f .env ]; then echo 'ERROR: .env missing'; exit 1; fi
set -a
. ./.env
set +a
clear 2>/dev/null || true
printf '=== 1. V5 CONTAINER ===\n'
docker compose ps nextory-abs-poc
printf '\n=== 2. LIVE NEXTORY MULTI-BOOK TEST ===\n'
python3 - <<'PY'
import json, os, sys, time, urllib.error, urllib.request
base='http://127.0.0.1:'+os.getenv('PORT','13378')
def request(path, method='GET', data=None, token=None):
    body=json.dumps(data).encode('utf-8') if data is not None else None
    headers={'Content-Type':'application/json'}
    if token: headers['Authorization']='Bearer '+token
    req=urllib.request.Request(base+path,data=body,headers=headers,method=method)
    with urllib.request.urlopen(req,timeout=120) as response:
        return response.status,dict(response.headers),response.read()
def obj(*args,**kwargs):
    code,headers,body=request(*args,**kwargs)
    assert code==200,code
    return json.loads(body)
def playlist(session_id,index):
    path=f'/public/session/{session_id}/track/{index}'
    for depth in range(5):
        status,headers,body=request(path)
        assert status==200
        data=body.decode('utf-8')
        assert data.startswith('#EXTM3U'), 'Bad HLS playlist'
        assert 'https://api.nextory.com' not in data
        if '#EXT-X-STREAM-INF:' not in data:
            return sum(1 for line in data.splitlines() if line.startswith('#EXTINF:'))
        candidates=[l.strip() for l in data.splitlines() if l.strip().startswith('/hls/') and l.strip().endswith('.m3u8')]
        assert candidates, 'HLS master is missing local variant URI'
        path=candidates[0]
    raise AssertionError('Nested HLS playlist recursion limit')
try:
    # Docker `up -d` can return before Uvicorn finishes startup.
    for attempt in range(45):
        try:
            health=obj('/health')
            break
        except (urllib.error.URLError, TimeoutError, ConnectionError):
            if attempt == 44:
                raise
            time.sleep(1)
    print('HEALTH=PASS')
    assert health['configMounted']
    print('CONFIG_MOUNTED=TRUE')
    login=obj('/login','POST',{'username':os.environ.get('TEST_USERNAME','test'),'password':os.environ['TEST_PASSWORD']})
    token=login['user']['accessToken']
    assert token
    assert obj('/api/authorize','POST',{},token)['user']['id']
    print('LOGIN_AUTH=PASS')
    status=obj('/api/poc/catalog-status',token=token)
    if status['errors']:
        for item_id,message in status['errors'].items():
            print('BOOK_ERROR_ID='+str(item_id)+' REASON='+str(message)[:130])
        raise RuntimeError('One or more configured Nextory books could not be loaded')
    assert len(status['books'])==len(status['configuredIds']) and len(status['books'])>=1
    library=obj('/api/libraries',token=token)['libraries'][0]
    listing=obj('/api/libraries/'+library['id']+'/items?minified=1',token=token)
    assert len(listing['results'])>=len(status['books'])
    print('V4_PINNED_BOOKS='+str(len(status['books'])))
    print('LIBRARY_PAGE_ITEMS='+str(len(listing['results'])))
    for product in status['books']:
        ident=product['id']
        entry=next(x for x in listing['results'] if x['ino']==f'nextory-{ident}')
        item_id=entry['id']
        detail=obj('/api/items/'+item_id+'?expanded=1',token=token)
        assert detail['media']['metadata']['title']==product['title']
        assert detail['media']['numTracks']==product['parts']
        assert len(detail['media']['tracks'])==product['parts']
        assert len(detail['media']['chapters'])==product['parts']
        cover_status,headers,cover=request('/api/items/'+item_id+'/cover')
        assert cover_status==200 and cover[:2]==b'\xff\xd8'
        print('BOOK_ID='+str(ident)+' METADATA_COVER=PASS AUTHORS='+str(len(product['authors'])))
        session=obj('/api/items/'+item_id+'/play','POST',{'mediaPlayer':'AVPlayer'},token)
        assert session['playMethod']==0 and len(session['audioTracks'])==product['parts']
        assert abs(session['duration']-product['duration'])<=0.1
        assert all(t['index']==i+1 for i,t in enumerate(session['audioTracks']))
        assert all(session['audioTracks'][i]['startOffset'] < session['audioTracks'][i+1]['startOffset']
                   for i in range(len(session['audioTracks'])-1))
        assert playlist(session['id'],1)>0
        assert playlist(session['id'],product['parts'])>0
        request('/api/session/'+session['id']+'/close','POST',{},token)
        print('BOOK_ID='+str(ident)+' PLAYBACK_TRACKS='+str(product['parts'])+' FIRST_LAST_HLS=PASS')
    print('FULL_BOOK_TIMELINES=PASS')
    print('AUDIO_DOWNLOADED=FALSE (manifest and cover only)')
    print('IPHONE_CROSS_TRACK_SEEK=NOT_TESTED_HERE')
except urllib.error.HTTPError as exc:
    print('HTTP_ERROR='+str(exc.code))
    try:
        data=json.loads(exc.read())
        if data.get('detail'): print('REASON='+str(data['detail'])[:160])
    except Exception: pass
    sys.exit(1)
except Exception as exc:
    print('SMOKE_RESULT=FAIL TYPE='+type(exc).__name__)
    print('DETAIL='+str(exc)[:130])
    sys.exit(1)
PY
printf '\n=== 3. FINISHED ===\n'
