"""Experimental classic M4B over fixed-size ALAC packets.

Uses a normal, authorized local playback source; no provider credentials, key
extraction, downloader, changes to HLS authentication or persistent audio files.
Only use with media for which repackaging is permitted.
"""
from __future__ import annotations

import asyncio
import bisect
import hashlib
import logging
import math
import os
import struct
import threading
import time
from collections import OrderedDict
from dataclasses import dataclass
from urllib.parse import urlsplit
from uuid import UUID

from fastapi import Request
from fastapi.responses import Response, StreamingResponse
from .virtual_long import box, boxes, child, top
from .virtual_flat import replace_box, get_child
from .virtual_range import VirtualRange

LOG = logging.getLogger('uvicorn.error')
RATE = 24000
SAMPLES_PER_PACKET = 4096
PACKET_BYTES = 8196
PACKETS_PER_CHUNK = 64
CHUNK_SAMPLES = PACKETS_PER_CHUNK * SAMPLES_PER_PACKET
CHUNK_BYTES = PACKETS_PER_CHUNK * PACKET_BYTES
CACHE_BYTES = 8 * 1024 * 1024
# At most one FFmpeg worker, including encoding; do not exceed container budget.
_WORKERS = asyncio.Semaphore(1)
MAX_DURATION = 40 * 3600
MAX_ACTIVE = 4
# Bound speculative read-ahead. Actual nominal media rate ~48 KB/s.
SEND_RATE = 256 * 1024
BURST = 512 * 1024
FFMPEG_TIMEOUT = 25
TARGET_BOOK = 7207495
MARKER = 'NEXTORY_FIXED_M4B_V1'

class MediaError(RuntimeError):
    pass


def enabled(book_id: int) -> bool:
    return book_id == TARGET_BOOK and os.environ.get('NEXTORY_TEST_VIRTUAL_M4B_BOOK') == str(TARGET_BOOK)

# This template is generated locally by FFmpeg from two packets of silent
# 16-bit PCM. Only container metadata is included, not any audio payload.
_TEMPLATE = bytes.fromhex('000002866d6f6f760000006c6d766864000000000000000000000000000003e8000001560001000001000000000000000000000000010000000000000000000000000000000100000000000000000000000000004000000000000000000000000000000000000000000000000000000000000002000001b17472616b0000005c746b68640000000300000000000000000000000100000000000001560000000000000000000000010100000000010000000000000000000000000000000100000000000000000000000000004000000000000000000000000000014d6d646961000000206d64686400000000000000000000000000005dc00000200055c400000000002d68646c720000000000000000736f756e000000000000000000000000536f756e6448616e646c657200000000f86d696e6600000010736d686400000000000000000000002464696e660000001c6472656600000000000000010000000c75726c2000000001000000bc7374626c0000005873747364000000000000000100000048616c61630000000000000001000000000000000000010010000000005dc0000000000024616c616300000000000010000010000000010000000020040005dc0000005dc00000001873747473000000000000000100000002000010000000001c737473630000000000000001000000010000000200000001000000147374737a000000000000200400000002000000147374636f0000000000000001000002b20000006175647461000000596d657461000000000000002168646c7200000000000000006d6469726170706c0000000000000000000000002c696c737400000024a9746f6f0000001c6461746100000001000000004c61766636312e372e313033')


