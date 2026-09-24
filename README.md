# ClipHelm

Native macOS clip editor in development. Phase 4 adds media probing, source playback, thumbnails, frame sampling, audio extraction and editing proxies. Clip processing and final export remain planned.

## Run

Requires macOS 14+ and Xcode with Swift 6.

```bash
scripts/build-app.sh
open build/ClipHelm.app
```

Sources are read-only. Large video can use a temporary editing proxy while playback seeks in source time. FFmpeg at `/opt/homebrew/bin/ffmpeg` or `/usr/local/bin/ffmpeg` is an optional local fallback. Run `swift test --disable-sandbox`. See [architecture](docs/ARCHITECTURE.md) and [security](docs/SECURITY.md).
