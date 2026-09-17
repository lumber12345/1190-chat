# 1190 Chat app (Flutter)

Cross-platform client for **Android, iOS, Windows** (and Linux). End-to-end
encrypted messaging + file transfer over LAN (peer-to-peer) and an internet
relay.

See the [top-level README](../README.md) for architecture and security details.

## Develop

```bash
flutter pub get
flutter run                 # select a device with: flutter devices
flutter test                # 28 tests
flutter analyze             # clean
```

## Build

```bash
flutter build apk --release          # Android
flutter build ipa                    # iOS (on macOS)
flutter build windows --release      # Windows (on Windows)
flutter build linux --release        # Linux
```

## Code map (`lib/`)

- `main.dart` — bootstrap, theming (Material 3), root routing.
- `models/models.dart` — `Contact`, `Conversation`, `Message`, sealed bodies.
- `services/crypto_service.dart` — identity, X25519 ECDH + HKDF conversation
  keys, AES-256-GCM seal/open, per-file chunk crypto.
- `services/protocol.dart` — envelope type constants + binary chunk-frame codec.
- `services/transport.dart` — transport interface.
- `services/lan_transport.dart` — UDP discovery + direct WebSockets.
- `services/relay_transport.dart` — WebSocket/HTTP relay client.
- `services/storage_service.dart` — SQLite (FFI on desktop) persistence.
- `services/chat_store.dart` — orchestrator: routing, send/receive, files,
  receipts, typing, groups, outbox retry.
- `ui/` — onboarding, home (Chats / Nearby / Settings), chat screen, widgets.

## Platform notes

- **Android**: `INTERNET`, `ACCESS_NETWORK_STATE`, `ACCESS_WIFI_STATE`,
  `CHANGE_WIFI_MULTICAST_STATE` declared in `AndroidManifest.xml`.
- **iOS**: `NSLocalNetworkUsageDescription`, `NSPhotoLibraryUsageDescription`
  and an ATS exception (for `ws://`/`http://` dev relays) in `Info.plist`.
  UDP broadcast may additionally require Apple's multicast entitlement.
- **Windows/Linux**: sockets work out of the box; SQLite uses `sqflite_common_ffi`.
