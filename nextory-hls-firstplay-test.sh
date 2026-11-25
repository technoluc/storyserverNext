#!/usr/bin/env bash
# NEXTORY HLS FIRSTPLAY SERVER V1 - only for the isolated Nextory test deployment.
# Usage: bash nextory-hls-firstplay-test.sh apply|rollback
# The original v6, authentication, four duration workers and detail prewarming
# are not changed. No audio bytes are prefetched or stored to disk.
set -euo pipefail
MODE="${1:-apply}"
TEST="${NEXTORY_TEST_DIR:-$HOME/nextory-abs-virtual-poc-test}"
ORIGINAL="${NEXTORY_ORIGINAL_DIR:-$HOME/nextory-abs-virtual-poc}"
PROJECT='nextory-abs-test'
SERVICE='nextory-abs-poc'
OFFLINE="${_NEXTORY_OFFLINE_VERIFY:-0}"
clear 2>/dev/null || true

echo '=== 1. VEILIGHEIDSCONTROLE ==='
if [ "$MODE" != 'apply' ] && [ "$MODE" != 'rollback' ]; then
  echo 'ERROR: Gebruik apply of rollback.'; exit 1
fi
for name in docker-compose.yml docker-compose.test.yml app/main.py app/nextory.py app/prewarm.py; do
  if [ ! -f "$TEST/$name" ]; then echo "ERROR: Testbestand ontbreekt: $name"; exit 1; fi
done
if [ ! -f "$ORIGINAL/app/main.py" ] || [ ! -f "$ORIGINAL/app/nextory.py" ]; then
  echo 'ERROR: Originele broncode ontbreekt.'; exit 1
fi
if [ "$OFFLINE" = '1' ]; then
  echo 'OFFLINE_TEST=YES'
else
  original_running="$(docker inspect -f '{{.State.Running}}' nextory-abs-poc 2>/dev/null || true)"
  test_running="$(docker inspect -f '{{.State.Running}}' nextory-abs-poc-test 2>/dev/null || true)"
  test_project="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' nextory-abs-poc-test 2>/dev/null || true)"
  test_image="$(docker inspect -f '{{.Config.Image}}' nextory-abs-poc-test 2>/dev/null || true)"
  port_owner="$(docker ps --filter publish=13378 --format '{{.Names}}')"
  if [ "$original_running" != false ] || [ "$test_running" != true ] || \
     [ "$test_project" != "$PROJECT" ] || [ "$test_image" != 'nextory-abs-poc-test:dev' ] || \
     [ "$port_owner" != 'nextory-abs-poc-test' ]; then
    echo 'ERROR: Testomgeving, origineel of poort niet correct geïsoleerd.'; exit 1
  fi
  if ! NEXTORY_TEST="$TEST" NEXTORY_ORIGINAL="$ORIGINAL" python3 - <<'PYGUARD'
import json, os, subprocess, sys
from pathlib import Path
test = Path(os.environ['NEXTORY_TEST']).resolve(strict=True)
original = Path(os.environ['NEXTORY_ORIGINAL']).resolve(strict=True)
if test == original or original in test.parents or test in original.parents:
    sys.exit('ERROR: Origineel en test-directory overlappen')
command = ['docker','compose','-p','nextory-abs-test','-f',str(test/'docker-compose.yml'),'-f',str(test/'docker-compose.test.yml'),'config','--format','json']
p=subprocess.run(command,cwd=test,capture_output=True,text=True)
if p.returncode: sys.exit('ERROR: Compose-configuratie niet leesbaar')
try:
    cfg=json.loads(p.stdout); srv=cfg['services']['nextory-abs-poc']
    assert cfg['name']=='nextory-abs-test'
    assert srv['container_name']=='nextory-abs-poc-test'
    assert srv['image']=='nextory-abs-poc-test:dev'
    build=srv['build']; path=Path(build['context'] if isinstance(build,dict) else build).resolve(strict=True)
    assert path==test
    assert not srv.get('volumes_from') and not srv.get('network_mode')
    ports=srv['ports']
    assert len(ports)==1 and int(ports[0]['published'])==13378 and int(ports[0]['target'])==8000
    for mount in srv.get('volumes',[]):
        if mount['type']=='bind':
            src=Path(mount['source']).resolve()
            if src==original or original in src.parents:
                assert mount.get('read_only') and mount['target']=='/run/nextory'
            if not mount.get('read_only'):
                assert src==test or test in src.parents
        elif mount['type']=='volume':
            info=cfg.get('volumes',{}).get(mount.get('source'),{})
            assert not info.get('external', False)
            assert info.get('name','').startswith('nextory-abs-test_')
except (AssertionError, KeyError, ValueError, TypeError, OSError):
    sys.exit('ERROR: Compose-isolatie niet bewezen')
print('COMPOSE_ISOLATION=PASS')
PYGUARD
  then exit 1; fi
fi
printf 'MODE=%s\nORIGINAL=STOPPED_AND_UNMODIFIED\nPORT=13378\n' "$MODE"
echo

echo '=== 2. HLS FIRSTPLAY PATCH TOEPASSEN ==='
python3 - "$TEST" "$ORIGINAL" "$MODE" <<'PYPATCH'
from __future__ import annotations

import ast
import base64
import hashlib
import os
import shutil
import sys
from pathlib import Path

