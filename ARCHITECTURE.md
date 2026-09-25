# Current architecture

ClipHelm is a native macOS SwiftUI application. `SourceIngestor` prepares local or authorized remote media. Local `Media`, `Transcription`, and `Analysis` modules produce timeline evidence. `MomentEngine` selects candidate windows and uses `OpenRouterGateway` for bounded semantic evaluation. `ClipPlanner` combines validated proposals, user configuration, and local evidence into `ClipHelmEditSpec`. Framing, layout, pacing, captions, and AVFoundation rendering remain local. The results workspace saves corrections and exports selected clips.

The OpenRouter key is held only by `OpenRouterSecretVault` in Keychain. AI responses are untrusted data and cannot supply a renderer command, path, URL, or FFmpeg argument. Project manifests are versioned and atomic; source originals are never modified. A canceled batch discards only new generated files from that run, while accepted project clips remain.

The complete module dependency table, data flow, and edit-spec contract are in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and [docs/EDIT_SPEC.md](docs/EDIT_SPEC.md). Phase 16's evidence and limits are in [docs/QUALITY_BENCHMARK.md](docs/QUALITY_BENCHMARK.md).
