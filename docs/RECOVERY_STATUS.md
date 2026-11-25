# Recovery status

This page describes the original recovered snapshot. For the current Compose setup, see the [README](../README.md).

Recovered on 25 November 2026 from the available ChatGPT export and the previously generated `nextory-abs-virtual-poc-test-sanitized.zip` snapshot.

This repository is an archival proof of concept, not a production release. It contains no `.env`, provider credential file, state database, downloaded audiobook, media key, access token, or refresh token. Runtime credentials must remain outside Git and are mounted read-only by Docker Compose.

No new media-protection bypass was added during recovery. The code is preserved as found in the sanitized snapshot.

## Revision choice

The newest recovered code is implementation **G**: a classic virtual M4B whose byte offsets are deterministic because it uses fixed-size ALAC packets. It is the active code in `app/main.py`, `app/fixed_m4b.py`, `app/hls_proxy.py`, and the Dockerfile. The recovered G snapshot is intentionally restricted to book ID `7207495` and the AudioBooth client.

“Latest working” needs two separate meanings:

- **Latest code with partial live evidence:** G. A later captured log showed a real playback session starting and chunks 0–5 being generated on demand.
- **Latest architecture with live end-to-end seek evidence:** F. The ten-hour synthetic classic M4A started in roughly 1–2 seconds and sought directly to about eight hours without generating the preceding media.

The repository therefore preserves G as the latest actual snapshot, while F remains the strongest verified reference milestone.

## Evidence by milestone

| Milestone | What is supported by available evidence | Status |
|---|---|---|
| v1/v2 | Audiobookshelf-compatible login, metadata, cover, and session contract through local tests; iPhone login/details subsequently worked | Verified for stated scope |
| v3 | On-demand playback of the first Nextory HLS part and seek on the user's iPhone | Live verified |
| v4 | Complete 34-part book and a direct jump to a middle chapter | Live verified |
| v5/v6 | Search/catalog/collections and faster metadata/detail paths; first Play still required Pause → Play in AudioBooth | Mixed: features verified, first-Play issue unresolved |
| A | Direct M4A started immediately | Live verified |
| B/C | Synthetic HLS MPEG-TS and HLS fMP4 both reproduced the AudioBooth first-Play problem | Live verified |
| D | Short virtual indexed M4A with HTTP Range started directly | Live verified |
| E | Ten-hour fragmented virtual MP4 was locally readable/seekable but did not start audio in AudioBooth | Live failure, retained as evidence |
| F | Ten-hour classic virtual M4A with a complete sample index started and late-seeked successfully | Live verified reference |
| G | Real source session opened; classic virtual M4B header/ranges and early chunk generation worked | First playback verified; late seek unverified |

## Checks reproducible from this snapshot

- The recovered archive contains 158 files (before this recovery documentation was added) and approximately 4.27 MB of source, fixtures, scripts, and historical baselines.
- All recovered Python files parse successfully with the local Python compiler.
- The tree contains 25 ordinary pytest test functions plus additional assertions embedded in the patch scripts.
- The source contains no committed `.env`, `audiobook-dl.toml`, state directory, or full downloaded audiobook.

The historic claims of 36/36 focused tests and 152 passing regressions cannot be independently reproduced from this snapshot because the complete suite is not present. The original runtime host, containers, volumes, and `/state` contents are also unavailable here.

## Chat-history coverage

The referenced branch itself exposes only five recent turns and no downloadable attachments. A separate recovered Markdown export contains the long main development conversation and was sufficient to reconstruct the milestone sequence. It is not guaranteed to be a byte-for-byte complete account history: some branch context, screenshots, runtime logs, and historical ZIP/patch downloads are absent. The transcript is not committed because it may contain unrelated or sensitive conversational material.

## Known open work

- Live late seek, pause/resume, chapter boundaries, disconnect behavior, and long-running reliability for G.
- A generic authorized-source interface; current source integration is project-specific.
- The planned bounded 30 GB disk cache; the current G cache is an 8 MiB in-memory LRU per session.
- Load, CPU, source-bandwidth, cache-hit, and audio-quality measurements.
- Reliable handling of expired upstream playback URLs during long sessions.
- Production security review and deployment hardening.

## Safe-use boundary

This snapshot should only be used with media and playback interfaces the operator is authorized to access and process. It is not an official Nextory or Audiobookshelf integration. Do not add code that extracts provider secrets, exports media keys, defeats access controls, or retains content beyond applicable permissions.
