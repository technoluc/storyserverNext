#!/usr/bin/env bash
# Opt-in fixed-packet virtual M4B playback prototype for authorized streams.
# Alleen nextory-abs-poc-test; geen wijziging aan de originele v6 of AudioBooth.
# Gebruik: bash nextory-fixed-m4b-test.sh apply|rollback
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
for f in docker-compose.yml docker-compose.test.yml app/main.py app/nextory.py app/hls_proxy.py app/prewarm.py app/hls_delivery.py app/hls_root.py app/hls_book.py; do
  if [ ! -f "$TEST/$f" ]; then echo "ERROR: Testbestand ontbreekt: $f"; exit 1; fi
done
if [ ! -f "$ORIGINAL/app/main.py" ]; then echo 'ERROR: Originele broncode ontbreekt.'; exit 1; fi
if [ "$OFFLINE" != 1 ]; then
  original_running="$(docker inspect -f '{{.State.Running}}' nextory-abs-poc 2>/dev/null || true)"
  test_running="$(docker inspect -f '{{.State.Running}}' nextory-abs-poc-test 2>/dev/null || true)"
  test_project="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' nextory-abs-poc-test 2>/dev/null || true)"
  test_image="$(docker inspect -f '{{.Config.Image}}' nextory-abs-poc-test 2>/dev/null || true)"
  port_owner="$(docker ps --filter publish=13378 --format '{{.Names}}')"
  if [ "$original_running" != false ] || \
     { [ "$MODE" = apply ] && [ "$test_running" != true ]; } || \
     [ "$test_project" != "$PROJECT" ] || [ "$test_image" != 'nextory-abs-poc-test:dev' ] || \
     { [ "$port_owner" != 'nextory-abs-poc-test' ] && { [ "$MODE" != rollback ] || [ -n "$port_owner" ]; }; }; then
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

echo '=== 2. CLASSIC VIRTUAL M4B ==='
python3 - "$TEST" "$ORIGINAL" "$MODE" <<'PYCODE'
from pathlib import Path
import ast

def once(s,a,b):
    if s.count(a)!=1:raise ValueError('unexpected anchor '+a[:120])
    return s.replace(a,b,1)

def patch_main(s):
    if 'NEXTORY_SINGLE_PRESENTATION_V2' not in s or 'NEXTORY_NAMED_HLS_URL' not in s or 'format_control.install' not in s:
        raise ValueError('Required v2 + named route + format controls not found')
    s=once(s,'from .progress import progress_store\n','from .progress import progress_store\nfrom . import fixed_m4b  # NEXTORY_FIXED_M4B_V1\n')
    # Avoid any accidental changes to other response contracts.
    start=s.index("@app.post('/api/items/{item_id}/play')")
    end=s.index("@app.api_route('/public/session/{session_id}/track/{track_index}'",start)
    part=s[start:end]
    part=once(part,'    chapters = tracks\n    playback_tracks = tracks\n','    use_fixed = is_audiobooth and fixed_m4b.enabled(book_id)\n    chapters = tracks\n    playback_tracks = tracks\n')
    part=once(part,'    if is_audiobooth and len(tracks) > 1:\n','    if is_audiobooth and len(tracks) > 1 and not use_fixed:\n')
    part=once(part,'    session = None\n    if plan is not None:\n','''    session = None
    if use_fixed:
        try:
            # The internal source tracks are retained. AudioBooth sees only
            # one classic M4B track, using the same existing playback session.
            session = registry.create(book_id=info.book_id, title=info.title,
                                      tracks=tracks, user_id=USER_ID, current_time=start_time,
                                      fixed_presentation=True)
            engine = fixed_m4b.FixedM4B(tracks, fixed_m4b.LocalPlaybackSource(session))
            session.fixed_m4b = engine
            duration = round(engine.duration, 3)
            session.duration = duration
            playback_tracks = (TrackPart(1, tracks[0].uri, 0., duration, info.title),)
            logging.getLogger('uvicorn.error').info(
                'POC_FIXED_M4B event=play book=%s chapters=%d audio_tracks=1 duration=%.3f header_bytes=%d virtual_bytes=%d chunks=%d',
                ref, len(chapters), duration, engine.media_start, engine.size, engine.chunk_count)
        except Exception as exc:
            if session is not None: registry.close(session.id)
            logging.getLogger('uvicorn.error').warning('POC_FIXED_M4B event=prepare_error type=%s', type(exc).__name__)
            raise HTTPException(status_code=503, detail='Virtual M4B preparation failed') from None
    if plan is not None:
''')
    part=once(part,"    return {\n        'id': session.id", "    result = {\n        'id': session.id")
    anchor="        'libraryItem': library_item,\n    }\n"
    part=once(part,anchor,anchor+"    if use_fixed:\n        fixed_m4b.patch_payload(result, session.fixed_m4b)\n    return result\n")
    s=s[:start]+part+s[end:]
    # Named HLS routes are still the current ordinary playback source; only
    # the extensionless track route for the new experimental session changes.
    s=once(s,"    # NEXTORY_SINGLE_PRESENTATION_V1: single logical book item.\n", """    if session.fixed_m4b is not None and not req.url.path.endswith('.m3u8'):
        if track_index != 1:
            raise HTTPException(status_code=404, detail='Virtual track unavailable')
        return await session.fixed_m4b.response(req)
    # NEXTORY_SINGLE_PRESENTATION_V1: single logical book item.
""")
    # Match the metadata from the warm layout, as well as the play session.
    s=once(s,"        result = item_json(info, tracks, expanded=True)\n    else:\n        result = preview_detail(preview)","""        if fixed_m4b.enabled(book_id):
            try:
                parts = fixed_m4b.timeline(tracks)
                header, packets, samples = fixed_m4b.make_index(parts[-1].end)
                duration = round(samples / fixed_m4b.RATE, 3)
                candidate = (TrackPart(1, tracks[0].uri, 0., duration, info.title),)
                result = item_json(info, candidate, expanded=True)
                result['media']['chapters'] = chapters_json(tracks)
                result['media']['numChapters'] = len(tracks)
                fixed_m4b.patch_item(result, fixed_m4b.Metadata(len(header)+packets*fixed_m4b.PACKET_BYTES, duration))
            except fixed_m4b.MediaError:
                result = item_json(info, tracks, expanded=True)
        else:
            result = item_json(info, tracks, expanded=True)
    else:
        result = preview_detail(preview)""")
    ast.parse(s);return s

