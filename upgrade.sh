#!/bin/sh
# V5 -> V6: one library with collections, fast metadata, fast first HLS track.
# Only update this isolated POC; retain credentials, book IDs and state volume.
set -eu
ZIP=${1:-/tmp/nextory-abs-virtual-poc-v6.zip}
ROOT=nextory-abs-virtual-poc-v6
clear 2>/dev/null || true
printf '=== 1. V5 PRE-FLIGHT ===\n'
for FILE in .env Dockerfile docker-compose.yml app/main.py app/nextory.py app/hls_proxy.py app/discovery.py book-ids.txt; do
  if [ ! -f "$FILE" ]; then echo "ERROR: Missing $FILE. Run in current V5 POC folder"; exit 1; fi
done
if [ ! -f "$ZIP" ]; then echo "ERROR: ZIP missing: $ZIP"; exit 1; fi
unzip -tq "$ZIP" >/dev/null || { echo 'ERROR: ZIP validation failed'; exit 1; }
command -v docker >/dev/null || { echo 'ERROR: Docker command missing'; exit 1; }
docker compose version >/dev/null
docker compose config -q
docker compose config --services | grep -qx 'nextory-abs-poc' || {
  echo 'ERROR: POC compose service missing'; exit 1;
}
printf 'PROJECT=OK\nARCHIVE=OK\nCOMPOSE=OK\n'

printf '\n=== 2. SAVE V5 ROLLBACK CODE ===\n'
BACKUP=".poc-v5-backup-$(date +%Y%m%d-%H%M%S)-$$"
(umask 077 && mkdir "$BACKUP")
for FILE in README.md smoke.sh catalog-smoke.sh upgrade.sh rollback.sh app/main.py app/nextory.py; do
  if [ -f "$FILE" ]; then
    mkdir -p "$BACKUP/$(dirname "$FILE")"
    cp -p "$FILE" "$BACKUP/$FILE"
  fi
done
printf 'BACKUP=%s\n' "$BACKUP"
printf 'ENV=UNCHANGED\nNEXTORY_TOML=UNCHANGED\nBOOK_IDS=UNCHANGED\nSTATE_VOLUME=UNCHANGED\n'

printf '\n=== 3. VERIFY NEW CODE ===\n'
STAGE=".poc-v6-stage-$$"
(umask 077 && mkdir "$STAGE")
trap 'rm -rf "$STAGE" 2>/dev/null || true' EXIT HUP INT TERM
FILES='README.md smoke.sh catalog-smoke.sh upgrade.sh rollback.sh app/main.py app/nextory.py'
for FILE in $FILES; do
  mkdir -p "$STAGE/$(dirname "$FILE")"
  unzip -p "$ZIP" "$ROOT/$FILE" > "$STAGE/$FILE"
  if [ ! -s "$STAGE/$FILE" ]; then
    echo "ERROR: Incomplete ZIP member $FILE"; exit 1
  fi
done
python3 -m py_compile "$STAGE/app/main.py" "$STAGE/app/nextory.py"
printf 'SYNTAX=PASS\n'

printf '\n=== 4. INSTALL V6 CODE ONLY ===\n'
for FILE in $FILES; do
  cp -p "$STAGE/$FILE" "$FILE"
done
chmod 755 smoke.sh catalog-smoke.sh upgrade.sh rollback.sh
printf 'CODE=INSTALLED\nCOMPOSE_AND_CONFIG=UNCHANGED\n'

printf '\n=== 5. RECREATE ONLY POC CONTAINER ===\n'
docker compose up -d --build --force-recreate nextory-abs-poc

printf '\n=== 6. FULL BOOK PLAYBACK REGRESSION ===\n'
sh smoke.sh

printf '\n=== 7. ONE LIBRARY, COLLECTIONS AND LIVE SEARCH ===\n'
if sh catalog-smoke.sh; then
  printf 'DISCOVERY=PASS\n'
else
  printf 'DISCOVERY=UNVERIFIED; REVIEW OUTPUT\n'
fi

printf '\n=== FINISHED ===\n'
printf 'ROLLBACK=sh rollback.sh %s\n' "$BACKUP"
printf 'No Nextory audio, credentials, saved books, or listening progress were removed.\n'
