#!/bin/sh
set -eu
cd "$(dirname "$0")"
clear 2>/dev/null || true
printf '=== NEXTORY ABS POC SETUP ===\n'
if [ -e .env ]; then
    echo 'Existing .env preserved - no changes.'
else
    umask 077
    python3 - <<'PY'
import secrets
from pathlib import Path
content = (
    'TEST_USERNAME=test\n'
    + 'TEST_PASSWORD=' + secrets.token_urlsafe(24) + '\n'
    + 'TEST_AUTH_SECRET=' + secrets.token_urlsafe(48) + '\n'
    + 'BIND_IP=127.0.0.1\nPORT=13378\nTEST_ALLOWED_ORIGIN=\n'
)
Path('.env').write_text(content)
PY
    echo '.env created (mode 600).'
fi
printf '\n=== NEXT STEPS ===\n'
echo '1. For LAN access: edit BIND_IP=0.0.0.0 in .env (use only in trusted LAN).'
echo '2. docker compose up -d --build'
echo '3. sh smoke.sh'
echo '4. In Audiobookshelf iPhone app, add ANOTHER server (do not replace existing).'
echo '   Enter http://HOST-LAN-IP:13378 or your separate HTTPS test hostname.'
echo '   Username is test; get password locally with: grep ^TEST_PASSWORD= .env'
echo '   Never paste that password into chat or deployment logs.'
