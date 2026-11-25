#!/bin/sh
# Revert POC application code from V6 to V5; preserve all user state.
set -eu
BACKUP=${1:-}
BACKUP=${BACKUP#./}
clear 2>/dev/null || true
printf '=== 1. CHECK V5 BACKUP ===\n'
case "$BACKUP" in
  .poc-v5-backup-[0-9]*-[0-9]*) ;;
  *) echo 'USAGE: sh rollback.sh .poc-v5-backup-YYYYMMDD-HHMMSS-PID'; exit 2;;
esac
for FILE in app/main.py app/nextory.py smoke.sh catalog-smoke.sh; do
  if [ ! -s "$BACKUP/$FILE" ]; then echo "ERROR: Backup missing $FILE"; exit 1; fi
done
printf 'BACKUP=VALID\n'

printf '\n=== 2. RESTORE V5 POC CODE ONLY ===\n'
for FILE in README.md smoke.sh catalog-smoke.sh upgrade.sh rollback.sh app/main.py app/nextory.py; do
  if [ -f "$BACKUP/$FILE" ]; then cp -p "$BACKUP/$FILE" "$FILE"; fi
done
printf 'CODE=RESTORED\nENV=UNCHANGED\nNEXTORY_CONFIG=UNCHANGED\nBOOK_LIST=UNCHANGED\nSTATE_VOLUME=UNCHANGED\n'

printf '\n=== 3. RECREATE TEST CONTAINER ===\n'
docker compose up -d --build --force-recreate nextory-abs-poc

printf '\n=== 4. VERIFY V5 PLAYBACK ===\n'
sh smoke.sh
printf '\n=== ROLLBACK COMPLETE ===\n'
