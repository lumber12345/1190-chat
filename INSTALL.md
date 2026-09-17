# Installing 1190 Chat

There are two things you can install:

1. **The app** — onto an Android phone, iPhone/iPad, or Windows PC.
2. **The relay server** (optional) — only needed so people can reach each
   other *over the internet*. On the same Wi‑Fi, the app works with **no
   server at all** (LAN peer-to-peer).

Pick the platform(s) you want below. You do **not** need to build all three.

---

## ⭐ Easiest: build in the cloud with GitHub Actions (no local toolchain)

Don't want to install Flutter / Android Studio / Xcode / Visual Studio? Let
**GitHub build it for you.** A ready-made workflow is included at
`.github/workflows/build.yml`.

1. Push this folder to a GitHub repo:
   ```bash
   cd 1190-chat
   git init && git add -A && git commit -m "1190 Chat"
   git branch -M main
   git remote add origin https://github.com/YOUR_NAME/1190-chat.git
   git push -u origin main
   ```
2. On GitHub open the **Actions** tab. The push triggers **“Build & Release”**,
   which first runs the analyzer + tests, then builds:
   - **Android** → `app-release.apk` (installable) and `app-release.aab`
   - **Windows** → `chat1190-windows-x64.zip` (portable `.exe` + deps)
   - **Linux** → `chat1190-linux-x64.tar.gz`
3. Open the workflow run → **Artifacts** (bottom) → download. The Android APK
   is signed with the debug key, so it sideloads directly onto a phone.
4. **Publish a proper Release with all binaries attached** by pushing a tag:
   ```bash
   git tag v0.1.0 && git push --tags
   ```
   → a GitHub Release appears with the APK/AAB/zip/tar.gz attached.

> You can also start a build on demand: **Actions → Build & Release →
> “Run workflow”**. iOS is compile-checked on tags/dispatch but yields an
> *unsigned* app (installing on an iPhone needs your Apple signing — see §B).

Prefer to build on your own machine? Continue below.

---

## 0. One-time setup (any platform)

1. **Get the code** onto your computer (copy the `1190-chat/` folder, or
   unzip `1190-chat-source.zip`).
2. **Install the Flutter SDK** — <https://docs.flutter.dev/get-started/install>
   - Verify with:
     ```bash
     flutter doctor
     ```
     Fix anything it flags for the platform you care about.
3. **Fetch app dependencies:**
     ```bash
     cd 1190-chat/app
     flutter pub get
     ```

---

## A. Android

### Fastest: install straight onto your phone (debug build)
1. On the phone: **Settings → About → tap “Build number” 7 times** to enable
   Developer options, then **Developer options → USB debugging = ON**.
2. Plug in via USB (accept the “Allow USB debugging?” prompt).
3. Confirm it’s seen, then build+install+launch:
   ```bash
   flutter devices          # should list your phone
   flutter run              # installs and opens the app
   ```

### Distributable APK (sideload to any Android)
```bash
flutter build apk --release
# output: build/app/outputs/flutter-apk/app-release.apk
```
Copy that `.apk` to the phone and tap it (allow “Install unknown apps” when
prompted).

> **Signing note:** by default `flutter build apk --release` signs with the
> debug key — fine for personal sideloading. For the Play Store, create a
> release keystore and wire it up:
> ```bash
> keytool -genkey -v -keystore ~/upload-keystore.jks -keyalg RSA \
>   -keysize 2048 -validity 10000 -alias upload
> ```
> Create `android/key.properties`:
> ```
> storePassword=***
> keyPassword=***
> keyAlias=upload
> storeFile=/absolute/path/to/upload-keystore.jks
> ```
> Then reference it in `android/app/build.gradle.kts` (signingConfigs +
> `buildTypes.release.signingConfig`). See
> <https://docs.flutter.dev/deployment/android#signing-the-app>.
> For the Play Store use `flutter build appbundle --release` (`.aab`).

---

## B. iOS  (requires a Mac)

1. Install **Xcode** from the App Store, then:
   ```bash
   sudo xcodebuild -runFirstLaunch
   brew install cocoapods        # or: sudo gem install cocoapods
   ```
