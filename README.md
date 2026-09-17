# 1190 Chat

**End-to-end encrypted messaging and file transfer** for Android, iOS and Windows
(with a bonus Linux desktop target). One Flutter codebase, one small Node.js
relay server.

Devices on the same network talk **directly** (peer-to-peer over LAN). When a
peer isn't reachable locally, messages and files fall back to a **self-hosted
relay** that only ever sees ciphertext. Either way the payload is sealed
end-to-end: X25519 key agreement → HKDF-SHA256 → AES-256-GCM.

```
┌────────────┐   LAN: UDP beacon + direct WebSocket (no server)   ┌────────────┐
│  Device A  │◀──────────────────────────────────────────────────▶│  Device B  │
│ (Flutter)  │                                                     │ (Flutter)  │
└─────┬──────┘   Internet: sealed envelopes via relay              └─────┬──────┘
      │            (server stores & forwards, cannot read)               │
      └───────────────────────────┐   ┌──────────────────────────────────┘
                                   ▼   ▼
                          ┌──────────────────┐
                          │  Relay (Node.js) │  sees: routing metadata + ciphertext
                          │  ws + http store │  never sees: plaintext / keys
                          └──────────────────┘
```

---

## Features

- **1:1 and group chats** with message history persisted in SQLite.
- **File & image transfer** with live progress, chunked and encrypted
  independently of the message stream (128 KB chunks, per-file AES-256-GCM key).
- **Two transports, one crypto core**
  - **LAN** — UDP broadcast discovery + direct WebSockets between peers.
  - **Relay** — WebSocket + HTTP store-and-forward for when peers are apart.
  - Automatic routing: prefer LAN, fall back to relay, queue in an outbox when
    offline and flush on reconnect.
- **Presence** (nearby / online / offline), **typing indicators**, and
  **delivery + read receipts**.
- **Cross-platform**: Android, iOS, Windows (and Linux) from a single codebase.

---

## Repository layout

```
1190-chat/
├── app/                     Flutter client (Android/iOS/Windows/Linux)
│   ├── lib/
│   │   ├── main.dart        app entry + theming + root routing
│   │   ├── models/          Contact, Conversation, Message, wire bodies
│   │   ├── services/
│   │   │   ├── crypto_service.dart   X25519 + HKDF + AES-GCM, file chunk crypto
│   │   │   ├── protocol.dart         envelope types + binary frame codec
│   │   │   ├── transport.dart        transport interface
│   │   │   ├── lan_transport.dart    UDP discovery + direct WebSockets
│   │   │   ├── relay_transport.dart  WebSocket/HTTP client for the relay
│   │   │   ├── storage_service.dart  SQLite persistence
│   │   │   └── chat_store.dart       orchestrator (ChangeNotifier)
│   │   └── ui/              onboarding, home (chats/nearby/settings), chat
│   └── test/                28 tests: crypto, protocol, integration, widgets
└── server/                  Node.js relay (ws + http), with smoke test
```

---

## Quick start

### 1. Run the relay server (optional — needed only for internet fallback)

```bash
cd server
npm install
npm start                 # listens on 0.0.0.0:8090
# verify:
node smoke_test.js        # 17 checks, all green
```

Set `PORT` / `HOST` / `DATA_DIR` via environment variables to override defaults.

### 2. Run the app

```bash
cd app
flutter pub get
flutter run               # pick a device/emulator
```

On first launch:
1. Enter a display name → a X25519 identity is generated **on device**.
2. (Optional) tap **Add relay server** and enter your server URL, e.g.
   `http://192.168.1.10:8090`. Leave it empty for **LAN-only** mode.
3. Open **Nearby** to see devices on the same network, or add a contact by
   their **1190 Chat ID** (found under their Settings). Tap to chat.

LAN mode works with **zero configuration** — no server required. Two devices on
the same Wi‑Fi will discover each other and transfer directly.

---

## Building release binaries

| Platform | Command | Requires |
|----------|---------|----------|
| **Android** | `flutter build apk --release` (or `appbundle`) | Android Studio / SDK + JDK |
| **iOS** | `flutter build ipa` | macOS + Xcode |
| **Windows** | `flutter build windows --release` | Windows + Visual Studio (C++ desktop workload) |
| Linux *(bonus)* | `flutter build linux --release` | clang, cmake, ninja, libgtk-3-dev |

Run each command from the `app/` directory on the appropriate host OS.

> iOS LAN note: broadcasting/discovering on the local network uses the Local
> Network permission (`NSLocalNetworkUsageDescription` is already set). For
> UDP **broadcast/multicast** on some iOS versions you may also need Apple's
> `com.apple.developer.networking.multicast` entitlement. Without it, iOS
> devices still work fully through the relay, and can still *receive* direct
> LAN connections.

---

## Security model

**What's protected**
- Each device holds a long-term **X25519** key pair; the private seed never
  leaves the device. The user ID is derived from the public key
  (`nk_` + SHA-256 prefix), so an ID is cryptographically bound to a key.
- 1:1 conversation keys = `HKDF-SHA256(X25519(privA, pubB))`, salted with the
  sorted public-key pair and bound to the conversation ID. Both sides derive
  the same key without ever transmitting it.
- Every message body and every file chunk is sealed with **AES-256-GCM**.
  Additional-authenticated-data binds the ciphertext to `type|conv|sender`, so
  an envelope can't be silently re-targeted to another chat.
- Files use a **fresh random per-file key** (carried inside the sealed offer);
  chunks use deterministic unique nonces (`base[0..8] || counter`).
- Groups use a random shared key distributed to each member **sealed under
  their 1:1 key**.

**The relay cannot read anything.** It stores/forwards `ct` (ciphertext) plus
routing metadata (`from`, `to`, `conv`, timestamps). Delivery/read receipts and
typing indicators are ephemeral and not queued.

**Honest limitations (v0.1)**
- **Trust-on-first-use**: public keys are learned from LAN beacons or relay
  lookup; there's no out-of-band verification yet. Compare the **key
  fingerprint** (Settings) over another channel to mitigate MITM.
- **No forward secrecy**: keys are static (long-term X25519). A future Double
  Ratchet would add FS + post-compromise security.
- **Relay has no auth/rate-limiting** in this demo. Harden before public
  deployment (see `server/README.md`).
- Group membership changes don't yet re-key past members.

These are documented deliberately — the crypto core is solid and well-tested,
but the key *distribution* and *ratcheting* are where a production messenger
needs more work.

---

## Testing

```bash
cd app && flutter test      # 28 tests
cd server && node smoke_test.js   # 17 checks
```

The integration test spins up two independent `ChatStore`s (Alice & Bob) over an
in-memory transport and verifies real end-to-end flows: sealed text delivery,
ciphertext-only wire, a 400 KB multi-chunk encrypted file transfer (byte-for-byte
identical on receipt), typing + read receipts, and SQLite persistence/reload.

---

## License

MIT — see headers. Built as a complete, runnable reference implementation.
