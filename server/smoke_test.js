/**
 * Smoke test for the 1190 Chat relay server.
 * Starts the server, registers two users, and verifies:
 *   1. online message routing (msg + ack)
 *   2. offline queueing (message to a disconnected user, then flush on reconnect)
 *   3. store-and-forward of a binary file (upload chunks, fileready, filereq, download, fileack)
 *   4. presence broadcasts
 */
'use strict';

const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');
const WebSocket = require('ws');

const PORT = 8099;
const BASE = `http://127.0.0.1:${PORT}`;
const DATA = path.join(__dirname, 'data_test');

let passed = 0;
let failed = 0;
function check(name, cond, extra) {
  if (cond) {
    passed++;
    console.log(`  PASS  ${name}`);
  } else {
    failed++;
    console.log(`  FAIL  ${name}${extra ? ' :: ' + extra : ''}`);
  }
}

function waitFor(pred, ms = 4000) {
  const start = Date.now();
  return new Promise((resolve) => {
    const t = setInterval(() => {
      let v;
      try {
        v = pred();
      } catch (_) {
        v = null;
      }
      if (v) {
        clearInterval(t);
        resolve(v);
      } else if (Date.now() - start > ms) {
        clearInterval(t);
        resolve(null);
      }
    }, 25);
  });
}