TEST = Path(sys.argv[1]).resolve(strict=True)
ORIGINAL = Path(sys.argv[2]).resolve(strict=True)
MODE = sys.argv[3]
MAIN = TEST / 'app/main.py'
NEXTORY = TEST / 'app/nextory.py'
DELIVERY = TEST / 'app/hls_delivery.py'
UNIT = TEST / 'tests/test_hls_firstplay.py'
BACKUP = TEST / '.nextory-hls-firstplay-baseline'
MARKER = 'HLS_FIRSTPLAY_SERVER_V1'
DELIVERY_SOURCE = base64.b64decode('IiIiSExTX0ZJUlNUUExBWV9TRVJWRVJfVjE6IGJvdW5kZWQsIHZlcmlmaWVkIEhMUyBwYXNzdGhyb3VnaC4KClRoZSBwcm92aWRlcidzIGJ5dGVzIGFyZSBuZXZlciBtb2RpZmllZCwgZGVjcnlwdGVkLCB0cmFuc2NvZGVkIG9yIHdyaXR0ZW4gdG8KcGVyc2lzdGVudCBzdG9yYWdlLiBTbWFsbCBhdWRpbyBzZWdtZW50cyBhbmQgQUVTIGtleXMgYXJlIHJlYWQgY29tcGxldGVseQpiZWZvcmUgcmV0dXJuaW5nIEhUVFAgaGVhZGVycywgc28gc2hvcnQvdHJ1bmNhdGVkIHVwc3RyZWFtIHJlc3BvbnNlcyBmYWlsIHdpdGgKNTAyIGluc3RlYWQgb2YgYSBmYWxzZSAyMDAuIExhcmdlIGNvbnRlbnQgZmFsbHMgYmFjayB0byBzdHJlYW1pbmcuCiIiIgpmcm9tIF9fZnV0dXJlX18gaW1wb3J0IGFubm90YXRpb25zCgppbXBvcnQgbG9nZ2luZwppbXBvcnQgb3MKaW1wb3J0IHJlCmltcG9ydCB0aHJlYWRpbmcKaW1wb3J0IHRpbWUKCmZyb20gZmFzdGFwaSBpbXBvcnQgSFRUUEV4Y2VwdGlvbgpmcm9tIGZhc3RhcGkucmVzcG9uc2VzIGltcG9ydCBSZXNwb25zZSwgU3RyZWFtaW5nUmVzcG9uc2UKCkxPRyA9IGxvZ2dpbmcuZ2V0TG9nZ2VyKCd1dmljb3JuLmVycm9yJykKTUFYX0JVRkZFUkVEX1NFR01FTlRfQllURVMgPSAyICogMTAyNCAqIDEwMjQKTUFYX0JVRkZFUkVEX0tFWV9CWVRFUyA9IDY0CkNIVU5LX0JZVEVTID0gNjQgKiAxMDI0Cl9SQU5HRSA9IHJlLmNvbXBpbGUocidieXRlcz0oXGQqKS0oXGQqKVxaJykKX0JVRkZFUl9TTE9UUyA9IHRocmVhZGluZy5Cb3VuZGVkU2VtYXBob3JlKDgpCgoKZGVmIF9jb250ZW50X3R5cGUodXBzdHJlYW0sIGtpbmQ6IHN0ciwgZmlsZW5hbWU6IHN0cikgLT4gc3RyOgogICAgdmFsdWUgPSB1cHN0cmVhbS5oZWFkZXJzLmdldCgnQ29udGVudC1UeXBlJywgJycpLnNwbGl0KCc7JywgMSlbMF0uc3RyaXAoKS5sb3dlcigpCiAgICBpZiBraW5kID09ICdrZXknOgogICAgICAgIHJldHVybiAnYXBwbGljYXRpb24vb2N0ZXQtc3RyZWFtJwogICAgaWYgdmFsdWUgYW5kIHZhbHVlIG5vdCBpbiB7J2FwcGxpY2F0aW9uL29jdGV0LXN0cmVhbScsICdiaW5hcnkvb2N0ZXQtc3RyZWFtJ306CiAgICAgICAgcmV0dXJuIHZhbHVlCiAgICBleHRlbnNpb24gPSBmaWxlbmFtZS5yc3BsaXQoJy4nLCAxKVstMV0ubG93ZXIoKSBpZiAnLicgaW4gZmlsZW5hbWUgZWxzZSAnJwogICAgcmV0dXJuIHsKICAgICAgICAndHMnOiAndmlkZW8vbXAydCcsICdhYWMnOiAnYXVkaW8vYWFjJywKICAgICAgICAnbXAzJzogJ2F1ZGlvL21wZWcnLCAnbTRzJzogJ3ZpZGVvL2lzby5zZWdtZW50JywKICAgICAgICAnbXA0JzogJ2F1ZGlvL21wNCcsCiAgICB9LmdldChleHRlbnNpb24sICdhcHBsaWNhdGlvbi9vY3RldC1zdHJlYW0nKQoKCmRlZiBfaGVhZGVyX2ludCh2YWx1ZTogc3RyIHwgTm9uZSkgLT4gaW50IHwgTm9uZToKICAgIHRyeToKICAgICAgICBpZiB2YWx1ZSBpcyBub3QgTm9uZSBhbmQgdmFsdWUuaXNkZWNpbWFsKCk6CiAgICAgICAgICAgIHJldHVybiBpbnQodmFsdWUpCiAgICBleGNlcHQgKFR5cGVFcnJvciwgVmFsdWVFcnJvcik6CiAgICAgICAgcGFzcwogICAgcmV0dXJuIE5vbmUKCgpkZWYgX2JvZHlfcmFuZ2UodmFsdWU6IHN0ciB8IE5vbmUsIHRvdGFsOiBpbnQpOgogICAgIiIiU2luZ2xlIEhUVFAgYnl0ZS1yYW5nZSBvbmx5LiBOb25lIG1lYW5zIGxlYXZlIHByb3ZpZGVyIHJlc3BvbnNlIGFzLWlzLiIiIgogICAgaWYgbm90IHZhbHVlOgogICAgICAgIHJldHVybiBOb25lCiAgICBtYXRjaCA9IF9SQU5HRS5mdWxsbWF0Y2godmFsdWUuc3RyaXAoKSkKICAgIGlmIG5vdCBtYXRjaCBvciBub3QgKG1hdGNoLmdyb3VwKDEpIG9yIG1hdGNoLmdyb3VwKDIpKSBvciB0b3RhbCA8IDE6CiAgICAgICAgcmV0dXJuIE5vbmUKICAgIGlmIG1hdGNoLmdyb3VwKDEpOgogICAgICAgIHN0YXJ0ID0gaW50KG1hdGNoLmdyb3VwKDEpKQogICAgICAgIGVuZCA9IGludChtYXRjaC5ncm91cCgyKSkgaWYgbWF0Y2guZ3JvdXAoMikgZWxzZSB0b3RhbCAtIDEKICAgICAgICBpZiBlbmQgPCBzdGFydDoKICAgICAgICAgICAgcmV0dXJuIE5vbmUKICAgIGVsc2U6CiAgICAgICAgc3VmZml4ID0gaW50KG1hdGNoLmdyb3VwKDIpKQogICAgICAgIGlmIHN1ZmZpeCA9PSAwOgogICAgICAgICAgICByZXR1cm4gTm9uZQogICAgICAgIHN0YXJ0LCBlbmQgPSBtYXgoMCwgdG90YWwgLSBzdWZmaXgpLCB0b3RhbCAtIDEKICAgIGlmIHN0YXJ0ID49IHRvdGFsOgogICAgICAgIHJldHVybiAoTm9uZSwgTm9uZSkKICAgIHJldHVybiAoc3RhcnQsIG1pbihlbmQsIHRvdGFsIC0gMSkpCgoKZGVmIF9zdHJlYW1fcmVzcG9uc2UodXBzdHJlYW0sIGhlYWRlcnM6IGRpY3QsIG1lZGlhX3R5cGU6IHN0ciwgc3RhdHVzOiBpbnQsCiAgICAgICAgICAgICAgICAgICAgIHN0YXJ0ZWQ6IGZsb2F0LCBwcmVmaXg6IHR1cGxlW2J5dGVzLCAuLi5dID0gKCksIGl0ZXJhdG9yPU5vbmUsCiAgICAgICAgICAgICAgICAgICAgIGtpbmQ6IHN0ciA9ICdzZWdtZW50Jyk6CiAgICAiIiJGYWxsIGJhY2sgd2l0aG91dCBsb3NpbmcgcHJlZmV0Y2hlZCBieXRlcyBmb3Igb3ZlcnNpemVkIHNlZ21lbnQgZGF0YS4iIiIKICAgIGlmIGl0ZXJhdG9yIGlzIE5vbmU6CiAgICAgICAgaXRlcmF0b3IgPSB1cHN0cmVhbS5pdGVyX2NvbnRlbnQoY2h1bmtfc2l6ZT1DSFVOS19CWVRFUykKICAgICMgcmVxdWVzdHMuaXRlcl9jb250ZW50IG1heSB0cmFuc3BhcmVudGx5IGRlY29tcHJlc3M7IGl0cyB1cHN0cmVhbQogICAgIyBDb250ZW50LUxlbmd0aCB0aGVuIG5vIGxvbmdlciBkZXNjcmliZXMgdGhlIHlpZWxkZWQgYm9keS4KICAgIGlmIHVwc3RyZWFtLmhlYWRlcnMuZ2V0KCdDb250ZW50LUVuY29kaW5nJywgJ2lkZW50aXR5JykubG93ZXIoKSBub3QgaW4gKCdpZGVudGl0eScsICcnKToKICAgICAgICBoZWFkZXJzLnBvcCgnQ29udGVudC1MZW5ndGgnLCBOb25lKQogICAgYnl0ZXNfc2VudCA9IDAKCiAgICBkZWYgY2h1bmtzKCk6CiAgICAgICAgbm9ubG9jYWwgYnl0ZXNfc2VudAogICAgICAgIGZpbmlzaGVkID0gRmFsc2UKICAgICAgICB0cnk6CiAgICAgICAgICAgIGZvciBwYXlsb2FkIGluIHByZWZpeDoKICAgICAgICAgICAgICAgIGlmIHBheWxvYWQ6CiAgICAgICAgICAgICAgICAgICAgYnl0ZXNfc2VudCArPSBsZW4ocGF5bG9hZCkKICAgICAgICAgICAgICAgICAgICB5aWVsZCBwYXlsb2FkCiAgICAgICAgICAgIGZvciBwYXlsb2FkIGluIGl0ZXJhdG9yOgogICAgICAgICAgICAgICAgaWYgcGF5bG9hZDoKICAgICAgICAgICAgICAgICAgICBieXRlc19zZW50ICs9IGxlbihwYXlsb2FkKQogICAgICAgICAgICAgICAgICAgIHlpZWxkIHBheWxvYWQKICAgICAgICAgICAgZmluaXNoZWQgPSBUcnVlCiAgICAgICAgZmluYWxseToKICAgICAgICAgICAgdXBzdHJlYW0uY2xvc2UoKQogICAgICAgICAgICBMT0cuaW5mbygnUE9DX0hMU19ERUxJVkVSWSBraW5kPSVzIG1vZGU9c3RyZWFtIHN0YXR1cz0lZCBjb21wbGV0ZT0lZCBieXRlcz0lZCBlbGFwc2VkX21zPSVkJywKICAgICAgICAgICAgICAgICAgICAga2luZCwgc3RhdHVzLCBpbnQoZmluaXNoZWQpLCBieXRlc19zZW50LAogICAgICAgICAgICAgICAgICAgICBpbnQoKHRpbWUucGVyZl9jb3VudGVyKCkgLSBzdGFydGVkKSAqIDEwMDApKQoKICAgIHJldHVybiBTdHJlYW1pbmdSZXNwb25zZShjaHVua3MoKSwgc3RhdHVzX2NvZGU9c3RhdHVzLCBtZWRpYV90eXBlPW1lZGlhX3R5cGUsCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgaGVhZGVycz1oZWFkZXJzKQoKCmRlZiBidWlsZF9yZXNvdXJjZV9yZXNwb25zZSh1cHN0cmVhbSwga2luZDogc3RyLCBmaWxlbmFtZTogc3RyLAogICAgICAgICAgICAgICAgICAgICAgICAgICAgbWV0aG9kOiBzdHIsIGNsaWVudF9yYW5nZTogc3RyIHwgTm9uZSk6CiAgICAiIiJSdW5zIGluIGEgRmFzdEFQSSB0aHJlYWRwb29sOyBkb2VzIG5vdCBibG9jayB0aGUgYXN5bmNpbyBldmVudCBsb29wLiIiIgogICAgc3RhcnRlZCA9IHRpbWUucGVyZl9jb3VudGVyKCkKICAgIHN0YXR1cyA9IHVwc3RyZWFtLnN0YXR1c19jb2RlCiAgICBpZiBzdGF0dXMgbm90IGluICgyMDAsIDIwNik6CiAgICAgICAgdXBzdHJlYW0uY2xvc2UoKQogICAgICAgIHJhaXNlIEhUVFBFeGNlcHRpb24oc3RhdHVzX2NvZGU9NTAyLCBkZXRhaWw9J05leHRvcnkgSExTIG1lZGlhIHVuYXZhaWxhYmxlJykKICAgIG1lZGlhX3R5cGUgPSBfY29udGVudF90eXBlKHVwc3RyZWFtLCBraW5kLCBmaWxlbmFtZSkKICAgIGhlYWRlcnMgPSB7J0NhY2hlLUNvbnRyb2wnOiAnbm8tc3RvcmUnfQogICAgZm9yIGtleSBpbiAoJ0NvbnRlbnQtTGVuZ3RoJywgJ0NvbnRlbnQtUmFuZ2UnLCAnRVRhZycsICdMYXN0LU1vZGlmaWVkJyk6CiAgICAgICAgdmFsdWUgPSB1cHN0cmVhbS5oZWFkZXJzLmdldChrZXkpCiAgICAgICAgaWYgdmFsdWU6CiAgICAgICAgICAgIGhlYWRlcnNba2V5XSA9IHZhbHVlCiAgICAjIEFkdmVydGlzaW5nIGJ5dGUtcmFuZ2Ugc3VwcG9ydCB3aGVuIGl0IGlzIGdlbnVpbmVseSBhdmFpbGFibGUgKG9yIHdoZW4KICAgICMgd2UgY2FuIHNlcnZlIGxvY2FsIGJ5dGUgcmFuZ2VzIGZyb20gYSBjb21wbGV0ZSBzbWFsbCBzZWdtZW50KS4KICAgIGlmIHVwc3RyZWFtLmhlYWRlcnMuZ2V0KCdBY2NlcHQtUmFuZ2VzJywgJycpLmxvd2VyKCkgPT0gJ2J5dGVzJyBvciBzdGF0dXMgPT0gMjA2OgogICAgICAgIGhlYWRlcnNbJ0FjY2VwdC1SYW5nZXMnXSA9ICdieXRlcycKCiAgICBpZiBtZXRob2QgPT0gJ0hFQUQnOgogICAgICAgIHVwc3RyZWFtLmNsb3NlKCkKICAgICAgICBMT0cuaW5mbygnUE9DX0hMU19ERUxJVkVSWSBraW5kPSVzIG1vZGU9aGVhZCBzdGF0dXM9JWQgZWxhcHNlZF9tcz0lZCcsCiAgICAgICAgICAgICAgICAga2luZCwgc3RhdHVzLCBpbnQoKHRpbWUucGVyZl9jb3VudGVyKCkgLSBzdGFydGVkKSAqIDEwMDApKQogICAgICAgIHJldHVybiBSZXNwb25zZShjb250ZW50PWInJywgc3RhdHVzX2NvZGU9c3RhdHVzLCBtZWRpYV90eXBlPW1lZGlhX3R5cGUsIGhlYWRlcnM9aGVhZGVycykKCiAgICBidWZmZXJpbmcgPSBraW5kID09ICdrZXknIG9yIG9zLmVudmlyb24uZ2V0KCdORVhUT1JZX0hMU19CVUZGRVJfU01BTEwnLCAnMScpID09ICcxJwogICAgaWYgbm90IGJ1ZmZlcmluZzoKICAgICAgICByZXR1cm4gX3N0cmVhbV9yZXNwb25zZSh1cHN0cmVhbSwgaGVhZGVycywgbWVkaWFfdHlwZSwgc3RhdHVzLCBzdGFydGVkLCBraW5kPWtpbmQpCgogICAgc2xvdCA9IEZhbHNlCiAgICBpZiBraW5kID09ICdzZWdtZW50JzoKICAgICAgICBzbG90ID0gX0JVRkZFUl9TTE9UUy5hY3F1aXJlKGJsb2NraW5nPUZhbHNlKQogICAgICAgIGlmIG5vdCBzbG90OgogICAgICAgICAgICByZXR1cm4gX3N0cmVhbV9yZXNwb25zZSh1cHN0cmVhbSwgaGVhZGVycywgbWVkaWFfdHlwZSwgc3RhdHVzLCBzdGFydGVkLAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBraW5kPWtpbmQpCiAgICB0cnk6CiAgICAgICAgcmV0dXJuIF9idWlsZF9idWZmZXJlZF9yZXNwb25zZSh1cHN0cmVhbSwga2luZCwgbWVkaWFfdHlwZSwgc3RhdHVzLAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgaGVhZGVycywgY2xpZW50X3JhbmdlLCBzdGFydGVkKQogICAgZmluYWxseToKICAgICAgICBpZiBzbG90OgogICAgICAgICAgICBfQlVGRkVSX1NMT1RTLnJlbGVhc2UoKQoKCmRlZiBfYnVpbGRfYnVmZmVyZWRfcmVzcG9uc2UodXBzdHJlYW0sIGtpbmQsIG1lZGlhX3R5cGUsIHN0YXR1cywgaGVhZGVycywKICAgICAgICAgICAgICAgICAgICAgICAgICAgICBjbGllbnRfcmFuZ2UsIHN0YXJ0ZWQpOgogICAgbGltaXQgPSBNQVhfQlVGRkVSRURfS0VZX0JZVEVTIGlmIGtpbmQgPT0gJ2tleScgZWxzZSBNQVhfQlVGRkVSRURfU0VHTUVOVF9CWVRFUwogICAgZGVjbGFyZWRfbGVuZ3RoID0gX2hlYWRlcl9pbnQodXBzdHJlYW0uaGVhZGVycy5nZXQoJ0NvbnRlbnQtTGVuZ3RoJykpCiAgICBpZiBkZWNsYXJlZF9sZW5ndGggaXMgbm90IE5vbmUgYW5kIGRlY2xhcmVkX2xlbmd0aCA+IGxpbWl0OgogICAgICAgIHJldHVybiBfc3RyZWFtX3Jlc3BvbnNlKHVwc3RyZWFtLCBoZWFkZXJzLCBtZWRpYV90eXBlLCBzdGF0dXMsIHN0YXJ0ZWQsIGtpbmQ9a2luZCkKCiAgICBpdGVyYXRvciA9IHVwc3RyZWFtLml0ZXJfY29udGVudChjaHVua19zaXplPUNIVU5LX0JZVEVTKQogICAgY2h1bmtzID0gW10KICAgIHRvdGFsID0gMAogICAgdHJ5OgogICAgICAgIGZvciBjaHVuayBpbiBpdGVyYXRvcjoKICAgICAgICAgICAgaWYgbm90IGNodW5rOgogICAgICAgICAgICAgICAgY29udGludWUKICAgICAgICAgICAgY2h1bmtzLmFwcGVuZChjaHVuaykKICAgICAgICAgICAgdG90YWwgKz0gbGVuKGNodW5rKQogICAgICAgICAgICBpZiB0b3RhbCA+IGxpbWl0OgogICAgICAgICAgICAgICAgcmV0dXJuIF9zdHJlYW1fcmVzcG9uc2UodXBzdHJlYW0sIGhlYWRlcnMsIG1lZGlhX3R5cGUsIHN0YXR1cywgc3RhcnRlZCwKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIHR1cGxlKGNodW5rcyksIGl0ZXJhdG9yLCBraW5kPWtpbmQpCiAgICAgICAgdXBzdHJlYW0uY2xvc2UoKQogICAgZXhjZXB0IEV4Y2VwdGlvbiBhcyBleGM6CiAgICAgICAgdXBzdHJlYW0uY2xvc2UoKQogICAgICAgIGlmIGlzaW5zdGFuY2UoZXhjLCBIVFRQRXhjZXB0aW9uKToKICAgICAgICAgICAgcmFpc2UKICAgICAgICBMT0cud2FybmluZygnUE9DX0hMU19ERUxJVkVSWSBraW5kPSVzIG1vZGU9YnVmZmVyIHN0YXR1cz11cHN0cmVhbV9lcnJvciBlcnJvcl90eXBlPSVzJywKICAgICAgICAgICAgICAgICAgICBraW5kLCB0eXBlKGV4YykuX19uYW1lX18pCiAgICAgICAgcmFpc2UgSFRUUEV4Y2VwdGlvbihzdGF0dXNfY29kZT01MDIsIGRldGFpbD0nSW5jb21wbGV0ZSB1cHN0cmVhbSBITFMgbWVkaWEnKSBmcm9tIGV4YwoKICAgICMgcmVxdWVzdHMuUmVzcG9uc2UuaXRlcl9jb250ZW50IG1heSBkZWNvZGUgQ29udGVudC1FbmNvZGluZy4gRG8gbm90IGtlZXAKICAgICMgcHJvdmlkZXIncyBlbmNvZGVkIGJ5dGUgY291bnQgYXMgdGhlIGRvd25zdHJlYW0gQ29udGVudC1MZW5ndGguCiAgICBlbmNvZGluZyA9IHVwc3RyZWFtLmhlYWRlcnMuZ2V0KCdDb250ZW50LUVuY29kaW5nJywgJ2lkZW50aXR5JykubG93ZXIoKQogICAgaWYgZGVjbGFyZWRfbGVuZ3RoIGlzIG5vdCBOb25lIGFuZCBlbmNvZGluZyBpbiAoJ2lkZW50aXR5JywgJycpIGFuZCB0b3RhbCAhPSBkZWNsYXJlZF9sZW5ndGg6CiAgICAgICAgTE9HLndhcm5pbmcoJ1BPQ19ITFNfREVMSVZFUlkga2luZD0lcyBtb2RlPWJ1ZmZlciBzdGF0dXM9dHJ1bmNhdGVkIGRlY2xhcmVkPSVkIGFjdHVhbD0lZCcsCiAgICAgICAgICAgICAgICAgICAga2luZCwgZGVjbGFyZWRfbGVuZ3RoLCB0b3RhbCkKICAgICAgICByYWlzZSBIVFRQRXhjZXB0aW9uKHN0YXR1c19jb2RlPTUwMiwgZGV0YWlsPSdJbmNvbXBsZXRlIHVwc3RyZWFtIEhMUyBtZWRpYScpCgogICAgaWYga2luZCA9PSAna2V5JyBhbmQgdG90YWwgIT0gMTY6CiAgICAgICAgIyBTb21lIEhMUyBtZXRob2RzIHVzZSBub24tcmF3IGtleSByZXNvdXJjZXMuIFByZXNlcnZlIHByb3ZpZGVyIGJ5dGVzLgogICAgICAgIExPRy5pbmZvKCdQT0NfSExTX0RFTElWRVJZIGtpbmQ9a2V5IG1vZGU9YnVmZmVyIGtleV9ieXRlcz0lZCcsIHRvdGFsKQoKICAgIHBheWxvYWQgPSBiJycuam9pbihjaHVua3MpCiAgICAjIFNvbWUgQ0ROcyBpZ25vcmUgYSBjbGllbnQgUmFuZ2UgcmVxdWVzdCBhbmQgYW5zd2VyIDIwMC4gRm9yIGEgY29tcGxldGUKICAgICMgc21hbGwgcmVzcG9uc2UsIGhvbm9yIGEgc3RhbmRhcmQgc2luZ2xlIHJhbmdlIGxvY2FsbHksIHRvIHByb3ZpZGUgYQogICAgIyBkZXRlcm1pbmlzdGljIGFuc3dlciB0byBBVkZvdW5kYXRpb24ncyBieXRlLXJhbmdlIHByb2Jlcy4KICAgIGlmIHN0YXR1cyA9PSAyMDAgYW5kIGNsaWVudF9yYW5nZToKICAgICAgICBzZWxlY3RlZCA9IF9ib2R5X3JhbmdlKGNsaWVudF9yYW5nZSwgbGVuKHBheWxvYWQpKQogICAgICAgIGlmIHNlbGVjdGVkID09IChOb25lLCBOb25lKToKICAgICAgICAgICAgTE9HLmluZm8oJ1BPQ19ITFNfREVMSVZFUlkga2luZD0lcyBtb2RlPWJ1ZmZlciBzdGF0dXM9NDE2IGJ5dGVzPSVkJywga2luZCwgdG90YWwpCiAgICAgICAgICAgIHJldHVybiBSZXNwb25zZShjb250ZW50PWInJywgc3RhdHVzX2NvZGU9NDE2LAogICAgICAgICAgICAgICAgICAgICAgICAgICAgaGVhZGVycz17J0NvbnRlbnQtUmFuZ2UnOiBmJ2J5dGVzICove3RvdGFsfScsCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAnQ2FjaGUtQ29udHJvbCc6ICduby1zdG9yZSd9KQogICAgICAgIGlmIHNlbGVjdGVkIGlzIG5vdCBOb25lOgogICAgICAgICAgICBiZWdpbiwgZW5kID0gc2VsZWN0ZWQKICAgICAgICAgICAgcGF5bG9hZCA9IHBheWxvYWRbYmVnaW46ZW5kICsgMV0KICAgICAgICAgICAgc3RhdHVzID0gMjA2CiAgICAgICAgICAgIGhlYWRlcnNbJ0NvbnRlbnQtUmFuZ2UnXSA9IGYnYnl0ZXMge2JlZ2lufS17ZW5kfS97dG90YWx9JwogICAgICAgICAgICBoZWFkZXJzWydBY2NlcHQtUmFuZ2VzJ10gPSAnYnl0ZXMnCiAgICBoZWFkZXJzWydDb250ZW50LUxlbmd0aCddID0gc3RyKGxlbihwYXlsb2FkKSkKICAgIGlmIHN0YXR1cyA9PSAyMDA6CiAgICAgICAgaGVhZGVycy5wb3AoJ0NvbnRlbnQtUmFuZ2UnLCBOb25lKQogICAgTE9HLmluZm8oJ1BPQ19ITFNfREVMSVZFUlkga2luZD0lcyBtb2RlPWJ1ZmZlciBzdGF0dXM9JWQgY29tcGxldGU9MSBieXRlcz0lZCBlbGFwc2VkX21zPSVkIHJhbmdlPSVkJywKICAgICAgICAgICAgIGtpbmQsIHN0YXR1cywgbGVuKHBheWxvYWQpLCBpbnQoKHRpbWUucGVyZl9jb3VudGVyKCkgLSBzdGFydGVkKSAqIDEwMDApLAogICAgICAgICAgICAgaW50KGJvb2woY2xpZW50X3JhbmdlKSkpCiAgICByZXR1cm4gUmVzcG9uc2UoY29udGVudD1wYXlsb2FkLCBzdGF0dXNfY29kZT1zdGF0dXMsCiAgICAgICAgICAgICAgICAgICAgbWVkaWFfdHlwZT1tZWRpYV90eXBlLCBoZWFkZXJzPWhlYWRlcnMpCg==').decode('utf-8')
TEST_SOURCE = base64.b64decode('IiIiSExTX0ZJUlNUUExBWV9TRVJWRVJfVjEgb2ZmbGluZSBwcm90b2NvbCB0ZXN0cywgbm8gcHJvdmlkZXIgY29ubmVjdGlvbnMuIiIiCmltcG9ydCBvcwppbXBvcnQgc3lzCmZyb20gcGF0aGxpYiBpbXBvcnQgUGF0aAoKb3MuZW52aXJvbi5zZXRkZWZhdWx0KCdURVNUX1BBU1NXT1JEJywgJ2xvY2FsLXRlc3QtcGFzc3dvcmQtMTIzNDU2JykKb3MuZW52aXJvbi5zZXRkZWZhdWx0KCdURVNUX0FVVEhfU0VDUkVUJywgJ3Rlc3Qtb25seS1zZWNyZXQtMDEyMzQ1Njc4OWFiY2RlZmdoaWprbG1ub3BxcnN0dXZ3eHl6JykKb3MuZW52aXJvblsnQ0FUQUxPR19BVVRPU1lOQyddID0gJzAnCnN5cy5wYXRoLmluc2VydCgwLCBzdHIoUGF0aChfX2ZpbGVfXykucmVzb2x2ZSgpLnBhcmVudC5wYXJlbnQpKQoKaW1wb3J0IHB5dGVzdApmcm9tIGZhc3RhcGkgaW1wb3J0IEhUVFBFeGNlcHRpb24KZnJvbSBmYXN0YXBpLnJlc3BvbnNlcyBpbXBvcnQgUmVzcG9uc2UsIFN0cmVhbWluZ1Jlc3BvbnNlCmZyb20gZmFzdGFwaS50ZXN0Y2xpZW50IGltcG9ydCBUZXN0Q2xpZW50CmZyb20gZmFzdGFwaSBpbXBvcnQgRmFzdEFQSQoKZnJvbSBhcHAuaGxzX2RlbGl2ZXJ5IGltcG9ydCBidWlsZF9yZXNvdXJjZV9yZXNwb25zZQpmcm9tIGFwcC5uZXh0b3J5IGltcG9ydCBOZXh0b3J5QmFja2VuZCwgTmV4dG9yeUVycm9yCgoKY2xhc3MgVXBzdHJlYW06CiAgICBkZWYgX19pbml0X18oc2VsZiwgcGF5bG9hZDogYnl0ZXMsIHN0YXR1cz0yMDAsIGhlYWRlcnM9Tm9uZSwgKiwgY2h1bmtzPU5vbmUsIHVybD0naHR0cHM6Ly9jZG4uZXhhbXBsZS5vcmcvYXVkaW8uYWFjJyk6CiAgICAgICAgc2VsZi5wYXlsb2FkID0gcGF5bG9hZAogICAgICAgIHNlbGYuc3RhdHVzX2NvZGUgPSBzdGF0dXMKICAgICAgICBzZWxmLmhlYWRlcnMgPSBoZWFkZXJzIG9yIHsnQ29udGVudC1UeXBlJzogJ2F1ZGlvL2FhYycsICdDb250ZW50LUxlbmd0aCc6IHN0cihsZW4ocGF5bG9hZCkpfQogICAgICAgIHNlbGYuY2h1bmtzID0gY2h1bmtzCiAgICAgICAgc2VsZi51cmwgPSB1cmwKICAgICAgICBzZWxmLmNsb3NlZCA9IEZhbHNlCgogICAgZGVmIGl0ZXJfY29udGVudChzZWxmLCBjaHVua19zaXplPTY1NTM2KToKICAgICAgICBpZiBzZWxmLmNodW5rcyBpcyBub3QgTm9uZToKICAgICAgICAgICAgeWllbGQgZnJvbSBzZWxmLmNodW5rcwogICAgICAgIGVsc2U6CiAgICAgICAgICAgIGZvciBwb3MgaW4gcmFuZ2UoMCwgbGVuKHNlbGYucGF5bG9hZCksIGNodW5rX3NpemUpOgogICAgICAgICAgICAgICAgeWllbGQgc2VsZi5wYXlsb2FkW3Bvczpwb3MrY2h1bmtfc2l6ZV0KCiAgICBkZWYgY2xvc2Uoc2VsZik6CiAgICAgICAgc2VsZi5jbG9zZWQgPSBUcnVlCgoKY2xhc3MgUmF3OgogICAgZGVmIF9faW5pdF9fKHNlbGYsIGRhdGE6IGJ5dGVzKToKICAgICAgICBzZWxmLmRhdGEgPSBkYXRhCiAgICBkZWYgcmVhZChzZWxmLCBjb3VudCwgZGVjb2RlX2NvbnRlbnQ9VHJ1ZSk6CiAgICAgICAgcmV0dXJuIHNlbGYuZGF0YVs6Y291bnRdCgoKY2xhc3MgTWFuaWZlc3RVcHN0cmVhbShVcHN0cmVhbSk6CiAgICBkZWYgX19pbml0X18oc2VsZiwgdGV4dDogYnl0ZXMsIHVybCk6CiAgICAgICAgc3VwZXIoKS5fX2luaXRfXyh0ZXh0LCBoZWFkZXJzPXsnQ29udGVudC1MZW5ndGgnOiBzdHIobGVuKHRleHQpKX0sIHVybD11cmwpCiAgICAgICAgc2VsZi5yYXcgPSBSYXcodGV4dCkKCgpkZWYgdGVzdF9tYW5pZmVzdF9jYWNoZV9mcm9tX3ByZXdhcm1fcmV1c2VkX2J5X3BsYXkobW9ua2V5cGF0Y2gpOgogICAgcHJvdmlkZXIgPSBOZXh0b3J5QmFja2VuZCgpCiAgICB1cmwgPSAnaHR0cHM6Ly9jZG4uZXhhbXBsZS5vcmcvcGxheWxpc3QubTN1OD9wcml2YXRlPWZha2UnCiAgICBkb2N1bWVudCA9IGInI0VYVE0zVVxuI0VYVElORjo1LFxuc2VnbWVudDEuYWFjXG4jRVhULVgtRU5ETElTVFxuJwogICAgcmVxdWVzdHMgPSBbXQoKICAgIGRlZiBmZXRjaChsaW5rKToKICAgICAgICByZXF1ZXN0cy5hcHBlbmQobGluaykKICAgICAgICByZXR1cm4gTWFuaWZlc3RVcHN0cmVhbShkb2N1bWVudCwgdXJsKQoKICAgIG1vbmtleXBhdGNoLnNldGF0dHIocHJvdmlkZXIsICdyZW1vdGVfZ2V0JywgZmV0Y2gpCiAgICBmaXJzdCA9IHByb3ZpZGVyLmdldF9tYW5pZmVzdCh1cmwpCiAgICBzZWNvbmQgPSBwcm92aWRlci5nZXRfbWFuaWZlc3QodXJsKQogICAgYXNzZXJ0IGZpcnN0ID09IHNlY29uZAogICAgYXNzZXJ0IGxlbihyZXF1ZXN0cykgPT0gMQogICAgYXNzZXJ0IHByb3ZpZGVyLl9tYW5pZmVzdF9jYWNoZV9ieXRlcyA9PSBsZW4oZG9jdW1lbnQpCgoKZGVmIHRlc3RfbWFuaWZlc3RfY2FjaGVfZXhwaXJlc19hbmRfcmVmZXRjaGVzKG1vbmtleXBhdGNoKToKICAgIHByb3ZpZGVyID0gTmV4dG9yeUJhY2tlbmQoKQogICAgdXJsID0gJ2h0dHBzOi8vY2RuLmV4YW1wbGUub3JnL21lZGlhLm0zdTgnCiAgICBkb2N1bWVudCA9IGInI0VYVE0zVVxuI0VYVElORjozLFxueC5hYWNcbicKICAgIGNhbGxzID0gW10KICAgIG1vbmtleXBhdGNoLnNldGF0dHIocHJvdmlkZXIsICdyZW1vdGVfZ2V0JywgbGFtYmRhIGxpbms6IChjYWxscy5hcHBlbmQobGluaykgb3IgTWFuaWZlc3RVcHN0cmVhbShkb2N1bWVudCwgdXJsKSkpCiAgICBwcm92aWRlci5nZXRfbWFuaWZlc3QodXJsKQogICAgZGF0YSwgZW5kX3VybCwgc2l6ZSwgY3JlYXRlZCA9IHByb3ZpZGVyLl9tYW5pZmVzdF9jYWNoZVt1cmxdCiAgICBwcm92aWRlci5fbWFuaWZlc3RfY2FjaGVbdXJsXSA9IChkYXRhLCBlbmRfdXJsLCBzaXplLCBjcmVhdGVkIC0gOTk5KQogICAgcHJvdmlkZXIuZ2V0X21hbmlmZXN0KHVybCkKICAgIGFzc2VydCBsZW4oY2FsbHMpID09IDIKCgpkZWYgdGVzdF9tYW5pZmVzdF9jYWNoZV9ib3VuZHNfYW5kX25vX292ZXJzaXplZF9jYWNoZShtb25rZXlwYXRjaCk6CiAgICBpbXBvcnQgYXBwLm5leHRvcnkgYXMgbW9kdWxlCiAgICBwcm92aWRlciA9IE5leHRvcnlCYWNrZW5kKCkKICAgIG1vbmtleXBhdGNoLnNldGF0dHIobW9kdWxlLCAnTUFYX01BTklGRVNUX0NBQ0hFX0VOVFJJRVMnLCAyKQogICAgZm9yIGkgaW4gcmFuZ2UoNSk6CiAgICAgICAgcHJvdmlkZXIuX21hbmlmZXN0X2NhY2hlX3B1dChmJ2h0dHBzOi8vY2RuLmV4YW1wbGUub3JnL3tpfScsICcjRVhUTTNVJywgJ2h0dHBzOi8vY2RuLmV4YW1wbGUub3JnL3onLCA3KQogICAgYXNzZXJ0IGxlbihwcm92aWRlci5fbWFuaWZlc3RfY2FjaGUpID09IDIKICAgIGFzc2VydCBwcm92aWRlci5fbWFuaWZlc3RfY2FjaGVfYnl0ZXMgPT0gMTQKICAgIHByb3ZpZGVyLl9tYW5pZmVzdF9jYWNoZV9wdXQoJ2h0dHBzOi8vY2RuLmV4YW1wbGUub3JnL21hc3NpdmUnLCAnI0VYVE0zVScsICd1cmwnLCAzKjEwMjQqMTAyNCkKICAgIGFzc2VydCBsZW4ocHJvdmlkZXIuX21hbmlmZXN0X2NhY2hlKSA9PSAyCgoKZGVmIHRlc3RfYnVmZmVyZWRfc2VnbWVudF9zdWNjZXNzX2FuZF9tYXRjaGluZ19sZW5ndGgoKToKICAgIHNvdXJjZSA9IFVwc3RyZWFtKGInYWJjMTIzJykKICAgIHJlc3AgPSBidWlsZF9yZXNvdXJjZV9yZXNwb25zZShzb3VyY2UsICdzZWdtZW50JywgJ3N0cmVhbS5hYWMnLCAnR0VUJywgTm9uZSkKICAgIGFzc2VydCBpc2luc3RhbmNlKHJlc3AsIFJlc3BvbnNlKQogICAgYXNzZXJ0IHJlc3Auc3RhdHVzX2NvZGUgPT0gMjAwCiAgICBhc3NlcnQgcmVzcC5ib2R5ID09IGInYWJjMTIzJwogICAgYXNzZXJ0IHJlc3AuaGVhZGVyc1snY29udGVudC1sZW5ndGgnXSA9PSAnNicKICAgIGFzc2VydCByZXNwLmhlYWRlcnNbJ2NvbnRlbnQtdHlwZSddLnN0YXJ0c3dpdGgoJ2F1ZGlvL2FhYycpCiAgICBhc3NlcnQgc291cmNlLmNsb3NlZAoKCmRlZiB0ZXN0X2J1ZmZlcmVkX3ZhbGlkXzIwNl9yYW5nZV9wcmVzZXJ2ZWQoKToKICAgIHNvdXJjZSA9IFVwc3RyZWFtKGInYWJjZCcsIHN0YXR1cz0yMDYsIGhlYWRlcnM9ewogICAgICAgICdDb250ZW50LUxlbmd0aCc6ICc0JywgJ0NvbnRlbnQtUmFuZ2UnOiAnYnl0ZXMgMC0zLzEwMCcsICdDb250ZW50LVR5cGUnOiAnYXVkaW8vYWFjJwogICAgfSkKICAgIHJlc3AgPSBidWlsZF9yZXNvdXJjZV9yZXNwb25zZShzb3VyY2UsICdzZWdtZW50JywgJ3N0cmVhbS5hYWMnLCAnR0VUJywgJ2J5dGVzPTAtMycpCiAgICBhc3NlcnQgcmVzcC5zdGF0dXNfY29kZSA9PSAyMDYKICAgIGFzc2VydCByZXNwLmJvZHkgPT0gYidhYmNkJwogICAgYXNzZXJ0IHJlc3AuaGVhZGVyc1snY29udGVudC1yYW5nZSddID09ICdieXRlcyAwLTMvMTAwJwogICAgYXNzZXJ0IHJlc3AuaGVhZGVyc1snYWNjZXB0LXJhbmdlcyddID09ICdieXRlcycKCgpkZWYgdGVzdF9wcm92aWRlcl9pZ25vcmVzX3JhbmdlX3NlcnZlZF9hc18yMDZfbG9jYWxseSgpOgogICAgc291cmNlID0gVXBzdHJlYW0oYidBQkNERUZHJykKICAgIHJlc3AgPSBidWlsZF9yZXNvdXJjZV9yZXNwb25zZShzb3VyY2UsICdzZWdtZW50JywgJ3N0cmVhbS5hYWMnLCAnR0VUJywgJ2J5dGVzPTItNCcpCiAgICBhc3NlcnQgcmVzcC5zdGF0dXNfY29kZSA9PSAyMDYKICAgIGFzc2VydCByZXNwLmJvZHkgPT0gYidDREUnCiAgICBhc3NlcnQgcmVzcC5oZWFkZXJzWydjb250ZW50LXJhbmdlJ10gPT0gJ2J5dGVzIDItNC83JwogICAgYXNzZXJ0IHJlc3AuaGVhZGVyc1snY29udGVudC1sZW5ndGgnXSA9PSAnMycKCgpkZWYgdGVzdF9pbnZhbGlkX3JhbmdlX3JldHVybnNfNDE2X3dpdGhvdXRfZXhwb3Npbmdfc291cmNlX3VybCgpOgogICAgc291cmNlID0gVXBzdHJlYW0oYidhYmNkZWYnKQogICAgcmVzcCA9IGJ1aWxkX3Jlc291cmNlX3Jlc3BvbnNlKHNvdXJjZSwgJ3NlZ21lbnQnLCAnc3RyZWFtLmFhYycsICdHRVQnLCAnYnl0ZXM9OTktMTAwJykKICAgIGFzc2VydCByZXNwLnN0YXR1c19jb2RlID09IDQxNgogICAgYXNzZXJ0IHJlc3AuaGVhZGVyc1snY29udGVudC1yYW5nZSddID09ICdieXRlcyAqLzYnCgoKZGVmIHRlc3RfdHJ1bmNhdGVkX2JvZHlfZmFpbHNfYmVmb3JlX2ZhbHNlXzIwMCgpOgogICAgc291cmNlID0gVXBzdHJlYW0oYicxMjM0NScsIGhlYWRlcnM9eydDb250ZW50LUxlbmd0aCc6JzYnLCAnQ29udGVudC1UeXBlJzonYXVkaW8vYWFjJ30pCiAgICB3aXRoIHB5dGVzdC5yYWlzZXMoSFRUUEV4Y2VwdGlvbikgYXMgZXg6CiAgICAgICAgYnVpbGRfcmVzb3VyY2VfcmVzcG9uc2Uoc291cmNlLCAnc2VnbWVudCcsICdzdHJlYW0uYWFjJywgJ0dFVCcsIE5vbmUpCiAgICBhc3NlcnQgZXgudmFsdWUuc3RhdHVzX2NvZGUgPT0gNTAyCiAgICBhc3NlcnQgc291cmNlLmNsb3NlZAoKCmRlZiB0ZXN0X2Jyb2tlbl91cHN0cmVhbV9mYWlsc19iZWZvcmVfaGVhZGVycygpOgogICAgc291cmNlID0gVXBzdHJlYW0oYicnLCBjaHVua3M9W2InYWInXSkKICAgIGRlZiBicm9rZW5faXRlcihjaHVua19zaXplPTY1NTM2KToKICAgICAgICB5aWVsZCBiJ2FiJwogICAgICAgIHJhaXNlIE9TRXJyb3IoJ3N5bnRoZXRpYyBvcmlnaW4gZGlzY29ubmVjdGVkJykKICAgIHNvdXJjZS5pdGVyX2NvbnRlbnQgPSBicm9rZW5faXRlcgogICAgd2l0aCBweXRlc3QucmFpc2VzKEhUVFBFeGNlcHRpb24pIGFzIGV4OgogICAgICAgIGJ1aWxkX3Jlc291cmNlX3Jlc3BvbnNlKHNvdXJjZSwgJ3NlZ21lbnQnLCAnc3RyZWFtLmFhYycsICdHRVQnLCBOb25lKQogICAgYXNzZXJ0IGV4LnZhbHVlLnN0YXR1c19jb2RlID09IDUwMgogICAgYXNzZXJ0IHNvdXJjZS5jbG9zZWQKCgpkZWYgdGVzdF9lbmNyeXB0ZWRfa2V5X3Bhc3N0aHJvdWdoXzE2X2J5dGVzX25vX2RlY3J5cHRpb24oKToKICAgIHJhdyA9IGInMTIzNDU2Nzg5MGFiY2RlZicKICAgIHNvdXJjZSA9IFVwc3RyZWFtKHJhdywgaGVhZGVycz17J0NvbnRlbnQtTGVuZ3RoJzonMTYnLCdDb250ZW50LVR5cGUnOidhcHBsaWNhdGlvbi9vY3RldC1zdHJlYW0nfSkKICAgIHJlc3AgPSBidWlsZF9yZXNvdXJjZV9yZXNwb25zZShzb3VyY2UsICdrZXknLCAnc3RyZWFtLmJpbicsICdHRVQnLCBOb25lKQogICAgYXNzZXJ0IHJlc3AuYm9keSA9PSByYXcKICAgIGFzc2VydCBzb3VyY2UuY2xvc2VkCgoKZGVmIHRlc3RfaGVhZF9kb2VzX25vdF9mZXRjaF9yZXNwb25zZV9ib2R5KCk6CiAgICBzb3VyY2UgPSBVcHN0cmVhbShiJ0FCQycpCiAgICBkZWYgZmFpbCgqYXJncywgKiprd2FyZ3MpOgogICAgICAgIHJhaXNlIEFzc2VydGlvbkVycm9yKCdIRUFEIG11c3Qgbm90IGRvd25sb2FkIHRoZSBzZWdtZW50JykKICAgIHNvdXJjZS5pdGVyX2NvbnRlbnQgPSBmYWlsCiAgICByZXNwID0gYnVpbGRfcmVzb3VyY2VfcmVzcG9uc2Uoc291cmNlLCAnc2VnbWVudCcsICdzdHJlYW0uYWFjJywgJ0hFQUQnLCBOb25lKQogICAgYXNzZXJ0IHJlc3Auc3RhdHVzX2NvZGUgPT0gMjAwCiAgICBhc3NlcnQgcmVzcC5ib2R5ID09IGInJwogICAgYXNzZXJ0IHJlc3AuaGVhZGVyc1snY29udGVudC1sZW5ndGgnXSA9PSAnMycKICAgIGFzc2VydCBzb3VyY2UuY2xvc2VkCgoKZGVmIHRlc3RfbGFyZ2Vfc2VnbWVudF9wcmVzZXJ2ZXNfc3RyZWFtaW5nX2ZhbGxiYWNrKCk6CiAgICByYXcgPSBiJ1onICogKDIqMTAyNCoxMDI0KzExKQogICAgc291cmNlID0gVXBzdHJlYW0ocmF3KQogICAgYXBwID0gRmFzdEFQSSgpCiAgICBAYXBwLmdldCgnL3NhbXBsZScpCiAgICBkZWYgc2FtcGxlKCk6CiAgICAgICAgcmV0dXJuIGJ1aWxkX3Jlc291cmNlX3Jlc3BvbnNlKHNvdXJjZSwgJ3NlZ21lbnQnLCAnc3RyZWFtLmFhYycsICdHRVQnLCBOb25lKQogICAgcmVzcG9uc2UgPSBUZXN0Q2xpZW50KGFwcCkuZ2V0KCcvc2FtcGxlJykKICAgIGFzc2VydCByZXNwb25zZS5zdGF0dXNfY29kZSA9PSAyMDAKICAgIGFzc2VydCByZXNwb25zZS5jb250ZW50ID09IHJhdwogICAgYXNzZXJ0IHNvdXJjZS5jbG9zZWQKCgpkZWYgdGVzdF9pbmNvbXBsZXRlX3Byb3ZpZGVyX3N0YXR1c19mYWlsc19jbG9zZWQoKToKICAgIHNvdXJjZSA9IFVwc3RyZWFtKGInYXV0aCBmYWlsdXJlJywgc3RhdHVzPTQwMykKICAgIHdpdGggcHl0ZXN0LnJhaXNlcyhIVFRQRXhjZXB0aW9uKSBhcyBleDoKICAgICAgICBidWlsZF9yZXNvdXJjZV9yZXNwb25zZShzb3VyY2UsICdzZWdtZW50JywgJ3N0cmVhbS5hYWMnLCAnR0VUJywgTm9uZSkKICAgIGFzc2VydCBleC52YWx1ZS5zdGF0dXNfY29kZSA9PSA1MDIKICAgIGFzc2VydCBzb3VyY2UuY2xvc2VkCgoKZGVmIHRlc3RfcGFyYWxsZWxfYnVmZmVyX2J1ZGdldF9mYWxsc19iYWNrX3RvX3N0cmVhbShtb25rZXlwYXRjaCk6CiAgICBpbXBvcnQgYXBwLmhsc19kZWxpdmVyeSBhcyBtb2R1bGUKICAgIGNsYXNzIEJ1c3k6CiAgICAgICAgZGVmIGFjcXVpcmUoc2VsZiwgYmxvY2tpbmc9RmFsc2UpOgogICAgICAgICAgICByZXR1cm4gRmFsc2UKICAgICAgICBkZWYgcmVsZWFzZShzZWxmKToKICAgICAgICAgICAgcmFpc2UgQXNzZXJ0aW9uRXJyb3IoJ05vIHNsb3QgYWNxdWlyZWQsIHNvIG5vIHJlbGVhc2UgYWxsb3dlZCcpCiAgICBtb25rZXlwYXRjaC5zZXRhdHRyKG1vZHVsZSwgJ19CVUZGRVJfU0xPVFMnLCBCdXN5KCkpCiAgICBzb3VyY2UgPSBVcHN0cmVhbShiJ2FiYycpCiAgICByZXNwb25zZSA9IGJ1aWxkX3Jlc291cmNlX3Jlc3BvbnNlKHNvdXJjZSwgJ3NlZ21lbnQnLCAnc3RyZWFtLmFhYycsICdHRVQnLCBOb25lKQogICAgYXNzZXJ0IGlzaW5zdGFuY2UocmVzcG9uc2UsIFN0cmVhbWluZ1Jlc3BvbnNlKQogICAgYXNzZXJ0IG5vdCBzb3VyY2UuY2xvc2VkICAjIENsb3NlZCBvbmx5IGFmdGVyIHN0cmVhbWluZyBmaW5pc2hlcy4KICAgIGZyb20gZmFzdGFwaSBpbXBvcnQgRmFzdEFQSQogICAgYXBwID0gRmFzdEFQSSgpCiAgICBAYXBwLmdldCgnL3N0cmVhbScpCiAgICBkZWYgc3RyZWFtKCk6CiAgICAgICAgcmV0dXJuIHJlc3BvbnNlCiAgICBhc3NlcnQgVGVzdENsaWVudChhcHApLmdldCgnL3N0cmVhbScpLmNvbnRlbnQgPT0gYidhYmMnCiAgICBhc3NlcnQgc291cmNlLmNsb3NlZAoKCmRlZiB0ZXN0X3BhcmFsbGVsX21hbmlmZXN0X2xvb2t1cHNfZG9fbm90X2hvbGRfbmV0d29ya19sb2NrKG1vbmtleXBhdGNoKToKICAgIGZyb20gY29uY3VycmVudC5mdXR1cmVzIGltcG9ydCBUaHJlYWRQb29sRXhlY3V0b3IKICAgIGltcG9ydCB0aHJlYWRpbmcKICAgIGJhY2tlbmQgPSBOZXh0b3J5QmFja2VuZCgpCiAgICBiYXJyaWVyID0gdGhyZWFkaW5nLkJhcnJpZXIoNCkKICAgIGRvY3VtZW50ID0gYicjRVhUTTNVXG4jRVhUSU5GOjMsXG5hLmFhY1xuJwogICAgZGVmIGZldGNoKHVybCk6CiAgICAgICAgIyBEZWFkbG9ja3MgaWYgdGhlIHNoYXJlZCBjYWNoZSBsb2NrIGlzIGhlbGQgb3ZlciByZW1vdGVfZ2V0KCkuCiAgICAgICAgYmFycmllci53YWl0KHRpbWVvdXQ9MikKICAgICAgICByZXR1cm4gTWFuaWZlc3RVcHN0cmVhbShkb2N1bWVudCwgdXJsKQogICAgbW9ua2V5cGF0Y2guc2V0YXR0cihiYWNrZW5kLCAncmVtb3RlX2dldCcsIGZldGNoKQogICAgdXJscyA9IFtmJ2h0dHBzOi8vY2RuLmV4YW1wbGUub3JnL21lZGlhLXtpfS5tM3U4JyBmb3IgaSBpbiByYW5nZSg0KV0KICAgIHdpdGggVGhyZWFkUG9vbEV4ZWN1dG9yKG1heF93b3JrZXJzPTQpIGFzIHBvb2w6CiAgICAgICAgcmVzdWx0cyA9IGxpc3QocG9vbC5tYXAoYmFja2VuZC5nZXRfbWFuaWZlc3QsIHVybHMpKQogICAgYXNzZXJ0IGxlbihyZXN1bHRzKSA9PSA0CiAgICBhc3NlcnQgYWxsKHJlc3VsdFswXS5zdGFydHN3aXRoKCcjRVhUTTNVJykgZm9yIHJlc3VsdCBpbiByZXN1bHRzKQo=').decode('utf-8')


