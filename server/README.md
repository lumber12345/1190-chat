# 1190 Chat relay server

A tiny, dependency-light Node.js server that lets 1190 Chat peers reach each
other when they are **not** on the same local network. It routes sealed
(ciphertext) envelopes and does **store-and-forward** for encrypted files.

> The server never sees plaintext. Message bodies and file bytes are sealed
> end-to-end on the clients (X25519 + HKDF + AES-256-GCM). The server only
> handles routing metadata and opaque ciphertext.

## Run

```bash
npm install
npm start                 # 0.0.0.0:8090
```

Environment variables:

| Var        | Default        | Meaning                          |
|------------|----------------|----------------------------------|
| `PORT`     | `8090`         | TCP port                          |
| `HOST`     | `0.0.0.0`      | Bind address                      |
| `DATA_DIR` | `./data`       | Where users/queues/files persist  |

## Verify

```bash
node smoke_test.js        # 17 checks: routing, offline queue, file store-and-forward, presence
```

## HTTP API

- `GET  /health` → `{ ok, uptime, users }`
- `POST /register` `{ userId, publicKey(b64), displayName }` → upsert identity
- `GET  /users/:id` → `{ userId, displayName, publicKey, online }`

## WebSocket API (`/ws`)

Text frames are JSON envelopes; binary frames are encrypted file chunks
(`[uint32 hdrLen][header JSON][ciphertext]`).

```
-> hello {userId}                 register this socket
<- welcome {userId, serverTime}
-> msg|ginvite|filemeta {id, conv, to, ts, ct}
<- ack {id}                       delivered live or queued for offline peer
-> typing|receipt {...}           ephemeral (dropped if peer offline)
-> filestored {fid, to}           upload finished
<- fileready {fid, from}          file available to fetch
-> filereq {fid}
<- <binary chunk frames...>
<- filedone {fid}
-> fileack {fid}                  mark received (deleted after a grace period)
<- presence {userId, online}
```

Offline messages are queued per-user under `data/queue/<userId>.jsonl` and
flushed on reconnect. Uploaded files are stored under `data/files/<fid>.bin`
and removed by a janitor ~10 minutes after a recipient acknowledges (or after
48 h if never claimed).

## Data on disk

```
data/
├── users.json            userId -> { publicKey, displayName, timestamps }
├── queue/<userId>.jsonl  undelivered envelopes
└── files/<fid>.bin       length-prefixed encrypted chunk frames
```

Everything stored is either public (public keys, display names) or ciphertext.
You can delete `data/` at any time to reset the relay.

## Deploy with Docker (recommended)

Everything you need is in this folder: `Dockerfile`, `docker-compose.yml`,
`Caddyfile`, `.dockerignore`.

**Fastest — build & run on any machine with Docker:**
```bash
cd server
docker compose up -d --build          # relay on http://<host>:8090
docker compose logs -f relay          # watch logs
docker compose ps                     # health status
```
State (users, offline queues, stored files) persists in the `relay-data`
Docker volume. To update: `git pull && docker compose up -d --build`.

**Add automatic HTTPS (TLS) with Caddy:**
1. Point your domain's DNS at the server.
2. Edit `Caddyfile` → replace `relay.example.com` with your domain.
3. `docker compose --profile tls up -d` → Caddy serves `wss://your-domain`
   and proxies to the relay (WebSockets included). In the app, set the relay
   URL to `https://your-domain`.

**Plain Docker (no compose):**
```bash
docker build -t 1190-chat-relay .
docker run -d --name chat1190-relay --restart unless-stopped \
  -p 8090:8090 -v relay-data:/data 1190-chat-relay
```

### CI: image on GHCR + one-click VPS deploy

Two workflows ship in `.github/workflows/`:

- **`server-image.yml`** — on changes to `server/**` (or a `v*` tag), builds
  the image and pushes it to `ghcr.io/<you>/1190-chat-relay` (tagged
  `latest`, semver, sha). No secrets needed beyond the default `GITHUB_TOKEN`.
- **`deploy.yml`** — manual ("Run workflow"): copies `server/` to your VPS and
  runs `docker compose up -d --build` there. Add these repo secrets first:
  `DEPLOY_HOST`, `DEPLOY_USER`, `DEPLOY_SSH_KEY` (private key), optional
  `DEPLOY_PORT`. The VPS just needs Docker + the Compose plugin.

Pull the published image on a VPS instead of building:
```bash
echo "$CR_PAT" | docker login ghcr.io -u <you> --password-stdin
docker pull ghcr.io/<you>/1190-chat-relay:latest
```
(then point `docker-compose.yml`'s `image:` at it and drop the `build:` key.)

## Production hardening checklist

This is a reference implementation. Before exposing it publicly:

- Put it behind **TLS** (a reverse proxy like Caddy/nginx → `wss://`, `https://`).
- Add **authentication** to `/register` and `hello` (e.g. signed challenge) so
  users can't claim arbitrary IDs, and **rate-limit** WS + HTTP.
- Cap `data/queue` and `data/files` sizes per user; add retention limits.
- Run as a non-root user; set `DATA_DIR` to a backed-up volume.
- Consider **key transparency** / a directory with signed keys so clients can
  verify each other's public keys out-of-band.

## Deploy example (systemd)

```ini
[Unit]
Description=1190 Chat relay
After=network.target

[Service]
WorkingDirectory=/opt/1190-chat/server
ExecStart=/usr/bin/node server.js
Environment=PORT=8090 DATA_DIR=/var/lib/chat1190
Restart=on-failure
User=chat1190

[Install]
WantedBy=multi-user.target
```