2. Get the project on the Mac and:
   ```bash
   cd 1190-chat/app
   flutter pub get
   ```
3. **Signing** (needed for a real device): open `ios/Runner.xcworkspace` in
   Xcode → select the **Runner** target → **Signing & Capabilities** →
   check *Automatically manage signing* → pick your **Team**.
   - A **free Apple ID** works for development (app re-signs every 7 days).
   - A paid **Apple Developer** account ($99/yr) is needed for TestFlight /
     the App Store.
   - If the bundle id `app.chat1190` is taken, change it to something unique
     like `com.yourname.chat1190` in that same screen.
4. Run it:
   ```bash
   flutter run                  # connected iPhone (trust the computer first)
   # or on a simulator:
   open -a Simulator
   flutter run
   ```
5. Release/TestFlight build:
   ```bash
   flutter build ipa            # then upload via Xcode Organizer / Transporter
   ```

> iOS LAN note: broadcasting to discover nearby devices may require Apple’s
> **multicast entitlement** on some iOS versions. Without it, iOS still works
> fully through the relay and can still *receive* direct LAN connections. The
> Local Network permission prompt is already configured in `Info.plist`.

---

## C. Windows

1. On a Windows PC, install **Visual Studio 2022** (Community is free) with
   the **“Desktop development with C++”** workload. Then:
   ```powershell
   flutter doctor               # should show Windows toolchain ✓
   flutter config --enable-windows-desktop
   ```
2. Build:
   ```powershell
   cd 1190-chat\app
   flutter pub get
   flutter build windows --release
   ```
   Output folder:
   `build\windows\x64\runner\Release\` — it contains `chat1190.exe` plus the
   DLLs and `data\` it needs.
3. **Run it:** double-click `chat1190.exe` (keep the whole `Release` folder
   together — the exe needs its sibling files).
4. **Make an installer (optional):** wrap that `Release` folder with
   [Inno Setup](https://jrsoftware.org/isinfo.php) or
   [MSIX](https://learn.microsoft.com/windows/msix/) to get a setup.exe /
   app package.

---

## D. Relay server (optional — for internet, not needed for LAN)

1. Install **Node.js 18+** — <https://nodejs.org>.
2. Run it:
   ```bash
   cd 1190-chat/server
   npm install
   npm start                     # listens on 0.0.0.0:8090
   ```
   - Self-test: `node smoke_test.js` (17 checks).
3. **Expose it to the internet** (so friends outside your network can reach
   you): run it on a small VPS and put it behind TLS, e.g. with
   [Caddy](https://caddyserver.com):
   ```
   relay.yourdomain.com {
       reverse_proxy localhost:8090
   }
   ```
   That gives you `wss://relay.yourdomain.com`.
4. In the app: **Settings → Relay server URL** → enter
   `https://relay.yourdomain.com` (or `http://YOUR_PC_LAN_IP:8090` for home
   testing) → **Save**.

> Production hardening (auth, rate limits, retention) is a checklist in
> `server/README.md`. The relay only ever stores ciphertext.

### Deploy on Render (easiest — free hosting with automatic HTTPS)

The repo includes a `render.yaml` blueprint, so the relay can be deployed
with zero configuration:

1. Delete any half-configured manual service first (optional).
2. Open **<https://render.com/deploy?repo=https://github.com/lumber12345/1190-chat>**
   (or Render dashboard → **New → Blueprint** → pick this repo).
3. Click **Apply** — Render reads `render.yaml` and creates the
   `chat1190-relay` web service (Node 20, root dir `server`, health check
   `/health`, free plan).
4. When the build finishes you get `https://chat1190-relay.onrender.com` —
   open `<that-url>/health` in a browser to confirm, then enter it in the
   app under **Settings → Relay server URL**.

Free-tier notes: the disk is ephemeral (registrations/offline queues are
wiped on restart — devices re-register themselves automatically) and the
service spins down after 15 min idle (first message pays a ~50 s cold
start). For persistence, see the commented-out `disk:`/`DATA_DIR` block in
`render.yaml` (requires the Starter plan).

### Run the relay with Docker (recommended for a server)