def fail(msg):
    raise SystemExit('ERROR: ' + msg)


def once(src, old, new, label):
    matches = src.count(old)
    if matches != 1:
        fail(f'{label}: expected one code anchor, got {matches}')
    return src.replace(old, new, 1)


def patch_main(src: str) -> str:
    src = once(src,
        'from .prewarm import PrewarmManager  # NEXTORY_DETAIL_PREWARM_V1\n',
        'from .prewarm import PrewarmManager  # NEXTORY_DETAIL_PREWARM_V1\n'
        'from .hls_delivery import build_resource_response  # HLS_FIRSTPLAY_SERVER_V1\n',
        'HLS module import')
    before = '''        payload = playlist.encode('utf-8')
        return Response(content=b'' if req.method == 'HEAD' else payload,
                        media_type='application/vnd.apple.mpegurl',
                        headers={'Content-Length': str(len(payload)),
                                 'Cache-Control': 'no-store',
                                 'Access-Control-Allow-Origin': '*'})'''
    after = '''        payload = playlist.encode('utf-8')
        # HLS_FIRSTPLAY_SERVER_V1: anonymous HLS semantics, never URLs/tokens.
        logging.getLogger('uvicorn.error').info(
            'POC_HLS_MANIFEST kind=%s segments=%d endlist=%d encrypted=%d maps=%d bytes=%d',
            'master' if '#EXT-X-STREAM-INF:' in document else 'media',
            document.count('#EXTINF:'), int('#EXT-X-ENDLIST' in document),
            int('#EXT-X-KEY:' in document), int('#EXT-X-MAP:' in document), len(payload))
        return Response(content=b'' if req.method == 'HEAD' else payload,
                        media_type='application/vnd.apple.mpegurl',
                        headers={'Content-Length': str(len(payload)),
                                 'Cache-Control': 'no-store',
                                 'Access-Control-Allow-Origin': '*'})'''
    src = once(src, before, after, 'HLS playlist metadata telemetry')
    before = '''    content_type = upstream.headers.get('Content-Type', 'application/octet-stream').split(';', 1)[0]
    if resource.kind == 'key':
        content_type = 'application/octet-stream'
    elif content_type in {'', 'application/octet-stream'}:
        content_type = ('video/mp2t' if filename.endswith('.ts') else
                        'audio/aac' if filename.endswith('.aac') else 'application/octet-stream')
    headers = {'Cache-Control': 'no-store', 'Accept-Ranges': 'bytes'}
    for key in ('Content-Length', 'Content-Range', 'ETag', 'Last-Modified'):
        if value := upstream.headers.get(key):
            headers[key] = value
    if req.method == 'HEAD':
        upstream.close()
        return Response(content=b'', media_type=content_type,
                        status_code=upstream.status_code, headers=headers)

    def chunks():
        try:
            for chunk in upstream.iter_content(chunk_size=64 * 1024):
                if chunk:
                    yield chunk
        finally:
            upstream.close()
    return StreamingResponse(chunks(), media_type=content_type,
                             status_code=upstream.status_code, headers=headers)'''
    after = '''    # HLS_FIRSTPLAY_SERVER_V1: verify delivery for small segments before 200;
    # preserve streaming for large segments. Never put media on disk.
    return await run_in_threadpool(
        build_resource_response, upstream, resource.kind, filename,
        req.method, req.headers.get('range'))'''
    src = once(src, before, after, 'segment and key passthrough')
    ast.parse(src, filename='main.py')
    return src


