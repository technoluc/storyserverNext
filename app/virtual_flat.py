"""Provider-independent, non-fragmented virtual M4A compatibility control.

All sample sizes are already known from E's five locally authored AAC templates.
Use a conventional front-loaded moov and one mdat instead of sidx/moof/mfra.
No book audio, provider requests, remuxing of protected media, or full file.
"""
from __future__ import annotations

import asyncio
import bisect
import hashlib
import logging
import struct
import threading
import time
from fastapi import Request
from fastapi.responses import Response, StreamingResponse
from .virtual_range import VirtualRange
from .virtual_long import (
    LongVirtual, SLOT_COUNT, TICKS, TIMESCALE, FREQUENCIES,
    BURST_BYTES, RATE_BYTES, MAX_ACTIVE, box, boxes, child, top, init_for_duration,
)

LOG = logging.getLogger('uvicorn.error')
SAMPLES = 300
SAMPLE_DURATION = 1024
BLOCK = 65536


def replace_box(data, parent, target, replacement):
    """Replace one exact child, rebuilding the parent length."""
    if len(data) < 8 or data[4:8] != parent:
        raise ValueError('Wrong MP4 parent')
    found = [(p,n) for p,n,t in boxes(data,8) if t == target]
    if len(found) != 1:
        raise ValueError('Missing or duplicate MP4 child')
    p,n = found[0]
    return box(parent, data[8:p]+replacement+data[p+n:])


def get_child(data, name):
    p,n = child(data,0,len(data),name)
    return data[p:p+n]


def sample_table(templates, chapter_counts):
    """Return true AAC access-unit sizes and mdat payloads, not estimates."""
    payloads=[]; sizes=[]
    for fragment,_,_ in templates:
        m,n=top(fragment,b'moof')
        t,tn=child(fragment,m,n,b'traf')
        r,rn=child(fragment,t,tn,b'trun')
        flags,count,offset=struct.unpack_from('>IIi',fragment,r+8)
        if flags!=0x201 or count!=SAMPLES or rn!=20+4*SAMPLES:
            raise ValueError('Unexpected test AAC template')
        p,pn=top(fragment,b'mdat')
        raw=fragment[p+8:p+pn]
        lengths=struct.unpack_from('>300I',fragment,r+20)
        if sum(lengths)!=len(raw) or min(lengths)<=0 or offset!=p+8:
            raise ValueError('Invalid sample sizes')
        payloads.append(raw)
        sizes.append(fragment[r+20:r+20+4*SAMPLES])
    size_table=b''.join(s*count for s,count in zip(sizes,chapter_counts,strict=True))
    return payloads,size_table


class LimitedFlatResponse(StreamingResponse):
    def __init__(self, owner, iterator, **kwargs):
        super().__init__(iterator, **kwargs)
        self.owner=owner

    async def __call__(self, scope, receive, send):
        with self.owner._lock:
            admitted=self.owner._active<MAX_ACTIVE
            if admitted:
                self.owner._active+=1
        if not admitted:
            await Response(status_code=503,headers={'Retry-After':'1'})(scope,receive,send)
            return
        try:
            await super().__call__(scope,receive,send)
        finally:
            with self.owner._lock:
                self.owner._active-=1


