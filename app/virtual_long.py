"""Synthetic long direct-play test; no Nextory or external media access.

Generate a deterministic, globally indexed fragmented MP4 from five short
locally authored AAC templates.  Each 6.4 s media slot is independently
addressable. No full assembled file is written or held in memory.
"""
from __future__ import annotations

import asyncio
import hashlib
import json
import logging
import struct
import threading
import time
from collections import OrderedDict
from pathlib import Path

from fastapi import Request
from fastapi.responses import Response, StreamingResponse
from .virtual_range import VirtualRange

LOG = logging.getLogger('uvicorn.error')
SLOT = 65536
TIMESCALE = 48000
TICKS = 307200
SLOT_COUNT = 5625
FREQUENCIES = (330, 440, 550, 660, 770)
CACHE_SLOTS = 64
BURST_BYTES = 512 * 1024
RATE_BYTES = 256 * 1024  # per response after burst; not a production setting
MAX_ACTIVE = 12
MAX_COUNT = 5625


def box(kind, payload):
    return struct.pack('>I4s', len(payload) + 8, kind) + payload


def boxes(data, start=0, end=None):
    end = len(data) if end is None else end
    while start < end:
        if end-start < 8:
            raise ValueError('Truncated box header')
        n, t = struct.unpack_from('>I4s', data, start)
        if n < 8 or start+n > end:
            raise ValueError('Unsupported box length')
        yield start, n, t
        start += n


def child(data, start, length, name):
    found = [(p,n) for p,n,t in boxes(data,start+8,start+length) if t==name]
    if len(found) != 1:
        raise ValueError('Missing or duplicate box '+name.decode('ascii'))
    return found[0]


def top(data, name):
    found = [(p,n) for p,n,t in boxes(data) if t==name]
    if len(found)!=1:
        raise ValueError('Missing or duplicate top-level box')
    return found[0]


def init_for_duration(template, count):
    # Exact duration in both the track and movie time bases, in addition to
    # sidx and tfra. We accept only the known v0, one-track test template.
    data = bytearray(template)
    m,n = top(data,b'moov')
    mvhd,l = child(data,m,n,b'mvhd')
    trak,tl = child(data,m,n,b'trak')
    tkhd,l = child(data,trak,tl,b'tkhd')
    mdia,ml = child(data,trak,tl,b'mdia')
    mdhd,l = child(data,mdia,ml,b'mdhd')
    assert data[mvhd+8] == data[tkhd+8] == data[mdhd+8] == 0
    assert struct.unpack_from('>I',data,mvhd+20)[0] == 1000
    assert struct.unpack_from('>I',data,mdhd+20)[0] == TIMESCALE
    assert struct.unpack_from('>I',data,tkhd+20)[0] == 1
    duration_ms = count*TICKS*1000//TIMESCALE
    struct.pack_into('>I',data,mvhd+24,duration_ms)
    struct.pack_into('>I',data,tkhd+28,duration_ms)
    struct.pack_into('>I',data,mdhd+24,count*TICKS)
    return bytes(data)


def template_offsets(data):
    moof,n = top(data,b'moof')
    mdat,ml = top(data,b'mdat')
    assert moof==0 and mdat==n and n+ml==len(data)
    mfhd,mfl = child(data,moof,n,b'mfhd')
    traf,tl = child(data,moof,n,b'traf')
    tfhd,hl = child(data,traf,tl,b'tfhd')
    tfdt,dl = child(data,traf,tl,b'tfdt')
    trun,rl = child(data,traf,tl,b'trun')
    assert mfl==16 and dl==20 and data[tfdt+8]==1
    assert struct.unpack_from('>I',data,tfhd+8)[0]==0x020038
    assert struct.unpack_from('>II',data,tfhd+12)==(1,1024)
    assert struct.unpack_from('>IIi',data,trun+8)==(0x201,300,n+8)
    assert rl==20+300*4
    assert sum(struct.unpack_from('>300I',data,trun+20))==ml-8
    assert len(data)<=SLOT-8
    return mfhd+12,tfdt+12