def patch_nextory(src: str) -> str:
    src = once(src,
        'import io\nimport ipaddress\n',
        'import io\nimport ipaddress\nfrom collections import OrderedDict\n',
        'ordered LRU import')
    src = once(src,
        'CACHE_SECONDS = 5 * 60\n',
        'CACHE_SECONDS = 5 * 60\n'
        'MANIFEST_CACHE_SECONDS = 45  # HLS_FIRSTPLAY_SERVER_V1\n'
        'MAX_MANIFEST_CACHE_BYTES = 16 * 1024 * 1024\n'
        'MAX_MANIFEST_CACHE_ENTRIES = 160\n'
        'MAX_CACHED_MANIFEST_BYTES = 2 * 1024 * 1024\n',
        'cache limits')
    src = once(src,
        '        self._covers: dict[int, tuple[bytes, float]] = {}\n',
        '        self._covers: dict[int, tuple[bytes, float]] = {}\n'
        '        # Keep signed playlist URLs and bodies only briefly in memory.\n'
        '        self._manifest_lock = threading.Lock()  # HLS_FIRSTPLAY_SERVER_V1\n'
        '        self._manifest_cache = OrderedDict()\n'
        '        self._manifest_cache_bytes = 0\n',
        'backend cache init')
    before = '''    def get_manifest(self, url: str) -> tuple[str, str]:
        response = self.remote_get(url)
        try:
            if response.status_code != 200:
                raise NextoryError(f'Nextory HLS manifest HTTP {response.status_code}')
            body = response.raw.read(MAX_MANIFEST_BYTES + 1, decode_content=True)
            if len(body) > MAX_MANIFEST_BYTES or not body.startswith(b'#EXTM3U'):
                raise NextoryError('Invalid or oversized HLS playlist')
            return body.decode('utf-8-sig'), response.url
        except UnicodeDecodeError as exc:
            raise NextoryError('Nextory HLS playlist is not UTF-8') from exc
        finally:
            response.close()

'''
    after = '''    def _manifest_cache_get(self, url: str) -> tuple[str, str] | None:
        # HLS_FIRSTPLAY_SERVER_V1: do not hold this lock over a network call.
        now = time.monotonic()
        with self._manifest_lock:
            cached = self._manifest_cache.get(url)
            if cached is None:
                return None
            (data, final_url, size, created) = cached
            if now - created >= MANIFEST_CACHE_SECONDS:
                self._manifest_cache_bytes -= size
                del self._manifest_cache[url]
                return None
            self._manifest_cache.move_to_end(url)
        logging.getLogger('uvicorn.error').info(
            'POC_HLS_MANIFEST_CACHE status=hit bytes=%d', size)
        return data, final_url

    def _manifest_cache_put(self, url: str, data: str, final_url: str, size: int) -> None:
        if size > MAX_CACHED_MANIFEST_BYTES:
            return
        now = time.monotonic()
        with self._manifest_lock:
            # Drop stale entries before LRU insertion; no provider URLs in logs.
            for key, entry in list(self._manifest_cache.items()):
                if now - entry[3] >= MANIFEST_CACHE_SECONDS:
                    self._manifest_cache_bytes -= entry[2]
                    del self._manifest_cache[key]
            old = self._manifest_cache.pop(url, None)
            if old is not None:
                self._manifest_cache_bytes -= old[2]
            self._manifest_cache[url] = (data, final_url, size, now)
            self._manifest_cache_bytes += size
            while (len(self._manifest_cache) > MAX_MANIFEST_CACHE_ENTRIES or
                   self._manifest_cache_bytes > MAX_MANIFEST_CACHE_BYTES):
                _, previous = self._manifest_cache.popitem(last=False)
                self._manifest_cache_bytes -= previous[2]

    def get_manifest(self, url: str) -> tuple[str, str]:
        # Prewarming already requests these playlists to calculate durations.
        # Reuse the raw playlist at Play; rewrite it per playback session so
        # session URLs remain isolated and no key/media bytes are cached here.
        cached = self._manifest_cache_get(url)
        if cached is not None:
            return cached
        response = self.remote_get(url)
        try:
            if response.status_code != 200:
                raise NextoryError(f'Nextory HLS manifest HTTP {response.status_code}')
            body = response.raw.read(MAX_MANIFEST_BYTES + 1, decode_content=True)
            if len(body) > MAX_MANIFEST_BYTES or not body.startswith(b'#EXTM3U'):
                raise NextoryError('Invalid or oversized HLS playlist')
            try:
                document = body.decode('utf-8-sig')
            except UnicodeDecodeError as exc:
                raise NextoryError('Nextory HLS playlist is not UTF-8') from exc
            result = (document, response.url)
            self._manifest_cache_put(url, document, response.url, len(body))
            return result
        finally:
            response.close()

'''
    src = once(src, before, after, 'Nextory get_manifest')
    ast.parse(src, filename='nextory.py')
    return src


