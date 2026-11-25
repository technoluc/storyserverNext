"""Bounded, metadata-only Nextory discovery index.

The direct Nextory search endpoint supplies audiobook-only previews. Public
category pages supply paginated *candidate IDs*; each candidate is checked
against Nextory product metadata before appearing in Audiobookshelf.

No media packages, signed HLS URLs, keys, or login details are stored here.
"""
from __future__ import annotations

import html
import hashlib
import json
import os
import re
import sqlite3
import threading
import time
from contextlib import closing, contextmanager
from dataclasses import dataclass
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import urlparse
from uuid import uuid5, NAMESPACE_URL

import requests

from .nextory import NextoryError, nextory

DB_PATH = Path(os.getenv('CATALOG_DB', '/state/catalog.sqlite3'))
REFRESH_SECONDS = max(3600, int(os.getenv('CATALOG_REFRESH_SECONDS', '21600')))
WEB_TIMEOUT = (7, 15)
MAX_WEB_BYTES = 2 * 1024 * 1024
HOME_URLS = ('https://nextory.com/nl', 'https://nextory.com/nl/audiobooks',
             'https://nextory.com/nl/categories/books')
CATEGORIES = (
    ('misdaad', 'Misdaad', '/nl/category/books/misdaad-22'),
    ('biografie', 'Biografieën', '/nl/category/books/biografieen-en-reportages-31'),
    ('fictie', 'Fictie', '/nl/category/books/fictie-50'),
    ('feelgood', 'Feelgood en romantiek', '/nl/category/books/feelgood-en-romantiek-69'),
    ('ontwikkeling', 'Persoonlijke ontwikkeling', '/nl/category/books/persoonlijke-ontwikkeling-94'),
    ('kinderboeken', 'Kinderboeken', '/nl/category/books/kinderboeken-110'),
    ('waargebeurd', 'Waargebeurde verhalen', '/nl/category/books/waargebeurde-verhalen-155'),
    ('slapen', 'Slapen en relaxen', '/nl/category/books/slapen-en-relaxen-161'),
    ('spanning', 'Spanning', '/nl/category/books/spanning-170'),
    ('nonfictie', 'Non-fictie', '/nl/category/books/non-fictie-175'),
    ('maatschappij', 'Maatschappij en politiek', '/nl/category/books/maatschappij-en-politiek-226'),
    ('fantasy', 'Fantasy en sciencefiction', '/nl/category/books/fantasy-en-sciencefiction-235'),
    ('humor', 'Strips en humor', '/nl/category/books/strips-en-humor-249'),
    ('youngadult', 'Young Adult', '/nl/category/books/young-adult-tieners-265'),
    ('lifestyle', 'Lifestyle en hobby', '/nl/category/books/lifestyle-en-hobby-274'),
    ('klassiek', 'Klassieke fictie en poëzie', '/nl/category/books/klassieke-fictie-en-poezie-293'),
    ('makkelijk', 'Makkelijk lezen', '/nl/category/books/makkelijk-lezen-boeken-298'),
    ('horror', 'Horror', '/nl/category/books/horror-301'),
    ('erotiek', 'Erotiek', '/nl/category/books/erotiek-305'),
)
CATEGORY_PATHS = {code: path for code, _, path in CATEGORIES}
BOOK_HREF = re.compile(r'^/nl/book/[a-zA-Z0-9%\-]+-(\d{5,12})/?$')
COLLECTION_INITIAL_TARGET = 120
COLLECTION_GROWTH = 36
SOURCE_PAGES_PER_REQUEST = 6
CATEGORY_STALL_LIMIT = 3
CATEGORY_MAX_SOURCE_PAGES = 100
CATEGORY_FAILURE_COOLDOWN = 3600
PREVIEW_MISS_TTL = 7 * 86400


def is_dutch(language: str | None) -> bool:
    if not isinstance(language, str):
        return False
    language = language.strip().casefold().replace('_', '-')
    return (language in {'dutch', 'nederlands', 'flemish', 'vlaams'} or
            language.split('-', 1)[0] in {'nl', 'nld', 'dut'})