def make_index(source_samples: int):
    """A classic non-fragmented ISO BMFF header with an exact constant stsz."""
    if not 0 < source_samples <= MAX_DURATION * RATE:
        raise MediaError('duration_out_of_range')
    count = (source_samples + SAMPLES_PER_PACKET - 1) // SAMPLES_PER_PACKET
    total_samples = count * SAMPLES_PER_PACKET
    media_bytes = count * PACKET_BYTES
    chunk_count = (count + PACKETS_PER_CHUNK - 1) // PACKETS_PER_CHUNK
    last_count = count - (chunk_count-1)*PACKETS_PER_CHUNK
    # The small template uses version-0 movie/track headers and a single track.
    m = bytearray(_TEMPLATE)
    a,b = child(m,0,len(m),b'mvhd')
    p,n = child(m,0,len(m),b'trak')
    t,tn = child(m,p,n,b'tkhd')
    d,dn = child(m,p,n,b'mdia')
    h,hn = child(m,d,dn,b'mdhd')
    if m[a+8] or m[t+8] or m[h+8] or struct.unpack_from('>I',m,a+20)[0]!=1000 or struct.unpack_from('>I',m,h+20)[0]!=RATE:
        raise MediaError('invalid_alac_template')
    ms = (total_samples*1000+RATE-1)//RATE
    struct.pack_into('>I',m,a+24,ms)
    struct.pack_into('>I',m,t+28,ms)
    struct.pack_into('>I',m,h+24,total_samples)
    moov=bytes(m); trak=get_child(moov,b'trak'); mdia=get_child(trak,b'mdia')
    minf=get_child(mdia,b'minf'); stbl=get_child(minf,b'stbl')
    stsd=get_child(stbl,b'stsd')
    stts=box(b'stts',struct.pack('>IIII',0,1,count,SAMPLES_PER_PACKET))
    runs=[(1, min(PACKETS_PER_CHUNK,count), 1)]
    if chunk_count>1 and last_count!=PACKETS_PER_CHUNK:
        runs.append((chunk_count,last_count,1))
    stsc=box(b'stsc',struct.pack('>II',0,len(runs))+b''.join(struct.pack('>III',*r) for r in runs))
    stsz=box(b'stsz',struct.pack('>III',0,PACKET_BYTES,count))
    # co64 also supports long books above 4 GiB; offsets never depend on media.
    co64=box(b'co64',struct.pack('>II',0,chunk_count)+bytes(8*chunk_count))
    stbl=box(b'stbl',stsd+stts+stsc+stsz+co64)
    minf=replace_box(minf,b'minf',b'stbl',stbl)
    mdia=replace_box(mdia,b'mdia',b'minf',minf)
    trak=replace_box(trak,b'trak',b'mdia',mdia)
    moov=replace_box(moov,b'moov',b'trak',trak)
    # Drop the template's encoder tags (not source metadata).
    if any(k==b'udta' for _,_,k in boxes(moov,8)):
        moov=replace_box(moov,b'moov',b'udta',b'')
    ftyp=box(b'ftyp',b'M4B '+struct.pack('>I',512)+b'M4A isommp42')
    mdat=(struct.pack('>I4s',media_bytes+8,b'mdat') if media_bytes+8<2**32
          else struct.pack('>I4sQ',1,b'mdat',media_bytes+16))
    header=bytearray(ftyp+moov+mdat)
    a,b=child(header,len(ftyp),len(moov),b'trak')
    a,b=child(header,a,b,b'mdia'); a,b=child(header,a,b,b'minf')
    a,b=child(header,a,b,b'stbl'); a,b=child(header,a,b,b'co64')
    if b != 16+8*chunk_count:
        raise MediaError('invalid_offset_table')
    for i in range(chunk_count):
        struct.pack_into('>Q',header,a+16+8*i,len(header)+i*CHUNK_BYTES)
    return bytes(header),count,total_samples


def alac_config(moov):
    stsd=get_child(get_child(get_child(get_child(get_child(moov,b'trak'),b'mdia'),b'minf'),b'stbl'),b'stsd')
    # Single version-0 ALAC sample description; nested alac config is 36 bytes.
    if stsd[20:24]!=b'alac' or struct.unpack_from('>I',stsd,12)[0]!=1:
        raise MediaError('unexpected_sample_description')
    entry=stsd[16:]
    if len(entry)<36 or struct.unpack_from('>H',entry,24)[0]!=1:
        raise MediaError('unexpected_alac_channels')
    configs=[entry[p:p+n] for p,n,k in boxes(entry,36) if k==b'alac']
    if len(configs)!=1 or len(configs[0])!=36:
        raise MediaError('unexpected_alac_config')
    return configs[0]


async def ffmpeg(args, data=None, timeout=FFMPEG_TIMEOUT):
    p=await asyncio.create_subprocess_exec('ffmpeg','-nostdin','-hide_banner','-loglevel','error',*args,
        stdin=asyncio.subprocess.PIPE if data is not None else asyncio.subprocess.DEVNULL,
        stdout=asyncio.subprocess.PIPE,stderr=asyncio.subprocess.PIPE)
    try:
        out,err=await asyncio.wait_for(p.communicate(data),timeout=timeout)
    except BaseException:
        if p.returncode is None:
            try: p.kill()
            except ProcessLookupError: pass
        await asyncio.shield(p.wait())
        raise
    diagnostic=err.lower()
    if b'could not seek' in diagnostic or b'seek failed' in diagnostic or b'error seeking' in diagnostic:
        raise MediaError('source_seek_failed')
    if p.returncode:
        reason=next((label for needle,label in (
            (b'403 forbidden','source_forbidden'), (b'401 unauthorized','source_unauthorized'),
            (b'404 not found','source_missing'), (b'not on whitelist','protocol_refused'),
            (b'invalid data','invalid_media'), (b'could not find codec','codec_unavailable'),
            (b'connection refused','source_unavailable'), (b'timed out','source_timeout'))
            if needle in diagnostic),'ffmpeg_failed')
        raise MediaError(reason)
    return out


