# Nextory Virtual Audiobookshelf v6

> Recovered proof-of-concept snapshot. The active source also contains the later
> fixed-size ALAC virtual-M4B experiment (“G”), while this original v6 README
> describes the older HLS baseline. See [docs/RECOVERY_STATUS.md](docs/RECOVERY_STATUS.md)
> for the evidence level of each milestone, known gaps, and secret-handling notes.

V6 is an isolated, unofficial personal test server for the native Audiobookshelf iPhone app. It builds on the v5 installation that the user confirmed can play and seek through full Nextory audiobooks. It does not contain copyrighted audio, pre-download complete books, decrypt HLS, or store media keys.

## Changes since v5

1. **One visible Nextory library**, same persistent library ID as v5's original 'all' library. The 19 existing Nextory categories plus 'Nieuw ontdekt' appear as **20 native Audiobookshelf Collections**, under the normal Collections tab. Old category-library IDs are accepted as read-only aliases temporarily for previously cached iOS clients, but are no longer advertised in `/api/libraries`.
2. **Fast book details**. Library filters, book listings and the home page use the existing SQLite metadata index. On `GET /api/items/{id}`, the server first returns the real cached Nextory product title, authors, narrators, description, publisher and cover reference, without opening HLS manifests or calculating every track. A single *virtual preview track* represents a playable audiobook on a details/collection card; it does not contain or play audio. The actual `POST /play` still returns all precisely timed real HLS parts and chapters. Once the real layout is in the in-memory provider cache, the details endpoint can also show the complete track structure.
3. **Faster first HLS track request**. Instead of another synchronous Nextory product API call on the first `/public/session/{id}/track/N` request, the server reuses the signed URI from the session that `/play` just created. Sessions older than five minutes still refresh URLs as before. It preserves the existing 302 redirect to a `.m3u8` HLS playlist, which was confirmed compatible with iOS.
4. **Diagnostics without secrets**. `POC_TIMING` server messages show elapsed time for book details, cover, playback start, and HLS track entry. No upstream tokens, source URLs or user passwords are logged.
5. **Same automatic six-hour discovery and live Nextory search**, no manual `add-book.sh`, no change to the existing HLS segment proxy or listening-position store.

## Upgrade in the existing v5 Docker project

Place the ZIP on the Docker host as `/tmp/nextory-abs-virtual-poc-v6.zip`, open the directory with the existing `.env` and `docker-compose.yml`, and run:

```sh
ZIP=/tmp/nextory-abs-virtual-poc-v6.zip
clear 2>/dev/null || true
unzip -tq "$ZIP" || exit 1
unzip -p "$ZIP" nextory-abs-virtual-poc-v6/upgrade.sh | sh -s -- "$ZIP"
```

The installer checks the archive and the current project, saves a hidden `.poc-v5-backup-...` copy of the old code (NO copy of `.env`), stages and syntax-checks the new code, updates only `app/main.py`, `app/nextory.py`, scripts and docs, then runs:

```sh
docker compose up -d --build --force-recreate nextory-abs-poc
sh smoke.sh
sh catalog-smoke.sh
```

The Nextory TOML credentials, `.env`, bind mounts, `book-ids.txt`, `docker-compose.yml`, Docker image build settings and named state volume (including `progress.json` and `catalog.sqlite3`) are retained. Neither production Audiobookshelf nor the other `audiobook-dl-web` node is touched.

The smoke scripts may access **metadata, covers and HLS playlists**, but do not fetch audio segments. The catalog script calls an unofficial Nextory live search endpoint, so a provider network error can fail that separate test without necessarily breaking existing playback.

## iPhone acceptance

1. Fully close the Audiobookshelf app and reopen it. Because the mobile app caches library selections, if the old category libraries still appear, reconnect to this test server in the app. There should now be **one Nextory library**.
2. Select the **Collections** tab. You should see 20 category collections, including 'Nieuw ontdekt', 'Misdaad', 'Biografieen' and 'Fictie'. On first open, category contents are requested on demand and can initially take time, unlike the collection list itself. Empty collection covers until the first successful category scan are expected; reopening the category uses cached data.
3. Open an indexed book. Its main details should now return from SQLite without performing all HLS manifest requests. The first uncached cover may still require a remote image fetch. The full track list is returned when playback starts.
4. Press **Play once** and do not toggle pause. Test starting from the beginning, restarting at a saved position, and seeking across parts. Use the known books and an unpinned book.
5. If initial Play still stalls, capture the `POC_TIMING` messages and the recent `/public/session` and `/hls` HTTP status codes. This cannot be conclusively verified in local protocol tests: the iOS AVPlayer's initial asynchronous seek may fail, which a server-side timing improvement does not guarantee to fix.

## Quick diagnostics (no credentials)

```sh
clear 2>/dev/null || true
printf '=== SERVER ===\n'
docker compose ps nextory-abs-poc
printf '\n=== FIRST-PLAY TIMINGS ===\n'
docker logs --since 3m nextory-abs-poc 2>&1 | grep -E 'POC_TIMING|/public/session/|/hls/' | tail -45 | sed -E 's@(/hls/)[^ ]+@\1[REDACTED]@g; s@(/public/session/)[^ ]+@\1[REDACTED]@g'
```

## Rollback

The v6 updater prints the exact backup name. From the same project directory:

```sh
sh rollback.sh .poc-v5-backup-YYYYMMDD-HHMMSS-PID
```

This restores v5 application code and rebuilds only the test container. No credentials, saved book IDs, metadata index or listening progress are deleted.

## Limitations

- **No official complete catalog export**. Categories use Nextory's public product-page links with metadata verification; the categories and search API are unofficial and may change.
- **Category collections are not local immutable lists**. Their contents grow through on-demand page discovery and the existing background refresh. The list of 20 collection *names* appears immediately; an empty collection is not evidence that Nextory has no books in that category.
- **iOS first-play fix remains a hypothesis until on-device verification**. V6 removes an avoidable provider lookup at track entry; it does not patch the native iOS `AVQueuePlayer` or its initial `seek` callback.
- Server authentication and temporary HLS capability URLs are suitable for an isolated, trusted private network, not unguarded public internet exposure. Check applicable Nextory terms and permissions.

## Test evidence

Local Python unit/API tests use deterministic Nextory metadata and HTTP fixtures. Tests cover login, 34-part audio sessions, 20 collections in one library, cached item details, skipping provider requests in the initial track-entry route, session URL refresh after five minutes, HLS playlist rewrites and seek/progress persistence. There is no live Nextory or iPhone network in the build environment, and Docker rebuilds must be tested on the user's node.
