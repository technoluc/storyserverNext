# Nextory -> Audiobookshelf virtual-item proof of concept (STEP 2)

A **stand-alone** REST + minimal Socket.IO websocket server for the native
Audiobookshelf mobile app. It presents **one virtual item** based on Nextory
product ID `7207495` and the UUID returned by the previous live probe.

This is NOT Nextory streaming. The book cover is an **original mock cover**
with the real test title, NOT the publisher's cover. No Nextory login, API
access, media download, HLS decryption, transcoding or caching occurs.
A dummy virtual audio file is included **only as JSON metadata** to make
Audiobookshelf show its Stream button. Clicking it deliberately returns 501.
The dummy duration (120 seconds) is not the real book duration.

## Install on a Docker host

```sh
unzip nextory-abs-virtual-poc.zip
cd nextory-abs-virtual-poc
sh setup.sh
```

The setup script creates a local `.env` containing random test credentials.
Review `.env`. For testing directly from an iPhone on the trusted LAN, set:

```ini
BIND_IP=0.0.0.0
```

Then:

```sh
docker compose up -d --build
sh smoke.sh
```

Default host port: `13378`. The service **does not** use the same ports,
containers, databases or volumes as the existing Audiobookshelf installation.
This is not a Coolify component and requires no Nextory credentials.

## Connect iPhone

1. On the phone, ensure the Docker host is reachable (same trusted LAN or
   your existing VPN). Prefer HTTPS behind a **separate hostname and proxy**
   with WebSocket upgrade support. If iOS blocks plain HTTP, use HTTPS.
2. In the Audiobookshelf app **add another server**. Do not overwrite the
   existing server profile.
3. Enter `http://DOCKER_HOST_LAN_IP:13378` or your distinct HTTPS test URL.
4. Log in using username `test`, password from `.env` (retrieve on host with
   `grep ^TEST_PASSWORD= .env` and do not paste it into chat).
5. Select the `Nextory - Virtual POC` library. It should show one book:
   `Hier gebeurt nooit iets : De veiligste plek om te wonen is een klein stadje. Toch?`
6. Open the book. Verify the mock cover, title and **Stream** button.
7. **Do not** press Stream expecting audio; this stage deliberately has none.

## Test checkpoints

- `GET /status` -> Audiobookshelf status, `isInit=true`
- `POST /login` -> `user.token`
- `POST /api/authorize` -> user + library + settings
- `GET /api/libraries` -> virtual library
- `GET /api/libraries/{id}?include=filterdata` -> library/filterdata
- `GET /api/libraries/{id}/personalized` -> one book shelf
- `GET /api/libraries/{id}/items?minified=1` -> one item
- `GET /api/items/{id}?expanded=1` -> one virtual track
- `GET /api/items/{id}/cover` -> JPEG
- `GET /socket.io/?EIO=4&transport=websocket` -> Socket.IO v4 websocket handshake,
  `auth` event and `init` reply
- `POST /api/items/{id}/play` -> intentionally 501

The server identifies itself with API compatibility version **2.25.0**
for the app's legacy token flow. This is not the actual Audiobookshelf
software version. It is a minimal **compatibility probe**; it may require
adjustments for specific iOS app releases. The Socket.IO implementation only
supports default-namespace connect, ping/pong and auth/init events.

## Security

- The service is password protected (random credentials generated locally).
- Never reuse your real Nextory or Audiobookshelf credentials.
- Only enable `BIND_IP=0.0.0.0` for a trusted LAN / firewall-restricted host.
- Use HTTPS and normal access controls for off-LAN access.
- No persistent database, external volumes, Nextory access or media files.
- Default port binding is loopback only.

## Diagnostics

```sh
sh smoke.sh
docker compose logs --tail=80
```

Only share redacted error lines and test results. Do not share the generated
`.env`, bearer tokens, password or Authorization header.

## Rollback / removal

```sh
docker compose down
```

The existing Audiobookshelf installation is unaffected. The only persistent
local files are the extracted project and `.env` test credentials, which may
be removed after you are finished.
