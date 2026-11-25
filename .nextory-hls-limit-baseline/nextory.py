"""Nextory product metadata and bounded, unchanged HLS relay.

No copyrighted audio is downloaded to disk, decrypted or transcoded. Catalog
searches and category previews request only metadata; audiobook parts remain
on-demand for opened titles.
"""
from __future__ import annotations

import io
import ipaddress
import logging
import math
import os
import socket
import threading
import time
import tomllib
import uuid
from dataclasses import dataclass
from datetime import date
from functools import lru_cache
from pathlib import Path
from urllib.parse import quote, urljoin, urlparse

import requests
from dateutil.relativedelta import relativedelta
from PIL import Image

CONFIG_PATH = Path(os.getenv('NEXTORY_CONFIG_PATH', '/run/nextory/audiobook-dl.toml'))
MAX_MANIFEST_BYTES = 512 * 1024
MAX_COVER_BYTES = 5 * 1024 * 1024
MAX_REDIRECTS = 4
MAX_PARTS = 256
CACHE_SECONDS = 5 * 60


class NextoryError(Exception):
    """Provider error with no credentials, signed media URLs or response bodies."""


@dataclass(frozen=True)
class BookInfo:
    book_id: int
    title: str
    authors: tuple[str, ...]
    narrators: tuple[str, ...]
    description: str
    language: str | None
    cover_url: str
    publisher: str | None
    isbn: str | None
    published_date: str | None
    series_name: str | None
    series_order: int | None
    subtitle: str | None
    genres: tuple[str, ...]
    parts: tuple[dict, ...]


@dataclass(frozen=True)
class TrackPart:
    index: int
    uri: str
    start: float
    duration: float
    title: str  # A technical part label unless Nextory provides a real title.


@lru_cache(maxsize=128)
def _public_dns_host(host: str) -> bool:
    if not host or len(host) > 253 or not all(c.isascii() and (c.isalnum() or c in '.-') for c in host):
        return False
    if host == 'localhost' or host.endswith(('.local', '.internal', '.localhost')):
        return False
    try:
        ipaddress.ip_address(host)
        return False  # No IP literals, including global IPs.
    except ValueError:
        pass
    try:
        addresses = socket.getaddrinfo(host, 443, type=socket.SOCK_STREAM)
    except OSError:
        return False
    return bool(addresses) and all(ipaddress.ip_address(entry[4][0]).is_global for entry in addresses)


def safe_remote_url(url: str) -> str:
    parsed = urlparse(url)
    hostname = (parsed.hostname or '').lower()
    if (parsed.scheme != 'https' or parsed.username or parsed.password or
            parsed.port not in (None, 443) or len(url) > 8192 or
            not _public_dns_host(hostname)):
        raise NextoryError('Blocked unsafe media URL')
    return url


def _strings_of_named(values: object) -> tuple[str, ...]:
    if not isinstance(values, list):
        return ()
    result = []
    for entry in values:
        name = entry.get('name') if isinstance(entry, dict) else None
        if isinstance(name, str) and name.strip():
            result.append(name.strip())
    return tuple(result)