def atomic_write(path: Path, content: str, mode=None) -> None:
    temp = path.with_name(path.name + '.hls-firstplay-tmp')
    try:
        temp.write_text(content, encoding='utf-8')
        if mode is not None:
            os.chmod(temp, mode)
        os.replace(temp, path)
    finally:
        temp.unlink(missing_ok=True)


if MODE not in {'apply', 'rollback'}:
    fail('Gebruik apply of rollback')
if ORIGINAL == TEST or ORIGINAL in TEST.parents or TEST in ORIGINAL.parents:
    fail('Test en origineel overlappen')
for item in (MAIN, NEXTORY, DELIVERY, UNIT, BACKUP, BACKUP/'main.py', BACKUP/'nextory.py'):
    if item.is_symlink():
        fail('Symlink in code of backup')
for test_path in (MAIN, NEXTORY):
    original_path = ORIGINAL/'app'/test_path.name
    if not test_path.is_file() or not original_path.is_file():
        fail('Origineel of testbestand ontbreekt')
    if os.path.samefile(test_path, original_path):
        fail('Origineel en test delen een inode')
if not (TEST/'app/prewarm.py').is_file():
    fail('Prewarming ontbreekt; geen verdere wijzigingen uitgevoerd')
if not (TEST/'tests').is_dir():
    fail('Tests-directory ontbreekt')

