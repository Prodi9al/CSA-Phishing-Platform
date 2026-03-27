# CSA Phishing Awareness Demo Kit

> **INTERNAL USE ONLY — Authorised Personnel Only**
> See [LICENSE.md](LICENSE.md) for full terms.

A controlled phishing simulation platform used in **CSA / CBAC security awareness training**. It demonstrates how phishing attacks harvest credentials, capture device information, and track location — all displayed live on an instructor dashboard during the training reveal.

---

## Table of Contents

- [Overview](#overview)
- [Project Structure](#project-structure)
- [Requirements](#requirements)
- [Setup](#setup)
- [Launching a Session](#launching-a-session)
- [Accessing the Platform](#accessing-the-platform)
- [Remote Deployment](#remote-deployment)
- [Instructor Dashboard](#instructor-dashboard)
- [REST API](#rest-api)
- [Authentication](#authentication)
- [Updating](#updating)
- [Legal & Ethical Notes](#legal--ethical-notes)

---

## Overview

The kit runs a single Node.js server (`relay.js`) that handles everything — WebSocket connections, static file serving, and a REST API — all on one port. Victims open the phishing page in their browser, and the instructor watches their data populate on the dashboard in real time.

**What gets collected from each victim:**

- Full device fingerprint (OS, browser, screen resolution, CPU cores, RAM, battery, GPU renderer, canvas fingerprint, network type)
- GPS coordinates (if permission granted) or IP-based geolocation as fallback
- Live camera stream and a high-resolution face capture
- Form submission data (name, email, organisation, staff ID)

---

## Project Structure

```
CSA-Phishing-Platform/
├── relay.js              # Unified server — WebSockets, REST API, static files
├── phish.html            # Victim-facing phishing page (CSA event portal pretext)
├── instructor.html       # Instructor live dashboard
├── setup.sh              # One-shot setup script (Linux/macOS)
├── launch.sh             # Automated launch — starts server + Cloudflare tunnel
├── update.sh             # Pull latest code and update dependencies
├── windows/
│   ├── setup.ps1         # Windows setup script
│   ├── launch.ps1        # Windows launch script
│   ├── update.ps1        # Windows update script
│   ├── run.bat           # Launcher batch file
│   └── update.bat        # Updater batch file
├── ngrok-setup.md        # Alternative tunnel setup guide (ngrok)
├── package.json          # Node.js project manifest
├── sessions.db           # Auto-created — SQLite database (gitignored)
└── relay.log             # Auto-created — server log (gitignored)
```

---

## Requirements

- **Node.js** v16 or later
- **npm** (bundled with Node.js)
- **cloudflared** (for remote HTTPS access — camera and GPS require HTTPS)

Dependencies installed automatically by `setup.sh`:

| Package | Purpose |
|---|---|
| `ws` | WebSocket server |
| `better-sqlite3` | SQLite session persistence |
| `dotenv` | Environment variable support |

---

## Setup

### Linux / macOS

```bash
git clone https://github.com/kinglukainzy-ai/CSA-Phishing-Platform
cd CSA-Phishing-Platform
chmod +x setup.sh launch.sh update.sh
./setup.sh
```

### Windows

```powershell
# Run as Administrator
cd windows
.\setup.ps1
```

`setup.sh` / `setup.ps1` will:
1. Check and install Node.js if missing
2. Check and install cloudflared if missing
3. Run `npm install` to install dependencies

---

## Launching a Session

### Linux / macOS (recommended)

```bash
./launch.sh
```

This starts `relay.js` and opens a Cloudflare tunnel automatically. When ready it prints:

```
╔══════════════════════════════════════════════════════════════╗
║  DEPLOYMENT SUCCESSFUL                                       ║
║                                                              ║
║  VICTIM LINK (Share this):                                   ║
║  https://random-words.trycloudflare.com/phish               ║
║                                                              ║
║  INSTRUCTOR DASHBOARD:                                       ║
║  https://random-words.trycloudflare.com/instructor          ║
╚══════════════════════════════════════════════════════════════╝
```

Press `Ctrl+C` to stop all processes cleanly.

### Windows

```powershell
cd windows
.\run.bat
```

Or double-click `run.bat`.

### Manual Start

```bash
node relay.js
# Then in a separate terminal:
cloudflared tunnel --url http://localhost:8765
```

---

## Accessing the Platform

| URL | Description |
|---|---|
| `/phish` or `/phish.html` | Victim-facing phishing page |
| `/instructor` or `/instructor.html` | Instructor live dashboard |

**Local access (HTTP — no camera/GPS):**
```
http://localhost:8765/phish
http://localhost:8765/instructor
```

**Remote access via tunnel (HTTPS — full functionality):**
```
https://your-tunnel.trycloudflare.com/phish
https://your-tunnel.trycloudflare.com/instructor
```

> Camera and GPS require HTTPS. Always use the tunnel URL when running live training sessions.

---

## Remote Deployment

Since the server is unified, only **one tunnel** is needed pointing to port `8765`.

### Cloudflare Tunnel (recommended)

```bash
cloudflared tunnel --url http://localhost:8765
```

Cloudflare provides a free HTTPS subdomain that handles SSL automatically. The tunnel URL changes each session unless you use a named tunnel with a Cloudflare account.

### ngrok (alternative)

See [ngrok-setup.md](ngrok-setup.md) for ngrok-specific instructions.

---

## Instructor Dashboard

Open the instructor URL in your browser before sharing the victim link. The dashboard shows:

- **Live victim cards** — one card per connected participant, updating in real time
- **Camera feed** — live stream and high-resolution face capture
- **Device info** — OS, browser, device type, screen size, battery, RAM, CPU, GPU renderer, canvas fingerprint, network type
- **Location** — GPS coordinates with Google Maps link, or IP-based city/country fallback
- **Form data** — name, email, organisation, staff ID (card flashes red on submission)
- **Session export** — CSV download of all collected data for post-session review
- **Live config** — update the event name, date, time, and venue on all active victim pages without refreshing

### Connecting as Instructor

Enter your instructor token in the dashboard login field. The default token is `CSA-DEMO-2026`. Change this before any live session — see [Authentication](#authentication).

---

## REST API

The server exposes a read-only HTTP API on the same port for reviewing past sessions:

| Endpoint | Method | Description |
|---|---|---|
| `/api/sessions` | GET | List all recorded session IDs with victim counts |
| `/api/sessions/:id` | GET | All victim records for a specific session |

Example:

```bash
curl http://localhost:8765/api/sessions
curl http://localhost:8765/api/sessions/2026-03-27T09-00
```

Each victim record includes: IP address, connection timestamp, device info, location, form data, and last camera frame timestamp.

---

## Authentication

Instructor tokens are defined in `relay.js` under `INSTRUCTOR_TOKENS`:

```js
const INSTRUCTOR_TOKENS = {
  'CSA-DEMO-2026': 'default',
  'CSA-AM-2026':   'session_AM',
  'CSA-PM-2026':   'session_PM',
};
```

Each token maps to a **room**. Instructors only see victims in their assigned room, allowing separate morning and afternoon cohorts to run simultaneously without cross-visibility.

**Before any live session:**
1. Change the token strings in `relay.js` to values not publicly known
2. Update `INSTRUCTOR_TOKEN` in `instructor.html` to match

The relay blocks and logs any connection attempt with an invalid token. After 5 failed attempts from the same IP, further attempts are rate-limited.

---

## Updating

```bash
# Linux / macOS
./update.sh

# Windows
cd windows
.\update.bat
```

This pulls the latest code from GitHub and runs `npm install` to update dependencies.

---

## Legal & Ethical Notes

- **Authorised use only.** Deploy exclusively in controlled training environments where participants have been informed they are attending a cybersecurity awareness exercise.
- **Consent.** Participants must be briefed that a demonstration will occur. The debrief is the core of the training — show participants exactly what was collected and explain each attack vector in detail.
- **Data Protection Act, 2012 (Act 843).** All data collected must be processed in accordance with Ghana's Data Protection Act. This platform is compliant when used for declared training purposes under authorised CSA/CBAC programmes.
- **Data retention.** `sessions.db` and `relay.log` contain personally identifiable information including names, emails, IP addresses, GPS coordinates, and face images. **Delete both files after every training session.**
- **Do not deploy publicly.** The victim page must never be distributed outside a controlled, time-limited training session.
- **Tokens are secrets.** Never commit `.env` files or expose instructor tokens publicly. Rotate tokens between sessions.
- **Never commit sensitive files.** `sessions.db`, `relay.log`, and `.env` are excluded from git via `.gitignore`. Verify this before pushing any changes.
