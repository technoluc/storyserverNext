#!/bin/sh
# Add a configured Nextory audiobook to the existing live POC (no restart).
set -eu
cd "$(dirname "$0")"
clear 2>/dev/null || true
printf '=== 1. NEXTORY BOOK VALIDATION ===\n'
if [ "$#" -ne 1 ]; then
  echo 'USAGE: sh add-book.sh 7257862'
  echo 'OR:    sh add-book.sh https://nextory.com/nl/book/example-7257862'
  exit 2
fi
RAW="$1"
BOOK_ID=$(python3 - "$RAW" <<'PY'
import re,sys
from urllib.parse import urlsplit
s=sys.argv[1].strip()
if re.fullmatch(r'[0-9]{5,12}',s):
    print(s); sys.exit(0)
try:
    p=urlsplit(s)
    if p.scheme!='https' or p.hostname not in ('nextory.com','www.nextory.com'):
        raise ValueError()
    match=re.search(r'-(\d{5,12})/?$',p.path)
    if not match: raise ValueError()
    print(match.group(1))
except ValueError:
    sys.exit('INVALID_NEXTORY_URL_OR_ID')
PY
)
if [ -z "$BOOK_ID" ]; then exit 1; fi
if [ ! -f book-ids.txt ]; then
  echo 'ERROR: book-ids.txt missing. Upgrade to v4 first.'; exit 1
fi
if grep -qx "$BOOK_ID" book-ids.txt; then
  printf 'BOOK_ALREADY_CONFIGURED=%s\n' "$BOOK_ID"; exit 0
fi
COUNT=$(grep -Ec '^[0-9]+$' book-ids.txt || true)
if [ "$COUNT" -ge 25 ]; then
  echo 'ERROR: Max 25 books in this test library.'; exit 1
fi
printf 'NEXTORY_ID=%s\n' "$BOOK_ID"
printf '\n=== 2. PROVIDER HAS AN AUDIOBOOK ===\n'
if ! docker exec nextory-abs-poc python -c '
import sys
from app.nextory import nextory, NextoryError
try:
    b=nextory.get_book(int(sys.argv[1]))
    tracks=nextory.get_layout(b.book_id)
    print("TITLE="+b.title)
    print("AUTHORS="+", ".join(b.authors))
    print("AUDIO_PARTS="+str(len(tracks)))
    print("DURATION_SECONDS="+str(round(tracks[-1].start+tracks[-1].duration,2)))
except NextoryError as exc:
    print("PROVIDER_CHECK_FAILED="+str(exc))
    sys.exit(1)
' "$BOOK_ID"; then
  echo 'NOT ADDED: The selected book could not be validated for HLS playback.'
  exit 1
fi
printf '\n=== 3. ADD TO LIVE LIBRARY ===\n'
(umask 022; printf '%s\n' "$BOOK_ID" >> book-ids.txt)
printf 'BOOK_ADDED=%s\n' "$BOOK_ID"
echo 'Open Audiobookshelf again, or switch libraries and back to refresh.'
echo 'No container rebuild or existing book change was needed.'
