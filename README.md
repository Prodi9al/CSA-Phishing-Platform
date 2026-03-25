# CSA Phishing Awareness Demo Kit v2

> **INTERNAL USE ONLY — Authorised Personnel Only**
> See [LICENSE.md](LICENSE.md) for full terms.

A controlled phishing simulation used in CSA / CBAC security awareness training.
The kit demonstrates credential harvesting, geolocation, device fingerprinting, and camera capture — all explained live to participants through the instructor dashboard.

Supports **multiple simultaneous instructors** with separate session rooms and **persistent SQLite storage** of all victim records across runs.

---

## Files

| File | Purpose |
|---|---|
| `phish.html` | Victim-facing phishing page (CSA event portal pretext) |
| `instructor.html` | Instructor live dashboard — camera feeds, IP, device info, geo, form data |
| `relay.js` | WebSocket relay + REST API server |
| `setup.sh` | One-shot Linux setup script |
| `package.json` | Node.js project manifest |
| `ngrok-setup.md` | Tunnel instructions for remote sessions |
| `sessions.db` | **Auto-created** — SQLite database (gitignored, contains personal data) |
| `session-*.log` | **Auto-created** — per-run log files (gitignored, contain personal data) |

---

## Quick Start (Linux / macOS)

```bash
# 1. Clone
git clone <your-repo-url>
cd csa-phishing-awareness-demo

# 2. Set up (installs Node.js dependencies)
chmod +x setup.sh
./setup.sh

# 3. Start the relay server (default session label = current datetime)
node relay.js

# Or with an explicit session label:
SESSION_ID="2026-03-25-AM" node relay.js

# 4. Open the instructor dashboard
#    Just double-click instructor.html, or:
xdg-open instructor.html   # Linux
open instructor.html        # macOS

# 5. Serve the phish page to participants (LAN)
python3 -m http.server 8080
# Share:  http://YOUR-LAN-IP:8080/phish.html
```

---

## Requirements

- **Node.js** v16 or later
- `npm` (comes with Node.js)
- Dependencies installed by `setup.sh` / `npm install`:
  - `ws` — WebSocket server
  - `better-sqlite3` — SQLite persistence

---

## Multi-Session / Multi-Instructor Setup

### Session Labels

Each run of `relay.js` is tagged with a **session ID**.  
Default: current ISO datetime, e.g. `2026-03-25T09-15`.  
Override with an environment variable:

```bash
SESSION_ID="Morning-Cohort" node relay.js
SESSION_ID="Afternoon-Cohort" node relay.js
```

### Instructor Tokens & Rooms

Open `relay.js` and edit `INSTRUCTOR_TOKENS`:

```js
const INSTRUCTOR_TOKENS = {
  'CSA-AM-2026': 'session_AM',   // morning instructor token → AM room
  'CSA-PM-2026': 'session_PM',   // afternoon instructor token → PM room
};
```

- Each instructor opens `instructor.html` and sets `INSTRUCTOR_TOKEN` to their assigned token.
- Each instructor **only sees victims in their own room** — they cannot see the other cohort.
- All records are stored in the same `sessions.db` with their room label.

---

## Changing Instructor Tokens

1. Edit `relay.js` → update `INSTRUCTOR_TOKENS`
2. Edit `instructor.html` → update `const INSTRUCTOR_TOKEN`
3. Restart `node relay.js`

Both values must match exactly — the relay rejects and closes any connection with an invalid token.

---

## REST API — Reviewing Past Sessions

A lightweight HTTP server runs on port **8766** alongside the WebSocket server:

| Endpoint | Description |
|---|---|
| `GET http://localhost:8766/api/sessions` | List all recorded session IDs |
| `GET http://localhost:8766/api/sessions/:id` | All victim records for a session |
| `GET http://localhost:8766/api/current` | Victims in this run's session |

Each victim record includes: IP, connected timestamp, device info (OS / browser / hardware), geolocation, **submitted form data** (name, email, staff ID), and last camera frame timestamp.

---

## Remote / Cross-Network Setup (ngrok)

See **[ngrok-setup.md](ngrok-setup.md)** for full tunnel instructions.

After tunnelling, update the WebSocket URL in **both** `phish.html` and `instructor.html`:

```js
const WS_URL = 'wss://YOUR-SUBDOMAIN.ngrok-free.app';
```

---

## Instructor Dashboard Features

### Live Victim Cards

Each victim card shows:

```
IP: 196.0.x.x · Android 14 · Chrome 124 · 📱 Mobile
256x2340 · Africa/Accra · 🔋 82% (charging) · CPU: 8c · RAM: 6GB
📍 GPS  5.60123, -0.18456 ±8m  [maps]
⚠ FORM SUBMITTED | 👤 Kwame Mensah · ✉ k.mensah@org.gov.gh · 🪪 GH-12345
```

When a participant submits the form, the card **border flashes red** and their name, email, and staff ID appear.

| Colour | Field |
|---|---|
| Blue | Server-resolved IP |
| Purple | OS |
| Green | Browser |
| Gold | Device type |
| Red | Location tag |
| Red (bright) | Submitted form data |

### Header

After connecting, the header shows: `SESSION: <id>   ROOM: <room>` so the instructor always knows which cohort they are monitoring.

---

## 🔄 How to Update
If you already have the repository:
1.  **First-Time Only:** Run `git pull origin master` manually to get the new scripts.
2.  **Every Time After:** Just run:
    - **Linux/Kali:** `./update.sh`
    - **Windows:** `./update.ps1`

This will pull the latest code and update any new dependencies automatically.

## 🌐 Remote Deployment (Unified Architecture)
The platform now uses a **unified server** (`relay.js`). This means you only need **one** Cloudflare tunnel for everything (Camera, GPS, WebSocket, and Dashboard).

### Step 1: Start the Relay
```bash
node relay.js
```

### Step 2: Open One Tunnel
In a new terminal, point Cloudflare to the relay port (`8765`):
```bash
cloudflared tunnel --url http://localhost:8765
```

### Step 3: Access
Cloudflare will provide a secure URL (e.g. `https://example.trycloudflare.com`).
- **Victim Page:** `https://example.trycloudflare.com/phish`
- **Instructor Dashboard:** `https://example.trycloudflare.com/instructor`

> [!TIP]
> Use the **`launch.sh`** script (on Linux) to automate this entire process with one command. It will start the server, the tunnel, and print the final active links for you.

---

## 📄 Session Log Files

Each run creates a timestamped log file, e.g. `session-2026-03-25T09-15.log`.

It records:
- All WebSocket connections (IP + timestamp)
- Device info per client
- Geolocation hits
- Form submissions (name, email, staff ID)
- Disconnections

Log files are excluded from git (`.gitignore`). Delete after training to comply with data protection obligations.

---

## Git Workflow

```bash
# Do NOT commit:  sessions.db  session-*.log  node_modules/
# These are all in .gitignore

# Commit and push changes:
git add -A
git commit -m "Your message"
git push origin main
```

---

## Legal & Ethical Notes

- Run only in authorised training environments with participant consent.
- Complies with Ghana's **Data Protection Act, 2012 (Act 843)** when used for declared training purposes.
- Do **not** deploy `phish.html` outside a controlled demo session.
- `sessions.db` and `session-*.log` contain personal data — **delete after training**.
- Instructor tokens are secrets — change `INSTRUCTOR_TOKENS` before sharing or publishing the repo.