def patch_proxy(s):
    s=once(s,'    book_playlist_segments: int = 0\n','    book_playlist_segments: int = 0\n    fixed_m4b: object | None = None  # NEXTORY_FIXED_M4B_V1\n    fixed_reservation: bool = False\n')
    s=once(s,'            self.book_playlist_segments = 0\n','            self.book_playlist_segments = 0\n            if self.fixed_m4b is not None:\n                self.fixed_m4b.close()\n                self.fixed_m4b = None\n            self.fixed_reservation = False\n')
    s=once(s,'               book_presentation: bool = False) -> Playback:\n','               book_presentation: bool = False, fixed_presentation: bool = False) -> Playback:\n')
    s=once(s,"            if book_presentation and sum(s.book_playlist is not None for s in self._sessions.values()) >= 4:\n", "            if fixed_presentation and sum(s.fixed_reservation for s in self._sessions.values()) >= 2:\n                raise NextoryError('Virtual M4B session capacity reached')\n            if book_presentation and sum(s.book_playlist is not None for s in self._sessions.values()) >= 4:\n")
    s=once(s,'                               book_playlist=b"" if book_presentation else None)\n','                               book_playlist=b"" if book_presentation else None,\n                               fixed_reservation=fixed_presentation)\n')
    ast.parse(s);return s

def patch_dockerfile(s):
    if not s.startswith('FROM python:3.13-slim\n') or 'USER 10001:10001' not in s:
        raise ValueError('Unexpected Dockerfile')
    if 'NEXTORY_TEST_VIRTUAL_M4B_BOOK' in s or 'ffmpeg' in s:
        raise ValueError('FFmpeg or experimental mode already exists')
    return once(s,'FROM python:3.13-slim\n','FROM python:3.13-slim\nRUN apt-get update && apt-get install -y --no-install-recommends ffmpeg && rm -rf /var/lib/apt/lists/*\nENV NEXTORY_TEST_VIRTUAL_M4B_BOOK=7207495\n')

PATCHERS={'app/main.py':patch_main,'app/hls_proxy.py':patch_proxy,'Dockerfile':patch_dockerfile}

