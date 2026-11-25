#!/bin/sh
# Probe one real Nextory HLS part. No audio segment or encryption key is fetched.
set -eu
cd "$(dirname "$0")"
if [ ! -f .env ]; then
  echo 'ERROR: .env missing. Do not overwrite an existing v2 .env.'
  exit 1
fi
set -a
. ./.env
set +a
clear 2>/dev/null || true
printf '=== 1. V3 CONTAINER ===\n'
docker compose ps
printf '\n=== 2. LOGIN, AUTH, FIRST NEXTORY HLS PART ===\n'
python3 - <<'PY'
import json, os, sys, urllib.error, urllib.parse, urllib.request
base='http://127.0.0.1:'+os.environ.get('PORT','13378')
def req(path,method='GET',data=None,token=None,follow=True):
    body=json.dumps(data).encode() if data is not None else None
    headers={'Content-Type':'application/json'}
    if token: headers['Authorization']='Bearer '+token
    request=urllib.request.Request(base+path,data=body,headers=headers,method=method)
    with urllib.request.urlopen(request,timeout=50) as r:
        return r.status,dict(r.headers),r.read()
try:
    st,headers,b=req('/health')
    health=json.loads(b)
    assert st==200
    print('HEALTH=PASS')
    print('CONFIG_MOUNTED='+str(bool(health.get('configMounted'))).upper())
    if not health.get('configMounted'):
        print('NEXTORY=UNCONFIGURED (run sh configure-nextory.sh)')
        sys.exit(1)
    st,headers,b=req('/login','POST',{'username':os.environ.get('TEST_USERNAME','test'),'password':os.environ['TEST_PASSWORD']})
    login=json.loads(b)
    token=login['user'].get('accessToken') or login['user']['token']
    assert token and st==200
    print('LOGIN=PASS')
    st,headers,b=req('/api/authorize','POST',{},token)
    assert json.loads(b)['user']['id']
    print('AUTHORIZE=PASS')
    st,headers,b=req('/api/libraries',token=token)
    assert len(json.loads(b)['libraries'])==1
    print('LIBRARY=PASS')
    book_id='572c4427-e49a-579d-b5bb-0b24729778bf'
    st,headers,b=req('/api/items/'+book_id,token=token)
    assert json.loads(b)['id']==book_id
    print('VIRTUAL_BOOK=PASS (Nextory 7207495)')
    st,headers,b=req('/api/items/'+book_id+'/play','POST',{'forceDirectPlay':True,'mediaPlayer':'AVPlayer'},token)
    playback=json.loads(b)
    assert st==200 and playback['playMethod']==0 and len(playback['audioTracks'])==1
    assert playback['duration']>0
    print('PLAY_SESSION=PASS')
    print('DURATION_FIRST_PART_SECONDS='+str(round(playback['duration'],2)))
    print('NEXTORY_PARTS=FIRST_OF_34_FROM_PREVIOUS_PROBE')
    path='/public/session/'+playback['id']+'/track/1'
    for depth in range(5):
        st,headers,b=req(path)
        text=b.decode('utf-8')
        assert st==200 and text.startswith('#EXTM3U')
        assert 'https://api.nextory.com' not in text
        if '#EXT-X-STREAM-INF:' not in text:
            break
        variant=next((line.strip() for line in text.splitlines()
                      if line.strip().startswith('/hls/') and line.strip().endswith('.m3u8')), None)
        assert variant, 'HLS master playlist without local variant'
        path=variant
    else:
        raise AssertionError('Too many nested HLS playlists')
    count=sum(1 for line in text.splitlines() if line.startswith('#EXTINF:'))
    assert count>0, 'No media segments declared in HLS playlist'
    print('HLS_MEDIA_PLAYLIST=PASS')
    print('PLAYLIST_SEGMENTS_DECLARED='+str(count))
    st,headers,b=req('/api/session/'+playback['id']+'/close','POST',{},token)
    assert st==200
    print('SESSION_CLOSE=PASS')
    print('AUDIO_DOWNLOADED=FALSE (playlist only)')
    print('IPHONE_PLAYBACK=NOT_TESTED_HERE')
except urllib.error.HTTPError as exc:
    print('POC_HTTP_ERROR='+str(exc.code))
    try:
        detail=json.loads(exc.read()).get('detail','')
        if detail: print('REASON='+str(detail)[:180])
    except Exception: pass
    sys.exit(1)
except Exception as exc:
    print('POC_RESULT=FAIL TYPE='+type(exc).__name__)
    sys.exit(1)
PY
printf '\n=== 3. FINISHED ===\n'