function openClient(userId) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(`ws://127.0.0.1:${PORT}/ws`);
    const inbox = [];
    const binInbox = [];
    ws.on('open', () => {
      ws.send(JSON.stringify({ type: 'hello', userId }));
      resolve({ ws, inbox, binInbox });
    });
    ws.on('message', (data, isBinary) => {
      if (isBinary) binInbox.push(Buffer.from(data));
      else inbox.push(JSON.parse(data.toString()));
    });
    ws.on('error', reject);
  });
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function main() {
  fs.rmSync(DATA, { recursive: true, force: true });
  const proc = spawn(process.execPath, [path.join(__dirname, 'server.js')], {
    env: { ...process.env, PORT: String(PORT), DATA_DIR: DATA },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  proc.stdout.on('data', () => {});
  proc.stderr.on('data', (d) => console.error('server:', d.toString()));

  try {
    // wait for health
    let up = false;
    for (let i = 0; i < 50; i++) {
      try {
        const r = await fetch(`${BASE}/health`);
        if (r.ok) {
          up = true;
          break;
        }
      } catch (_) {}
      await sleep(100);
    }
    check('server starts /health', up);
    if (!up) return;

    // register two users
    let r = await fetch(`${BASE}/register`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ userId: 'alice', publicKey: 'cHViLWFsaWNl', displayName: 'Alice' }),
    });
    check('register alice', (await r.json()).ok === true);
    r = await fetch(`${BASE}/register`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ userId: 'bob', publicKey: 'cHViLWJvYg==', displayName: 'Bob' }),
    });
    check('register bob', (await r.json()).ok === true);

    // lookup
    r = await fetch(`${BASE}/users/bob`);
    const bob = await r.json();
    check('lookup bob returns publicKey', bob.publicKey === 'cHViLWJvYg==' && bob.displayName === 'Bob');

    // presence: alice sees bob come online
    const alice = await openClient('alice');
    await sleep(150);
    const bobC = await openClient('bob');
    const presence = await waitFor(() => alice.inbox.find((m) => m.type === 'presence' && m.userId === 'bob' && m.online));
    check('alice receives presence(bob online)', !!presence);

    // online msg routing
    alice.ws.send(
      JSON.stringify({ type: 'msg', id: 'm1', conv: 'dm:alice+bob', to: 'bob', ts: Date.now(), ct: 'SEVMTE8=' })
    );
    const gotMsg = await waitFor(() => bobC.inbox.find((m) => m.type === 'msg' && m.id === 'm1'));
    check('bob receives msg m1 with stamped from', !!gotMsg && gotMsg.from === 'alice' && gotMsg.ct === 'SEVMTE8=');
    const ack = await waitFor(() => alice.inbox.find((m) => m.type === 'ack' && m.id === 'm1'));
    check('alice receives ack for m1', !!ack);

    // typing is ephemeral
    alice.ws.send(JSON.stringify({ type: 'typing', id: 't1', conv: 'dm:alice+bob', to: 'bob', ct: 'eA==' }));
    const typing = await waitFor(() => bobC.inbox.find((m) => m.type === 'typing'));
    check('typing routed', !!typing);

    // offline queue: disconnect bob, alice sends m2, bob reconnects and flushes
    bobC.ws.close();
    await sleep(200);
    alice.ws.send(JSON.stringify({ type: 'msg', id: 'm2', conv: 'dm:alice+bob', to: 'bob', ts: Date.now(), ct: 'T0ZGTElORQ==' }));
    const ack2 = await waitFor(() => alice.inbox.find((m) => m.type === 'ack' && m.id === 'm2'));
    check('ack for queued m2', !!ack2);
    const bob2 = await openClient('bob');
    const flushed = await waitFor(() => bob2.inbox.find((m) => m.type === 'msg' && m.id === 'm2'));
    check('bob receives queued m2 after reconnect', !!flushed && flushed.ct === 'T0ZGTElORQ==');

    // file store-and-forward: alice uploads 3 chunks for bob (offline flow via relay)
    const payload = Buffer.from('chat1190-secret-file-bytes');
    const chunks = [];
    for (let i = 0; i < 3; i++) chunks.push(payload.subarray(i * 9, Math.min((i + 1) * 9, payload.length)));

    // send filemeta first (bob is online now via bob2)
    alice.ws.send(
      JSON.stringify({ type: 'filemeta', id: 'fm1', conv: 'dm:alice+bob', to: 'bob', ts: Date.now(), ct: 'TUVUQQ==' })
    );
    const meta = await waitFor(() => bob2.inbox.find((m) => m.type === 'filemeta' && m.id === 'fm1'));
    check('bob receives filemeta', !!meta);

    // upload binary chunk frames
    for (let i = 0; i < chunks.length; i++) {
      const hdr = Buffer.from(JSON.stringify({ t: 'chunk', fid: 'file1', seq: i, conv: 'dm:alice+bob', from: 'alice', to: 'bob' }));
      const frame = Buffer.alloc(4 + hdr.length + chunks[i].length);
      frame.writeUInt32BE(hdr.length, 0);
      hdr.copy(frame, 4);
      chunks[i].copy(frame, 4 + hdr.length);
      alice.ws.send(frame);
    }
    await sleep(250);
    alice.ws.send(JSON.stringify({ type: 'filestored', fid: 'file1', to: 'bob' }));
    const ready = await waitFor(() => bob2.inbox.find((m) => m.type === 'fileready' && m.fid === 'file1'));
    check('bob receives fileready', !!ready);

    // bob requests the file
    bob2.ws.send(JSON.stringify({ type: 'filereq', fid: 'file1' }));
    const done = await waitFor(() => bob2.inbox.find((m) => m.type === 'filedone' && m.fid === 'file1'), 6000);
    check('bob receives filedone', !!done);
    // Each forwarded frame is [u32 hdrLen][header JSON][ciphertext]; strip headers and reassemble.
    const bodies = [];
    for (const frame of bob2.binInbox) {
      const hdrLen = frame.readUInt32BE(0);
      bodies.push(frame.subarray(4 + hdrLen));
    }
    const reassembled = Buffer.concat(bodies);
    check('file bytes intact after store-and-forward', reassembled.equals(payload), `got ${reassembled.length} bytes`);
    check('received 3 chunk frames', bob2.binInbox.length === 3, `got ${bob2.binInbox.length}`);

    // fileack registers for deletion after a grace period (not immediate,
    // so other group members can still fetch the same fid).
    bob2.ws.send(JSON.stringify({ type: 'fileack', fid: 'file1' }));
    await sleep(150);
    check('fileack accepted (file kept during grace period)', fs.existsSync(path.join(DATA, 'files', 'file1.bin')));

    // queue file cleared after flush
    const qf = path.join(DATA, 'queue', 'bob.jsonl');
    check('queue file cleared after flush', !fs.existsSync(qf) || fs.readFileSync(qf, 'utf8').trim() === '');

    alice.ws.close();
    bob2.ws.close();
  } finally {
    proc.kill('SIGTERM');
    await sleep(200);
    try { proc.kill('SIGKILL'); } catch (_) {}
    fs.rmSync(DATA, { recursive: true, force: true });
  }

  console.log(`\n${passed} passed, ${failed} failed`);
  process.exit(failed ? 1 : 0);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
