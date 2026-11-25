#!/usr/bin/env bash
# Start the Nextory test project on the original port, without touching the original.
# Run using: bash /path/to/nextory-test-safe-start.sh

ORIGINAL="$HOME/nextory-abs-virtual-poc"
TEST="$HOME/nextory-abs-virtual-poc-test"
PROJECT="nextory-abs-test"
SERVICE="nextory-abs-poc"

clear 2>/dev/null || true

echo "=== 1. VOORCONTROLE ==="
if [ ! -f "$TEST/docker-compose.yml" ] || [ ! -f "$TEST/docker-compose.test.yml" ]; then
    echo "ERROR: De Compose-bestanden ontbreken in de testmap."
    exit 1
fi
if [ ! -f "$TEST/.env" ]; then
    echo "ERROR: .env ontbreekt in de testmap."
    exit 1
fi
if [ "$(docker inspect -f '{{.State.Running}}' nextory-abs-poc 2>/dev/null)" != "false" ]; then
    echo "ERROR: De originele container is niet aantoonbaar gestopt."
    exit 1
fi
if [ -n "$(docker ps -q --filter publish=13378)" ]; then
    echo "ERROR: Poort 13378 is al in gebruik door Docker."
    exit 1
fi
if docker container inspect nextory-abs-poc-test >/dev/null 2>&1; then
    echo "ERROR: De testcontainer bestaat al. Inspecteer hem eerst."
    exit 1
fi
cd "$TEST" || exit 1
printf 'ORIGINAL=STOPPED\nTEST_DIRECTORY=FOUND\nPORT=13378\n'

echo
echo "=== 2. EFFECTIEVE COMPOSE-CONFIGURATIE EN ISOLATIE ==="
python3 - "$ORIGINAL" "$TEST" "$PROJECT" <<'PY'
import json
import os
import subprocess
import sys
from pathlib import Path

original = Path(sys.argv[1]).resolve()
test = Path(sys.argv[2]).resolve()
project = sys.argv[3]

def fail(message):
    print("ERROR: " + message)
    sys.exit(1)

def within(path, root):
    path = Path(path).resolve()
    return path == root or root in path.parents

cmd = [
    "docker", "compose", "-p", project,
    "-f", "docker-compose.yml", "-f", "docker-compose.test.yml",
    "config", "--format", "json",
]
try:
    r = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
except OSError:
    fail("Docker Compose niet beschikbaar")
if r.returncode:
    fail("Docker Compose-configuratie ongeldig (geen secrets getoond)")
try:
    cfg = json.loads(r.stdout)
    svc = cfg["services"]["nextory-abs-poc"]
except (KeyError, ValueError, TypeError):
    fail("Nextory-service ontbreekt in geldige JSON-configuratie")

if cfg.get("name") != project:
    fail("Compose-projectnaam is niet geisoleerd")
if svc.get("container_name") != "nextory-abs-poc-test":
    fail("Testcontainernaam is niet geisoleerd")
if svc.get("image") != "nextory-abs-poc-test:dev":
    fail("Test-image is niet geisoleerd")
if svc.get("network_mode") or svc.get("volumes_from"):
    fail("Onverwachte gedeelde netwerk- of volume-instelling")

ports = svc.get("ports", [])
if len(ports) != 1:
    fail("Onverwacht aantal gepubliceerde poorten")
p = ports[0]
if str(p.get("published")) != "13378" or str(p.get("target")) != "8000":
    fail("Poort moet exact 13378:8000 blijven")

build = svc.get("build")
if not build:
    fail("Build-context ontbreekt")
context = build.get("context") if isinstance(build, dict) else build
if not context or not within(context, test):
    fail("Build-context ligt buiten testmap")

for envfile in svc.get("env_file", []):
    path = envfile.get("path") if isinstance(envfile, dict) else envfile
    if not path or not within(path, test):
        fail("env_file wijst buiten testmap")

allowed_shared_config = False
for mount in svc.get("volumes", []):
    kind = mount.get("type")
    source = mount.get("source")
    target = mount.get("target", "")
    readonly = mount.get("read_only", False)

    if kind == "bind":
        if not source:
            fail("Bind mount zonder bron: " + target)
        in_original = within(source, original)
        in_test = within(source, test)
        if in_original:
            if target == "/run/nextory" and readonly:
                allowed_shared_config = True
                print("READONLY_NEXTORY_CONFIG=ALLOWED")
            else:
                fail("Bind mount naar origineel niet toegestaan: " + target)
        elif not in_test and not readonly:
            fail("Schrijfbare bind mount buiten testmap: " + target)
        elif not in_test:
            print("EXTERNAL_READONLY_BIND=" + target)
        else:
            print("TEST_BIND=" + target)
    elif kind == "volume":
        if not source:
            fail("Anoniem volume vereist afzonderlijke controle: " + target)
        definition = cfg.get("volumes", {}).get(source, {})
        name = definition.get("name", "")
        if definition.get("external") or not name.startswith(project + "_"):
            fail("Docker-volume is niet project-geisoleerd: " + target)
        print("ISOLATED_VOLUME=" + target)
    else:
        fail("Onbekend mounttype bij " + target)

for net in svc.get("networks", {}) or {}:
    definition = cfg.get("networks", {}).get(net, {})
    name = definition.get("name", "")
    if definition.get("external") or (name and not name.startswith(project + "_")):
        fail("Docker-netwerk is niet project-geisoleerd")

for key, value in svc.get("environment", {}).items():
    if not isinstance(value, str) or str(original) not in value:
        continue
    if key == "NEXTORY_CONFIG_SOURCE" and allowed_shared_config:
        continue
    fail("Omgevingsvariabele verwijst naar origineel: " + key)

print("PROJECT=ISOLATED")
print("CONTAINER=ISOLATED")
print("IMAGE=ISOLATED")
print("PORT=13378")
print("SAFETY_CHECK=PASS")
PY
if [ "$?" -ne 0 ]; then
    echo
    echo "=== START AFGEBROKEN ==="
    echo "Geen container gestart; originele installatie ongewijzigd."
    exit 1
fi

echo
echo "=== 3. TESTSERVER BOUWEN EN STARTEN ==="
docker compose -p "$PROJECT" \
    -f docker-compose.yml \
    -f docker-compose.test.yml \
    up -d --build --no-deps "$SERVICE"
if [ "$?" -ne 0 ]; then
    echo "ERROR: Testserver kon niet worden gestart. Origineel blijft intact."
    exit 1
fi

echo
echo "=== 4. EINDCONTROLE ==="
docker ps -a --filter name=nextory-abs-poc \
    --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
docker inspect nextory-abs-poc --format 'ORIGINAL_RUNNING={{.State.Running}}'
docker inspect nextory-abs-poc-test --format 'TEST_RUNNING={{.State.Running}} HEALTH={{if .State.Health}}{{.State.Health.Status}}{{else}}n/a{{end}}'

echo
echo "=== EINDE ==="
echo "ORIGINAL=UNCHANGED"
echo "TEST_PORT=13378"