class LongVirtual(VirtualRange):
    """Uses the existing Range parser; media slots have a generated backing."""
    def __init__(self, root: Path, count=SLOT_COUNT, *, rate=RATE_BYTES, cache_slots=CACHE_SLOTS):
        if not 1<=count<=MAX_COUNT or not 1<=cache_slots<=CACHE_SLOTS or rate<=0:
            raise ValueError('Invalid long control limits')
        self.root=root.resolve(strict=True)
        expected=json.loads((self.root/'sha256.json').read_text())
        names=['init.bin']+[f'tone-{f}.bin' for f in FREQUENCIES]
        if set(expected)!=set(names):
            raise ValueError('Invalid template manifest')
        assets={}
        for name in names:
            p=self.root/name
            if p.is_symlink() or not p.is_file() or p.stat().st_size> SLOT:
                raise ValueError('Invalid template file')
            v=p.read_bytes()
            if hashlib.sha256(v).hexdigest()!=expected[name]:
                raise ValueError('Template checksum mismatch')
            assets[name]=v
        self.count=count
        self.rate=rate
        self.cache_slots=cache_slots
        self.duration=count*TICKS/TIMESCALE
        self.templates=[]
        for f in FREQUENCIES:
            data=assets[f'tone-{f}.bin']
            a,b=template_offsets(data)
            self.templates.append((data,a,b))
        self.header=init_for_duration(assets['init.bin'],count)+box(b'sidx',
            struct.pack('>IIIQQHH',0x01000000,1,TIMESCALE,0,0,0,count)
            +struct.pack('>III',SLOT,TICKS,0x80000000)*count)
        tfra=box(b'tfra',struct.pack('>IIII',0x01000000,1,0,count)+b''.join(
            struct.pack('>QQBBB',i*TICKS,len(self.header)+i*SLOT,1,1,1)
            for i in range(count)))
        self.tail=box(b'mfra',tfra+box(b'mfro',struct.pack('>II',0,len(tfra)+24)))
        self.media_end=len(self.header)+SLOT*count
        self.size=self.media_end+len(self.tail)
        # Stable validator without constructing the entire representation.
        # The schema version must change if the generation algorithm changes.
        digest=hashlib.sha256(b'long-virtual-v1\0'+str(count).encode()+self.header+self.tail+
                              b''.join(t[0] for t in self.templates)).hexdigest()
        self.etag='"'+digest+'"'
        self._lock=threading.Lock()
        self._cache=OrderedDict()
        self._unique=set()
        self._generated=0
        self._hits=0
        self._requests=0
        self._sent=0
        self._active=0
        self._completed=0
        self._aborted=0
        self._next_request=0
        self._template_bytes=sum(len(v) for v in assets.values())
        self.chapters=[]
        for j,freq in enumerate(FREQUENCIES):
            a=j*count//len(FREQUENCIES)
            b=(j+1)*count//len(FREQUENCIES)
            if b>a:
                self.chapters.append({'id':j+1,'start':a*TICKS/TIMESCALE,
                    'end':b*TICKS/TIMESCALE,'title':f'Chapter {j+1} - {freq} Hz'})

    def fragment(self,i):
        if not 0<=i<self.count:
            raise IndexError('Fragment outside file')
        with self._lock:
            if i in self._cache:
                self._cache.move_to_end(i)
                self._hits+=1
                return self._cache[i]
            # Determine chapter based on exact integer slot boundary.
            j=min(4,((i+1)*len(FREQUENCIES)-1)//self.count)
            original,seq_pos,time_pos=self.templates[j]
            data=bytearray(original)
            struct.pack_into('>I',data,seq_pos,i+1)
            struct.pack_into('>Q',data,time_pos,i*TICKS)
            data=bytes(data)+box(b'free',bytes(SLOT-len(data)-8))
            assert len(data)==SLOT
            self._cache[i]=data
            self._unique.add(i)
            self._generated+=1
            while len(self._cache)>self.cache_slots:
                self._cache.popitem(last=False)
            if self._generated<=16 or self._generated%64==0:
                LOG.info('POC_VIRTUAL_LONG event=generate slot=%d chapter=%d generated=%d unique=%d/%d cache_bytes=%d',
                         i,j+1,self._generated,len(self._unique),self.count,len(self._cache)*SLOT)
            return data

    def piece(self,pos,end):
        if pos<len(self.header):
            data=self.header; offset=pos
        elif pos<self.media_end:
            i,offset=divmod(pos-len(self.header),SLOT)
            data=self.fragment(i)
        else:
            data=self.tail; offset=pos-self.media_end
        return data[offset:offset+min(end-pos+1,65536)]

    def stats(self):
        with self._lock:
            return {'duration_seconds':self.duration,'virtual_bytes':self.size,
                'total_slots':self.count,'template_bytes':self._template_bytes,
                'generated_slots':self._generated,'unique_slots':len(self._unique),
                'cache_hits':self._hits,'cache_slots':len(self._cache),
                'cache_bytes':len(self._cache)*SLOT,'cache_limit_bytes':self.cache_slots*SLOT,
                'requests':self._requests,'body_bytes':self._sent,'active':self._active,
                'completed':self._completed,'aborted':self._aborted,
                'first_generated_slots':sorted(self._unique)[:12],
                'last_generated_slots':sorted(self._unique)[-12:],
                'source':'synthetic_template_bank','provider_calls':0}

    async def stream(self,start,end,rid):
        sent=0; next_log=1024*1024
        begun=time.monotonic()
        with self._lock:
            self._active+=1
        try:
            pos=start
            while pos<=end:
                # Pacing a large open-ended Range is legitimate: do not
                # truncate or lie about length. Let small probe requests
                # finish immediately; let cancellation stop generation.
                budget=BURST_BYTES+int((time.monotonic()-begun)*self.rate)
                delay=(sent-budget)/self.rate
                if delay>0:
                    await asyncio.sleep(delay)
                data=self.piece(pos,end)
                if not data:
                    raise IOError('Empty virtual media slice')
                pos+=len(data); sent+=len(data)
                with self._lock:
                    self._sent+=len(data)
                yield data
                if sent>=next_log:
                    LOG.info('POC_VIRTUAL_LONG event=progress request=%d bytes=%d',rid,sent)
                    next_log=sent+1024*1024
                # Yield even when sockets have not applied backpressure.
                await asyncio.sleep(0)
        finally:
            complete=int(sent==end-start+1)
            with self._lock:
                self._active-=1
                self._completed+=complete
                self._aborted+=1-complete
            LOG.info('POC_VIRTUAL_LONG event=body request=%d bytes=%d complete=%d',rid,sent,complete)

    def response(self,req: Request):
        h={'Accept-Ranges':'bytes','Cache-Control':'no-store','ETag':self.etag}
        value=req.headers.get('range') if req.method=='GET' else None
        if req.headers.get('if-range') not in (None,self.etag):
            value=None
        try:
            start,end,partial=self.bounds(value)
        except ValueError:
            return Response(status_code=416,headers={**h,'Content-Range':f'bytes */{self.size}'})
        h['Content-Length']=str(end-start+1)
        if partial:
            h['Content-Range']=f'bytes {start}-{end}/{self.size}'
        status=206 if partial else 200
        with self._lock:
            self._requests+=1
            self._next_request+=1
            rid=self._next_request
            active=self._active
        LOG.info('POC_VIRTUAL_LONG event=response request=%d method=%s status=%d start=%d end=%d total=%d active=%d',rid,req.method,status,start,end,self.size,active)
        if req.method=='HEAD':
            return Response(status_code=status,headers=h,media_type='audio/mp4')
        # A session can initiate several parallel probes. Keep a high enough
        # ceiling for that, but do not accept an unbounded number of streams.
        if active>=MAX_ACTIVE:
            return Response(status_code=503,headers={'Retry-After':'1'})
        return StreamingResponse(self.stream(start,end,rid),status_code=status,headers=h,media_type='audio/mp4')