async def encode_pcm(data):
    if len(data)% (SAMPLES_PER_PACKET*2) or not 0<len(data)<=CHUNK_SAMPLES*2:
        raise MediaError('invalid_pcm_length')
    count=len(data)//(SAMPLES_PER_PACKET*2)
    out=await ffmpeg(['-f','s16le','-ar',str(RATE),'-ac','1','-i','pipe:0',
        '-map','0:a:0','-threads','1','-filter_threads','1','-c:a','alac','-compression_level','0','-sample_fmt','s16p',
        '-frames:a',str(count),'-movflags','empty_moov+frag_keyframe+default_base_moof','-f','mp4','pipe:1'],data)
    m,n=top(out,b'moov')
    if alac_config(out[m:m+n]) != alac_config(_TEMPLATE):
        raise MediaError('alac_config_mismatch')
    p,pn=top(out,b'moof'); t,tn=child(out,p,pn,b'traf')
    h,hn=child(out,t,tn,b'tfhd'); r,rn=child(out,t,tn,b'trun')
    # Require the exact packet defaults and one trun. Do not treat byte padding
    # as valid audio or accept merely an average bitrate.
    if hn!=28 or struct.unpack_from('>III',out,h+8)!=(0x020038,1,SAMPLES_PER_PACKET) or struct.unpack_from('>I',out,h+20)[0]!=PACKET_BYTES:
        raise MediaError('unexpected_packet_defaults')
    flags,actual,offset=struct.unpack_from('>IIi',out,r+8)
    a,b=top(out,b'mdat')
    if rn!=20 or flags!=1 or actual!=count or offset!=a+8-p or b!=8+count*PACKET_BYTES:
        raise MediaError('unexpected_alac_packet_lengths')
    return out[a+8:a+b]


@dataclass(frozen=True)
class Part:
    index: int
    start: int
    end: int


def timeline(tracks):
    """Map already measured chapters onto the fixed sample clock."""
    result=[]; last=0
    for expected,t in enumerate(tracks,1):
        if t.index!=expected or not math.isfinite(t.start) or not math.isfinite(t.duration) or t.duration<=0:
            raise MediaError('invalid_timeline')
        start=round(t.start*RATE); end=round((t.start+t.duration)*RATE)
        if abs(start-last)>RATE//100 or end<=last:
            raise MediaError('noncontiguous_timeline')
        result.append(Part(expected,last,end)); last=end
    if not result or last>RATE*MAX_DURATION:
        raise MediaError('duration_out_of_range')
    return tuple(result)


