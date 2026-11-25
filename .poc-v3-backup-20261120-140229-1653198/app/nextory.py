"""Minimal authenticated Nextory lookup + passthrough transport for ONE real book.

This is an isolated POC. We do not decrypt, transcode, download or cache audio.
Provider credentials remain in the existing read-only audiobook-dl TOML mount.
Encrypted HLS, if present, is relayed unchanged to the user's media player.
"""

from __future__ import annotations

import ipaddress
import io
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

BOOK_ID = 7207495
CONFIG_PATH = Path(os.getenv("NEXTORY_CONFIG_PATH", "/run/nextory/audiobook-dl.toml"))
MAX_MANIFEST_BYTES = 512 * 1024
MAX_COVER_BYTES = 5 * 1024 * 1024
MAX_REDIRECTS = 4


class NextoryError(Exception):
    """Safe provider error: no token, URL or response body in messages."""


@dataclass(frozen=True)
class BookInfo:
    title: str
    authors: list[str]
    narrators: list[str]
    description: str
    language: str
    cover_url: str
    parts: list[dict]


@lru_cache(maxsize=64)
def _public_dns_host(host: str) -> bool:
    """Refuse local/private and malformed destinations (best-effort SSRF guard)."""
    if not host or len(host) > 253 or not all(c.isascii() and (c.isalnum() or c in '.-') for c in host):
        return False
    if host in {"localhost"} or host.endswith(('.local', '.internal', '.localhost')):
        return False
    try:
        ipaddress.ip_address(host)
        return False
    except ValueError:
        pass
    try:
        addresses = socket.getaddrinfo(host, 443, type=socket.SOCK_STREAM)
    except (OSError, socket.gaierror):
        return False
    if not addresses:
        return False
    return all(ipaddress.ip_address(item[4][0]).is_global for item in addresses)


def safe_remote_url(url: str) -> str:
    parsed = urlparse(url)
    host = (parsed.hostname or "").lower()
    if (parsed.scheme != "https" or parsed.username is not None or
            parsed.password is not None or parsed.port not in (None, 443) or
            len(url) > 8192 or not _public_dns_host(host)):
        raise NextoryError("Blocked unsafe media URL")
    return url


