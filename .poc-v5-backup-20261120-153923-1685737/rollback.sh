#!/bin/sh
# Restore code to pre-v5, without touching credentials, book list or volumes.
set -eu
BACKUP=${1:-}
BACKUP=${BACKUP#./}
clear 2>/dev/null || true
printf '=== 1. V4 BACKUP VALIDATION ===\n'
case "$BACKUP" in
  .poc-v4-backup-[0-9]*-[0-9]*) ;;
  *) echo 'USAGE: sh rollback.sh .poc-v4-backup-YYYYMMDD-HHMMSS-PID'; exit 2 ;;
esac
for FILE in "$BACKUP/app/main.py" "$BACKUP/app/nextory.py" "$BACKUP/docker-compose.yml" "$BACKUP/smoke.sh"; do
  if [ ! -f "$FILE" ]; then echo "ERROR: Incomplete backup ($FILE)"; exit 1; fi
done
printf 'BACKUP=VALID\n'

printf '\n=== 2. RESTORE V4 APPLICATION CODE ===\n'
# Preserve live .env, Nextory TOML, book-ids.txt and Docker named volume.
for FILE in Dockerfile docker-compose.yml requirements.txt README.md smoke.sh setup.sh configure-nextory.sh upgrade.sh add-book.sh rollback.sh .dockerignore .gitignore app/main.py app/nextory.py app/hls_proxy.py app/progress.py; do
  if [ -f "$BACKUP/$FILE" ]; then cp -p "$BACKUP/$FILE" "$FILE"; fi
done
if [ -f "$BACKUP/app/discovery.py" ]; then
  cp -p "$BACKUP/app/discovery.py" app/discovery.py
else
  rm -f app/discovery.py
fi
if [ -f "$BACKUP/catalog-smoke.sh" ]; then
  cp -p "$BACKUP/catalog-smoke.sh" catalog-smoke.sh
else
  rm -f catalog-smoke.sh
fi
printf 'CODE=RESTORED\nSECRETS_AND_PROGRESS=PRESERVED\n'

printf '\n=== 3. RECREATE ONLY POC CONTAINER ===\n'
docker compose config -q
docker compose up -d --build --force-recreate nextory-abs-poc

printf '\n=== 4. VERIFY V4 AUDIO ===\n'
sh smoke.sh
printf '\n=== DONE ===\n'