```bash
cd 1190-chat/server
docker compose up -d --build        # relay on :8090, state in a volume
# add automatic HTTPS (edit Caddyfile with your domain first):
docker compose --profile tls up -d  # Caddy serves wss://your-domain
```

There are also two ready-made GitHub Actions in `.github/workflows/`:
**`server-image.yml`** publishes the Docker image to GHCR on every server
change/tag, and **`deploy.yml`** (manual) copies the server to your VPS and
runs `docker compose up -d --build` over SSH. Both are documented in
`server/README.md`.

---

## E. First launch & connecting two people

1. Open the app → enter a **display name** → an encryption identity is
   generated on-device.
2. (Optional) add your **relay server URL** under Settings, or skip for
   LAN-only.
3. To chat with someone:
   - **Same Wi‑Fi:** open the **Nearby** tab — their device appears
     automatically. Tap to chat. Zero config.
   - **Different networks:** each person shares their **1190 Chat ID**
     (Settings → “Your 1190 Chat ID”, starts with `c_`). The other adds it via
     **Nearby → + (Add contact)**. Requires the relay server.
4. Send text, photos, or any file with the 📎 button. Files show live progress
   and are stored under the app’s documents folder.

---

## Troubleshooting

- **`flutter doctor` shows a missing toolchain** — install the item it names
  (Android Studio/SDK, Xcode, or Visual Studio C++).
- **Android build fails on Gradle/Java** — install the JDK bundled with
  Android Studio and open `android/` once in Android Studio to let it sync.
- **iOS `pod install` errors** — run `cd ios && pod repo update && pod install`.
- **Can’t see nearby devices** — confirm both are on the *same* subnet and
  that LAN discovery is ON in Settings; some corporate/hotel Wi‑Fi blocks
  device-to-device traffic (use the relay there).
- **Windows exe won’t start** — make sure you copied the entire `Release`
  folder, not just `chat1190.exe`.

---

## Appendix: Android release signing (Play Store)

The CI/debug-signed APK is fine for personal use and sideloading. To publish to
the Play Store (or drop the “debug-signed” warning), sign with your own
keystore:

1. **Create a keystore** (one time — back it up; every future update must be
   signed with the *same* key):
   ```bash
   keytool -genkey -v -keystore upload-keystore.jks -keyalg RSA \
     -keysize 2048 -validity 10000 -alias upload
   ```
2. **Create `app/android/key.properties`** (never commit it):
   ```
   storePassword=YOUR_STORE_PW
   keyPassword=YOUR_KEY_PW
   keyAlias=upload
   storeFile=/absolute/path/to/upload-keystore.jks
   ```
   Ensure `key.properties` and `*.jks` are git-ignored.
3. **Load it in `app/android/app/build.gradle.kts`** (official Flutter pattern):
   ```kotlin
   // just under the plugins { } block:
   val keystoreProperties = java.util.Properties()
   val keystorePropertiesFile = rootProject.file("key.properties")
   if (keystorePropertiesFile.exists()) {
       keystoreProperties.load(java.io.FileInputStream(keystorePropertiesFile))
   }

   // inside android { }:
   signingConfigs {
       if (keystorePropertiesFile.exists()) {
           create("release") {
               keyAlias = keystoreProperties["keyAlias"] as String
               keyPassword = keystoreProperties["keyPassword"] as String
               storeFile = file(keystoreProperties["storeFile"] as String)
               storePassword = keystoreProperties["storePassword"] as String
           }
       }
   }
   buildTypes {
       release {
           signingConfig = if (keystorePropertiesFile.exists())
               signingConfigs.getByName("release")
           else
               signingConfigs.getByName("debug")
       }
   }
   ```
4. **Sign in CI too (optional):** add repo secrets and have the workflow write
   `key.properties`. Store the keystore as base64:
   ```bash
   base64 -w0 upload-keystore.jks   # paste into secret ANDROID_KEYSTORE_BASE64
   ```
   Secrets to add: `ANDROID_KEYSTORE_BASE64`, `ANDROID_STORE_PASSWORD`,
   `ANDROID_KEY_PASSWORD`, `ANDROID_KEY_ALIAS`.

Reference: <https://docs.flutter.dev/deployment/android#signing-the-app>
