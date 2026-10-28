#!/usr/bin/env python3
"""EK Instrumentation | PM & Gas receiver, ESP32 Classic compatible.

Python standard library only, port 8787. Features:
- Every unique ESP event is persisted in SQLite (even outside REC).
- Flexible REC: manual stop or persisted scheduled automatic stop.
- Name a session and change its label without stopping the recording.
- CSV merged by SENSOR MEASUREMENT timestamp, not arrival time; raw SQLite preserved.
- Per-reading session name + label retained; raw CSV export remains available.
- Data for six charts, 1s polling handled in index.html.

Designed for trusted private LANs; HTTP endpoints have no user login.
"""
import csv
import hmac
import ipaddress
import shutil
import datetime as dt
import io
import json
import math
import os
from pathlib import Path
import re
import sqlite3
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

ROOT = Path(__file__).resolve().parent
# All persisted state lives under a single data/ directory. Installer updates code only.
DATA = ROOT / 'data'
RECORDS = DATA / 'records'
DB = DATA / 'monitoring.sqlite3'
DELETE_PASSWORD = os.getenv('EK_DELETE_PASSWORD', 'ekinstru')  # Local-admin deletion password.
DATA.mkdir(parents=True, exist_ok=True)
RECORDS.mkdir(parents=True, exist_ok=True)


def migrate_legacy_storage():
    """Copy/migrate REV5-REV8 data from project root; preserve a local recovery copy."""
    legacy_db = ROOT / 'monitoring.sqlite3'
    if legacy_db.is_file() and not DB.exists():
        # SQLite's backup API includes committed WAL transactions.
        with sqlite3.connect(str(legacy_db)) as source, sqlite3.connect(str(DB)) as target:
            source.backup(target)
        # Keep original database files together under data/ (not in app root).
        archive = DATA / 'legacy_backup'
        archive.mkdir(exist_ok=True)
        for suffix in ('', '-wal', '-shm'):
            old = Path(str(legacy_db) + suffix)
            if old.exists():
                shutil.move(str(old), str(archive / old.name))
        print(f'Old database migrated into {DB}', flush=True)
    legacy_records = ROOT / 'records'
    if legacy_records.is_dir() and legacy_records != RECORDS:
        for old in legacy_records.glob('*.csv'):
            dest = RECORDS / old.name
            if not dest.exists():
                shutil.copy2(old, dest)
        archive_records = DATA / 'legacy_backup' / 'records'
        archive_records.mkdir(parents=True, exist_ok=True)
        for old in legacy_records.glob('*.csv'):
            shutil.move(str(old), str(archive_records / old.name))
        try:
            legacy_records.rmdir()
        except OSError:
            pass

PORT = int(os.getenv('ESP_LAN_PORT', '8787'))
TOKEN = os.getenv('ESP_LAN_TOKEN', '')
LOCK = threading.RLock()
PM_FIELDS = ['pm1_pms1', 'pm25_pms1', 'pm10_pms1', 'pm1_pms2', 'pm25_pms2', 'pm10_pms2', 'suhu', 'kelembapan']
GAS_FIELDS = ['co_ppm', 'co2_ppm', 'no2_ppm', 'suhu_c', 'rh_pct', 'red_v', 'nox_v', 'red_ratio', 'nox_ratio']
FIELDS = {'pm': PM_FIELDS, 'gas': GAS_FIELDS}
# Keep existing columns for backward compatibility, append new session metadata.
COLS = ['received_at', 'timestamp', 'event_id', 'device_id', 'device_type', 'sample_name', 'uptime_ms'] + PM_FIELDS + GAS_FIELDS + ['session_name', 'label']
# Six leading analysis columns (PM averages are calculated from the two PMS5003T units).
# Every original sensor field is retained, without device_id/device_type columns.
MERGED_COLS = (
    ['time_utc', 'session_name', 'label', 'sync_status', 'time_basis']
    + ['pm1_avg', 'pm25_avg', 'pm10_avg', 'co_ppm', 'co2_ppm', 'no2_ppm']
    + PM_FIELDS
    + ['gas_' + key for key in GAS_FIELDS[3:]]
    + ['pm_sample_name', 'gas_sample_name', 'pm_uptime_ms', 'gas_uptime_ms']
)
MAX_DURATION_SECONDS = 7 * 24 * 60 * 60