current_main = MAIN.read_text(encoding='utf-8')
current_nextory = NEXTORY.read_text(encoding='utf-8')
old_main = BACKUP/'main.py'
old_nextory = BACKUP/'nextory.py'

if MODE == 'rollback':
    if not (old_main.is_file() and old_nextory.is_file() and DELIVERY.is_file() and UNIT.is_file()):
        fail('Geen complete backup gevonden')
    source_main = old_main.read_text(encoding='utf-8')
    source_nextory = old_nextory.read_text(encoding='utf-8')
    if (current_main != patch_main(source_main) or
            current_nextory != patch_nextory(source_nextory) or
            DELIVERY.read_text(encoding='utf-8') != DELIVERY_SOURCE or
            UNIT.read_text(encoding='utf-8') != TEST_SOURCE):
        fail('Code gewijzigd na patch; rollback geweigerd om wijzigingen te beschermen')
    atomic_write(MAIN, source_main, MAIN.stat().st_mode & 0o777)
    atomic_write(NEXTORY, source_nextory, NEXTORY.stat().st_mode & 0o777)
    DELIVERY.unlink()
    UNIT.unlink()
    print('ROLLBACK=RESTORED_PREVIOUS_PREWARM_VERSION')
    print('ORIGINAL=NOT_MODIFIED')
    raise SystemExit(0)