def item_id_for(book_id: int) -> str:
    # Preserve the legacy client ID when this title is discovered normally.
    if book_id == 7207495:
        return '572c4427-e49a-579d-b5bb-0b24729778bf'
    return str(uuid5(NAMESPACE_URL, f'nextory-abs-poc:item:{book_id}'))


class Links(HTMLParser):
    """Extract public /nl/book/...-123 IDs from actual <a href> links."""
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.books: list[int] = []
        self._seen: set[int] = set()
        self.category_links: list[tuple[str, str]] = []
        self._current: list[str] = []
        self._href: str | None = None

    def handle_starttag(self, tag, attrs):
        if tag != 'a':
            return
        href = dict(attrs).get('href', '')
        parsed = urlparse(href)
        if parsed.netloc and parsed.netloc not in ('nextory.com', 'www.nextory.com'):
            return
        candidate = parsed.path.rstrip('/')
        m = BOOK_HREF.fullmatch(candidate)
        if m:
            product = int(m.group(1))
            if product not in self._seen:
                self._seen.add(product)
                self.books.append(product)
        if candidate.startswith('/nl/category/books/') and len(candidate) < 180:
            self._href = candidate
            self._current = []

    def handle_data(self, data):
        if self._href:
            self._current.append(data)

    def handle_endtag(self, tag):
        if tag == 'a' and self._href:
            title = html.unescape(' '.join(self._current)).strip()
            if title and len(title) < 100:
                self.category_links.append((title, self._href))
            self._href = None
            self._current = []


def parse_book_ids(document: str) -> list[int]:
    parser = Links()
    parser.feed(document)
    return parser.books


@dataclass(frozen=True)
class CatalogPreview:
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
    duration: float | None
    subtitle: str | None
    genres: tuple[str, ...]

    @classmethod
    def from_dict(cls, data: dict):
        fields = dict(data)
        fields['authors'] = tuple(fields.get('authors') or ())
        fields['narrators'] = tuple(fields.get('narrators') or ())
        fields['genres'] = tuple(fields.get('genres') or ())
        return cls(**fields)

    def as_dict(self) -> dict:
        return {key: getattr(self, key) for key in self.__dataclass_fields__}


