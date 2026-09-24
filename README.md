# ClipHelm

Native macOS clip editor in development. Phase 2 adds one OpenRouter credential stored only in macOS Keychain, a sanitized gateway, model discovery, and connection settings. Clip processing is planned.

## Run

Requires macOS 14+ and Xcode with Swift 6.

```bash
scripts/build-app.sh
open build/ClipHelm.app
```

Settings → OpenRouter can add, test, replace, or remove a key. Model discovery is capability-based. Tests use mocks and do not spend API credits. Run `swift test --disable-sandbox`. See [architecture](docs/ARCHITECTURE.md) and [security](docs/SECURITY.md).
