#!/bin/sh
# Detect audiobook-dl-web's existing /app/config mount without copying secrets.
set -eu
cd "$(dirname "$0")"
clear 2>/dev/null || true
printf '=== NEXTORY CONFIG READ-ONLY MOUNT ===\n'
if [ ! -f .env ]; then
    echo 'ERROR: No .env; run sh setup.sh first or preserve your v2 .env.'
    exit 1
fi
python3 - "$@" <<'PY'
import json, subprocess, sys
from pathlib import Path
root=Path.cwd()
env_path=root/'.env'
source=sys.argv[1] if len(sys.argv)>1 else None
if not source:
    try:
        ids=subprocess.run(['docker','ps','-q'],check=True,capture_output=True,text=True).stdout.splitlines()
    except (OSError, subprocess.CalledProcessError):
        ids=[]
    for cid in ids:
        try:
            details=json.loads(subprocess.run(['docker','inspect',cid],check=True,capture_output=True,text=True).stdout)[0]
        except (OSError, ValueError, subprocess.CalledProcessError):
            continue
        label=(details.get('Name','')+' '+details.get('Config',{}).get('Image','')).lower()
        if 'audiobook-dl-web' not in label:
            continue
        for mount in details.get('Mounts',[]):
            if mount.get('Destination','').rstrip('/') == '/app/config':
                source=mount.get('Source')
                break
        if source:
            break
if not source:
    print('CONFIG_RESULT=NOT_FOUND')
    print('Set manually with: sh configure-nextory.sh /absolute/host/config/directory')
    sys.exit(1)
source_path=Path(source)
if not source_path.is_absolute() or not (source_path/'audiobook-dl.toml').is_file():
    print('CONFIG_RESULT=NOT_FOUND')
    print('Expected existing file: <HOST_CONFIG_DIRECTORY>/audiobook-dl.toml')
    sys.exit(1)
if any(c in str(source_path) for c in ('\n','\r','#')):
    print('CONFIG_RESULT=UNSUPPORTED_PATH')
    sys.exit(1)
lines=env_path.read_text().splitlines()
lines=[line for line in lines if not line.startswith('NEXTORY_CONFIG_SOURCE=')]
lines.append('NEXTORY_CONFIG_SOURCE='+str(source_path))
env_path.write_text('\n'.join(lines)+'\n')
env_path.chmod(0o600)
print('CONFIG_RESULT=FOUND')
print('CONFIG_READ_ONLY=TRUE')
print('CREDENTIALS_COPIED=FALSE')
print('BOOK_ID=7207495')
PY
printf '\n=== NEXT STEP ===\n'
echo 'docker compose up -d --build && sh smoke.sh'