class NextoryBackend:
    def __init__(self):
        self._lock = threading.RLock()
        self._api = requests.Session()
        self._public = requests.Session()
        self._authed_at = 0.0
        # Dedicated device identity for this test backend instance.
        self._device_id = str(uuid.uuid4())
        self._books: dict[int, tuple[BookInfo, float]] = {}
        self._layouts: dict[int, tuple[tuple[TrackPart, ...], float]] = {}
        self._covers: dict[int, tuple[bytes, float]] = {}

    def _credentials(self) -> tuple[str, str]:
        try:
            with CONFIG_PATH.open('rb') as handle:
                config = tomllib.load(handle)
        except (OSError, ValueError) as exc:
            raise NextoryError('Nextory TOML config not mounted or unreadable') from exc
        sources = config.get('sources') or {}
        entry = next((v for k, v in sources.items() if k.lower() == 'nextory'), None)
        if not isinstance(entry, dict) or not entry.get('username') or not entry.get('password'):
            raise NextoryError('Nextory credentials not configured in TOML')
        return str(entry['username']), str(entry['password'])

    def _checked_json(self, response: requests.Response, label: str) -> dict:
        if response.status_code != 200:
            raise NextoryError(f'Nextory {label} returned HTTP {response.status_code}')
        try:
            result = response.json()
        except ValueError as exc:
            raise NextoryError(f'Nextory {label} returned invalid JSON') from exc
        if not isinstance(result, dict):
            raise NextoryError(f'Nextory {label} returned unexpected JSON')
        return result

    def _ensure_login(self):
        with self._lock:
            if time.monotonic() - self._authed_at < 20 * 60:
                return
            username, password = self._credentials()
            self._api.headers.clear()
            compatible = date.today() - relativedelta(months=2)
            self._api.headers.update({
                'X-Application-Id': '200', 'X-App-Version': compatible.strftime('%Y-%m-%d'),
                'X-Locale': 'en_GB', 'X-Model': 'Personal Computer',
                'X-Device-Id': self._device_id,
                'X-Os-Info': 'ios',
            })
            try:
                resp = self._api.post('https://api.nextory.com/user/v1/sessions',
                                      json={'identifier': username, 'password': password},
                                      timeout=(8, 18), allow_redirects=False)
                data = self._checked_json(resp, 'login')
                token, country = data.get('login_token'), data.get('country')
                if not token or not country:
                    raise NextoryError('Nextory login did not return login token and country')
                self._api.headers.update({'token': token, 'X-Login-Token': token,
                                          'X-Country-Code': country})
                profiles = self._checked_json(self._api.get(
                    'https://api.nextory.com/user/v1/me/profiles',
                    timeout=(8, 18), allow_redirects=False), 'profiles').get('profiles')
                if not isinstance(profiles, list) or not profiles or not profiles[0].get('login_key'):
                    raise NextoryError('No usable Nextory profile')
                data = self._checked_json(self._api.post(
                    'https://api.nextory.com/user/v1/profile/authorize',
                    json={'login_key': profiles[0]['login_key']}, timeout=(8, 18),
                    allow_redirects=False), 'profile authorize')
                if not data.get('profile_token'):
                    raise NextoryError('Nextory profile token missing')
                self._api.headers['X-Profile-Token'] = data['profile_token']
                self._authed_at = time.monotonic()
            except requests.RequestException as exc:
                raise NextoryError(f'Network error during Nextory login ({type(exc).__name__})') from exc

    def _authenticated_get_json(self, url: str, label: str) -> dict:
        """NEXTORY_AUTH_RETRY: on HTTP 401 refresh profile auth exactly once.

        Caller holds the backend RLock so no concurrent request can replace
        the shared requests.Session credentials while we retry.
        """
        self._ensure_login()
        try:
            response = self._api.get(url, timeout=(8, 18), allow_redirects=False)
            if response.status_code == 401:
                response.close()
                logging.getLogger('uvicorn.error').warning(
                    'NEXTORY_AUTH_RETRY endpoint=%s initial_status=401', label)
                self._authed_at = 0.0
                self._api.cookies.clear()
                self._ensure_login()
                response = self._api.get(url, timeout=(8, 18), allow_redirects=False)
                logging.getLogger('uvicorn.error').info(
                    'NEXTORY_AUTH_RETRY endpoint=%s final_status=%d', label, response.status_code)
            return self._checked_json(response, label)
        except requests.RequestException as exc:
            raise NextoryError(
                f'Nextory {label} network error ({type(exc).__name__})'
            ) from exc

    def get_book(self, book_id: int) -> BookInfo:
        if isinstance(book_id, bool) or not isinstance(book_id, int) or not 10000 <= book_id <= 999999999999:
            raise NextoryError('Invalid Nextory book ID')
        with self._lock:
            cached = self._books.get(book_id)
            if cached and time.monotonic() - cached[1] < CACHE_SECONDS:
                return cached[0]
            self._ensure_login()
            prefix = 'https://api.nextory.com'
            try:
                info = self._authenticated_get_json(
                    f'{prefix}/discovery/v1/product/{book_id}', 'product')
                if int(info.get('id') or 0) != book_id:
                    raise NextoryError('Nextory returned a different product')
                formats = info.get('formats') or []
                fmt = next((f for f in formats if isinstance(f, dict) and f.get('type') == 'hls'), None)
                if not fmt:
                    raise NextoryError('Nextory book has no HLS audiobook format')
                format_id = fmt.get('identifier')
                if not isinstance(format_id, (str, int)) or not 1 <= len(str(format_id)) <= 120 or '/' in str(format_id) or '..' in str(format_id):
                    raise NextoryError('Invalid Nextory format identifier')
                audio = self._authenticated_get_json(
                    f'{prefix}/reader/books/{quote(str(format_id), safe="")}/packages/audio',
                    'audio package')
            except requests.RequestException as exc:
                raise NextoryError(f'Nextory catalog network error ({type(exc).__name__})') from exc
            except (TypeError, ValueError) as exc:
                raise NextoryError('Nextory product format is invalid') from exc
            parts = audio.get('files')
            if not isinstance(parts, list) or not 1 <= len(parts) <= MAX_PARTS:
                raise NextoryError('Nextory audio package has no valid parts')
            cleaned = []
            for i, part in enumerate(parts):
                if not isinstance(part, dict) or not isinstance(part.get('uri'), str):
                    raise NextoryError(f'Nextory audio part {i + 1} has no HLS URL')
                safe_remote_url(part['uri'])
                cleaned.append({'uri': part['uri'], 'start_at': part.get('start_at'),
                                'title': part.get('title') if isinstance(part.get('title'), str) else None})
            series = info.get('series') if isinstance(info.get('series'), dict) else {}
            publisher = fmt.get('publisher') if isinstance(fmt.get('publisher'), dict) else {}
            raw_volume = info.get('volume')
            try:
                sequence = int(raw_volume) if raw_volume is not None and not isinstance(raw_volume, bool) else None
                if sequence is not None and sequence <= 0:
                    sequence = None
            except (TypeError, ValueError):
                sequence = None
            published = fmt.get('publication_date')
            if not isinstance(published, str) or len(published) != 10:
                published = None
            result = BookInfo(
                book_id=book_id, title=str(info.get('title') or '').strip(),
                authors=_strings_of_named(info.get('authors')),
                narrators=_strings_of_named(info.get('narrators')),
                description=str(info.get('description_full') or ''),
                language=str(info.get('language') or '').strip() or None,
                cover_url=str(fmt.get('img_url') or ''),
                publisher=str(publisher.get('name') or '').strip() or None,
                isbn=str(fmt.get('isbn') or '').strip() or None,
                published_date=published,
                series_name=str(series.get('name') or '').strip() or None,
                series_order=sequence, subtitle=str(info.get('subtitle') or '').strip() or None,
                genres=_strings_of_named(info.get('genres')),
                parts=tuple(cleaned),
            )
            if not result.title:
                raise NextoryError('Nextory product has no title')
            self._books[book_id] = (result, time.monotonic())
            return result

    def peek_book_and_layout(self, book_id: int) -> tuple[BookInfo, tuple[TrackPart, ...]] | None:
        """Return memory cache without I/O; used only to enrich detail views."""
        with self._lock:
            b, tracks = self._books.get(book_id), self._layouts.get(book_id)
            if b and tracks and time.monotonic()-b[1] < CACHE_SECONDS and time.monotonic()-tracks[1] < CACHE_SECONDS:
                return b[0], tracks[0]
        return None

    def get_layout(self, book_id: int) -> tuple[TrackPart, ...]:
        """Obtain a precise whole-book timeline from Nextory's start_at values.

        Only playlist metadata is requested. When provider start_at values are
        missing/inconsistent, all durations are measured from HLS manifests.
        This slower fallback performs no audio downloads.
        """
        with self._lock:
            cached = self._layouts.get(book_id)
            if cached and time.monotonic() - cached[1] < CACHE_SECONDS:
                return cached[0]
            info = self.get_book(book_id)
            parts = info.parts
            try:
                first_duration = self.first_part_duration(parts[0]['uri'])
                final_duration = (self.first_part_duration(parts[-1]['uri'])
                                  if len(parts) > 1 else first_duration)
                # start_at is usually an offset in seconds. Some titles may omit
                # it: in that case measure all playlists instead of failing.
                try:
                    starts = [float(p['start_at']) for p in parts]
                    usable = (all(math.isfinite(s) and s >= 0 for s in starts) and
                              all(starts[i] > starts[i - 1] for i in range(1, len(starts))))
                except (TypeError, ValueError, KeyError, OverflowError):
                    starts, usable = [], False
                if usable and len(parts) > 1:
                    delta = starts[1] - starts[0]
                    usable = abs(delta - first_duration) <= max(5, first_duration * 0.025)
                # Spot-check mid-book and penultimate chapter timings. The iOS
                # seek offsets must agree with the actual HLS durations.
                if usable and len(parts) > 3:
                    for i in sorted({len(parts)//2, len(parts)-2}):
                        measured = self.first_part_duration(parts[i]['uri'])
                        delta = starts[i + 1] - starts[i]
                        if abs(delta-measured) > max(5, measured * 0.025):
                            usable = False
                            break
                if usable:
                    starts = [round(s - starts[0], 3) for s in starts]
                    durations = [round(starts[i+1] - starts[i], 3) for i in range(len(parts)-1)]
                    durations.append(round(final_duration, 3))
                else:
                    durations = [0.0] * len(parts)
                    durations[0] = first_duration
                    durations[-1] = final_duration
                    if len(parts) > 2:
                        # Keep the login/header lock re-entrant: media URLs may
                        # themselves be on api.nextory.com, so background worker
                        # threads here could deadlock on _ensure_login().
                        for i, part in enumerate(parts[1:-1], 1):
                            durations[i] = self.first_part_duration(part['uri'])
                    starts = []
                    elapsed = 0.0
                    for duration in durations:
                        starts.append(round(elapsed, 3))
                        elapsed += duration
            except (ValueError, TypeError, OverflowError) as exc:
                raise NextoryError('Nextory chapter timing is invalid') from exc
            if any(not math.isfinite(d) or d <= 0 or d > 24 * 3600 for d in durations):
                raise NextoryError('Nextory HLS part has invalid duration')
            result = tuple(TrackPart(i+1, p['uri'], starts[i], durations[i],
                                     (p['title'].strip() if isinstance(p['title'], str) and p['title'].strip()
                                      else f'Audiodeel {i + 1}'))
                           for i, p in enumerate(parts))
            self._layouts[book_id] = (result, time.monotonic())
            return result

    def remote_get(self, url: str, *, byte_range: str | None = None) -> requests.Response:
        headers = {'Accept': '*/*'}
        if byte_range and len(byte_range) < 80 and byte_range.startswith('bytes='):
            headers['Range'] = byte_range
        for _ in range(MAX_REDIRECTS + 1):
            safe_remote_url(url)
            host = urlparse(url).hostname
            if host == 'api.nextory.com':
                self._ensure_login()
            session = self._api if host == 'api.nextory.com' else self._public
            try:
                response = session.get(url, headers=headers, timeout=(8, 20),
                                       stream=True, allow_redirects=False)
            except requests.RequestException as exc:
                raise NextoryError(f'Nextory HLS network error ({type(exc).__name__})') from exc
            if response.status_code in (301, 302, 303, 307, 308):
                location = response.headers.get('Location')
                response.close()
                if not location:
                    raise NextoryError('Nextory asset redirect missing location')
                url = urljoin(url, location)
                continue
            return response
        raise NextoryError('Too many Nextory asset redirects')

    def get_manifest(self, url: str) -> tuple[str, str]:
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

    def first_part_duration(self, url: str) -> float:
        """Sum HLS EXTINF values, following the master playlist. No audio fetched."""
        for _ in range(5):
            manifest, final_url = self.get_manifest(url)
            if '#EXT-X-STREAM-INF' in manifest:
                lines = [line.strip() for line in manifest.splitlines() if line.strip()]
                for i, line in enumerate(lines[:-1]):
                    if line.startswith('#EXT-X-STREAM-INF'):
                        next_line = lines[i+1]
                        if next_line and not next_line.startswith('#'):
                            url = urljoin(final_url, next_line)
                            break
                else:
                    raise NextoryError('No usable HLS variant')
                continue
            durations = []
            for line in manifest.splitlines():
                if line.startswith('#EXTINF:'):
                    try:
                        durations.append(float(line.split(':', 1)[1].split(',', 1)[0]))
                    except ValueError as exc:
                        raise NextoryError('Invalid HLS segment duration') from exc
            if not durations:
                raise NextoryError('HLS media playlist has no audio segments')
            return round(sum(durations), 3)
        raise NextoryError('Too many nested HLS playlists')

    @staticmethod
    def _preview_from_product(info: dict) -> dict | None:
        """Metadata-only verified audiobook preview; does NOT request audio."""
        if not isinstance(info, dict) or not isinstance(info.get('formats'), list):
            return None
        fmt = next((f for f in info['formats'] if isinstance(f, dict) and
                    f.get('type') == 'hls' and f.get('state', 'ACTIVE') == 'ACTIVE'), None)
        if not fmt or not fmt.get('identifier'):
            return None
        try:
            book_id = int(info.get('id'))
            if not 10000 <= book_id <= 999999999999:
                return None
            duration = float(fmt.get('duration') or 0)
            if not math.isfinite(duration) or duration <= 0:
                duration = None
        except (ValueError, TypeError, OverflowError):
            return None
        title = str(info.get('title') or '').strip()
        if not title:
            return None
        series = info.get('series') if isinstance(info.get('series'), dict) else {}
        publisher = fmt.get('publisher') if isinstance(fmt.get('publisher'), dict) else {}
        try:
            series_order = int(info.get('volume')) if info.get('volume') else None
        except (ValueError, TypeError):
            series_order = None
        raw_cover = fmt.get('img_url') or ''
        cover_url = str(raw_cover).replace('{$width}', '600').replace('{$height}', '900')
        return {
            'book_id': book_id, 'title': title,
            'authors': list(_strings_of_named(info.get('authors'))),
            'narrators': list(_strings_of_named(info.get('narrators'))),
            'description': str(info.get('description_full') or info.get('blurb') or ''),
            'language': str(info.get('language') or '') or None,
            'cover_url': cover_url,
            'publisher': str(publisher.get('name') or '') or None,
            'isbn': str(fmt.get('isbn') or '') or None,
            'published_date': str(fmt.get('publication_date') or '') or None,
            'series_name': str(series.get('name') or '') or None,
            'series_order': series_order, 'duration': duration,
            'subtitle': str(info.get('subtitle') or '') or None,
            'genres': list(_strings_of_named(info.get('genres'))),
        }

    def get_product_preview(self, book_id: int) -> dict | None:
        """One authenticated Nextory product lookup, without fetching audio."""
        if not isinstance(book_id, int) or not 10000 <= book_id <= 999999999999:
            raise NextoryError('Invalid product ID')
        with self._lock:
            self._ensure_login()
            try:
                response = self._api.get(
                    f'https://api.nextory.com/discovery/v1/product/{book_id}',
                    timeout=(8, 18), allow_redirects=False)
                data = self._checked_json(response, 'product preview')
            except requests.RequestException as exc:
                raise NextoryError('Network error fetching product preview') from exc
            if str(data.get('id')) != str(book_id):
                raise NextoryError('Product preview ID mismatch')
            return self._preview_from_product(data)

    def search_catalog(self, phrase: str, page: int = 0, per: int = 20) -> list[dict]:
        """Nextory discovery API (unofficial), format=audiobook, paginated.

        Public adapter evidence: Vito0912/abs-agg, src/providers/nextory/index.ts.
        Never falls back to book-ID enumeration or bulk audio downloads.
        """
        if (not isinstance(phrase, str) or len(phrase) > 100 or
                page < 0 or page > 10000 or per < 1 or per > 50):
            raise NextoryError('Invalid Nextory search parameters')
        params = {'search_phrase': phrase, 'page': page, 'per': per,
                  'format': 'audiobook', 'sort': 'relevance'}
        with self._lock:
            self._ensure_login()
            url = 'https://api.nextory.com/discovery/v1/search/products/books'
            try:
                response = self._api.get(url, params=params,
                                         timeout=(8, 20), allow_redirects=False)
                if response.status_code != 200:
                    # The public web-client contract differs from the reader
                    # login session. No user tokens are sent on this fallback.
                    headers = {'X-Application-Id': '203', 'X-App-Version': '53.0',
                               'X-Country-Code': str(self._api.headers.get('X-Country-Code', 'NL')),
                               'X-Device-Id': str(uuid.uuid4()), 'X-Locale': 'nl_NL',
                               'X-Model': 'web', 'Origin': 'https://nextory.com',
                               'Referer': 'https://nextory.com/'}
                    response = self._public.get(url, params=params, headers=headers,
                                                timeout=(8, 20), allow_redirects=False)
                result = self._checked_json(response, 'search')
            except requests.RequestException as exc:
                raise NextoryError('Network error during Nextory search') from exc
            if not isinstance(result.get('products'), list):
                raise NextoryError('Nextory search response missing products')
            products = []
            for entry in result['products'][:per]:
                if not isinstance(entry, dict) or entry.get('media_type', 'book') != 'book':
                    continue
                mapped = self._preview_from_product(entry)
                if mapped:
                    products.append(mapped)
            return products

    def get_cover_jpeg(self, book_id: int, cover_url_hint: str | None = None) -> bytes:
        with self._lock:
            cached = self._covers.get(book_id)
            if cached and time.monotonic() - cached[1] < 60 * 60:
                return cached[0]
            preview = None if cover_url_hint else self.get_product_preview(book_id)
            cover_url = cover_url_hint or (preview['cover_url'] if preview else self.get_book(book_id).cover_url)
            if not cover_url:
                raise NextoryError('Nextory product has no cover URL')
            response = self.remote_get(cover_url)
            try:
                if response.status_code != 200:
                    raise NextoryError(f'Nextory cover HTTP {response.status_code}')
                body = response.raw.read(MAX_COVER_BYTES+1, decode_content=True)
                if len(body) > MAX_COVER_BYTES:
                    raise NextoryError('Nextory cover too large')
                with Image.open(io.BytesIO(body)) as image:
                    output = io.BytesIO()
                    image.convert('RGB').save(output, 'JPEG', quality=86, optimize=True)
                    jpeg = output.getvalue()
            except (OSError, ValueError) as exc:
                raise NextoryError('Nextory cover could not be decoded') from exc
            finally:
                response.close()
            self._covers[book_id] = (jpeg, time.monotonic())
            return jpeg


nextory = NextoryBackend()