class NextoryBackend:
    def __init__(self):
        self._lock = threading.RLock()
        self._api = requests.Session()
        self._public = requests.Session()
        self._authed_at = 0.0
        self._book: BookInfo | None = None
        self._book_at = 0.0
        self._cover: bytes | None = None

    def _credentials(self) -> tuple[str, str]:
        try:
            with CONFIG_PATH.open("rb") as handle:
                config = tomllib.load(handle)
        except (OSError, ValueError, tomllib.TOMLDecodeError) as exc:
            raise NextoryError("Nextory config not mounted or unreadable") from exc
        sources = config.get("sources") or {}
        entry = next((value for key, value in sources.items() if key.lower() == "nextory"), None)
        if not isinstance(entry, dict) or not entry.get("username") or not entry.get("password"):
            raise NextoryError("Nextory credentials not configured in audiobook-dl.toml")
        return str(entry["username"]), str(entry["password"])

    def _ensure_login(self) -> None:
        # A conservative short session; provider may invalidate earlier.
        with self._lock:
            if time.monotonic() - self._authed_at < 20 * 60:
                return
            username, password = self._credentials()
            self._api.headers.clear()
            self._api.headers.update({
                "X-Application-Id": "200",
                "X-App-Version": (date.today() - relativedelta(months=2)).strftime("%Y-%-m-%-d")
                if os.name != "nt" else (date.today() - relativedelta(months=2)).strftime("%Y-%m-%d"),
                "X-Locale": "en_GB", "X-Model": "Personal Computer",
                "X-Device-Id": str(uuid.uuid3(uuid.NAMESPACE_DNS, "audiobook-dl")),
                "X-Os-Info": "ios",
            })
            def checked_json(resp: requests.Response, label: str) -> dict:
                if resp.status_code != 200:
                    raise NextoryError(f"Nextory {label} returned HTTP {resp.status_code}")
                try:
                    value = resp.json()
                except ValueError as exc:
                    raise NextoryError(f"Nextory {label} returned non-JSON") from exc
                if not isinstance(value, dict):
                    raise NextoryError(f"Nextory {label} returned unexpected JSON")
                return value
            try:
                resp = self._api.post("https://api.nextory.com/user/v1/sessions", json={"identifier": username, "password": password}, timeout=(8, 18), allow_redirects=False)
                data = checked_json(resp, "login")
                token, country = data.get("login_token"), data.get("country")
                if not token or not country:
                    raise NextoryError("Nextory login did not return account token and country")
                self._api.headers.update({"token": token, "X-Login-Token": token, "X-Country-Code": country})
                resp = self._api.get("https://api.nextory.com/user/v1/me/profiles", timeout=(8, 18), allow_redirects=False)
                profiles = checked_json(resp, "profiles").get("profiles")
                if not isinstance(profiles, list) or not profiles or not profiles[0].get("login_key"):
                    raise NextoryError("Nextory returned no usable profile")
                resp = self._api.post("https://api.nextory.com/user/v1/profile/authorize", json={"login_key": profiles[0]["login_key"]}, timeout=(8, 18), allow_redirects=False)
                profile_token = checked_json(resp, "profile authorize").get("profile_token")
                if not profile_token:
                    raise NextoryError("Nextory profile token missing")
                self._api.headers["X-Profile-Token"] = profile_token
                self._authed_at = time.monotonic()
            except requests.RequestException as exc:
                raise NextoryError(f"Network error during Nextory login ({type(exc).__name__})") from exc

    def get_book(self) -> BookInfo:
        with self._lock:
            if self._book is not None and time.monotonic() - self._book_at < 10 * 60:
                return self._book
            self._ensure_login()
            api_prefix = "https://api.nextory.com"
            info_resp = self._api.get(f"{api_prefix}/discovery/v1/product/{BOOK_ID}", timeout=(8, 18), allow_redirects=False)
            if info_resp.status_code != 200:
                self._authed_at = 0.0
                raise NextoryError(f"Nextory product HTTP {info_resp.status_code}")
            try:
                info = info_resp.json()
                assert int(info.get("id")) == BOOK_ID
                fmt = next(f for f in info["formats"] if f.get("type") == "hls")
                format_id = str(fmt["identifier"])
                if not format_id or len(format_id) > 120 or '/' in format_id or '..' in format_id:
                    raise ValueError("Invalid audio format identifier")
            except (ValueError, KeyError, TypeError, StopIteration, AssertionError) as exc:
                raise NextoryError("Nextory product has no valid HLS format") from exc
            package = self._api.get(f"{api_prefix}/reader/books/{quote(format_id, safe='')}/packages/audio", timeout=(8, 18), allow_redirects=False)
            if package.status_code != 200:
                raise NextoryError(f"Nextory audio package HTTP {package.status_code}")
            try:
                parts = package.json()["files"]
                if not isinstance(parts, list) or not parts or not isinstance(parts[0].get("uri"), str):
                    raise ValueError("Missing files")
                safe_remote_url(parts[0]["uri"])
            except (ValueError, KeyError, TypeError, IndexError) as exc:
                raise NextoryError("Nextory audio package has no usable HLS URL") from exc
            self._book = BookInfo(
                title=str(info.get("title") or "Hier gebeurt nooit iets"),
                authors=[str(x.get("name")) for x in info.get("authors", []) if x.get("name")],
                narrators=[str(x.get("name")) for x in info.get("narrators", []) if x.get("name")],
                description=str(info.get("description_full") or ""),
                language=str(info.get("language") or "nl"),
                cover_url=str(fmt.get("img_url") or ""),
                parts=parts,
            )
            self._book_at = time.monotonic()
            return self._book

    def remote_get(self, url: str, *, byte_range: str | None = None) -> requests.Response:
        """Return a streaming response. Caller MUST close it; never expose remote URLs."""
        headers = {"Accept": "*/*"}
        if byte_range and len(byte_range) < 80 and byte_range.startswith("bytes="):
            headers["Range"] = byte_range
        for _ in range(MAX_REDIRECTS + 1):
            safe_remote_url(url)
            host = urlparse(url).hostname
            # Never forward Nextory profile tokens to arbitrary CDN domains.
            session = self._api if host == "api.nextory.com" else self._public
            if host == "api.nextory.com":
                self._ensure_login()
            try:
                response = session.get(url, headers=headers, timeout=(8, 20), stream=True, allow_redirects=False)
            except requests.RequestException as exc:
                raise NextoryError(f"Nextory asset network error ({type(exc).__name__})") from exc
            if response.status_code in (301, 302, 303, 307, 308):
                location = response.headers.get("Location")
                response.close()
                if not location:
                    raise NextoryError("Asset redirect missing Location")
                url = urljoin(url, location)
                continue
            # Caller may read response.url for resolving relative manifest URLs; keep it internal.
            return response
        raise NextoryError("Too many Nextory asset redirects")

    def get_manifest(self, url: str) -> tuple[str, str]:
        response = self.remote_get(url)
        try:
            if response.status_code != 200:
                raise NextoryError(f"Nextory HLS manifest HTTP {response.status_code}")
            content = response.raw.read(MAX_MANIFEST_BYTES + 1, decode_content=True)
            if len(content) > MAX_MANIFEST_BYTES or not content.startswith(b"#EXTM3U"):
                raise NextoryError("Invalid/oversize HLS playlist")
            return content.decode("utf-8-sig"), response.url
        except UnicodeDecodeError as exc:
            raise NextoryError("Nextory HLS playlist is not UTF-8") from exc
        finally:
            response.close()

    def first_part_duration(self, url: str) -> float:
        """Calculate duration from first media playlist, without downloading audio."""
        from urllib.parse import urljoin
        for _ in range(5):
            manifest, final_url = self.get_manifest(url)
            if "#EXT-X-STREAM-INF" in manifest:
                lines = [line.strip() for line in manifest.splitlines() if line.strip()]
                for i, line in enumerate(lines[:-1]):
                    if line.startswith("#EXT-X-STREAM-INF"):
                        next_line = lines[i + 1]
                        if not next_line.startswith("#"):
                            url = urljoin(final_url, next_line)
                            break
                else:
                    raise NextoryError("No HLS variant found")
                continue
            durations = []
            for line in manifest.splitlines():
                if line.startswith("#EXTINF:"):
                    try:
                        durations.append(float(line.split(":", 1)[1].split(",", 1)[0]))
                    except ValueError as exc:
                        raise NextoryError("Invalid EXTINF in HLS playlist") from exc
            if not durations:
                raise NextoryError("No playable segments in media playlist")
            return sum(durations)
        raise NextoryError("Too many nested HLS manifests")

    def get_cover_jpeg(self) -> bytes:
        with self._lock:
            if self._cover is not None:
                return self._cover
            info = self.get_book()
            if not info.cover_url:
                raise NextoryError("Nextory product does not supply cover image")
            response = self.remote_get(info.cover_url)
            try:
                if response.status_code != 200:
                    raise NextoryError(f"Nextory cover HTTP {response.status_code}")
                body = response.raw.read(MAX_COVER_BYTES + 1, decode_content=True)
                if len(body) > MAX_COVER_BYTES:
                    raise NextoryError("Nextory cover image too large")
                with Image.open(io.BytesIO(body)) as img:
                    img = img.convert("RGB")
                    output = io.BytesIO()
                    img.save(output, format="JPEG", quality=86, optimize=True)
                    self._cover = output.getvalue()
                    return self._cover
            except (OSError, ValueError) as exc:
                raise NextoryError("Nextory cover image could not be decoded") from exc
            finally:
                response.close()


nextory = NextoryBackend()
