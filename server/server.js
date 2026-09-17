/**
 * 1190 Chat relay server
 * ---------------------
 * Routes end-to-end-encrypted envelopes between clients and store-and-forwards
 * encrypted files. The server NEVER sees plaintext: message payloads and file
 * bytes are sealed client-to-client (X25519 + AES-256-GCM).
 *
 * HTTP API
 *   GET  /health            -> { ok: true }
 *   POST /register          -> { userId, publicKey(b64), displayName }   (upsert)
 *   GET  /users/:id         -> { userId, displayName, publicKey }
 *
 * WebSocket API  (path: /ws)
 *   Text frames (JSON envelopes):
 *     -> hello      { userId }
 *     <- welcome    { userId, serverTime }
 *     -> msg|ginvite|filemeta { id, conv, to, ts, ct }      (ct = base64 ciphertext)
 *     <- ack        { id }                                  (delivered or queued)
 *     -> typing|receipt { id, conv, to, ct }                (dropped when peer offline)
 *     -> filestored { fid, to }                             (upload finished)
 *     <- fileready  { fid, from }                           (file available to fetch)
 *     -> filereq    { fid }
 *     <- [binary chunk frames...]
 *     <- filedone   { fid }
 *     -> fileack    { fid }                                 (server deletes stored file)
 *     <- presence   { userId, online }
 *     <- error      { message }
 *
 *   Binary frames (file chunks, opaque to the server):
 *     [uint32 BE header length][header JSON][AES-GCM ciphertext]
 *     header: { t: "chunk", fid, seq, conv, from, to }
 *
 * Storage: ./data/users.json, ./data/queue/<userId>.jsonl, ./data/files/<fid>.bin
 */

'use strict';

const http = require('http');
const fs = require('fs');
const fsp = fs.promises;
const path = require('path');
const { WebSocketServer } = require('ws');

const PORT = parseInt(process.env.PORT || '8090', 10);
const HOST = process.env.HOST || '0.0.0.0';
const DATA = process.env.DATA_DIR || path.join(__dirname, 'data');
const FILES_DIR = path.join(DATA, 'files');
const QUEUE_DIR = path.join(DATA, 'queue');
const USERS_FILE = path.join(DATA, 'users.json');
const MAX_FRAME = 16 * 1024 * 1024; // max stored binary frame size

const ID_RE = /^[A-Za-z0-9_-]{2,64}$/;
const FID_RE = /^[A-Za-z0-9_-]{1,64}$/;

for (const d of [DATA, FILES_DIR, QUEUE_DIR]) fs.mkdirSync(d, { recursive: true });

/* ------------------------------------------------------------------ users */

let users = {};
try {
  users = JSON.parse(fs.readFileSync(USERS_FILE, 'utf8'));
} catch (_) {
  users = {};
}

let saveTimer = null;
function saveUsers() {
  if (saveTimer) return;
  saveTimer = setTimeout(() => {
    saveTimer = null;
    fs.writeFile(USERS_FILE, JSON.stringify(users, null, 2), () => {});
  }, 500);
}

/* ------------------------------------------------------------ simple lock */

const locks = new Map();
function withLock(key, fn) {
  const prev = locks.get(key) || Promise.resolve();
  const next = prev.then(fn, fn);
  locks.set(
    key,
    next.catch(() => {})
  );
  return next;
}

/* --------------------------------------------------------------- http api */

function json(res, code, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(code, {
    'content-type': 'application/json',
    'access-control-allow-origin': '*',
    'access-control-allow-headers': 'content-type',
    'access-control-allow-methods': 'GET,POST,OPTIONS',
    'content-length': Buffer.byteLength(body),
  });
  res.end(body);
}

function readBody(req, limit = 1e6) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on('data', (c) => {
      size += c.length;
      if (size > limit) {
        reject(new Error('body too large'));
        req.destroy();
        return;
      }
      chunks.push(c);
    });
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    req.on('error', reject);
  });
}

const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, 'http://localhost');

    if (req.method === 'OPTIONS') {
      res.writeHead(204, {
        'access-control-allow-origin': '*',
        'access-control-allow-headers': 'content-type',
        'access-control-allow-methods': 'GET,POST,OPTIONS',
      });
      return res.end();
    }

    if (url.pathname === '/health') {
      return json(res, 200, { ok: true, uptime: process.uptime(), users: Object.keys(users).length });
    }

    if (req.method === 'POST' && url.pathname === '/register') {
      const body = JSON.parse((await readBody(req)) || '{}');
      const { userId, publicKey, displayName } = body;
      if (!userId || !ID_RE.test(userId)) return json(res, 400, { error: 'bad userId' });
      if (!publicKey || typeof publicKey !== 'string' || publicKey.length > 256)
        return json(res, 400, { error: 'bad publicKey' });
      const existing = users[userId];
      users[userId] = {
        publicKey,
        displayName: String(displayName || userId).slice(0, 64),
        createdAt: existing ? existing.createdAt : Date.now(),
        updatedAt: Date.now(),
      };
      saveUsers();
      return json(res, 200, { ok: true });
    }

    if (req.method === 'GET' && url.pathname.startsWith('/users/')) {
      const id = decodeURIComponent(url.pathname.slice('/users/'.length));
      const u = users[id];
      if (!u) return json(res, 404, { error: 'not found' });
      return json(res, 200, {
        userId: id,
        displayName: u.displayName,
        publicKey: u.publicKey,
        online: clients.has(id),
      });
    }

    return json(res, 404, { error: 'not found' });
  } catch (e) {
    return json(res, 500, { error: 'internal error' });
  }
});

