# Release checklist

This is a release gate, not a claim that ClipHelm is ready to ship. Record the Mac model, macOS version, source rights, measurements, and reviewer for each manual run.

The current pass/fail ledger and verification steps are in [docs/RELEASE_CHECKLIST.md](docs/RELEASE_CHECKLIST.md).

## Automated gates

- [x] Build and sign the macOS app with `scripts/build-app.sh`.
- [x] Run `swift test --disable-sandbox` with Keychain/media access; no paid API calls.
- [x] Cover cancellation and retry at direct download, transcription, analysis, OpenRouter response, rendering, and project save boundaries.
- [x] Reject untrusted AI fields before editing; no AI-provided executable instructions.
- [x] Audit Keychain, request headers, project persistence, logs, and subprocess arguments with a fake key.

## Required before external release

- [ ] Run the ten-content-type review matrix on rights-cleared real videos; score moment and boundary quality, crop/face retention, demo readability, layout stability, speech cuts, captions, audio sync, and render quality. Record failures as minimized regression fixtures.
- [ ] Run complete 30-minute, 1-hour, 2-hour, and 4-hour media jobs at 1080p and 4K on target Macs. Record wall time, peak resident memory, CPU, GPU/VideoToolbox activity, output size, and disk use. The current benchmark covers synthetic planning timelines and one-second real render fixtures only.
- [x] Disable direct video URL import in public builds before DNS or network access; keep the unsafe downloader unavailable until connected-address validation and adversarial tests exist.
- [ ] Review macOS diagnostic/core-dump policy and support collection for in-memory credentials.
- [ ] Inspect an exported clip from every real-video class for natural speech joins, accurate captions, AV sync, face retention, readable demos, and visual artifacts.
- [ ] Exercise launch, resize, source reattachment, edit, batch export, deletion, cancellation, and restart interactively in the packaged app.
- [ ] Verify YouTube support only on media the tester owns or has permission to process; confirm DRM/private-media restrictions are respected.

Measurements and the current coverage matrix: [docs/QUALITY_BENCHMARK.md](docs/QUALITY_BENCHMARK.md). Security findings: [SECURITY.md](SECURITY.md).
