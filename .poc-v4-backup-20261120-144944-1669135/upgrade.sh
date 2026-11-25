#!/bin/sh
# Safe v3 -> v4 upgrade. Run ONLY inside the isolated nextory-abs POC project.
set -eu
ZIP=${1:-/tmp/nextory-abs-virtual-poc-v4.zip}
ROOT=nextory-abs-virtual-poc-v4
clear 2>/dev/null || true
printf '=== 1. PRE-FLIGHT ===\n'
for FILE in .env docker-compose.yml app/main.py app/nextory.py app/hls_proxy.py; do
  if [ ! -f "$FILE" ]; then echo "ERROR: Missing $FILE - use your existing POC project folder"; exit 1; fi
done
if [ ! -f "$ZIP" ]; then echo "ERROR: ZIP not found: $ZIP"; exit 1; fi
unzip -tq "$ZIP" >/dev/null
command -v docker >/dev/null
docker compose version >/dev/null
printf 'POC_PROJECT=FOUND\nZIP=VALID\nDOCKER_COMPOSE=FOUND\n'

printf '\n=== 2. BACKUP LOCAL TEST FILES ===\n'
BACKUP=".poc-v3-backup-$(date +%Y%m%d-%H%M%S)-$$"
(umask 077 && mkdir "$BACKUP")
FILES='Dockerfile docker-compose.yml requirements.txt README.md smoke.sh setup.sh configure-nextory.sh upgrade.sh add-book.sh rollback.sh .dockerignore .gitignore book-ids.txt app/main.py app/nextory.py app/hls_proxy.py app/progress.py'
for FILE in $FILES; do
  if [ -f "$FILE" ]; then
    mkdir -p "$BACKUP/$(dirname "$FILE")"
    cp -p "$FILE" "$BACKUP/$FILE"
  fi
done
cp -p .env "$BACKUP/.env"
printf 'BACKUP=%s\nENV_PRESERVED=TRUE\n' "$BACKUP"

printf '\n=== 3. INSTALL V4 APPLICATION FILES ===\n'
for FILE in Dockerfile docker-compose.yml requirements.txt README.md smoke.sh setup.sh upgrade.sh add-book.sh rollback.sh .dockerignore .gitignore app/main.py app/nextory.py app/hls_proxy.py app/progress.py; do
  TMP="${FILE}.nextory-v4-tmp"
  unzip -p "$ZIP" "$ROOT/$FILE" > "$TMP"
  if [ ! -s "$TMP" ]; then echo "ERROR: Empty ZIP entry for $FILE"; exit 1; fi
  mv "$TMP" "$FILE"
done
chmod 755 smoke.sh setup.sh upgrade.sh add-book.sh rollback.sh
if [ ! -f book-ids.txt ]; then
  printf '7207495\n' > book-ids.txt
fi
python3 -m py_compile app/*.py
printf 'CODE=INSTALLED\nBOOK_LIST=%s\n' "$(grep -Ec '^[0-9]+$' book-ids.txt || true)"

printf '\n=== 4. VERIFY COMPOSE (ONLY TEST CONTAINER) ===\n'
if ! docker compose config -q; then
  echo 'ERROR: Compose invalid; restore files from BACKUP before retry.'
  exit 1
fi
printf 'COMPOSE_CONFIG=VALID\n'

printf '\n=== 5. REBUILD ISOLATED POC ===\n'
docker compose up -d --build nextory-abs-poc

printf '\n=== 6. LIVE SERVER CONTRACT TEST ===\n'
sh smoke.sh
printf '\n=== DONE ===\n'
printf 'ROLLBACK_BACKUP=%s\n' "$BACKUP"
echo 'Existing .env and Nextory credentials were not replaced.'