/* -------------------------------------------------------------- websocket */

const wss = new WebSocketServer({ server, path: '/ws', maxPayload: MAX_FRAME });
/** @type {Map<string, Set<import('ws').WebSocket>>} */
const clients = new Map();

function send(ws, obj) {
  if (ws && ws.readyState === 1) ws.send(JSON.stringify(obj));
}

function sendBin(ws, buf) {
  if (ws && ws.readyState === 1) ws.send(buf, { binary: true });
}

function socketsFor(userId) {
  const set = clients.get(userId);
  return set && set.size ? set : null;
}

function broadcastPresence(userId, online, except) {
  const ev = JSON.stringify({ type: 'presence', userId, online });
  for (const set of clients.values()) {
    for (const s of set) {
      if (s !== except && s.readyState === 1 && s.userId) s.send(ev);
    }
  }
}

/* --------------------------------------------------------- offline queues */

function queueFile(userId) {
  return path.join(QUEUE_DIR, `${userId}.jsonl`);
}

async function enqueue(userId, obj) {
  if (!ID_RE.test(userId)) return;
  await withLock(`q:${userId}`, async () => {
    const f = queueFile(userId);
    // cap the queue file so a dead account can't fill the disk
    try {
      const st = await fsp.stat(f);
      if (st.size > 8 * 1024 * 1024) return;
    } catch (_) {}
    await fsp.appendFile(f, JSON.stringify({ ...obj, _q: Date.now() }) + '\n');
  });
}

async function flushQueue(ws, userId) {
  await withLock(`q:${userId}`, async () => {
    const f = queueFile(userId);
    let content;
    try {
      content = await fsp.readFile(f, 'utf8');
    } catch (_) {
      return;
    }
    await fsp.writeFile(f, '');
    for (const line of content.split('\n')) {
      const t = line.trim();
      if (!t) continue;
      try {
        if (ws.readyState === 1) ws.send(t);
      } catch (_) {}
    }
  });
}

/* ------------------------------------------------------------- file store */

async function appendChunkFrame(fid, buf) {
  const file = path.join(FILES_DIR, `${fid}.bin`);
  const rec = Buffer.allocUnsafe(4 + buf.length);
  rec.writeUInt32BE(buf.length, 0);
  buf.copy(rec, 4);
  await withLock(`f:${fid}`, () => fsp.appendFile(file, rec));
}

async function streamFile(ws, fid) {
  if (!FID_RE.test(String(fid || ''))) return;
  const file = path.join(FILES_DIR, `${fid}.bin`);
  let fd;
  try {
    fd = await fsp.open(file, 'r');
  } catch (_) {
    return send(ws, { type: 'error', message: 'file not found', fid });
  }
  try {
    const lenBuf = Buffer.alloc(4);
    for (;;) {
      const r = await fd.read(lenBuf, 0, 4, null);
      if (r.bytesRead < 4) break;
      const len = lenBuf.readUInt32BE(0);
      if (len <= 0 || len > MAX_FRAME) break;
      const rec = Buffer.allocUnsafe(len);
      let off = 0;
      while (off < len) {
        const rr = await fd.read(rec, off, len - off, null);
        if (rr.bytesRead === 0) break;
        off += rr.bytesRead;
      }
      if (off < len) break;
      if (ws.readyState !== 1) return;
      sendBin(ws, rec);
    }
    send(ws, { type: 'filedone', fid });
  } finally {
    await fd.close();
  }
}

/* --------------------------------------------------------- ws message bus */