HELPER = '"""Experimental classic M4B over fixed-size ALAC packets.\n\nUses a normal, authorized local playback source; no provider credentials, key\nextraction, downloader, changes to HLS authentication or persistent audio files.\nOnly use with media for which repackaging is permitted.\n"""\nfrom __future__ import annotations\n\nimport asyncio\nimport bisect\nimport hashlib\nimport logging\nimport math\nimport os\nimport struct\nimport threading\nimport time\nfrom collections import OrderedDict\nfrom dataclasses import dataclass\nfrom urllib.parse import urlsplit\nfrom uuid import UUID\n\nfrom fastapi import Request\nfrom fastapi.responses import Response, StreamingResponse\nfrom .virtual_long import box, boxes, child, top\nfrom .virtual_flat import replace_box, get_child\nfrom .virtual_range import VirtualRange\n\nLOG = logging.getLogger(\'uvicorn.error\')\nRATE = 24000\nSAMPLES_PER_PACKET = 4096\nPACKET_BYTES = 8196\nPACKETS_PER_CHUNK = 64\nCHUNK_SAMPLES = PACKETS_PER_CHUNK * SAMPLES_PER_PACKET\nCHUNK_BYTES = PACKETS_PER_CHUNK * PACKET_BYTES\nCACHE_BYTES = 8 * 1024 * 1024\n# At most one FFmpeg worker, including encoding; do not exceed container budget.\n_WORKERS = asyncio.Semaphore(1)\nMAX_DURATION = 40 * 3600\nMAX_ACTIVE = 4\n# Bound speculative read-ahead. Actual nominal media rate ~48 KB/s.\nSEND_RATE = 256 * 1024\nBURST = 512 * 1024\nFFMPEG_TIMEOUT = 25\nTARGET_BOOK = 7207495\nMARKER = \'NEXTORY_FIXED_M4B_V1\'\n\nclass MediaError(RuntimeError):\n    pass\n\n\ndef enabled(book_id: int) -> bool:\n    return book_id == TARGET_BOOK and os.environ.get(\'NEXTORY_TEST_VIRTUAL_M4B_BOOK\') == str(TARGET_BOOK)\n\n# This template is generated locally by FFmpeg from two packets of silent\n# 16-bit PCM. Only container metadata is included, not any audio payload.\n_TEMPLATE = bytes.fromhex(\'000002866d6f6f760000006c6d766864000000000000000000000000000003e8000001560001000001000000000000000000000000010000000000000000000000000000000100000000000000000000000000004000000000000000000000000000000000000000000000000000000000000002000001b17472616b0000005c746b68640000000300000000000000000000000100000000000001560000000000000000000000010100000000010000000000000000000000000000000100000000000000000000000000004000000000000000000000000000014d6d646961000000206d64686400000000000000000000000000005dc00000200055c400000000002d68646c720000000000000000736f756e000000000000000000000000536f756e6448616e646c657200000000f86d696e6600000010736d686400000000000000000000002464696e660000001c6472656600000000000000010000000c75726c2000000001000000bc7374626c0000005873747364000000000000000100000048616c61630000000000000001000000000000000000010010000000005dc0000000000024616c616300000000000010000010000000010000000020040005dc0000005dc00000001873747473000000000000000100000002000010000000001c737473630000000000000001000000010000000200000001000000147374737a000000000000200400000002000000147374636f0000000000000001000002b20000006175647461000000596d657461000000000000002168646c7200000000000000006d6469726170706c0000000000000000000000002c696c737400000024a9746f6f0000001c6461746100000001000000004c61766636312e372e313033\')\n\n\ndef make_index(source_samples: int):\n    """A classic non-fragmented ISO BMFF header with an exact constant stsz."""\n    if not 0 < source_samples <= MAX_DURATION * RATE:\n        raise MediaError(\'duration_out_of_range\')\n    count = (source_samples + SAMPLES_PER_PACKET - 1) // SAMPLES_PER_PACKET\n    total_samples = count * SAMPLES_PER_PACKET\n    media_bytes = count * PACKET_BYTES\n    chunk_count = (count + PACKETS_PER_CHUNK - 1) // PACKETS_PER_CHUNK\n    last_count = count - (chunk_count-1)*PACKETS_PER_CHUNK\n    # The small template uses version-0 movie/track headers and a single track.\n    m = bytearray(_TEMPLATE)\n    a,b = child(m,0,len(m),b\'mvhd\')\n    p,n = child(m,0,len(m),b\'trak\')\n    t,tn = child(m,p,n,b\'tkhd\')\n    d,dn = child(m,p,n,b\'mdia\')\n    h,hn = child(m,d,dn,b\'mdhd\')\n    if m[a+8] or m[t+8] or m[h+8] or struct.unpack_from(\'>I\',m,a+20)[0]!=1000 or struct.unpack_from(\'>I\',m,h+20)[0]!=RATE:\n        raise MediaError(\'invalid_alac_template\')\n    ms = (total_samples*1000+RATE-1)//RATE\n    struct.pack_into(\'>I\',m,a+24,ms)\n    struct.pack_into(\'>I\',m,t+28,ms)\n    struct.pack_into(\'>I\',m,h+24,total_samples)\n    moov=bytes(m); trak=get_child(moov,b\'trak\'); mdia=get_child(trak,b\'mdia\')\n    minf=get_child(mdia,b\'minf\'); stbl=get_child(minf,b\'stbl\')\n    stsd=get_child(stbl,b\'stsd\')\n    stts=box(b\'stts\',struct.pack(\'>IIII\',0,1,count,SAMPLES_PER_PACKET))\n    runs=[(1, min(PACKETS_PER_CHUNK,count), 1)]\n    if chunk_count>1 and last_count!=PACKETS_PER_CHUNK:\n        runs.append((chunk_count,last_count,1))\n    stsc=box(b\'stsc\',struct.pack(\'>II\',0,len(runs))+b\'\'.join(struct.pack(\'>III\',*r) for r in runs))\n    stsz=box(b\'stsz\',struct.pack(\'>III\',0,PACKET_BYTES,count))\n    # co64 also supports long books above 4 GiB; offsets never depend on media.\n    co64=box(b\'co64\',struct.pack(\'>II\',0,chunk_count)+bytes(8*chunk_count))\n    stbl=box(b\'stbl\',stsd+stts+stsc+stsz+co64)\n    minf=replace_box(minf,b\'minf\',b\'stbl\',stbl)\n    mdia=replace_box(mdia,b\'mdia\',b\'minf\',minf)\n    trak=replace_box(trak,b\'trak\',b\'mdia\',mdia)\n    moov=replace_box(moov,b\'moov\',b\'trak\',trak)\n    # Drop the template\'s encoder tags (not source metadata).\n    if any(k==b\'udta\' for _,_,k in boxes(moov,8)):\n        moov=replace_box(moov,b\'moov\',b\'udta\',b\'\')\n    ftyp=box(b\'ftyp\',b\'M4B \'+struct.pack(\'>I\',512)+b\'M4A isommp42\')\n    mdat=(struct.pack(\'>I4s\',media_bytes+8,b\'mdat\') if media_bytes+8<2**32\n          else struct.pack(\'>I4sQ\',1,b\'mdat\',media_bytes+16))\n    header=bytearray(ftyp+moov+mdat)\n    a,b=child(header,len(ftyp),len(moov),b\'trak\')\n    a,b=child(header,a,b,b\'mdia\'); a,b=child(header,a,b,b\'minf\')\n    a,b=child(header,a,b,b\'stbl\'); a,b=child(header,a,b,b\'co64\')\n    if b != 16+8*chunk_count:\n        raise MediaError(\'invalid_offset_table\')\n    for i in range(chunk_count):\n        struct.pack_into(\'>Q\',header,a+16+8*i,len(header)+i*CHUNK_BYTES)\n    return bytes(header),count,total_samples\n\n\ndef alac_config(moov):\n    stsd=get_child(get_child(get_child(get_child(get_child(moov,b\'trak\'),b\'mdia\'),b\'minf\'),b\'stbl\'),b\'stsd\')\n    # Single version-0 ALAC sample description; nested alac config is 36 bytes.\n    if stsd[20:24]!=b\'alac\' or struct.unpack_from(\'>I\',stsd,12)[0]!=1:\n        raise MediaError(\'unexpected_sample_description\')\n    entry=stsd[16:]\n    if len(entry)<36 or struct.unpack_from(\'>H\',entry,24)[0]!=1:\n        raise MediaError(\'unexpected_alac_channels\')\n    configs=[entry[p:p+n] for p,n,k in boxes(entry,36) if k==b\'alac\']\n    if len(configs)!=1 or len(configs[0])!=36:\n        raise MediaError(\'unexpected_alac_config\')\n    return configs[0]\n\n\nasync def ffmpeg(args, data=None, timeout=FFMPEG_TIMEOUT):\n    p=await asyncio.create_subprocess_exec(\'ffmpeg\',\'-nostdin\',\'-hide_banner\',\'-loglevel\',\'error\',*args,\n        stdin=asyncio.subprocess.PIPE if data is not None else asyncio.subprocess.DEVNULL,\n        stdout=asyncio.subprocess.PIPE,stderr=asyncio.subprocess.PIPE)\n    try:\n        out,err=await asyncio.wait_for(p.communicate(data),timeout=timeout)\n    except BaseException:\n        if p.returncode is None:\n            try: p.kill()\n            except ProcessLookupError: pass\n        await asyncio.shield(p.wait())\n        raise\n    diagnostic=err.lower()\n    if b\'could not seek\' in diagnostic or b\'seek failed\' in diagnostic or b\'error seeking\' in diagnostic:\n        raise MediaError(\'source_seek_failed\')\n    if p.returncode:\n        reason=next((label for needle,label in (\n            (b\'403 forbidden\',\'source_forbidden\'), (b\'401 unauthorized\',\'source_unauthorized\'),\n            (b\'404 not found\',\'source_missing\'), (b\'not on whitelist\',\'protocol_refused\'),\n            (b\'invalid data\',\'invalid_media\'), (b\'could not find codec\',\'codec_unavailable\'),\n            (b\'connection refused\',\'source_unavailable\'), (b\'timed out\',\'source_timeout\'))\n            if needle in diagnostic),\'ffmpeg_failed\')\n        raise MediaError(reason)\n    return out\n\n\nasync def encode_pcm(data):\n    if len(data)% (SAMPLES_PER_PACKET*2) or not 0<len(data)<=CHUNK_SAMPLES*2:\n        raise MediaError(\'invalid_pcm_length\')\n    count=len(data)//(SAMPLES_PER_PACKET*2)\n    out=await ffmpeg([\'-f\',\'s16le\',\'-ar\',str(RATE),\'-ac\',\'1\',\'-i\',\'pipe:0\',\n        \'-map\',\'0:a:0\',\'-threads\',\'1\',\'-filter_threads\',\'1\',\'-c:a\',\'alac\',\'-compression_level\',\'0\',\'-sample_fmt\',\'s16p\',\n        \'-frames:a\',str(count),\'-movflags\',\'empty_moov+frag_keyframe+default_base_moof\',\'-f\',\'mp4\',\'pipe:1\'],data)\n    m,n=top(out,b\'moov\')\n    if alac_config(out[m:m+n]) != alac_config(_TEMPLATE):\n        raise MediaError(\'alac_config_mismatch\')\n    p,pn=top(out,b\'moof\'); t,tn=child(out,p,pn,b\'traf\')\n    h,hn=child(out,t,tn,b\'tfhd\'); r,rn=child(out,t,tn,b\'trun\')\n    # Require the exact packet defaults and one trun. Do not treat byte padding\n    # as valid audio or accept merely an average bitrate.\n    if hn!=28 or struct.unpack_from(\'>III\',out,h+8)!=(0x020038,1,SAMPLES_PER_PACKET) or struct.unpack_from(\'>I\',out,h+20)[0]!=PACKET_BYTES:\n        raise MediaError(\'unexpected_packet_defaults\')\n    flags,actual,offset=struct.unpack_from(\'>IIi\',out,r+8)\n    a,b=top(out,b\'mdat\')\n    if rn!=20 or flags!=1 or actual!=count or offset!=a+8-p or b!=8+count*PACKET_BYTES:\n        raise MediaError(\'unexpected_alac_packet_lengths\')\n    return out[a+8:a+b]\n\n\n@dataclass(frozen=True)\nclass Part:\n    index: int\n    start: int\n    end: int\n\n\ndef timeline(tracks):\n    """Map already measured chapters onto the fixed sample clock."""\n    result=[]; last=0\n    for expected,t in enumerate(tracks,1):\n        if t.index!=expected or not math.isfinite(t.start) or not math.isfinite(t.duration) or t.duration<=0:\n            raise MediaError(\'invalid_timeline\')\n        start=round(t.start*RATE); end=round((t.start+t.duration)*RATE)\n        if abs(start-last)>RATE//100 or end<=last:\n            raise MediaError(\'noncontiguous_timeline\')\n        result.append(Part(expected,last,end)); last=end\n    if not result or last>RATE*MAX_DURATION:\n        raise MediaError(\'duration_out_of_range\')\n    return tuple(result)\n\n\nclass LocalPlaybackSource:\n    """Ordinary playback of the existing, authorized local HLS track interface.\n\n    URL is derived from the server\'s own session, never from request input.\n    FFmpeg handles standard playback; no custom key fetching or protection\n    bypass. No retry with relaxed protocol/security flags.\n    """\n    def __init__(self, session):\n        if str(UUID(session.id))!=session.id:\n            raise MediaError(\'invalid_session\')\n        self.session=session\n\n    async def read(self,part: Part,start: int,count: int):\n        if self.session.closed:\n            raise MediaError(\'session_closed\')\n        offset=start-part.start\n        if not 0<=offset<part.end-part.start or count<=0 or start+count>part.end:\n            raise MediaError(\'invalid_source_interval\')\n        url=f\'http://127.0.0.1:8000/public/session/{self.session.id}/track/{part.index}.m3u8\'\n        # Input seek allows the normal HLS demuxer to select media near the\n        # requested time. A timeout bounds unsupported or slow source seeks.\n        args=[\'-threads\',\'1\',\'-rw_timeout\',\'8000000\']\n        if offset: args+=[\'-ss\',f\'{offset/RATE:.9f}\']\n        args+=[\'-i\',url,\'-map\',\'0:a:0\',\'-vn\',\'-sn\',\'-dn\',\'-threads\',\'1\',\'-filter_threads\',\'1\',\n               \'-t\',f\'{count/RATE:.9f}\',\'-ar\',str(RATE),\'-ac\',\'1\',\'-c:a\',\'pcm_s16le\',\n               \'-fs\',str(count*2+8192),\'-f\',\'s16le\',\'pipe:1\']\n        begun=time.monotonic()\n        pcm=await ffmpeg(args)\n        LOG.info(\'POC_FIXED_M4B event=source part=%d offset_seconds=%.3f requested_samples=%d received_samples=%d elapsed_ms=%d\',part.index,offset/RATE,count,len(pcm)//2,round((time.monotonic()-begun)*1000))\n        if len(pcm)%2 or len(pcm)>count*2+8192:\n            raise MediaError(\'invalid_source_pcm\')\n        if len(pcm)<count*2:\n            # Only tolerate a very small discrepancy at a real chapter end.\n            # Never hide a missing chapter or mid-book failure with silence.\n            missing=count*2-len(pcm)\n            if start+count!=part.end or missing>int(RATE*.05)*2 or not pcm:\n                raise MediaError(\'short_source_pcm\')\n            LOG.info(\'POC_FIXED_M4B event=chapter_end_rounding samples=%d\',missing//2)\n            pcm+=bytes(missing)\n        return pcm[:count*2]\n\n\nclass FixedM4B(VirtualRange):\n    """Classic fixed-packet M4B with on-demand audio and bounded memory."""\n    def __init__(self,tracks,source,*,rate=SEND_RATE,cache_bytes=CACHE_BYTES):\n        self.parts=timeline(tracks); self.ends=[p.end for p in self.parts]\n        self.source=source\n        self.source_samples=self.ends[-1]\n        self.header,self.packet_count,self.total_samples=make_index(self.source_samples)\n        self.media_start=len(self.header)\n        self.size=self.media_start+self.packet_count*PACKET_BYTES\n        self.duration=self.total_samples/RATE\n        self.chunk_count=(self.packet_count+PACKETS_PER_CHUNK-1)//PACKETS_PER_CHUNK\n        if rate<=0 or not 0<=cache_bytes<=CACHE_BYTES: raise MediaError(\'invalid_cache_limits\')\n        self.rate=rate; self.cache_limit=cache_bytes\n        self.cache=OrderedDict(); self.cache_size=0; self.hashes={}\n        self._guard=asyncio.Lock(); self._lock=threading.Lock(); self._active=0\n        self.closed=False; self.generated=0; self.requests=0\n        # Strong validator is session-specific. Cache regeneration is checked\n        # against hashes so a single session never silently changes its bytes.\n        self.etag=\'"\'+hashlib.sha256(os.urandom(32)+self.header).hexdigest()+\'"\'\n\n    def close(self):\n        self.closed=True; self.cache.clear(); self.cache_size=0; self.hashes.clear()\n\n    async def chunk(self,i):\n        if self.closed or not 0<=i<self.chunk_count:\n            raise MediaError(\'invalid_chunk\')\n        async with self._guard:\n            if self.closed: raise MediaError(\'session_closed\')\n            if i in self.cache:\n                self.cache.move_to_end(i)\n                return self.cache[i]\n            start=i*CHUNK_SAMPLES; end=min(start+CHUNK_SAMPLES,self.total_samples)\n            actual_end=min(end,self.source_samples)\n            started=time.monotonic(); pieces=[]; pos=start\n            async with _WORKERS:\n                while pos<actual_end:\n                    part=self.parts[bisect.bisect_right(self.ends,pos)]\n                    stop=min(actual_end,part.end)\n                    data=await self.source.read(part,pos,stop-pos)\n                    if len(data)!=(stop-pos)*2: raise MediaError(\'wrong_pcm_length\')\n                    pieces.append(data); pos=stop\n                # A fractional final ALAC packet is padded by at most 4095\n                # samples (0.171 seconds) so all packet lengths are identical.\n                if end>actual_end: pieces.append(bytes((end-actual_end)*2))\n                result=await encode_pcm(b\'\'.join(pieces))\n            if self.closed: raise MediaError(\'session_closed\')\n            expected=(end-start)//SAMPLES_PER_PACKET*PACKET_BYTES\n            if len(result)!=expected: raise MediaError(\'wrong_chunk_length\')\n            digest=hashlib.sha256(result).digest()\n            if i in self.hashes and self.hashes[i]!=digest:\n                raise MediaError(\'source_changed_within_session\')\n            self.hashes[i]=digest; self.generated+=1\n            if len(result)<=self.cache_limit:\n                while self.cache and self.cache_size+len(result)>self.cache_limit:\n                    _,old=self.cache.popitem(last=False); self.cache_size-=len(old)\n                self.cache[i]=result; self.cache_size+=len(result)\n            LOG.info(\'POC_FIXED_M4B event=chunk index=%d start_seconds=%.3f packets=%d bytes=%d elapsed_ms=%d generated=%d unique=%d cache_bytes=%d\',\n                i,start/RATE,len(result)//PACKET_BYTES,len(result),round((time.monotonic()-started)*1000),self.generated,len(self.hashes),self.cache_size)\n            return result\n\n    async def piece(self,pos,end):\n        if pos<self.media_start:\n            return self.header[pos:min(self.media_start,end+1,pos+65536)]\n        rel=pos-self.media_start; i,off=divmod(rel,CHUNK_BYTES)\n        data=await self.chunk(i)\n        return data[off:off+min(end-pos+1,65536)]\n\n    async def stream(self,start,end):\n        sent=media_sent=0; begin=None; pos=start\n        try:\n            while pos<=end and not self.closed:\n                if pos>=self.media_start:\n                    if begin is None: begin=time.monotonic()\n                    delay=(media_sent-BURST)/self.rate-(time.monotonic()-begin)\n                    if delay>0: await asyncio.sleep(delay)\n                data=await self.piece(pos,end)\n                if not data: raise MediaError(\'empty_range_slice\')\n                if pos>=self.media_start: media_sent+=len(data)\n                pos+=len(data); sent+=len(data)\n                yield data\n                await asyncio.sleep(0)\n        except (MediaError,asyncio.TimeoutError) as exc:\n            LOG.warning(\'POC_FIXED_M4B event=stream_error reason=%s\', str(exc) if isinstance(exc,MediaError) else \'timeout\')\n            raise\n        finally:\n            LOG.info(\'POC_FIXED_M4B event=body bytes=%d media_bytes=%d complete=%d\',sent,media_sent,int(pos>end))\n\n    async def response(self,req: Request):\n        if self.closed: return Response(status_code=404)\n        headers={\'Accept-Ranges\':\'bytes\',\'Cache-Control\':\'private, no-store\',\'ETag\':self.etag}\n        value=req.headers.get(\'range\') if req.method==\'GET\' else None\n        if req.headers.get(\'if-range\') not in (None,self.etag): value=None\n        try: start,end,partial=self.bounds(value)\n        except ValueError: return Response(status_code=416,headers={**headers,\'Content-Range\':f\'bytes */{self.size}\'})\n        headers[\'Content-Length\']=str(end-start+1)\n        if partial: headers[\'Content-Range\']=f\'bytes {start}-{end}/{self.size}\'\n        status=206 if partial else 200\n        self.requests+=1\n        LOG.info(\'POC_FIXED_M4B event=range status=%d start=%d end=%d total=%d\',status,start,end,self.size)\n        if req.method==\'HEAD\': return Response(status_code=status,headers=headers,media_type=\'audio/mp4\')\n        return LimitedResponse(self,self.stream(start,end),status_code=status,headers=headers,media_type=\'audio/mp4\')\n\n\nclass LimitedResponse(StreamingResponse):\n    def __init__(self,owner,iterator,**kwargs):\n        super().__init__(iterator,**kwargs); self.owner=owner\n    async def __call__(self,scope,receive,send):\n        with self.owner._lock:\n            admitted=self.owner._active<MAX_ACTIVE\n            if admitted:self.owner._active+=1\n        if not admitted:\n            await Response(status_code=503,headers={\'Retry-After\':\'1\'})(scope,receive,send); return\n        try: await super().__call__(scope,receive,send)\n        finally:\n            with self.owner._lock:self.owner._active-=1\n\n\ndef patch_item(item, engine):\n    """Advertise the same one-track classical file contract as F."""\n    size=engine.size; duration=round(engine.duration,3)\n    name=\'virtual-book.m4b\'\n    media=item[\'media\']; item[\'size\']=size\n    item[\'numFiles\']=1\n    media.update({\'size\':size,\'duration\':duration,\'numTracks\':1,\'numAudioFiles\':1})\n    for af in media.get(\'audioFiles\',[])+media.get(\'tracks\',[]):\n        patch_track(af,size,duration,name)\n    if media.get(\'chapters\'): media[\'chapters\'][-1][\'end\']=duration\n    return item\n\n\ndef patch_track(track,size,duration,name=\'virtual-book.m4b\'):\n    track.update({\'codec\':\'alac\',\'channels\':1,\'bitRate\':384000,\'duration\':duration,\'mimeType\':\'audio/mp4\'})\n    meta=track[\'metadata\']\n    meta.update({\'filename\':name,\'ext\':\'.m4b\',\'size\':size,\'path\':meta[\'path\'].rsplit(\'/\',1)[0]+\'/\'+name,\'relPath\':name})\n\n\ndef patch_payload(payload,engine):\n    duration=round(engine.duration,3)\n    payload[\'playMethod\']=0; payload[\'duration\']=duration\n    for t in payload[\'audioTracks\']: patch_track(t,engine.size,duration)\n    if payload[\'chapters\']: payload[\'chapters\'][-1][\'end\']=duration\n    patch_item(payload[\'libraryItem\'],engine)\n    return payload\n\n@dataclass(frozen=True)\nclass Metadata:\n    size: int\n    duration: float\n'

