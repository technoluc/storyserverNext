"""Read-only, indexed virtual MP4 over immutable, authorized local fragments."""
from __future__ import annotations

import bisect
import json
import logging
import os
import re
from pathlib import Path

from fastapi import Request
from fastapi.responses import Response, StreamingResponse

LOG = logging.getLogger('uvicorn.error')
RANGE = re.compile(r'bytes=([0-9]{0,20})-([0-9]{0,20})\Z', re.I)
CHUNK_SIZE = 64 * 1024


class VirtualRange:
    def __init__(self, root: Path):
        self.root = root.resolve(strict=True)
        index = json.loads((self.root/'index.json').read_text(encoding='utf-8'))
        self.parts = []
        self.ends = []
        total = 0
        for entry in index['parts']:
            name, length = entry['name'], entry['size']
            if not re.fullmatch(r'part-[0-9]{2}\.bin', name) or not isinstance(length, int) or length <= 0:
                raise ValueError('Invalid virtual media index')
            path = self.root/name
            if path.is_symlink() or not path.is_file() or path.stat().st_size != length:
                raise ValueError('Virtual fragment missing or changed')
            # The installer verifies the fixture bytes. Runtime only reads the
            # index and file lengths; audio is not read before a request.
            total += length
            self.parts.append((path, length))
            self.ends.append(total)
        if not self.parts or total != index['length']:
            raise ValueError('Invalid virtual media length')
        self.size = total
        digest = index['sha256']
        if not re.fullmatch(r'[0-9a-f]{64}', digest):
            raise ValueError('Invalid virtual media digest')
        self.etag = '"' + digest + '"' 

    def bounds(self, header: str | None):
        if not header or not header.lower().startswith('bytes='):
            return 0, self.size-1, False
        m = RANGE.fullmatch(header.strip())
        if m is None or not any(m.groups()):
            raise ValueError('Invalid or unsupported range')
        left, right = m.groups()
        if not left:
            count = int(right)
            if count <= 0:
                raise ValueError('Unsatisfiable range')
            return max(0, self.size-count), self.size-1, True
        start = int(left)
        end = min(int(right), self.size-1) if right else self.size-1
        if start >= self.size or end < start:
            raise ValueError('Unsatisfiable range')
        return start, end, True

    def read(self, start: int, end: int):
        # One fragment at a time; only the requested interval is opened/read.
        i = bisect.bisect_right(self.ends, start)
        pos = start
        sent = 0
        opened = 0
        try:
            while pos <= end:
                path, length = self.parts[i]
                previous = self.ends[i-1] if i else 0
                count = min(self.ends[i]-pos, end-pos+1)
                with path.open('rb') as f:
                    if os.fstat(f.fileno()).st_size != length:
                        raise IOError('Virtual fragment length changed')
                    f.seek(pos-previous)
                    opened += 1
                    LOG.info('POC_VIRTUAL_RANGE event=fragment index=%d bytes=%d', i, count)
                    while count:
                        block = f.read(min(CHUNK_SIZE, count))
                        if not block:
                            raise IOError('Virtual fragment truncated')
                        count -= len(block)
                        pos += len(block)
                        sent += len(block)
                        yield block
                i += 1
        finally:
            LOG.info('POC_VIRTUAL_RANGE event=body bytes=%d fragments=%d complete=%d',
                     sent, opened, int(sent==end-start+1))

    def response(self, req: Request):
        headers = {'Accept-Ranges':'bytes', 'Cache-Control':'no-store', 'ETag':self.etag}
        value = req.headers.get('range') if req.method == 'GET' else None
        if req.headers.get('if-range') not in (None, self.etag):
            value = None
        try:
            start, end, partial = self.bounds(value)
        except ValueError:
            LOG.info('POC_VIRTUAL_RANGE event=response status=416')
            return Response(status_code=416, headers={**headers,'Content-Range':f'bytes */{self.size}'})
        status = 206 if partial else 200
        headers['Content-Length'] = str(end-start+1)
        if partial:
            headers['Content-Range'] = f'bytes {start}-{end}/{self.size}'
        LOG.info('POC_VIRTUAL_RANGE event=response status=%d method=%s start=%d end=%d total=%d',
                 status, req.method, start, end, self.size)
        if req.method == 'HEAD':
            return Response(status_code=status, headers=headers, media_type='audio/mp4')
        return StreamingResponse(self.read(start,end), status_code=status, headers=headers, media_type='audio/mp4')