async function handleJson(ws, m) {
  switch (m.type) {
    case 'hello': {
      const id = m.userId;
      if (!id || !ID_RE.test(id)) return send(ws, { type: 'error', message: 'bad userId' });
      ws.userId = id;
      if (!clients.has(id)) clients.set(id, new Set());
      clients.get(id).add(ws);
      send(ws, { type: 'welcome', userId: id, serverTime: Date.now() });
      broadcastPresence(id, true, ws);
      await flushQueue(ws, id);
      break;
    }

    case 'msg':
    case 'ginvite':
    case 'filemeta': {
      if (!ws.userId || !m.to || !m.id) return;
      m.from = ws.userId; // stamp the authenticated sender
      const set = socketsFor(m.to);
      if (set) {
        for (const s of set) send(s, m);
      } else {
        await enqueue(m.to, m);
      }
      send(ws, { type: 'ack', id: m.id });
      break;
    }

    case 'typing':
    case 'receipt': {
      if (!ws.userId || !m.to) return;
      m.from = ws.userId;
      const set = socketsFor(m.to);
      if (set) for (const s of set) send(s, m); // ephemeral: never queued
      break;
    }

    case 'filestored': {
      if (!ws.userId || !FID_RE.test(String(m.fid || '')) || !m.to) return;
      const ev = { type: 'fileready', fid: m.fid, from: ws.userId };
      const set = socketsFor(m.to);
      if (set) {
        for (const s of set) send(s, ev);
      } else {
        await enqueue(m.to, ev);
      }
      send(ws, { type: 'ack', id: m.fid, t: 'filestored' });
      break;
    }

    case 'filereq': {
      await streamFile(ws, m.fid);
      break;
    }

    case 'fileack': {
      if (!FID_RE.test(String(m.fid || ''))) return;
      // Grace period before deletion: other group members may still be
      // fetching the same fid. A janitor performs the actual removal.
      ackedAt.set(String(m.fid), Date.now());
      break;
    }

    case 'ping':
      send(ws, { type: 'pong', t: Date.now() });
      break;

    default:
      break;
  }
}

async function handleBinary(ws, buf) {
  if (!ws.userId || buf.length < 8) return;
  const hdrLen = buf.readUInt32BE(0);
  if (hdrLen <= 0 || hdrLen > 4096 || buf.length < 4 + hdrLen) return;
  let hdr;
  try {
    hdr = JSON.parse(buf.slice(4, 4 + hdrLen).toString('utf8'));
  } catch (_) {
    return;
  }
  if (hdr.t !== 'chunk' || !FID_RE.test(String(hdr.fid || ''))) return;
  await appendChunkFrame(hdr.fid, buf);
}

wss.on('connection', (ws) => {
  ws.userId = null;
  ws.isAlive = true;
  ws.on('pong', () => {
    ws.isAlive = true;
  });

  ws.on('message', (data, isBinary) => {
    (async () => {
      try {
        if (isBinary) {
          await handleBinary(ws, Buffer.from(data));
        } else {
          const m = JSON.parse(Buffer.from(data).toString('utf8'));
          await handleJson(ws, m);
        }
      } catch (e) {
        send(ws, { type: 'error', message: 'bad request' });
      }
    })();
  });

  ws.on('close', () => detach(ws));
  ws.on('error', () => detach(ws));
});

function detach(ws) {
  const id = ws.userId;
  if (!id) return;
  ws.userId = null;
  const set = clients.get(id);
  if (set) {
    set.delete(ws);
    if (set.size === 0) {
      clients.delete(id);
      broadcastPresence(id, false);
    }
  }
}

/* ------------------------------------------------------------- heartbeats */

// fid -> timestamp when a recipient confirmed receipt.
const ackedAt = new Map();
const ACK_GRACE_MS = 10 * 60 * 1000; // delete 10 min after first ack
const ORPHAN_TTL_MS = 48 * 60 * 60 * 1000; // delete unclaimed files after 48 h

// janitor: remove acked files after the grace period, orphans after the TTL
setInterval(() => {
  const now = Date.now();
  for (const [fid, t] of ackedAt) {
    if (now - t > ACK_GRACE_MS) {
      ackedAt.delete(fid);
      fs.rm(path.join(FILES_DIR, `${fid}.bin`), () => {});
    }
  }
  fs.readdir(FILES_DIR, (err, names) => {
    if (err) return;
    for (const name of names) {
      if (!name.endsWith('.bin')) continue;
      const fid = name.slice(0, -4);
      if (ackedAt.has(fid)) continue;
      fs.stat(path.join(FILES_DIR, name), (e2, st) => {
        if (e2 || !st) return;
        if (now - st.mtimeMs > ORPHAN_TTL_MS) fs.rm(path.join(FILES_DIR, name), () => {});
      });
    }
  });
}, 60 * 1000);

setInterval(() => {
  for (const set of clients.values()) {
    for (const ws of set) {
      if (!ws.isAlive) {
        try {
          ws.terminate();
        } catch (_) {}
        detach(ws);
        continue;
      }
      ws.isAlive = false;
      try {
        ws.ping();
      } catch (_) {}
    }
  }
}, 30000);

server.listen(PORT, HOST, () => {
  console.log(`1190 Chat relay listening on ${HOST}:${PORT} (data: ${DATA})`);
});