import os, shutil, sys, tempfile, hashlib
root, original = (Path(s).resolve(strict=True) for s in sys.argv[1:3])
mode = sys.argv[3]
backup = root/'.nextory-fixed-m4b-baseline'
helper = root/'app/fixed_m4b.py'
if (root/'app').is_symlink() or backup.is_symlink() or helper.is_symlink():
    sys.exit('ERROR: Source or backup symlink detected.')
paths = {name:root/name for name in PATCHERS}
for name,p in paths.items():
    q=original/name
    if not p.is_file() or p.is_symlink() or (q.exists() and p.samefile(q)):
        sys.exit('ERROR: Unsafe or missing source '+name)
for name in ('virtual_flat.py','virtual_long.py','virtual_range.py','format_control.py'):
    p=root/'app'/name
    if not p.is_file() or p.is_symlink():
        sys.exit('ERROR: Working control F is required.')
current={n:p.read_text(encoding='utf-8') for n,p in paths.items()}
if backup.exists():
    if not all((backup/n).is_file() and not (backup/n).is_symlink() for n in paths):
        sys.exit('ERROR: Incomplete backup; nothing changed.')
    baseline={n:(backup/n).read_text(encoding='utf-8') for n in paths}
else:
    if helper.exists() or any('NEXTORY_FIXED_M4B_V1' in s for s in current.values()):
        sys.exit('ERROR: Existing experiment without backup.')
    baseline=current