def clock():
    return dt.datetime.now(dt.timezone.utc)


def iso(moment=None):
    return (moment or clock()).isoformat(timespec='milliseconds').replace('+00:00', 'Z')


def parse_utc(raw):
    if not raw:
        return None
    value = dt.datetime.fromisoformat(raw.replace('Z', '+00:00'))
    return value if value.tzinfo else value.replace(tzinfo=dt.timezone.utc)


def db_connect():
    conn = sqlite3.connect(DB, timeout=15)
    conn.execute('PRAGMA busy_timeout=15000')
    conn.row_factory = sqlite3.Row
    return conn


def init_db():
    migrate_legacy_storage()
    with db_connect() as c:
        c.execute('PRAGMA journal_mode=WAL')
        c.execute('CREATE TABLE IF NOT EXISTS sessions (id INTEGER PRIMARY KEY AUTOINCREMENT, started_at TEXT NOT NULL, stopped_at TEXT)')
        session_cols = {x[1] for x in c.execute('PRAGMA table_info(sessions)')}
        for key, sql_type in [('name', "TEXT NOT NULL DEFAULT ''"),
                              ('label', "TEXT NOT NULL DEFAULT ''"),
                              ('duration_seconds', 'INTEGER'),
                              ('scheduled_stop_at', 'TEXT'),
                              ('stop_reason', 'TEXT')]:
            if key not in session_cols:
                c.execute(f'ALTER TABLE sessions ADD COLUMN {key} {sql_type}')
        c.execute('''CREATE TABLE IF NOT EXISTS readings (
            event_id TEXT PRIMARY KEY, device_id TEXT NOT NULL, device_type TEXT NOT NULL,
            received_at TEXT NOT NULL, timestamp TEXT, uptime_ms INTEGER,
            sample_name TEXT NOT NULL, measurements TEXT NOT NULL,
            session_id INTEGER, label TEXT NOT NULL DEFAULT '')''')
        cols = {x[1] for x in c.execute('PRAGMA table_info(readings)')}
        if 'session_id' not in cols:
            c.execute('ALTER TABLE readings ADD COLUMN session_id INTEGER')
        if 'label' not in cols:
            c.execute("ALTER TABLE readings ADD COLUMN label TEXT NOT NULL DEFAULT ''")
        c.execute('CREATE INDEX IF NOT EXISTS idx_readings_recv ON readings(received_at)')
        c.execute('CREATE INDEX IF NOT EXISTS idx_readings_sess ON readings(session_id)')
        c.execute('CREATE INDEX IF NOT EXISTS idx_readings_type ON readings(device_type)')
        c.execute('CREATE TABLE IF NOT EXISTS label_events (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id INTEGER NOT NULL, changed_at TEXT NOT NULL, label TEXT NOT NULL)')


def active_session(c):
    row = c.execute('''SELECT id, started_at, name, label, duration_seconds, scheduled_stop_at
                       FROM sessions WHERE stopped_at IS NULL ORDER BY id DESC LIMIT 1''').fetchone()
    return dict(row) if row else None


def safe_csv_cell(v):
    if v is None:
        return ''
    if isinstance(v, (int, float)) and not isinstance(v, bool):
        return v
    s = str(v)
    # Prevent CSV formula injection in common spreadsheet programs.
    return "'" + s if s.lstrip().startswith(('=', '+', '-', '@')) else s


def csv_row(r):
    rec = dict(r)
    measurements = rec.get('measurements', {})
    if isinstance(measurements, str):
        measurements = json.loads(measurements)
    return [safe_csv_cell(rec[k] if k in rec else measurements.get(k)) for k in COLS]


def row_query(where='', order='ORDER BY readings.rowid', params=()):
    # Alias preserves single source for session_name in all CSV exports.
    return f'''SELECT readings.*, COALESCE(sessions.name, '') AS session_name
               FROM readings LEFT JOIN sessions ON sessions.id=readings.session_id
               {where} {order}''', params


def session_filename(session_id):
    return RECORDS / f'record_session_{int(session_id):06d}.csv'


