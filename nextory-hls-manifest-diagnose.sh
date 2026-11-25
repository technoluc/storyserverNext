#!/usr/bin/env bash
# Read-only Nextory HLS playlist classification for the isolated test container.
# No URLs, response bodies, credentials or signed tokens are printed.
clear 2>/dev/null || true
echo "=== 1. TESTOMGEVING CONTROLEREN ==="
original_running="$(docker inspect -f '{{.State.Running}}' nextory-abs-poc 2>/dev/null)"
test_running="$(docker inspect -f '{{.State.Running}}' nextory-abs-poc-test 2>/dev/null)"
if [ "$original_running" != false ] || [ "$test_running" != true ]; then
  echo "ABORT: Original must be stopped and test running."
  exit 1
fi
echo "ORIGINAL=STOPPED"
echo "TEST=RUNNING"
echo
echo "=== 2. HLS-ANTWOORD ONDERZOEKEN (MAXIMAAL 6 PLAYLISTS) ==="
docker exec -i nextory-abs-poc-test python - <<'PY'
from urllib.parse import urlparse

from app.main import id_to_book
from app.nextory import NextoryBackend, NextoryError, MAX_MANIFEST_BYTES

ITEM_ID = '773bcc60-375f-5f71-bb6f-60cc30b9278a'

class ProbeLimit(Exception):
    pass


def classify(data):
    if data.startswith(b'#EXTM3U'):
        return 'M3U8_OK'
    if data.startswith(b'\xef\xbb\xbf#EXTM3U'):
        return 'M3U8_UTF8_BOM'
    trimmed = data.lstrip(b' \r\n\t')
    if trimmed.startswith(b'#EXTM3U'):
        return 'M3U8_LEADING_WHITESPACE'
    if trimmed.startswith((b'<!DOCTYPE', b'<!doctype', b'<html', b'<HTML')):
        return 'HTML'
    if trimmed.startswith((b'{', b'[')):
        return 'JSON_LIKE'
    if trimmed.startswith(b'\x1f\x8b'):
        return 'GZIP_BINARY'
    if not data:
        return 'EMPTY'
    return 'OTHER'

try:
    book_id = id_to_book(ITEM_ID)
    backend = NextoryBackend()
    book = backend.get_book(book_id)
    print('BOOK_LOOKUP=PASS')
    print('PART_COUNT=' + str(len(book.parts)))

    requests_done = [0]

    def inspect_manifest(url):
        requests_done[0] += 1
        if requests_done[0] > 6:
            raise ProbeLimit()
        response = backend.remote_get(url)
        try:
            status = response.status_code
            data = response.raw.read(MAX_MANIFEST_BYTES + 1, decode_content=True)
            ctype = response.headers.get('Content-Type', '').split(';')[0].strip().lower()
            if not all(x.isalnum() or x in '-_./+' for x in ctype):
                ctype = 'UNRECOGNIZED'
            path = urlparse(response.url).path.lower()
            variant = ('MASTER' if 'master' in path else 'MEDIA' if 'media' in path else 'OTHER')
            start_valid = data.startswith(b'#EXTM3U')
            oversize = len(data) > MAX_MANIFEST_BYTES
            print('MANIFEST_%d=HTTP_%d TYPE=%s SIZE=%s FORMAT=%s PATH_KIND=%s' % (
                requests_done[0], status, ctype or 'UNKNOWN',
                'OVER_LIMIT' if oversize else str(len(data)), classify(data), variant))
            if status != 200:
                raise NextoryError('Nextory HLS manifest HTTP ' + str(status))
            if oversize or not start_valid:
                raise NextoryError('Invalid or oversized HLS playlist')
            return data.decode('utf-8-sig'), response.url
        finally:
            response.close()

    backend.get_manifest = inspect_manifest
    tracks = backend.get_layout(book_id)
    print('LAYOUT=PASS TRACKS=' + str(len(tracks)))
except ProbeLimit:
    print('LAYOUT=STOPPED_AFTER_6_MANIFESTS')
except NextoryError as exc:
    msg = str(exc)
    if msg.startswith(('Nextory ', 'Invalid ', 'No usable', 'HLS ', 'Too many ')):
        print('LAYOUT_ERROR=' + msg[:130])
    else:
        print('LAYOUT_ERROR=' + type(exc).__name__)
except Exception as exc:
    print('DIAG_ERROR=' + type(exc).__name__)
PY
status=$?
echo
echo "=== EINDE ==="
exit "$status"