try:
    modified={n:PATCHERS[n](s) for n,s in baseline.items()}
    ast.parse(HELPER,filename='fixed_m4b.py')
except (ValueError,SyntaxError) as exc:
    sys.exit('ERROR: Source structure does not match expected test version: '+str(exc))
clean=current==baseline and not helper.exists()
applied=current==modified and helper.is_file() and helper.read_text(encoding='utf-8')==HELPER
if not clean and not applied:
    sys.exit('ERROR: Unexpected local source changes. Nothing overwritten.')

def atomic_write(p,data):
    fd,name=tempfile.mkstemp(prefix='.m4b-patch-',dir=p.parent)
    try:
        with os.fdopen(fd,'w',encoding='utf-8') as f:f.write(data)
        os.chmod(name,(p.stat().st_mode & 0o777) if p.exists() else 0o644)
        os.replace(name,p)
    finally:
        if os.path.exists(name):os.unlink(name)

if mode=='rollback':
    if not backup.is_dir():sys.exit('ERROR: No backup available.')
    if applied:
        for n,p in paths.items():atomic_write(p,baseline[n])
        helper.unlink()
    print('FIXED_M4B=DISABLED')
    print('BASELINE=RESTORED')
else:
    if not backup.exists():
        backup.mkdir(mode=0o700)
        for n,p in paths.items():
            dst=backup/n;dst.parent.mkdir(parents=True,exist_ok=True)
            shutil.copy2(p,dst)
    if clean:
        for n,p in paths.items():atomic_write(p,modified[n])
        atomic_write(helper,HELPER)
    print('FIXED_M4B=ENABLED_FOR_BOOK_7207495_AUDIOBOOTH_ONLY')
    print('CODEC=ALAC_24000HZ_MONO_16BIT_FIXED_8196_BYTES')
    print('SOURCE=EXISTING_AUTHORIZED_PLAYBACK_SESSION')
    print('FFMPEG_WORKERS=1')
    print('MAX_M4B_SESSIONS=2 MEMORY_CACHE_PER_SESSION_BYTES=8388608')
    print('AUDIOBOOK_DOWNLOAD_AT_INSTALL=NO')