class FlatVirtual(VirtualRange):
    def __init__(self, source: LongVirtual, *, rate=RATE_BYTES):
        self.count=source.count
        self.rate=rate
        if not 1<=self.count<=SLOT_COUNT or rate<=0:
            raise ValueError('Invalid virtual file limits')
        self.duration=source.duration
        self.chapters=[dict(c) for c in source.chapters]
        self.chapter_counts=[(i+1)*self.count//len(FREQUENCIES)-i*self.count//len(FREQUENCIES)
                             for i in range(len(FREQUENCIES))]
        self.payloads,sizes=sample_table(source.templates,self.chapter_counts)
        self.chunk_types=[j for j,c in enumerate(self.chapter_counts) for _ in range(c)]
        self.ends=[]; size=0
        for j in self.chunk_types:
            size+=len(self.payloads[j]); self.ends.append(size)
        if len(self.ends)!=self.count or len(sizes)!=self.count*SAMPLES*4:
            raise ValueError('Invalid sample table length')
        if size+8>=2**32:
            raise ValueError('32-bit mdat exceeded')
        self.media_size=size
        # All movie and track durations match the samples in the table.
        ini=init_for_duration((source.root/'init.bin').read_bytes(),self.count)
        p,n=top(ini,b'moov'); moov=ini[p:p+n]
        trak=get_child(moov,b'trak'); mdia=get_child(trak,b'mdia')
        minf=get_child(mdia,b'minf'); stbl=get_child(minf,b'stbl')
        stsd=get_child(stbl,b'stsd')
        stts=box(b'stts',struct.pack('>IIII',0,1,self.count*SAMPLES,SAMPLE_DURATION))
        stsc=box(b'stsc',struct.pack('>IIIII',0,1,1,SAMPLES,1))
        stsz=box(b'stsz',struct.pack('>III',0,0,self.count*SAMPLES)+sizes)
        stco=box(b'stco',struct.pack('>II',0,self.count)+b'\0'*(4*self.count))
        new_stbl=box(b'stbl',stsd+stts+stsc+stsz+stco)
        minf=replace_box(minf,b'minf',b'stbl',new_stbl)
        mdia=replace_box(mdia,b'mdia',b'minf',minf)
        trak=replace_box(trak,b'trak',b'mdia',mdia)
        moov=replace_box(moov,b'moov',b'trak',trak)
        # Remove fragment-only movie metadata. Keep the actual AAC sample description.
        moov=replace_box(moov,b'moov',b'mvex',b'')
        ftyp=box(b'ftyp',b'M4A '+struct.pack('>I',512)+b'M4A isommp42')
        header=bytearray(ftyp+moov+struct.pack('>I4s',size+8,b'mdat'))
        self.media_start=len(header)
        # mdat is intentionally incomplete in the header buffer. Traverse moov only.
        a,b=child(header,len(ftyp),len(moov),b'trak')
        a,b=child(header,a,b,b'mdia'); a,b=child(header,a,b,b'minf')
        a,b=child(header,a,b,b'stbl'); a,b=child(header,a,b,b'stco')
        if b!=16+4*self.count:
            raise ValueError('Invalid offset table')
        for i in range(self.count):
            offset=self.media_start+(self.ends[i-1] if i else 0)
            if offset>=2**32:
                raise ValueError('32-bit chunk offset exceeded')
            struct.pack_into('>I',header,a+16+4*i,offset)
        self.header=bytes(header)
        self.size=self.media_start+self.media_size
        digest=hashlib.sha256(b'flat-m4a-control-v1\0'+self.header+b''.join(self.payloads)).hexdigest()
        self.etag='"'+digest+'"'
        self._lock=threading.Lock()
        self._requests=self._active=self._completed=self._aborted=0
        self._sent=self._media_sent=self._header_sent=0
        self._unique=set()
        self._template_bytes=sum(map(len,self.payloads))

    def piece(self,pos,end):
        if not 0<=pos<=end<self.size:
            raise ValueError('Invalid byte interval')
        if pos<self.media_start:
            return self.header[pos:min(self.media_start,end+1,pos+BLOCK)],None
        relative=pos-self.media_start
        i=bisect.bisect_right(self.ends,relative)
        previous=self.ends[i-1] if i else 0
        off=relative-previous
        data=self.payloads[self.chunk_types[i]]
        return data[off:off+min(end-pos+1,BLOCK)],i

    def stats(self):
        with self._lock:
            return {'duration_seconds':self.duration,'virtual_bytes':self.size,
                    'header_bytes':self.media_start,'media_bytes':self.media_size,
                    'total_chunks':self.count,'template_payload_bytes':self._template_bytes,
                    'unique_chunks':len(self._unique),'requests':self._requests,
                    'body_bytes':self._sent,'header_body_bytes':self._header_sent,
                    'media_body_bytes':self._media_sent,'active':self._active,
                    'completed':self._completed,'aborted':self._aborted,
                    'first_chunks':sorted(self._unique)[:12],
                    'last_chunks':sorted(self._unique)[-12:],
                    'source':'synthetic_aac_template_bank','provider_calls':0}

    async def stream(self,start,end,rid):
        sent=0; media_sent=0; next_log=1024*1024
        media_start_time=None; first=last=None
        try:
            pos=start
            while pos<=end:
                if pos>=self.media_start:
                    if media_start_time is None:
                        media_start_time=time.monotonic()
                    budget=BURST_BYTES+int((time.monotonic()-media_start_time)*self.rate)
                    delay=(media_sent-budget)/self.rate
                    if delay>0:
                        await asyncio.sleep(delay)
                data,i=self.piece(pos,end)
                if not data:
                    raise IOError('Empty virtual media slice')
                pos+=len(data); sent+=len(data)
                if i is not None:
                    if first is None:
                        first=i
                        LOG.info('POC_VIRTUAL_FLAT event=first_media request=%d chunk=%d time_seconds=%.1f',rid,i,i*TICKS/TIMESCALE)
                    last=i; media_sent+=len(data)
                with self._lock:
                    self._sent+=len(data)
                    if i is None:
                        self._header_sent+=len(data)
                    else:
                        self._media_sent+=len(data); self._unique.add(i)
                yield data
                if sent>=next_log:
                    LOG.info('POC_VIRTUAL_FLAT event=progress request=%d bytes=%d media_bytes=%d last_chunk=%s',rid,sent,media_sent,last)
                    next_log=sent+1024*1024
                await asyncio.sleep(0)
        finally:
            complete=int(sent==end-start+1)
            with self._lock:
                self._completed+=complete; self._aborted+=1-complete
            LOG.info('POC_VIRTUAL_FLAT event=body request=%d bytes=%d media_bytes=%d first_chunk=%s last_chunk=%s complete=%d',rid,sent,media_sent,first,last,complete)

    def response(self,req: Request):
        headers={'Accept-Ranges':'bytes','Cache-Control':'no-store','ETag':self.etag}
        value=req.headers.get('range') if req.method=='GET' else None
        if req.headers.get('if-range') not in (None,self.etag):
            value=None
        try:
            start,end,partial=self.bounds(value)
        except ValueError:
            return Response(status_code=416,headers={**headers,'Content-Range':f'bytes */{self.size}'})
        headers['Content-Length']=str(end-start+1)
        if partial:
            headers['Content-Range']=f'bytes {start}-{end}/{self.size}'
        status=206 if partial else 200
        with self._lock:
            self._requests+=1; rid=self._requests
        LOG.info('POC_VIRTUAL_FLAT event=response request=%d method=%s status=%d start=%d end=%d total=%d header_bytes=%d',rid,req.method,status,start,end,self.size,self.media_start)
        if req.method=='HEAD':
            return Response(status_code=status,headers=headers,media_type='audio/mp4')
        return LimitedFlatResponse(self,self.stream(start,end,rid),status_code=status,headers=headers,media_type='audio/mp4')
