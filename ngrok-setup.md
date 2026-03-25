# Tunnel Setup Guide — ngrok & cloudflared

Use a tunnel when participants are on a different network (mobile data, remote office,
or you want a public URL for QR code distribution).

---

## Option A — ngrok (recommended for most demos)

### 1. Install ngrok

```bash
# Download from https://ngrok.com/download, or on Debian/Ubuntu:
curl -sSL https://ngrok-agent.s3.amazonaws.com/ngrok.asc \
  | sudo tee /etc/apt/trusted.gpg.d/ngrok.asc >/dev/null
echo "deb https://ngrok-agent.s3.amazonaws.com buster main" \
  | sudo tee /etc/apt/sources.list.d/ngrok.list
sudo apt update && sudo apt install ngrok
```

### 2. Authenticate (free account required)

```bash
ngrok config add-authtoken YOUR_NGROK_AUTHTOKEN
```

Get your authtoken from: https://dashboard.ngrok.com/get-started/your-authtoken

### 3. Start the relay server

```bash
node relay.js
```

### 4. Open two tunnels — one HTTP (phish page), one WebSocket (relay)

In separate terminals:

```bash
# Terminal 1 — serve phish.html + instructor.html over HTTP
python3 -m http.server 8080
ngrok http 8080

# Terminal 2 — tunnel the WebSocket relay
ngrok http 8765
```

> **Note:** ngrok free tier gives you two separate random subdomains.
> Copy both URLs from the ngrok output before continuing.

### 5. Update WS_URL in both HTML files

You get URLs like:
```
https://a1b2c3d4.ngrok-free.app   ← HTTP tunnel (phish + instructor pages)
https://e5f6g7h8.ngrok-free.app   ← WebSocket tunnel
```

Edit the WebSocket URL in **phish.html** and **instructor.html**:

```js
// Change this in BOTH files:
const WS_URL = 'wss://e5f6g7h8.ngrok-free.app';
//              ^^^  secure WebSocket — ngrok handles TLS termination
```

Your relay server still runs plain `ws://` on localhost — ngrok wraps it in TLS.

### 6. Share the phish page

```
https://a1b2c3d4.ngrok-free.app/phish.html
```

Generate a QR code for the room:

```bash
# Install qrencode: sudo apt install qrencode
qrencode -t ANSIUTF8 "https://a1b2c3d4.ngrok-free.app/phish.html"
```

### 7. Open the instructor dashboard

```
https://a1b2c3d4.ngrok-free.app/instructor.html
```

Or open `instructor.html` directly from disk (`file://`) — both work as long as
`WS_URL` points to the correct ngrok WebSocket tunnel.

---

## Option B — cloudflared (Cloudflare Tunnel)

Use this if ngrok is blocked on the network, or you want a stable named subdomain.

### 1. Install cloudflared

```bash
# Debian/Ubuntu
curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb \
  -o cloudflared.deb
sudo dpkg -i cloudflared.deb
```

### 2. Quick tunnel (no login required for temporary URLs)

```bash
# Terminal 1 — HTTP server for HTML files
python3 -m http.server 8080
cloudflared tunnel --url http://localhost:8080

# Terminal 2 — WebSocket relay
node relay.js
cloudflared tunnel --url http://localhost:8765
```

cloudflared prints two `.trycloudflare.com` URLs. Use them the same way as ngrok above.

### 3. Update WS_URL

```js
const WS_URL = 'wss://your-random-id.trycloudflare.com';
```

---

## Persistent named subdomain (ngrok paid / Cloudflare named tunnel)

If your team runs demos regularly, a stable subdomain avoids having to re-edit
the HTML files before every session.

**ngrok static domain (free tier — one domain):**

```bash
ngrok http --domain=csa-demo.ngrok-free.app 8765
```

Then hardcode `wss://csa-demo.ngrok-free.app` in both HTML files permanently.

**Cloudflare named tunnel:**

```bash
cloudflared tunnel create csa-demo
cloudflared tunnel route dns csa-demo ws.yourdomain.com
cloudflared tunnel run --url http://localhost:8765 csa-demo
```

---

## Checklist before every session

- [ ] `node relay.js` running — check terminal shows `Relay server starting`
- [ ] `python3 -m http.server 8080` running (or equivalent)
- [ ] Tunnel(s) active — URLs copied
- [ ] `WS_URL` in `phish.html` updated to tunnel WebSocket URL
- [ ] `WS_URL` in `instructor.html` updated to same tunnel WebSocket URL
- [ ] `INSTRUCTOR_TOKEN` in both `relay.js` and `instructor.html` match
- [ ] `instructor.html` opened — status shows **AUTH OK**
- [ ] QR code generated and ready to display
- [ ] `session.log` cleared from previous session: `> session.log`