print('PYTHON_SYNTAX=PASS')
print('ORIGINAL=NOT_MODIFIED')

PYCODE

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
for _ in $(seq 1 30); do
  if docker exec nextory-abs-poc-test python -c 'import urllib.request; assert urllib.request.urlopen("http://127.0.0.1:8000/health",timeout=3).status==200' >/dev/null 2>&1; then
    READY=1; break
  fi
  sleep 2
done
if [ "$READY" != 1 ]; then
  echo 'ERROR: Testcontainer reageert niet op /health. Gebruik rollback indien nodig.'
  exit 1
fi
echo 'HEALTH=PASS'
echo
echo '=== 5. VERIFICATIE ==='
docker exec -i nextory-abs-poc-test python - "$MODE" <<'PY'
import asyncio,inspect,sys
from app import main
from app.format_control import FLAT
assert FLAT.duration==36000
if sys.argv[1]=='apply':
    from app import fixed_m4b as f
    assert f.enabled(7207495)
    assert f.TARGET_BOOK==7207495 and not f.enabled(4998973)
    raw=asyncio.run(f.encode_pcm(bytes(2*f.SAMPLES_PER_PACKET*2)))
    assert len(raw)==2*f.PACKET_BYTES
    header,count,total=f.make_index(36000*f.RATE)
    assert count==210938 and len(header)<30000
    assert 'NEXTORY_FIXED_M4B_V1' in inspect.getsource(main)
    print('RUNTIME_ALAC_ENCODER=PASS')
    print('CLASSIC_10H_INDEX=PASS')
    print('SOURCE_CALLS_IN_SELFTEST=0')
else:
    assert 'NEXTORY_FIXED_M4B_V1' not in inspect.getsource(main)
    print('BASELINE=RESTORED')
print('TEST_F_PRESERVED=YES')
PY
docker inspect nextory-abs-poc-test --format 'TEST_RUNNING={{.State.Running}} HEALTH={{if .State.Health}}{{.State.Health.Status}}{{else}}unknown{{end}}'
docker inspect nextory-abs-poc --format 'ORIGINAL_RUNNING={{.State.Running}}'
echo '=== EINDE ==='