if ('NEXTORY_DETAIL_PREWARM_V1' not in current_main or
        'AUDIOBOOTH_COMPAT_V1' not in current_main or
        'POC_DIRECT_PLAYLIST_EXPERIMENT' not in current_main or
        'NEXTORY_LAYOUT_PARALLEL_V1' not in current_nextory or
        'MAX_MANIFEST_BYTES = 8 * 1024 * 1024' not in current_nextory or
        'NEXTORY_AUTH_RETRY' not in current_nextory):
    fail('Huidige testversie mist een van de eerder bevestigde verbeteringen')
if MARKER in current_main or MARKER in current_nextory:
    if not (old_main.is_file() and old_nextory.is_file() and DELIVERY.is_file() and UNIT.is_file()):
        fail('Patch is onvolledig')
    if (current_main != patch_main(old_main.read_text(encoding='utf-8')) or
            current_nextory != patch_nextory(old_nextory.read_text(encoding='utf-8')) or
            DELIVERY.read_text(encoding='utf-8') != DELIVERY_SOURCE or
            UNIT.read_text(encoding='utf-8') != TEST_SOURCE):
        fail('Bestaande patch wijkt af; niet overschrijven')
    print('PATCH=ALREADY_APPLIED')
    raise SystemExit(0)
if DELIVERY.exists() or UNIT.exists():
    fail('Nieuwe module of test bestaat al; niet overschrijven')
