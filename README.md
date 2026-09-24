# ClipHelm

Native macOS clip editor in development. Phase 3 adds validated local MP4/MKV/MOV ingestion, drag and drop, direct HTTPS video download and authorized public YouTube import. Processing and export remain planned.

## Run

Requires macOS 14+ and Xcode with Swift 6.

```bash
scripts/build-app.sh
open build/ClipHelm.app
```

Remote sources are temporary and session-only. ClipHelm refuses private/protected media and never persists URL credentials. Settings stores one OpenRouter key in Keychain. Run `swift test --disable-sandbox` for source, core, gateway and app checks. See [architecture](docs/ARCHITECTURE.md) and [security](docs/SECURITY.md).
