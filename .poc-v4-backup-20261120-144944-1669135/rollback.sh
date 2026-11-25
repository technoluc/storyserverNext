#!/bin/sh
# Restore only the separate Nextory POC project from a v3 upgrade backup.
set -eu
clear 2>/dev/null || true
printf '=== 1. ROLLBACK VALIDATION ===\n'
if [ "$#" -ne 1 ]; then
  echo 'USAGE: sh rollback.sh .poc-v3-backup-YYYYMMDD-HHMMSS-PID'; exit 2
fi
BACKUP="$1"
case "$BACKUP" in
  .poc-v3-backup-[0-9]*-[0-9]*) ;;
  *) echo 'ERROR: Backup must be the v3 backup directory'; exit 1 ;;
esac
for FILE in "$BACKUP/.env" "$BACKUP/app/main.py" "$BACKUP/docker-compose.yml" "$BACKUP/Dockerfile"; do
  if [ ! -f "$FILE" ]; then echo 'ERROR: Missing backup file'; exit 1; fi
done
printf 'BACKUP_VALID=TRUE\n'
printf '\n=== 2. RESTORE V3 TEST FILES ===\n'
for FILE in .env Dockerfile docker-compose.yml requirements.txt README.md smoke.sh setup.sh configure-nextory.sh upgrade.sh .dockerignore .gitignore app/main.py app/nextory.py app/hls_proxy.py; do
  if [ -f "$BACKUP/$FILE" ]; then cp -p "$BACKUP/$FILE" "$FILE"; fi
done
printf 'V3_FILES_RESTORED=TRUE\n'
printf '\n=== 3. REBUILD ONLY THE TEST CONTAINER ===\n'
docker compose up -d --build nextory-abs-poc
printf '\n=== 4. VERIFICATION ===\n'
sh smoke.sh
printf '\n=== DONE ===\n'
echo 'V4 progress volume and book-ids.txt were not deleted.'
