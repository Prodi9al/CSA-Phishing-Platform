# CSA Phishing Awareness Demo Kit v2.2 (Unified)

> **INTERNAL USE ONLY — Authorised Personnel Only**
> See [LICENSE.md](LICENSE.md) for full terms.

A controlled, high-fidelity phishing simulation used in CSA / CBAC security awareness training. 
The kit demonstrates credential harvesting, geolocation, device fingerprinting, and live camera capture — all monitored through a unified instructor dashboard.

**Version 2.2** features a "Unified Relay" architecture, serving both the tracking logic and the static files from a single process.

---

## 📂 Project Structure

| File / Folder | Purpose |
|---|---|
| `relay.js` | **Unified Server** (WebSockets + REST API + Static Web Server) |
| `phish.html` | Victim-facing phishing page (Standard Portal pretext) |
| `phish_stealth.html` | **Stealth variant** of the phishing page |
| `instructor.html` | Instructor live dashboard (Camera feeds, Geo, Device info, Form data) |
| `setup.sh` | One-shot Linux/macOS setup script |
| `launch.sh` | Automated deployment script (Starts server + Cloudflare tunnel) |
| `windows/` | Windows-specific scripts (`setup.ps1`, `launch.ps1`, `run.bat`) |
| `sessions.db` | **Auto-created** — SQLite database for persistent records |
| `relay.log` | **Auto-created** — Unified server logs |

---

## 🚀 Quick Start

### 1. Setup
```bash
# Linux / macOS
chmod +x setup.sh update.sh launch.sh
./setup.sh

# Windows
# Run windows/setup.ps1 as Administrator
```

### 2. Launch
The easiest way to start on Linux is using the automated launch script:
```bash
./launch.sh
```
This starts the `relay.js` server and (optionally) sets up a secure tunnel.

**Manual Start:**
```bash
node relay.js
```

### 3. Accessing the Platform
The server defaults to port **8765**. Access these URLs locally:
- **Victim Page:** `http://localhost:8765/phish`
- **Stealth Page:** `http://localhost:8765/stealth`
- **Instructor Dashboard:** `http://localhost:8765/instructor`

---

## 🔐 Authentication & Multi-Tenancy

Authentication is managed via Environment Variables or a `.env` file.

### Instructor Tokens
Define instructor tokens in the format `INSTR_TOKEN_NAME=TOKEN:ROOM`:
```env
INSTR_TOKEN_DEFAULT=CSA-DEMO-2026:default
INSTR_TOKEN_AM=MORNING-TOKEN:room_a
```
- Instructors must enter their **Token** in the dashboard to connect.
- Each token maps to a specific **Room**. Instructors only see victims in their assigned room.

### Rate Limiting
The relay includes built-in brute-force protection. If an IP fails authentication 5 times within 60 seconds, it is temporarily blocked.

---

## 🛠 Features

- **Live Camera Streaming**: Real-time MJPEG-over-WebSocket frames from victim devices.
- **GPS & IP Geolocation**: Precise coordinates (if permitted) or IP-based location fallback.
- **Device Fingerprinting**: OS, Browser, Battery level, RAM, CPU cores, and Screen resolution.
- **Form Interception**: Instant red-flash notification when a victim submits "credentials".
- **Dynamic Config**: Instructors can update the "Event Name", "Venue", and "Time" live across all active phishing pages.
- **Persistence**: All data (including mugshot timestamps) is saved to `sessions.db` using high-performance WAL mode.

---

## 📊 REST API

The unified server provides a read-only API for reviewing data:

| Endpoint | Description |
|---|---|
| `GET /api/sessions` | List all unique Session IDs in the database |
| `GET /api/sessions/:id` | Retrieve all victim records for a specific session |

---

## 🌐 Remote Deployment (Cloudflare/ngrok)

The platform is designed to work behind tunnels. Since it is unified, you only need **one tunnel** pointing to port `8765`.

```bash
# Example using Cloudflare
cloudflared tunnel --url http://localhost:8765
```

The system will automatically detect the tunnel URL and adjust WebSocket connections accordingly.

---

## ⚖️ Legal & Ethical Notes

- **Authorised Use Only**: Run only in controlled training environments with explicit consent.
- **Data Privacy**: Complies with **Ghana's Data Protection Act, 2012 (Act 843)** for training purposes.
- **Data Retention**: `sessions.db` and `relay.log` contain PII. **Delete them after every training session.**
- **GitHub Safety**: Never commit `.env`, `sessions.db`, or `relay.log`. These are excluded via `.gitignore`.