if old_main.exists() and old_main.read_text(encoding='utf-8') != current_main:
    fail('Vorige backup verschilt van testcode')
if old_nextory.exists() and old_nextory.read_text(encoding='utf-8') != current_nextory:
    fail('Vorige backup verschilt van testcode')

modified_main = patch_main(current_main)
modified_nextory = patch_nextory(current_nextory)
for name, source in [('hls_delivery.py', DELIVERY_SOURCE), ('test_hls_firstplay.py', TEST_SOURCE)]:
    ast.parse(source, filename=name)

if not BACKUP.exists():
    BACKUP.mkdir(mode=0o700)
if not old_main.exists():
    shutil.copy2(MAIN, old_main)
    os.chmod(old_main, 0o600)
if not old_nextory.exists():
    shutil.copy2(NEXTORY, old_nextory)
    os.chmod(old_nextory, 0o600)
try:
    # Write dependency first, then import. On errors, restore without touching original.
    atomic_write(DELIVERY, DELIVERY_SOURCE, 0o644)
    atomic_write(UNIT, TEST_SOURCE, 0o644)
    atomic_write(NEXTORY, modified_nextory, NEXTORY.stat().st_mode & 0o777)
    atomic_write(MAIN, modified_main, MAIN.stat().st_mode & 0o777)
except Exception:
    atomic_write(MAIN, current_main, MAIN.stat().st_mode & 0o777)
    atomic_write(NEXTORY, current_nextory, NEXTORY.stat().st_mode & 0o777)
    for f in (DELIVERY, UNIT):
        if f.is_file():
            f.unlink()
    raise

print('MANIFEST_CACHE=45S_160_ENTRIES_16MIB')
print('SEGMENT_BUFFER=MAX_2MIB_PER_REQUEST')
print('STREAM_FALLBACK=PRESERVED_FOR_LARGE_SEGMENTS')
print('KEYS=PASSTHROUGH_NO_DISK')
print('AUDIO_PREWARM=UNCHANGED_NO_AUDIO_DOWNLOAD')
print('PREWARM=DETAIL_ONLY_PRESERVED')
print('HLS_WORKERS=4_PRESERVED')
print('PYTHON_SYNTAX=PASS')
print('ORIGINAL=NOT_MODIFIED')


PYPATCH

echo
if [ "$OFFLINE" = '1' ]; then
  echo '=== 3. OFFLINE-VERIFICATIE ==='
  echo 'PATCHED_SOURCE=PASS'
  exit 0
fi

echo '=== 3. ALLEEN TESTCONTAINER HERBOUWEN ==='
docker compose -p "$PROJECT" -f "$TEST/docker-compose.yml" -f "$TEST/docker-compose.test.yml" \
  up -d --build --no-deps "$SERVICE"
echo

echo '=== 4. WACHTEN OP /HEALTH ==='
READY=0
for i in $(seq 1 25); do
  if docker exec nextory-abs-poc-test python -c 'import urllib.request; assert urllib.request.urlopen("http://127.0.0.1:8000/health",timeout=3).status == 200' >/dev/null 2>&1; then
    READY=1
    break
  fi
  sleep 2
done
if [ "$READY" != 1 ]; then
  echo 'HEALTHCHECK=FAILED'
  docker logs --tail 25 nextory-abs-poc-test 2>&1 | grep -E 'ERROR|Traceback|startup|Exception' | tail -12 || true
  exit 1
fi

echo '=== 5. VERSIE EN ISOLATIE BEVESTIGEN ==='
docker exec -i nextory-abs-poc-test python - <<'PYVERIFY'
from app import main
from app import nextory as backend_module
from app.hls_delivery import MAX_BUFFERED_SEGMENT_BYTES
from app.nextory import MAX_MANIFEST_BYTES
print('HLS_FIRSTPLAY_SERVER=ENABLED' if hasattr(main,'build_resource_response') else 'HLS_FIRSTPLAY_SERVER=MISSING')
print('MANIFEST_CACHE_SECONDS='+str(backend_module.MANIFEST_CACHE_SECONDS))
print('SEGMENT_BUFFER_BYTES='+str(MAX_BUFFERED_SEGMENT_BYTES))
print('HLS_LIMIT_BYTES='+str(MAX_MANIFEST_BYTES))
print('PREWARM=DETAIL_ONLY_PRESERVED' if hasattr(main,'prewarm_manager') else 'PREWARM=MISSING')
PYVERIFY
docker inspect nextory-abs-poc-test --format 'TEST_RUNNING={{.State.Running}} HEALTH={{if .State.Health}}{{.State.Health.Status}}{{else}}unknown{{end}}'
docker inspect nextory-abs-poc --format 'ORIGINAL_RUNNING={{.State.Running}}'
echo
echo '=== 6. VOLGENDE TEST ==='
echo 'Open een nog niet recent afgespeeld boek, wacht op prewarm en druk eenmaal Play.'
echo 'Bekijk de HLS- en Play-regels met:'
echo "docker logs --since 10m nextory-abs-poc-test 2>&1 | grep -E 'POC_HLS_MANIFEST|POC_HLS_DELIVERY|POC_PREWARM stage=play|POC_TIMING stage=play-start' | tail -55"
echo 'Controleer of de afspeelteller bij de EERSTE Play nu loopt.'
echo 'Rollback: bash ~/nextory-abs-virtual-poc-test/nextory-hls-firstplay-test.sh rollback'
echo '=== EINDE ==='
