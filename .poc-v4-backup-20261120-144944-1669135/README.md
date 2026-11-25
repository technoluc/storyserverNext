# Nextory → Audiobookshelf iPhone | Virtual server v4

Version 4 extends the *working* v3 live POC. The existing Nextory product **7207495** and its existing Audiobookshelf item ID **572c4427-e49a-579d-b5bb-0b24729778bf** remain unchanged. The iOS app already played and sought within the first HLS part under v3.

## Changes

- The full Nextory audio package (e.g. all **34 real HLS parts** for product 7207495) is presented as sequential **Audiobookshelf direct-play `audioTracks`**. Each has a real duration and cumulative `startOffset`. Native iOS `AVQueuePlayer` queues these tracks, so it can seek across part boundaries without downloading or joining an audiobook.
- Nextory's actual product title, author(s), narrator(s), original description, audio-format cover, language, publisher, ISBN, publication date and series metadata are used when supplied. `chapters` are the **real audio-part time boundaries** with neutral labels `Audiodeel N` unless Nextory supplies an actual part title. These labels are **not** claims of authentic chapter titles.
- Author list and title/author search of the *configured test books*. This is NOT yet a general Nextory catalog browser.
- Add a second book by ID or a Nextory book URL using `sh add-book.sh ...`. The command verifies the actual Nextory HLS package before adding. `book-ids.txt` is read at each request, so a container rebuild/restart is not required.
- Each newly opened track refreshes its source URL via the short-lived Nextory product cache to reduce expiration during long playback.
- Current book progress (timestamps only; never audio or Nextory tokens) persists in a dedicated Docker named volume. Sessions still expire after idle 2 hours or an absolute 36 hours.
- Original Nextory HLS media and AES-128 references are **passed through unchanged**. No audio is downloaded to disk, decrypted, stored, transcoded or embedded in this project. No DRM bypass.

## Upgrade the EXISTING v3 POC on the Docker host

1. Upload this ZIP as `/tmp/nextory-abs-virtual-poc-v4.zip`.
2. Open a terminal **in your existing test project folder** (`docker-compose.yml`, `.env`, `app/main.py`). Do **not** use the real Audiobookshelf installation directory.
3. Run:

```sh
ZIP=/tmp/nextory-abs-virtual-poc-v4.zip
clear
unzip -p "$ZIP" nextory-abs-virtual-poc-v4/upgrade.sh | sh -s -- "$ZIP"
```

The updater checks prerequisites, creates `.poc-v3-backup-<timestamp>-<pid>/`, **preserves the existing `.env` and Nextory TOML**, creates `book-ids.txt` only if missing, rebuilds **only `nextory-abs-poc`**, and runs `sh smoke.sh`. All other Docker services are left unchanged. The same test account and test server address continue to work.

**Credentials remain on THIS node** in the existing read-only mount (`NEXTORY_CONFIG_SOURCE` in `.env` → `/run/nextory/audiobook-dl.toml`). Do not enter or re-upload Nextory credentials. The separate `audiobook-dl-web` node is not contacted.

### Add another real audiobook

From the same POC directory, run ONE of:

```sh
sh add-book.sh 7257862
# or, using an actual Nextory book link:
sh add-book.sh 'https://nextory.com/nl/book/<book-slug>-<book-id>'
```

The first number is a **candidate seen in the earlier public catalog probe**, not a confirmed playable audiobook. The script checks the actual Nextory HLS availability for your account and **refuses** to add a book that cannot be validated. It prints the title, authors, part count and duration from Nextory. Use any other confirmed Nextory audiobook URL if the candidate is unsupported.

Existing books continue to appear. In the Audiobookshelf app, switch away and back to the virtual library or relaunch the app if the list is cached. The new book has a stable unique item ID.

### Smoke test

```sh
clear
sh smoke.sh
```

This checks the configured books, genuine Nextory metadata, cover bytes, *all* HLS track descriptors, and the first + last HLS playlists. It does **not** request media segments or encryption keys and therefore does not itself demonstrate audible playback.

### iPhone acceptance test

1. Reopen **Hier gebeurt nooit iets** and check that the displayed total time is the **whole** book, not just 19 minutes.
2. Play near the end of audio part 1, allow the player to advance to part 2, then seek into a much later part and play/pause.
3. Close the book and reopen to check saved progress.
4. Add another selected book via `sh add-book.sh` and test its metadata/cover and audio, keeping the existing book intact.

A live iPhone test is still required for cross-part seek and track switching. The 13 offline tests verify API contract, metadata mapping, 34-track construction, session routes, HLS URI rewriting, byte ranges and persistent timestamp logic, but cannot replace the real iPhone + Nextory test.

## Security and operational limits

- POC runs on the local trusted network; default bind is loopback unless your existing `.env` binds LAN. If exposed externally, use HTTPS and a deliberate access-control design for HLS URLs. Session IDs and HLS paths are bearer capabilities. **Do not expose port 13378 directly to the public Internet.**
- `book-ids.txt` contains product IDs only. `.env` and Nextory TOML are never replaced during upgrade. The server runs as non-root UID 10001, Docker root filesystem is read-only and progress state uses a separate restricted named volume.
- Nextory's APIs here are unofficial and may change; provider access rights, contractual permissions and DRM protections are authoritative. There is no guarantee that all books are available as HLS, have valid chapter titles, or permit external playback.
- This is an independent test server, not a fork of Audiobookshelf. It is **not yet the complete Nextory catalog**; the library only lists IDs explicitly added for testing. No offline or permanent copies.
- Signed HLS URLs can expire while a particular segment is playing; the server refreshes them for newly opened tracks. That mitigates but does not eliminate expiration if Nextory uses very short-lived keys.

## Rollback to v3

The updater prints `BACKUP=.poc-v3-backup-...`. Within the same POC directory:

```sh
sh rollback.sh '.poc-v3-backup-YYYYMMDD-HHMMSS-PID'
```

The rollback tool restores saved project files and `.env`, then rebuilds only `nextory-abs-poc`. It does not delete the v4 named volume or any other services. Your separate Audiobookshelf and `audiobook-dl-web` installations remain untouched. The v4 `book-ids.txt` stays on the host, but v3 ignores it.
