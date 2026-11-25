# Nextory audiobook 7207495 -> Audiobookshelf iPhone, stage 3

This isolated v3 proof-of-concept uses the **real Nextory product 7207495**: *Hier gebeurt nooit iets : De veiligste plek om te wonen is een klein stadje. Toch?* It does **not** generate, include, download, decrypt, transcode, or store any audio. The book's cover and metadata are retrieved at runtime from the authenticated Nextory product API. The first **real HLS audio part** is passed through to iOS in the original format, with its original HLS encryption intact.

## What this proves (if the phone succeeds)

* Same virtual library / book ID as v2. The existing iPhone connection and test username/password remain unchanged.
* `POST /api/items/{id}/play` now produces an Audiobookshelf-style direct-play session (`playMethod: 0`, one `audioTrack`, a measured playlist duration).
* `GET /public/session/{id}/track/1` redirects to a `.m3u8` playlist on **this** POC server.
* HLS child playlists, segments, and AES-128 key URIs are mapped to temporary opaque local URLs; the provider's HLS content and encryption are untouched. No DRM bypass is implemented. Provider access and licenses remain authoritative.
* `POST /api/session/{id}/sync` and `/close` support initial pause / seek tests.

**Current scope is ONLY the first part of the book's HLS package** (the previous probe reported 34 parts). Seeking is supported *within that part*. This stage does not yet support the full 34-part audiobook or cross-device persistent progress.

## Update the existing v2 folder

1. Place `nextory-abs-virtual-poc-v3.zip` on the Docker host at `/tmp/nextory-abs-virtual-poc-v3.zip`.
2. Open your shell **inside the existing v2 POC project folder**, where `docker-compose.yml` and `.env` already exist.
3. Run:

```sh
ZIP=/tmp/nextory-abs-virtual-poc-v3.zip
clear
unzip -p "$ZIP" nextory-abs-virtual-poc-v3/upgrade.sh | sh -s -- "$ZIP"
```

The updater creates a private backup under `.poc-v2-backup-*` including `.env`, installs v3 files, discovers the existing `audiobook-dl-web` container's `/app/config` mount, and appends only `NEXTORY_CONFIG_SOURCE=` to the existing `.env` (no test password changes). It then rebuilds only `nextory-abs-poc`. The old mock cover is not packaged in v3 and is no longer used.

If auto-discovery fails (e.g., downloader runs on another host), the updater does not replace the running container. Supply the **host-side absolute directory containing** `audiobook-dl.toml`:

```sh
sh configure-nextory.sh /absolute/host/directory/containing/audiobook-dl.toml
docker compose up -d --build nextory-abs-poc
sh smoke.sh
```

No Nextory password should be added to `.env` or pasted into ChatGPT. The Nextory TOML is mounted read-only at `/run/nextory/audiobook-dl.toml`. If the user inside the container cannot read the existing file, `POST /play` reports `503` with a safe error: this POC does not change the source permissions or move its credentials. Fix the mount access separately instead of making the password world-readable.

## Smoke and iPhone test

`sh smoke.sh` checks server status, login, authorization, virtual book, actual Nextory product, a real `/play` session, an HLS playlist, and closes the session. It does **not request any segment or encryption key**. During the phone test, press Stream, listen, pause, and seek within the first part. Avoid skipping beyond the end of this first part.

If playback fails, run:

```sh
clear
echo '=== NEXTORY HLS IPHONE REQUESTS ==='
docker compose logs --no-color --since=2m nextory-abs-poc 2>&1 | tail -65
echo '=== END ==='
```

An iOS client uses the `/public/session/<session-id>/track/1` URL without a bearer header; the random session identifier and resource tokens are capabilities. For this POC, **only expose the container on a trusted LAN**. For off-LAN use, set up a separate HTTPS reverse proxy with authentication carefully designed to allow the player's HLS requests. A session expires after 60 minutes or after being closed. Server restart discards all sessions.

## Limits and provider compliance

Nextory's catalog and media APIs are not official stable integrations for Audiobookshelf. The user's existing login succeeded in the earlier read-only probe. Actual iOS playback is **not verified** until you test it on your device. This project does not provide any DRM bypass, local audio cache or permanent M4B export, and is not intended to expand media access beyond a valid Nextory subscription and permitted usage. If Nextory requires licensing tied to its own app, stop at this boundary rather than trying to defeat that protection.

## Rollback

Stop here and restore the saved POC files from `.poc-v2-backup-<timestamp>` (including `docker-compose.yml`, `Dockerfile`, `requirements.txt`, `app/main.py`, `smoke.sh`, and `.env`), then run `docker compose up -d --build nextory-abs-poc`. No changes were made to your separate Audiobookshelf or downloader deployments.
