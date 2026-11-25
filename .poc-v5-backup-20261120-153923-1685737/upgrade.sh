#!/bin/sh
# Upgrade ONLY an existing Nextory ABS v4 POC. Preserve credentials and state.
set -eu
ZIP=${1:-/tmp/nextory-abs-virtual-poc-v5.zip}
ROOT=nextory-abs-virtual-poc-v5
clear 2>/dev/null || true
printf '=== 1. PRE-FLIGHT (V4 ONLY) ===\n'
for FILE in .env Dockerfile docker-compose.yml app/main.py app/nextory.py app/hls_proxy.py app/progress.py book-ids.txt; do
  if [ ! -f "$FILE" ]; then echo "ERROR: Missing $FILE; run in existing v4 POC directory"; exit 1; fi
done
if [ ! -f "$ZIP" ]; then echo "ERROR: ZIP missing: $ZIP"; exit 1; fi
unzip -tq "$ZIP" >/dev/null || { echo 'ERROR: Invalid ZIP'; exit 1; }
command -v docker >/dev/null || { echo 'ERROR: Docker CLI missing'; exit 1; }
docker compose version >/dev/null
docker compose config -q
docker compose config --services | grep -qx 'nextory-abs-poc' || { echo 'ERROR: POC service not found'; exit 1; }
printf 'PROJECT=OK\nARCHIVE=OK\nCOMPOSE=OK\n'

printf '\n=== 2. BACKUP V4 CODE (NO STATE MUTATION) ===\n'
BACKUP=".poc-v4-backup-$(date +%Y%m%d-%H%M%S)-$$"
(umask 077 && mkdir "$BACKUP")
# Copy secret .env to a mode-600 backup but NEVER echo it. Keep live .env unchanged.
for FILE in .env Dockerfile docker-compose.yml requirements.txt README.md smoke.sh setup.sh configure-nextory.sh upgrade.sh add-book.sh rollback.sh catalog-smoke.sh .dockerignore .gitignore book-ids.txt app/main.py app/nextory.py app/hls_proxy.py app/progress.py app/discovery.py; do
  if [ -f "$FILE" ]; then
    mkdir -p "$BACKUP/$(dirname "$FILE")"
    cp -p "$FILE" "$BACKUP/$FILE"
  fi
done
chmod 600 "$BACKUP/.env"
printf 'BACKUP=%s\nSECRETS=UNCHANGED\nBOOK_IDS=UNCHANGED\nDOCKER_STATE_VOLUME=PRESERVED\n' "$BACKUP"

printf '\n=== 3. STAGE AND VALIDATE V5 CODE ===\n'
STAGE=".poc-v5-stage-$$"
(umask 077 && mkdir "$STAGE")
trap 'rm -r "$STAGE" 2>/dev/null || true' EXIT HUP INT TERM
FILES='README.md smoke.sh catalog-smoke.sh upgrade.sh rollback.sh app/main.py app/nextory.py app/discovery.py'
for FILE in $FILES; do
  mkdir -p "$STAGE/$(dirname "$FILE")"
  unzip -p "$ZIP" "$ROOT/$FILE" > "$STAGE/$FILE"
  if [ ! -s "$STAGE/$FILE" ]; then echo "ERROR: Incomplete V5 archive entry: $FILE"; exit 1; fi
done
python3 -m py_compile "$STAGE"/app/*.py
printf 'CODE_SYNTAX=PASS\n'

printf '\n=== 4. INSTALL V5 (KEEP COMPOSE AND CREDS) ===\n'
for FILE in $FILES; do
  cp -p "$STAGE/$FILE" "$FILE"
done
chmod 755 smoke.sh catalog-smoke.sh upgrade.sh rollback.sh
printf 'V5_CODE=INSTALLED\nEXISTING_DOCKER_COMPOSE=UNCHANGED\n'

printf '\n=== 5. RECREATE ONLY THE TEST CONTAINER ===\n'
docker compose up -d --build --force-recreate nextory-abs-poc

printf '\n=== 6. REGRESSION TEST FOR V4 AUDIO ===\n'
sh smoke.sh

printf '\n=== 7. NEXTORY CATALOG SEARCH CHECK ===\n'
if sh catalog-smoke.sh; then
  printf 'CATALOG_SEARCH=PASS\n'
else
  printf 'CATALOG_SEARCH=UNVERIFIED_OR_UNAVAILABLE\n'
  printf 'V4 PLAYBACK IS STILL CHECKED; INSPECT CATALOG SMOKE OUTPUT ABOVE.\n'
fi

printf '\n=== FINISHED ===\n'
printf 'ROLLBACK=sh rollback.sh %s\n' "$BACKUP"
printf 'No credentials, Nextory audio, audiobook files or progress were deleted.\n'