def download_filename(sid, session_name):
    label = re.sub(r'[^A-Za-z0-9_-]+', '_', session_name).strip('_')[:48]
    return f'record_session_{sid:06d}_{label}_gabungan.csv' if label else f'record_session_{sid:06d}_gabungan.csv'


def sensor_second(rec):
    """Return (UTC-second, provenance). Never merge by arrival for valid sensor timestamps."""
    source = rec.get('timestamp')
    if source:
        try:
            value = parse_utc(source)
            if value is not None:
                return value.astimezone(dt.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'), 'SENSOR'
        except (ValueError, TypeError, OverflowError):
            pass
    # Fallback only for missing/invalid sensor timestamps and marked explicitly.
    value = parse_utc(rec['received_at'])
    return value.astimezone(dt.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'), 'RECEIVED'


def mean_available(values):
    vals = [x for x in values if isinstance(x, (int, float)) and not isinstance(x, bool) and math.isfinite(x)]
    return round(sum(vals) / len(vals), 3) if vals else None


def merged_csv_rows(source_rows):
    """Pair distinct PM & Gas packets within same measured UTC second and session.

    Multiple samples in the same second are never silently discarded. If a side is
    absent it is left blank; this prevents false PM/Gas pairings from SD backlogs.
    """
    buckets = {}
    for row in source_rows:
        item = dict(row)
        if item.get('device_type') not in FIELDS:
            continue
        second, basis = sensor_second(item)
        key = (second, basis, item.get('session_id'))
        kinds = buckets.setdefault(key, {'pm': [], 'gas': []})
        kinds[item['device_type']].append(item)

    for key in sorted(buckets, key=lambda k: (k[0], k[2] if k[2] is not None else -1, k[1])):
        second, basis, session_id = key
        group = buckets[key]
        pm_list, gas_list = group['pm'], group['gas']
        for i in range(max(len(pm_list), len(gas_list))):
            pm = pm_list[i] if i < len(pm_list) else None
            gas = gas_list[i] if i < len(gas_list) else None
            pv = json.loads(pm['measurements']) if pm else {}
            gv = json.loads(gas['measurements']) if gas else {}
            # A single label where both agree. Conflicts are exposed explicitly,
            # not silently overwritten (possible with delayed SD uploads).
            plabel = (pm or {}).get('label') or ''
            glabel = (gas or {}).get('label') or ''
            if plabel and glabel and plabel != glabel:
                label = plabel + ' | ' + glabel
                status = 'LABEL_BERBEDA'
            else:
                label = plabel or glabel
                status = 'LENGKAP' if pm and gas else ('HANYA_PM' if pm else 'HANYA_GAS')
            pms = [mean_available([pv.get('pm1_pms1'), pv.get('pm1_pms2')]),
                   mean_available([pv.get('pm25_pms1'), pv.get('pm25_pms2')]),
                   mean_available([pv.get('pm10_pms1'), pv.get('pm10_pms2')])]
            sample = pm or gas
            row = ([second, sample.get('session_name') or '', label, status, basis]
                   + pms + [gv.get(k) for k in GAS_FIELDS[:3]]
                   + [pv.get(k) for k in PM_FIELDS]
                   + [gv.get(k) for k in GAS_FIELDS[3:]]
                   + [(pm or {}).get('sample_name'), (gas or {}).get('sample_name'),
                      (pm or {}).get('uptime_ms'), (gas or {}).get('uptime_ms')])
            yield [safe_csv_cell(x) for x in row]


def write_csv_merged(writer, rows):
    writer.writerow(MERGED_COLS)
    writer.writerows(merged_csv_rows(rows))


def write_session_file(session_id):
    """Build synchronized session CSV from durable SQLite rows.

    Called at start, stop, on download and on startup recovery. Data ingested
    during recording remains immediately durable in SQLite; CSV is a snapshot.
    """
    path = session_filename(session_id)
    tmp = path.with_suffix('.csv.tmp')
    with db_connect() as c, tmp.open('w', encoding='utf-8-sig', newline='') as fp:
        query, args = row_query('WHERE readings.session_id=?', params=(session_id,))
        write_csv_merged(csv.writer(fp), c.execute(query, args))
    tmp.replace(path)
    return path


def maybe_auto_stop_locked():
    """Must be called inside LOCK. Enforce timeout on server, not browser."""
    with db_connect() as c:
        s = active_session(c)
        if not s or not s['scheduled_stop_at']:
            return False
        deadline = parse_utc(s['scheduled_stop_at'])
        if deadline is None or clock() < deadline:
            return False
        c.execute('UPDATE sessions SET stopped_at=?, stop_reason=? WHERE id=? AND stopped_at IS NULL',
                  (iso(), 'automatic', s['id']))
        sid = s['id']
    try:
        write_session_file(sid)
    except OSError as exc:
        print('Automatic-stop CSV rebuild failed; retained in database:', exc, flush=True)
    print(f'Automatic stop: session #{sid}', flush=True)
    return True


def timer_worker():
    while True:
        try:
            with LOCK:
                maybe_auto_stop_locked()
        except Exception as exc:
            print('Timer error:', repr(exc), flush=True)
        threading.Event().wait(0.25)


def list_readings(limit=800):
    with db_connect() as c:
        query, params = row_query(order='ORDER BY readings.rowid DESC LIMIT ?', params=(limit,))
        rows = c.execute(query, params).fetchall()
    items = []
    for r in reversed(rows):
        item = dict(r)
        item['measurements'] = json.loads(item['measurements'])
        items.append(item)
    return items


def stats():
    with LOCK:
        maybe_auto_stop_locked()
        with db_connect() as c:
            counts = {kind: c.execute('SELECT COUNT(*) FROM readings WHERE device_type=?', (kind,)).fetchone()[0] for kind in FIELDS}
            counts['total'] = sum(counts.values())
            counts['devices'] = c.execute('SELECT COUNT(DISTINCT device_id) FROM readings').fetchone()[0]
            recent = {}
            for kind in FIELDS:
                r = c.execute('SELECT received_at FROM readings WHERE device_type=? ORDER BY rowid DESC LIMIT 1', (kind,)).fetchone()
                recent[kind] = r[0] if r else None
            current = active_session(c)
            sessions = [dict(r) for r in c.execute('SELECT * FROM sessions ORDER BY id DESC LIMIT 40')]
            session_rows = c.execute('SELECT COUNT(*) FROM readings WHERE session_id=?', (current['id'],)).fetchone()[0] if current else 0
    return dict(app_id='ek-laptop-server', storage_folder='data/', counts=counts, recent=recent, recording=current is not None,
                active_session=current, session_rows=session_rows, sessions=sessions,
                server_time=iso())


def clear_local_data(payload, client_address, origin):
    """Irreversibly erase local SQL rows, session CSVs and legacy backups.

    This is restricted to requests from the laptop itself, with explicit password,
    confirmation text and no active REC. The password is not sent to devices.
    """
    try:
        if not ipaddress.ip_address(client_address).is_loopback:
            return 403, {'ok': False, 'error': 'Penghapusan hanya diizinkan dari laptop server (localhost).'}
    except ValueError:
        return 403, {'ok': False, 'error': 'Invalid client address'}
    if origin:
        try:
            u = urlsplit(origin)
            if u.hostname not in ('localhost', '127.0.0.1', '::1') or u.port != PORT:
                return 403, {'ok': False, 'error': 'Origin tidak diizinkan'}
        except ValueError:
            return 403, {'ok': False, 'error': 'Origin tidak sah'}
    if not isinstance(payload, dict):
        return 400, {'ok': False, 'error': 'Invalid payload'}
    password = payload.get('password', '')
    if not isinstance(password, str) or not hmac.compare_digest(password, DELETE_PASSWORD):
        return 403, {'ok': False, 'error': 'Password salah'}
    if payload.get('confirmation') != 'HAPUS SEMUA':
        return 400, {'ok': False, 'error': 'Ketik HAPUS SEMUA untuk konfirmasi'}
    with LOCK:
        with db_connect() as c:
            if active_session(c):
                return 409, {'ok': False, 'error': 'Hentikan RECORD sebelum menghapus data'}
            n = c.execute('SELECT COUNT(*) FROM readings').fetchone()[0]
            m = c.execute('SELECT COUNT(*) FROM sessions').fetchone()[0]
            c.execute('DELETE FROM readings')
            c.execute('DELETE FROM label_events')
            c.execute('DELETE FROM sessions')
            c.execute("DELETE FROM sqlite_sequence WHERE name IN ('sessions','label_events')")
        # VACUUM shrinks local DB. If interrupted rows were still committed deleted.
        with db_connect() as c:
            c.execute('PRAGMA wal_checkpoint(TRUNCATE)')
            c.execute('VACUUM')
        for old in RECORDS.glob('*.csv'):
            old.unlink()
        legacy_archive = DATA / 'legacy_backup'
        if legacy_archive.is_dir():
            shutil.rmtree(legacy_archive)
    return 200, {'ok': True, 'removed_readings': n, 'removed_sessions': m,
                 'message': 'Semua data lokal dan CSV sesi telah dihapus. Firmware ESP / cloud tidak diubah.'}


def cleaned_text(value, field, max_len, default=''):
    if value is None:
        value = default
    if not isinstance(value, str) or len(value) > max_len or any(ord(x) < 32 for x in value):
        raise ValueError(f'{field} harus berupa teks maksimal {max_len} karakter tanpa karakter kontrol')
    return value.strip()


def valid_ingest(p):
    if not isinstance(p, dict) or p.get('device_type') not in FIELDS:
        raise ValueError('device_type must be pm or gas')
    for k in ('event_id', 'device_id', 'sample_name'):
        if not isinstance(p.get(k), str) or not 1 <= len(p[k]) <= 100:
            raise ValueError('Invalid ' + k)
    values = p.get('measurements')
    if not isinstance(values, dict):
        raise ValueError('measurements must be JSON object')
    out = {}
    for k in FIELDS[p['device_type']]:
        v = values.get(k)
        if v is None:
            out[k] = None
        elif isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v):
            out[k] = float(v)
        else:
            raise ValueError('Invalid sensor value ' + k)
    timestamp = p.get('timestamp')
    if timestamp is not None and (not isinstance(timestamp, str) or len(timestamp) > 50):
        raise ValueError('Invalid timestamp')
    uptime = p.get('uptime_ms')
    if uptime is not None and (not isinstance(uptime, int) or isinstance(uptime, bool) or uptime < 0):
        raise ValueError('Invalid uptime_ms')
    return dict(event_id=p['event_id'], device_id=p['device_id'], device_type=p['device_type'],
                sample_name=p['sample_name'], received_at=iso(), timestamp=timestamp,
                uptime_ms=uptime, measurements=out)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        if '/api/ingest' not in self.path:
            super().log_message(fmt, *args)

    def reply(self, status, data, typ='application/json; charset=utf-8', name=None):
        if isinstance(data, (dict, list)):
            data = json.dumps(data, ensure_ascii=False, separators=(',', ':')).encode('utf-8')
        elif isinstance(data, str):
            data = data.encode('utf-8')
        self.send_response(status)
        self.send_header('Content-Type', typ)
        self.send_header('Content-Length', str(len(data)))
        self.send_header('Cache-Control', 'no-store')
        self.send_header('X-Content-Type-Options', 'nosniff')
        if name:
            self.send_header('Content-Disposition', f'attachment; filename="{name}"')
        self.end_headers()
        try:
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def read_json(self):
        size = int(self.headers.get('Content-Length', '0'))
        if size < 0 or size > 8192:
            raise ValueError('Request too large')
        return json.loads(self.rfile.read(size) or b'{}')

    def do_POST(self):
        path = urlsplit(self.path).path
        if path == '/api/admin/clear-data':
            if not self.headers.get('Content-Type', '').lower().startswith('application/json'):
                return self.reply(415, {'ok': False, 'error': 'Content-Type harus application/json'})
            try:
                payload = self.read_json()
                status, result = clear_local_data(payload, self.client_address[0], self.headers.get('Origin', ''))
                return self.reply(status, result)
            except (ValueError, json.JSONDecodeError):
                return self.reply(400, {'ok': False, 'error': 'JSON tidak valid'})
            except Exception as exc:
                print('CLEAR DATA ERROR:', repr(exc), flush=True)
                return self.reply(500, {'ok': False, 'error': 'Gagal menghapus data lokal'})
        if path == '/api/ingest':
            if TOKEN and self.headers.get('X-Device-Token', '') != TOKEN:
                return self.reply(401, {'ok': False, 'error': 'Device token invalid'})
            try:
                rec = valid_ingest(self.read_json())
                with LOCK:
                    maybe_auto_stop_locked()
                    with db_connect() as c:
                        s = active_session(c)
                        sid = s['id'] if s else None
                        label = s['label'] if s else ''
                        sname = s['name'] if s else ''
                        cur = c.execute('''INSERT OR IGNORE INTO readings
                            (event_id,device_id,device_type,received_at,timestamp,uptime_ms,sample_name,measurements,session_id,label)
                            VALUES (?,?,?,?,?,?,?,?,?,?)''',
                            (rec['event_id'], rec['device_id'], rec['device_type'], rec['received_at'], rec['timestamp'],
                             rec['uptime_ms'], rec['sample_name'], json.dumps(rec['measurements']), sid, label))
                        fresh = cur.rowcount > 0
                    # CSV is generated on demand / STOP; SQLite stores live 1Hz packets.
                return self.reply(200, {'ok': True, 'duplicate': not fresh, 'recording': sid is not None})
            except (ValueError, json.JSONDecodeError) as exc:
                return self.reply(400, {'ok': False, 'error': str(exc)})
            except Exception as exc:
                print('INGEST ERROR:', repr(exc), flush=True)
                return self.reply(500, {'ok': False, 'error': 'Internal error'})

        if path in ('/api/record/start', '/api/record/stop', '/api/record/label'):
            try:
                payload = self.read_json()
                with LOCK:
                    maybe_auto_stop_locked()
                    with db_connect() as c:
                        current = active_session(c)
                        if path.endswith('/start'):
                            if current:
                                return self.reply(200, {'ok': True, 'already_recording': True, 'session': current})
                            name = cleaned_text(payload.get('name'), 'Nama sesi', 120)
                            if not name:
                                name = 'Sesi ' + clock().strftime('%Y-%m-%d %H-%M-%S UTC')
                            label = cleaned_text(payload.get('label'), 'Label', 80)
                            duration = payload.get('duration_seconds')
                            if duration in (None, 0):
                                duration = None
                                deadline = None
                            elif isinstance(duration, int) and not isinstance(duration, bool) and 1 <= duration <= MAX_DURATION_SECONDS:
                                deadline = iso(clock() + dt.timedelta(seconds=duration))
                            else:
                                raise ValueError('Durasi harus 1 hingga 604800 detik, atau manual')
                            started_at = iso()
                            cur = c.execute('''INSERT INTO sessions
                                (started_at, name, label, duration_seconds, scheduled_stop_at)
                                VALUES (?,?,?,?,?)''', (started_at, name, label, duration, deadline))
                            sid = cur.lastrowid
                            c.execute('INSERT INTO label_events(session_id,changed_at,label) VALUES (?,?,?)', (sid, started_at, label))
                            result = {'id': sid, 'started_at': started_at, 'name': name, 'label': label,
                                      'duration_seconds': duration, 'scheduled_stop_at': deadline}
                        elif path.endswith('/label'):
                            if not current:
                                return self.reply(409, {'ok': False, 'error': 'Tidak ada sesi yang sedang merekam'})
                            label = cleaned_text(payload.get('label'), 'Label', 80)
                            sid = current['id']
                            changed = iso()
                            c.execute('UPDATE sessions SET label=? WHERE id=?', (label, sid))
                            c.execute('INSERT INTO label_events(session_id,changed_at,label) VALUES (?,?,?)', (sid, changed, label))
                            result = {'id': sid, 'label': label, 'changed_at': changed}
                        else:
                            if not current:
                                return self.reply(200, {'ok': True, 'already_stopped': True})
                            sid = current['id']
                            stopped_at = iso()
                            c.execute('UPDATE sessions SET stopped_at=?, stop_reason=? WHERE id=?',
                                      (stopped_at, 'manual', sid))
                            result = {'id': sid, 'stopped_at': stopped_at, 'stop_reason': 'manual'}
                    # New session CSV or completed session regeneration.
                    if not path.endswith('/label'):
                        try:
                            write_session_file(sid)
                        except OSError as exc:
                            print('Session CSV problem (DB retained):', exc, flush=True)
                return self.reply(200, {'ok': True, 'session': result})
            except (ValueError, json.JSONDecodeError) as exc:
                return self.reply(400, {'ok': False, 'error': str(exc)})
            except Exception as exc:
                print('RECORD ERROR:', repr(exc), flush=True)
                return self.reply(500, {'ok': False, 'error': 'Cannot change recording state'})
        return self.reply(404, {'ok': False, 'error': 'Not found'})

    def do_GET(self):
        url = urlsplit(self.path)
        q = parse_qs(url.query)
        path = url.path
        if path == '/':
            return self.reply(200, (ROOT / 'index.html').read_bytes(), 'text/html; charset=utf-8')
        if path == '/favicon.ico':
            return self.reply(200, (ROOT / 'assets' / 'ek.ico').read_bytes(), 'image/x-icon')
        if path == '/api/status':
            return self.reply(200, stats())
        if path in ('/api/live', '/api/records'):
            try:
                limit = min(1200, max(1, int(q.get('limit', ['800'])[0])))
            except ValueError:
                return self.reply(400, {'ok': False, 'error': 'Invalid limit'})
            data = list_readings(limit)
            kind = q.get('device_type', ['all'])[0]
            if kind in FIELDS:
                data = [rec for rec in data if rec['device_type'] == kind]
            return self.reply(200, {'records': data})
        if path in ('/merged.csv', '/download.csv', '/api/download/all'):
            # User-facing CSV: one row per source measurement second + recording session.
            # No device_id or device_type. Preserve raw data in SQLite /raw.csv.
            data = io.StringIO()
            with db_connect() as c:
                sql, args = row_query()
                write_csv_merged(csv.writer(data), c.execute(sql, args))
            return self.reply(200, '\ufeff' + data.getvalue(), 'text/csv; charset=utf-8', 'EK_PM_GAS_GABUNGAN.csv')
        if path in ('/raw.csv', '/api/download/raw'):
            data = io.StringIO()
            writer = csv.writer(data)
            writer.writerow(COLS)
            kind = q.get('device_type', ['all'])[0]
            with db_connect() as c:
                where = 'WHERE readings.device_type=?' if kind in FIELDS else ''
                args = (kind,) if kind in FIELDS else ()
                sql, params = row_query(where, params=args)
                for r in c.execute(sql, params):
                    writer.writerow(csv_row(r))
            return self.reply(200, '\ufeff' + data.getvalue(), 'text/csv; charset=utf-8', 'EK_PM_GAS_MENTAH.csv')
        if path == '/api/download/session':
            try:
                sid = int(q.get('id', ['0'])[0])
                if sid <= 0:
                    raise ValueError()
            except ValueError:
                return self.reply(400, {'ok': False, 'error': 'Bad session ID'})
            with LOCK:
                with db_connect() as c:
                    sess = c.execute('SELECT name FROM sessions WHERE id=?', (sid,)).fetchone()
                if not sess:
                    return self.reply(404, {'ok': False, 'error': 'Session not found'})
                path_csv = write_session_file(sid)
                data = path_csv.read_bytes()
            return self.reply(200, data, 'text/csv; charset=utf-8', download_filename(sid, sess['name']))
        return self.reply(404, {'ok': False, 'error': 'Not found'})


if __name__ == '__main__':
    init_db()
    with LOCK:
        maybe_auto_stop_locked()
        with db_connect() as conn:
            active = active_session(conn)
        if active:
            write_session_file(active['id'])
    threading.Thread(target=timer_worker, daemon=True, name='auto-stop').start()
    print(f'\nEK INSTRUMENTATION / PM + GAS LAPTOP HUB | http://localhost:{PORT}', flush=True)
    print(f'ESP endpoint: http://<IP-LAPTOP>:{PORT}/api/ingest', flush=True)
    print(f'All local storage: {DATA} | DB: {DB} | Session CSV: {RECORDS}', flush=True)
    if not TOKEN:
        print('NOTE: LAN token OFF. Use trusted private Wi-Fi; do not expose to internet.', flush=True)
    ThreadingHTTPServer(('0.0.0.0', PORT), Handler).serve_forever()