class LocalPlaybackSource:
    """Ordinary playback of the existing, authorized local HLS track interface.

    URL is derived from the server's own session, never from request input.
    FFmpeg handles standard playback; no custom key fetching or protection
    bypass. No retry with relaxed protocol/security flags.
    """
    def __init__(self, session):
        if str(UUID(session.id))!=session.id:
            raise MediaError('invalid_session')
        self.session=session

    async def read(self,part: Part,start: int,count: int):
        if self.session.closed:
            raise MediaError('session_closed')
        offset=start-part.start
        if not 0<=offset<part.end-part.start or count<=0 or start+count>part.end:
            raise MediaError('invalid_source_interval')
        url=f'http://127.0.0.1:8000/public/session/{self.session.id}/track/{part.index}.m3u8'
        # Input seek allows the normal HLS demuxer to select media near the
        # requested time. A timeout bounds unsupported or slow source seeks.
        args=['-threads','1','-rw_timeout','8000000']
        if offset: args+=['-ss',f'{offset/RATE:.9f}']
        args+=['-i',url,'-map','0:a:0','-vn','-sn','-dn','-threads','1','-filter_threads','1',
               '-t',f'{count/RATE:.9f}','-ar',str(RATE),'-ac','1','-c:a','pcm_s16le',
               '-fs',str(count*2+8192),'-f','s16le','pipe:1']
        begun=time.monotonic()
        pcm=await ffmpeg(args)
        LOG.info('POC_FIXED_M4B event=source part=%d offset_seconds=%.3f requested_samples=%d received_samples=%d elapsed_ms=%d',part.index,offset/RATE,count,len(pcm)//2,round((time.monotonic()-begun)*1000))
        if len(pcm)%2 or len(pcm)>count*2+8192:
            raise MediaError('invalid_source_pcm')
        if len(pcm)<count*2:
            # Only tolerate a very small discrepancy at a real chapter end.
            # Never hide a missing chapter or mid-book failure with silence.
            missing=count*2-len(pcm)
            if start+count!=part.end or missing>int(RATE*.05)*2 or not pcm:
                raise MediaError('short_source_pcm')
            LOG.info('POC_FIXED_M4B event=chapter_end_rounding samples=%d',missing//2)
            pcm+=bytes(missing)
        return pcm[:count*2]


class FixedM4B(VirtualRange):
    """Classic fixed-packet M4B with on-demand audio and bounded memory."""
    def __init__(self,tracks,source,*,rate=SEND_RATE,cache_bytes=CACHE_BYTES):
        self.parts=timeline(tracks); self.ends=[p.end for p in self.parts]
        self.source=source
        self.source_samples=self.ends[-1]
        self.header,self.packet_count,self.total_samples=make_index(self.source_samples)
        self.media_start=len(self.header)
        self.size=self.media_start+self.packet_count*PACKET_BYTES
        self.duration=self.total_samples/RATE
        self.chunk_count=(self.packet_count+PACKETS_PER_CHUNK-1)//PACKETS_PER_CHUNK
        if rate<=0 or not 0<=cache_bytes<=CACHE_BYTES: raise MediaError('invalid_cache_limits')
        self.rate=rate; self.cache_limit=cache_bytes
        self.cache=OrderedDict(); self.cache_size=0; self.hashes={}
        self._guard=asyncio.Lock(); self._lock=threading.Lock(); self._active=0
        self.closed=False; self.generated=0; self.requests=0
        # Strong validator is session-specific. Cache regeneration is checked
        # against hashes so a single session never silently changes its bytes.
        self.etag='"'+hashlib.sha256(os.urandom(32)+self.header).hexdigest()+'"'

    def close(self):
        self.closed=True; self.cache.clear(); self.cache_size=0; self.hashes.clear()

    async def chunk(self,i):
        if self.closed or not 0<=i<self.chunk_count:
            raise MediaError('invalid_chunk')
        async with self._guard:
            if self.closed: raise MediaError('session_closed')
            if i in self.cache:
                self.cache.move_to_end(i)
                return self.cache[i]
            start=i*CHUNK_SAMPLES; end=min(start+CHUNK_SAMPLES,self.total_samples)
            actual_end=min(end,self.source_samples)
            started=time.monotonic(); pieces=[]; pos=start
            async with _WORKERS:
                while pos<actual_end:
                    part=self.parts[bisect.bisect_right(self.ends,pos)]
                    stop=min(actual_end,part.end)
                    data=await self.source.read(part,pos,stop-pos)
                    if len(data)!=(stop-pos)*2: raise MediaError('wrong_pcm_length')
                    pieces.append(data); pos=stop
                # A fractional final ALAC packet is padded by at most 4095
                # samples (0.171 seconds) so all packet lengths are identical.
                if end>actual_end: pieces.append(bytes((end-actual_end)*2))
                result=await encode_pcm(b''.join(pieces))
            if self.closed: raise MediaError('session_closed')
            expected=(end-start)//SAMPLES_PER_PACKET*PACKET_BYTES
            if len(result)!=expected: raise MediaError('wrong_chunk_length')
            digest=hashlib.sha256(result).digest()
            if i in self.hashes and self.hashes[i]!=digest:
                raise MediaError('source_changed_within_session')
            self.hashes[i]=digest; self.generated+=1
            if len(result)<=self.cache_limit:
                while self.cache and self.cache_size+len(result)>self.cache_limit:
                    _,old=self.cache.popitem(last=False); self.cache_size-=len(old)
                self.cache[i]=result; self.cache_size+=len(result)
            LOG.info('POC_FIXED_M4B event=chunk index=%d start_seconds=%.3f packets=%d bytes=%d elapsed_ms=%d generated=%d unique=%d cache_bytes=%d',
                i,start/RATE,len(result)//PACKET_BYTES,len(result),round((time.monotonic()-started)*1000),self.generated,len(self.hashes),self.cache_size)
            return result

    async def piece(self,pos,end):
        if pos<self.media_start:
            return self.header[pos:min(self.media_start,end+1,pos+65536)]
        rel=pos-self.media_start; i,off=divmod(rel,CHUNK_BYTES)
        data=await self.chunk(i)
        return data[off:off+min(end-pos+1,65536)]

    async def stream(self,start,end):
        sent=media_sent=0; begin=None; pos=start
        try:
            while pos<=end and not self.closed:
                if pos>=self.media_start:
                    if begin is None: begin=time.monotonic()
                    delay=(media_sent-BURST)/self.rate-(time.monotonic()-begin)
                    if delay>0: await asyncio.sleep(delay)
                data=await self.piece(pos,end)
                if not data: raise MediaError('empty_range_slice')
                if pos>=self.media_start: media_sent+=len(data)
                pos+=len(data); sent+=len(data)
                yield data
                await asyncio.sleep(0)
        except (MediaError,asyncio.TimeoutError) as exc:
            LOG.warning('POC_FIXED_M4B event=stream_error reason=%s', str(exc) if isinstance(exc,MediaError) else 'timeout')
            raise
        finally:
            LOG.info('POC_FIXED_M4B event=body bytes=%d media_bytes=%d complete=%d',sent,media_sent,int(pos>end))

    async def response(self,req: Request):
        if self.closed: return Response(status_code=404)
        headers={'Accept-Ranges':'bytes','Cache-Control':'private, no-store','ETag':self.etag}
        value=req.headers.get('range') if req.method=='GET' else None
        if req.headers.get('if-range') not in (None,self.etag): value=None
        try: start,end,partial=self.bounds(value)
        except ValueError: return Response(status_code=416,headers={**headers,'Content-Range':f'bytes */{self.size}'})
        headers['Content-Length']=str(end-start+1)
        if partial: headers['Content-Range']=f'bytes {start}-{end}/{self.size}'
        status=206 if partial else 200
        self.requests+=1
        LOG.info('POC_FIXED_M4B event=range status=%d start=%d end=%d total=%d',status,start,end,self.size)
        if req.method=='HEAD': return Response(status_code=status,headers=headers,media_type='audio/mp4')
        return LimitedResponse(self,self.stream(start,end),status_code=status,headers=headers,media_type='audio/mp4')


class LimitedResponse(StreamingResponse):
    def __init__(self,owner,iterator,**kwargs):
        super().__init__(iterator,**kwargs); self.owner=owner
    async def __call__(self,scope,receive,send):
        with self.owner._lock:
            admitted=self.owner._active<MAX_ACTIVE
            if admitted:self.owner._active+=1
        if not admitted:
            await Response(status_code=503,headers={'Retry-After':'1'})(scope,receive,send); return
        try: await super().__call__(scope,receive,send)
        finally:
            with self.owner._lock:self.owner._active-=1


def patch_item(item, engine):
    """Advertise the same one-track classical file contract as F."""
    size=engine.size; duration=round(engine.duration,3)
    name='virtual-book.m4b'
    media=item['media']; item['size']=size
    item['numFiles']=1
    media.update({'size':size,'duration':duration,'numTracks':1,'numAudioFiles':1})
    for af in media.get('audioFiles',[])+media.get('tracks',[]):
        patch_track(af,size,duration,name)
    if media.get('chapters'): media['chapters'][-1]['end']=duration
    return item


def patch_track(track,size,duration,name='virtual-book.m4b'):
    track.update({'codec':'alac','channels':1,'bitRate':384000,'duration':duration,'mimeType':'audio/mp4'})
    meta=track['metadata']
    meta.update({'filename':name,'ext':'.m4b','size':size,'path':meta['path'].rsplit('/',1)[0]+'/'+name,'relPath':name})


def patch_payload(payload,engine):
    duration=round(engine.duration,3)
    payload['playMethod']=0; payload['duration']=duration
    for t in payload['audioTracks']: patch_track(t,engine.size,duration)
    if payload['chapters']: payload['chapters'][-1]['end']=duration
    patch_item(payload['libraryItem'],engine)
    return payload

@dataclass(frozen=True)
class Metadata:
    size: int
    duration: float
