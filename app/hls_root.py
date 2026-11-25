"""NEXTORY_HLS_DIRECT_MEDIA_V1: simplify single-variant HLS roots.

No audio fetched, decrypted, transcoded or stored. The original encrypted
media segments and keys are still relayed through the same existing proxy.
When a master is complex, retain the original response unchanged.
"""
from __future__ import annotations

from urllib.parse import urljoin

from .hls_proxy import rewrite_playlist
from .nextory import safe_remote_url


def direct_media_playlist(fetch_manifest, root_url, session):
    """Return (rewritten_text|None, reason, segment_count), safely.

    Only flatten VOD masters with precisely one variant and no extra
    renditions, session keys, variable imports or master-level start tags.
    All other masters use the unchanged HLS code path.
    """
    master, final_url = fetch_manifest(root_url)
    lines = [line.strip() for line in master.splitlines() if line.strip()]
    if not lines or lines[0] != '#EXTM3U':
        return None, 'invalid_master', 0
    if not any(line.startswith('#EXT-X-STREAM-INF:') for line in lines):
        return None, 'already_media', 0
    unsafe_tags = ('#EXT-X-MEDIA:', '#EXT-X-I-FRAME-STREAM-INF:',
                   '#EXT-X-SESSION-KEY:', '#EXT-X-DEFINE:', '#EXT-X-START:')
    if any(line.startswith(unsafe_tags) for line in lines):
        return None, 'complex_master', 0
    variants = []
    for index, line in enumerate(lines):
        if not line.startswith('#EXT-X-STREAM-INF:'):
            continue
        if index + 1 >= len(lines) or lines[index+1].startswith('#'):
            return None, 'invalid_variant', 0
        variants.append(lines[index+1])
    if len(variants) != 1:
        return None, 'multiple_variants', len(variants)
    child_url = safe_remote_url(urljoin(final_url, variants[0]))
    if child_url == root_url:
        return None, 'loop', 0
    media, media_url = fetch_manifest(child_url)
    lines = [line.strip() for line in media.splitlines() if line.strip()]
    if (not lines or lines[0] != '#EXTM3U'
        or not any(s.startswith('#EXTINF:') for s in lines)
        or not any(s.startswith('#EXT-X-TARGETDURATION:') for s in lines)
        or '#EXT-X-ENDLIST' not in lines
        or any(s.startswith(('#EXT-X-STREAM-INF:', '#EXT-X-MEDIA:')) for s in lines)):
        return None, 'unsupported_media', 0
    count = sum(s.startswith('#EXTINF:') for s in lines)
    return rewrite_playlist(media, media_url, session), 'direct_media', count