class CatalogIndex:
    def __init__(self, path: Path = DB_PATH):
        self.path = path
        self._lock = threading.RLock()
        self._category_locks = {key: threading.Lock() for key in CATEGORY_PATHS}
        self._web = requests.Session()
        self._web.headers.update({'User-Agent': 'NextoryABS-Discovery/0.5 (personal metadata index)',
                                  'Accept': 'text/html'})
        self._connect_and_init()

    @contextmanager
    def _connect(self):
        with closing(sqlite3.connect(str(self.path), timeout=10)) as con, con:
            con.row_factory = sqlite3.Row
            con.create_function('is_dutch', 1, is_dutch, deterministic=True)
            con.execute('PRAGMA busy_timeout=10000')
            yield con

    def _connect_and_init(self):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        with self._lock, self._connect() as con:
            con.execute('''CREATE TABLE IF NOT EXISTS books (
                id INTEGER PRIMARY KEY, item_id TEXT NOT NULL UNIQUE, metadata TEXT NOT NULL,
                first_seen REAL NOT NULL, last_seen REAL NOT NULL)''')
            con.execute('''CREATE VIEW IF NOT EXISTS dutch_books AS
                SELECT * FROM books WHERE is_dutch(json_extract(metadata, '$.language'))''')
            con.execute('''CREATE TABLE IF NOT EXISTS shelves (
                shelf TEXT NOT NULL, page INTEGER NOT NULL,
                position INTEGER NOT NULL, book_id INTEGER NOT NULL,
                PRIMARY KEY(shelf, page, book_id))''')
            con.execute('CREATE INDEX IF NOT EXISTS idx_shelves ON shelves(shelf,page,position)')
            con.execute('''CREATE TABLE IF NOT EXISTS scans (
                shelf TEXT NOT NULL, page INTEGER NOT NULL, scanned_at REAL NOT NULL,
                PRIMARY KEY(shelf, page))''')
            con.execute('CREATE TABLE IF NOT EXISTS stats (key TEXT PRIMARY KEY, value TEXT NOT NULL)')
            con.execute('CREATE TABLE IF NOT EXISTS preview_misses (book_id INTEGER PRIMARY KEY, checked_at REAL NOT NULL)')
            con.execute('CREATE TABLE IF NOT EXISTS category_pages (shelf TEXT NOT NULL, fingerprint TEXT NOT NULL, PRIMARY KEY(shelf,fingerprint))')

    def upsert(self, products: list[dict], shelf: str | None = None,
               page: int = 0, replace: bool = False) -> int:
        """Only authenticated Nextory HLS-audiobook previews are stored."""
        now = time.time()
        unique = {}
        for raw in products:
            try:
                preview = CatalogPreview.from_dict(raw)
                if (not 10000 <= preview.book_id <= 999999999999 or not preview.title
                        or not is_dutch(preview.language)):
                    continue
                unique[preview.book_id] = preview
            except (ValueError, TypeError, KeyError):
                continue
        with self._lock, self._connect() as con:
            new = 0
            for position, (book_id, preview) in enumerate(unique.items()):
                existing = con.execute('SELECT 1 FROM books WHERE id=?', (book_id,)).fetchone()
                if not existing:
                    new += 1
                con.execute('''INSERT INTO books(id, item_id, metadata, first_seen, last_seen)
                               VALUES(?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET
                               metadata=excluded.metadata, last_seen=excluded.last_seen''',
                            (book_id, item_id_for(book_id),
                             json.dumps(preview.as_dict(), ensure_ascii=False), now, now))
                if shelf:
                    con.execute('''INSERT INTO shelves(shelf,page,position,book_id)
                                   VALUES(?,?,?,?) ON CONFLICT(shelf,page,book_id) DO UPDATE SET
                                   position=excluded.position''',
                                (shelf, page, position, book_id))
            if shelf and replace:
                if unique:
                    ids = list(unique)
                    placeholders = ','.join('?' for _ in ids)
                    con.execute(f'''DELETE FROM shelves WHERE shelf=? AND page=?
                                    AND book_id NOT IN ({placeholders})''',
                                (shelf, page, *ids))
                else:
                    con.execute('DELETE FROM shelves WHERE shelf=? AND page=?', (shelf, page))
                con.execute('''INSERT OR REPLACE INTO scans(shelf,page,scanned_at)
                               VALUES(?,?,?)''', (shelf, page, now))
        return new

    def lookup(self, book_id: int, *, dutch_only: bool = True) -> CatalogPreview | None:
        table = 'dutch_books' if dutch_only else 'books'
        with self._lock, self._connect() as con:
            row = con.execute(f'SELECT metadata FROM {table} WHERE id=?', (book_id,)).fetchone()
        return CatalogPreview.from_dict(json.loads(row['metadata'])) if row else None

    def resolve_item(self, item_id: str) -> int | None:
        with self._lock, self._connect() as con:
            row = con.execute("SELECT id FROM dutch_books WHERE item_id=?", (item_id,)).fetchone()
        return int(row[0]) if row else None

    def select(self, shelf: str = 'all', page: int = 0, limit: int = 20):
        with self._lock, self._connect() as con:
            if shelf == 'all':
                query = 'SELECT metadata FROM dutch_books ORDER BY first_seen DESC,id DESC'
                count = con.execute('SELECT COUNT(*) FROM dutch_books').fetchone()[0]
                rows = con.execute(query + ' LIMIT ? OFFSET ?', (limit, page*limit)).fetchall()
            elif shelf == 'new':
                count = con.execute("""SELECT COUNT(DISTINCT s.book_id) FROM shelves s
                                    JOIN dutch_books b ON b.id=s.book_id WHERE s.shelf='recent'""").fetchone()[0]
                rows = con.execute('''SELECT b.metadata FROM dutch_books b INNER JOIN
                                      (SELECT book_id, MAX(page) AS p FROM shelves
                                      WHERE shelf='recent' GROUP BY book_id) x ON x.book_id=b.id
                                      ORDER BY b.first_seen DESC,b.id DESC LIMIT ? OFFSET ?''',
                                   (limit, page*limit)).fetchall()
            else:
                count = con.execute('''SELECT COUNT(DISTINCT s.book_id) FROM shelves s
                                    JOIN dutch_books b ON b.id=s.book_id WHERE s.shelf=?''', (shelf,)).fetchone()[0]
                rows = con.execute('''SELECT b.metadata FROM dutch_books b INNER JOIN (
                                      SELECT book_id, MIN(page*1000+position) AS rank
                                      FROM shelves WHERE shelf=? GROUP BY book_id
                                      ) x ON b.id=x.book_id ORDER BY x.rank
                                      LIMIT ? OFFSET ?''', (shelf, limit, page*limit)).fetchall()
        return [CatalogPreview.from_dict(json.loads(r['metadata'])) for r in rows], count

    def select_all_offset(self, offset: int, limit: int, exclude_ids: tuple[int, ...] = ()):
        """Return a cursor slice over indexed titles."""
        if not 0 <= offset <= 1000000 or not 0 <= limit <= 1000:
            raise ValueError('Invalid catalog slice')
        with self._lock, self._connect() as con:
            where = ('WHERE id NOT IN (' + ','.join('?' for _ in exclude_ids) + ')') if exclude_ids else ''
            count = con.execute('SELECT COUNT(*) FROM dutch_books ' + where, exclude_ids).fetchone()[0]
            rows = con.execute('SELECT metadata FROM dutch_books ' + where +
                               ' ORDER BY first_seen DESC,id DESC LIMIT ? OFFSET ?',
                               (*exclude_ids, limit, offset)).fetchall()
        return [CatalogPreview.from_dict(json.loads(r['metadata'])) for r in rows], count

    def category_has_more(self, shelf: str) -> bool:
        if not shelf.startswith('category:'):
            return False
        with self._lock, self._connect() as con:
            exhausted = con.execute('SELECT 1 FROM stats WHERE key IN (?,?)', ('end:' + shelf, 'pause:' + shelf)).fetchone()
        return not bool(exhausted)

    def last_scan(self, shelf: str, page: int = 0) -> float:
        with self._lock, self._connect() as con:
            r = con.execute('SELECT scanned_at FROM scans WHERE shelf=? AND page=?', (shelf,page)).fetchone()
        return float(r[0]) if r else 0

    def statistics(self) -> dict:
        with self._lock, self._connect() as con:
            count = con.execute('SELECT COUNT(*) FROM dutch_books').fetchone()[0]
            recent = con.execute("""SELECT COUNT(DISTINCT s.book_id) FROM shelves s
                                 JOIN dutch_books b ON b.id=s.book_id WHERE s.shelf='recent'""").fetchone()[0]
            scans = con.execute('SELECT shelf,page,scanned_at FROM scans ORDER BY scanned_at DESC LIMIT 8').fetchall()
            row = con.execute("SELECT value FROM stats WHERE key='error'").fetchone()
            paused = con.execute("SELECT key,value FROM stats WHERE key LIKE 'pause:category:%'").fetchall()
        return {'indexedAudiobooks': count, 'recentlyDiscovered': recent,
                'lastScans': [dict(r) for r in scans], 'lastError': row[0] if row else None,
                'refreshSeconds': REFRESH_SECONDS, 'pausedCategories': {r[0].removeprefix('pause:category:'): r[1] for r in paused}}

    def _set_error(self, message: str):
        # Never persist Nextory tokens, credentials, or raw upstream responses.
        safe = re.sub(r'https?://\S+', '[URL]', message)[:160]
        with self._lock, self._connect() as con:
            con.execute("INSERT OR REPLACE INTO stats(key,value) VALUES('error',?)", (safe,))

    def _fetch_public(self, url: str) -> str:
        parsed = urlparse(url)
        if parsed.scheme != 'https' or parsed.netloc != 'nextory.com' or not parsed.path.startswith('/nl'):
            raise NextoryError('Invalid public Nextory discovery URL')
        try:
            with self._web.get(url, timeout=WEB_TIMEOUT, stream=True, allow_redirects=False) as response:
                if response.status_code != 200:
                    raise NextoryError(f'Public Nextory catalogue HTTP {response.status_code}')
                body = response.raw.read(MAX_WEB_BYTES + 1, decode_content=True)
                if len(body) > MAX_WEB_BYTES:
                    raise NextoryError('Public Nextory catalogue page too large')
                return body.decode('utf-8-sig', errors='replace')
        except requests.RequestException as exc:
            raise NextoryError('Network error fetching public Nextory catalogue') from exc

    def _hydrate(self, ids: list[int], max_new: int = 40) -> list[dict]:
        previews = []
        for n in dict.fromkeys(ids):
            cached = self.lookup(n, dutch_only=False)
            if cached:
                if is_dutch(cached.language):
                    previews.append(cached.as_dict())
                continue
            with self._lock, self._connect() as con:
                miss = con.execute('SELECT checked_at FROM preview_misses WHERE book_id=?', (n,)).fetchone()
            if miss and miss[0] > time.time() - PREVIEW_MISS_TTL:
                continue
            if max_new <= 0:
                break
            max_new -= 1
            # Fail the page on transient or authorization errors; never retry every ID.
            preview = nextory.get_product_preview(n)
            if preview and is_dutch(preview.get('language')):
                previews.append(preview)
                self.upsert([preview])
            else:
                with self._lock, self._connect() as con:
                    con.execute('INSERT OR REPLACE INTO preview_misses VALUES(?,?)', (n, time.time()))
            time.sleep(0.12)  # Bounded politeness for upstream metadata calls.
        return previews

    def refresh_recent(self) -> dict:
        """Scan live discovery pages. Not a full-catalog dump; zero audio downloads."""
        if self.last_scan('recent') > time.time() - REFRESH_SECONDS:
            return {'status': 'cached', **self.statistics()}
        candidates = []
        failures = []
        for url in HOME_URLS:
            try:
                candidates.extend(parse_book_ids(self._fetch_public(url)))
            except (NextoryError, requests.RequestException) as exc:
                failures.append(type(exc).__name__)
        ids = list(dict.fromkeys(candidates))[:70]
        products = self._hydrate(ids, max_new=55)
        source = 'public-pages'
        # Public links can be missing or point only to unavailable titles.
        if not products:
            try:
                products = search_dutch_catalog('', limit=30)
                source = 'nextory-search'
            except NextoryError as exc:
                failures.append(type(exc).__name__)
        if not products:
            message = 'Nextory discovery returned no accessible audiobooks'
            self._set_error(message + (': ' + ', '.join(failures) if failures else ''))
            raise NextoryError(message)
        self.upsert(products, 'recent', 0, replace=True)
        with self._lock, self._connect() as con:
            con.execute("DELETE FROM stats WHERE key='error'")
        return {'status': 'ok', 'source': source, **self.statistics()}

    def ensure_category(self, key: str, requested_page: int, limit: int = 20):
        if key not in CATEGORY_PATHS:
            raise NextoryError('Unknown Nextory catalogue category')
        with self._category_locks[key]:
            self._scan_category(key, (requested_page+1)*limit)

    def fill_next_category_page(self, key: str) -> tuple[int, int] | None:
        """Fill one source page per turn so all genres can make progress."""
        lock = self._category_locks[key]
        if not lock.acquire(blocking=False):
            return None
        try:
            with self._lock, self._connect() as con:
                retry = con.execute('SELECT value FROM stats WHERE key=?', ('retry:category:' + key,)).fetchone()
            if retry and float(retry[0]) > time.time():
                return None
            try:
                return self._scan_category(key, target=None, page_budget=1)
            except (NextoryError, OSError, ValueError, sqlite3.Error):
                with self._lock, self._connect() as con:
                    con.execute('INSERT OR REPLACE INTO stats VALUES(?,?)', ('retry:category:' + key, str(time.time() + CATEGORY_FAILURE_COOLDOWN)))
                raise
        finally:
            lock.release()

    def _scan_category(self, key: str, target: int | None,
                       page_budget: int = SOURCE_PAGES_PER_REQUEST) -> tuple[int, int] | None:
        shelf = 'category:' + key
        if not self.category_has_more(shelf):
            return None
        if target is not None and self.select(shelf, 0, 1)[1] >= target:
            return None
        with self._lock, self._connect() as db:
            first = db.execute('SELECT COALESCE(MAX(page), 0) + 1 FROM scans WHERE shelf=?',
                               (shelf,)).fetchone()[0]
        last_saved = None
        def pause(reason: str):
            with self._lock, self._connect() as con:
                con.execute('INSERT OR REPLACE INTO stats VALUES(?,?)', ('pause:' + shelf, reason))
        if first > CATEGORY_MAX_SOURCE_PAGES:
            pause('source-page-limit')
            return None
        for source_page in range(first, min(first + page_budget, CATEGORY_MAX_SOURCE_PAGES + 1)):
            uri = 'https://nextory.com' + CATEGORY_PATHS[key]
            if source_page > 1:
                uri += '?page=' + str(source_page)
            ids = parse_book_ids(self._fetch_public(uri))
            if not ids:
                if source_page == 1:
                    # A public site's anti-bot/error HTML can return HTTP 200.
                    # Never permanently index that as an empty category.
                    self._set_error('Category page has no verifiable book links: ' + key)
                    raise NextoryError('Nextory category page contains no book links')
                # A subsequent empty page means this category is exhausted.
                self.upsert([], shelf, source_page, replace=True)
                with self._lock, self._connect() as con:
                    con.execute('INSERT OR REPLACE INTO stats(key,value) VALUES(?,?)',
                                ('end:' + shelf, str(source_page)))
                return last_saved
            fingerprint = hashlib.sha256(','.join(map(str, sorted(set(ids)))).encode()).hexdigest()
            with self._lock, self._connect() as con:
                repeated = con.execute('SELECT 1 FROM category_pages WHERE shelf=? AND fingerprint=?', (shelf, fingerprint)).fetchone()
                row = con.execute('SELECT value FROM stats WHERE key=?', ('stall:' + shelf,)).fetchone()
            if repeated:
                pause('repeated-source-page')
                return last_saved
            if len(set(ids)) > 100:
                pause('source-page-candidate-limit')
                return last_saved
            before = self.select(shelf, 0, 1)[1]
            products = self._hydrate(ids, max_new=100)
            self.upsert(products, shelf, source_page, replace=True)
            count = self.select(shelf, 0, 1)[1]
            stall = (int(row[0]) if row else 0) + 1 if count <= before else 0
            with self._lock, self._connect() as con:
                con.execute('INSERT OR IGNORE INTO category_pages VALUES(?,?)', (shelf, fingerprint))
                con.execute('INSERT OR REPLACE INTO stats VALUES(?,?)', ('stall:' + shelf, str(stall)))
            last_saved = (source_page, count)
            if stall >= CATEGORY_STALL_LIMIT:
                pause('no-new-category-books')
                return last_saved
            if target is not None and count >= target:
                break
        return last_saved


def search_dutch_catalog(query: str, limit: int = 30) -> list[dict]:
    results = {}
    for page in range(3):
        try:
            previews = nextory.search_catalog(query, page=page, per=50)
        except NextoryError:
            if not results:
                raise
            break
        if not previews:
            break
        for preview in previews:
            if is_dutch(preview.get('language')):
                results.setdefault(preview['book_id'], preview)
                if len(results) == limit:
                    return list(results.values())
    return list(results.values())


catalog_index = CatalogIndex()
