# ClipHelm

Native macOS clip editor in development. Phase 1 adds the Home, Recent Projects, New Clip Project, Settings and Project Workspace shell. The guided flow saves draft choices; media processing is planned.

## Run

Requires macOS 14+ and Xcode with Swift 6.

```bash
scripts/build-app.sh
open build/ClipHelm.app
```

Run `swift test --disable-sandbox` for core validation and app restoration/layout checks. Architecture is in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).
