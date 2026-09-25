# ClipHelm architecture (Phase 0)

ClipHelm is a local-first native macOS editor. Its own pipeline owns media, timeline, framing, captions, and rendering. OpenRouter supplies bounded semantic suggestions through one gateway; it never edits media or emits executable renderer input.

## Module boundaries

Dependencies point downward. `ClipHelmCore`, `ClipHelmSecurity`, `ClipHelmOpenRouter`, `ClipHelmMedia`, `ClipHelmSources`, `ClipHelmTranscription`, `ClipHelmAnalysis`, `ClipHelmMoments`, `ClipHelmEditing`, and the `ClipHelmApp` shell are implemented targets. The remaining modules are design boundaries for later phases.

| Module | Owns | May depend on |
| --- | --- | --- |
| Core | IDs, media time, typed evidence, proposals, configuration, edit spec | Foundation |
| Security | `OpenRouterSecretVault` backed by Keychain, redaction policy | Security framework, Foundation |
| OpenRouter | One inference gateway, model discovery/capability selection, bounded request/response decoding | Core, Security |
| Sources | `SourceIngestor`, local file access, permitted remote acquisition | Core, Media |
| Projects | Project manifest, migrations, atomic saves, regeneratable cache references | Core |
| Media | Metadata, source playback, thumbnails, frame sampling, audio extraction, editing proxies | Core |
| Transcription | Chunked speech-to-word timeline, backend selection and normalization | Core, Media, OpenRouter |
| Analysis | Local scene, subject, audio activity and pause evidence | Core, Media |
| Moments | Hierarchical local candidates, bounded semantic scoring, ranking and deduplication | Core, Analysis, OpenRouter |
| Clipping | `ClipPlanner`: validates proposals/intents and selects source intervals | Core, Analysis |
| Framing | Tracking and crop trajectories for each shot | Core, Analysis |
| Layouts | Canvas placement for full-frame and blurred compositions | Core, Framing |
| Pacing | Dead-air, pause and filler cut proposals | Core, Transcription, Analysis |
| Captions | Word segmentation and style timing | Core, Transcription |
| Editing | Implemented `ClipHelmEditing`: deterministic planning, source/edited timeline mapping, spec validation, typed operations, and in-memory undo/redo | Core, Analysis |
| Rendering | Preview/export compiler, AVFoundation/VideoToolbox; optional FFmpeg adapter | Core, Media, Editing |
| SharedUI | Reusable SwiftUI controls and presentation | Core, SwiftUI |

The app target is the composition root. Settings wires the Keychain vault and OpenRouter gateway; the workspace uses media playback and starts a cancellable proxy task when the source is large. Service modules do not import SwiftUI. `Sources` is the only remote-media entry point; `OpenRouter` is the only AI network entry point. Renderer adapters accept validated `ClipHelmEditSpec`, never model text or raw network input.

Phase 2 model discovery fetches the OpenRouter catalog and the separately filtered transcription catalog. The registry derives text, vision, structured-output, and transcription candidates from catalog metadata, then validates a selected model against each task's required capabilities. Only selected model IDs are saved in preferences. Catalog claims are discovery hints; a later inference phase must handle per-provider capability failures.

Phase 3 `SourceIngestor` owns local inspection, direct HTTPS downloads, and the optional public YouTube adapter. `SourceDescriptor` accepts only validated user-authorized sources. The app receives progress and a `PreparedSource` with a local file URL and `MediaAsset` metadata. Project drafts persist metadata and a safe label; source access and downloaded bytes remain session-only until a later project-media phase defines durable references.

Phase 4 `MediaProbe` is shared by ingestion and editing. `PlaybackEngine` plays a source or proxy using `MediaTimeMap` to translate seeks and displayed time. `ThumbnailEngine` and `FrameSampler` decode one requested frame at a time. `AudioExtractor` writes AAC audio; `ProxyEngine` creates a 720p editing copy for sources above 1080p or 1 GB. Export and frame generation try AVFoundation first; an optional fixed-path FFmpeg adapter handles local decoder failures with array arguments, no shell, and a file-only protocol whitelist. Jobs report progress and cancellation, and failed partial outputs are removed. The original is never rewritten.

Phase 5 `TranscriptEngine` splits source audio into bounded chunks, checks for audible activity, calls one `TranscriptionBackend` per active chunk, validates relative word times, maps them to the source timeline and groups words into speaker-aware segments. `AppleSpeechBackend` requires on-device recognition; `OpenRouterTranscriptionBackend` sends only short audio chunks through `OpenRouterGateway` after an explicit user action. Both produce the same typed transcript. The workspace stores completed transcripts, supports search and seek, and leaves captions off when no words were recognized.

Phase 6 `AnalysisEngine` runs only after the user starts local analysis in the workspace. It samples at most about 3,600 frames with AVFoundation, uses Vision for face/person and text-box detections, measures frame changes, and streams PCM audio in 250 ms windows. Audio windows widen for unusually long recordings to cap stored evidence near 100,000 windows. It combines these into possible scene, motion, pause, subject, screen, and content-type evidence. Each signal carries source-media time, strength, and confidence. Talking head, conversation, screen share, presentation, demo, and gameplay labels are conservative heuristics; uncertain windows remain `unknown`. These confidence values are estimates, not calibrated probabilities, and fall as sampling becomes coarser. Scene boundaries may be seconds off in long recordings; quiet audio is only a possible pause. No vision AI or OpenRouter call occurs. The original source is read only. Completed analysis is stored in a private, disposable, versioned cache; see `PROJECT_FORMAT.md`.

Phase 7 `MomentEngine` partitions transcript and analysis evidence into source-time boundaries, builds duration-aware candidates locally, and sends only bounded candidate excerpts to a user-selected structured-output OpenRouter model. A `ClipProposal` must echo the exact local candidate ID, asset, and range; malformed or extra renderer fields are rejected. Ranking, quality thresholds, repeated-idea removal, duration checks, and count limits remain local. Silent demos use local visual evidence and are labeled for manual review. The workspace runs discovery on request, shows progress, supports cancellation, and can seek to results. No cuts or render specs are made in this phase.

Phase 8 extends the guided project setup with destination, framing, smart editing, pacing, multiple lengths, count target, sound, and caption effects. The SwiftUI draft converts to one validated `ClipConfiguration` at save time. The project manifest stores that core value; the clipping engine has no dependency on SwiftUI or draft state. A source without an audio track starts with captions off, and an empty transcript clears caption choices. Sound normalization and editing toggles are stored preferences for later processing phases, not active processing in setup.

Phase 9 adds `ClipHelmEditing` with no provider dependency. `ClipPlanner` combines a typed proposal and configuration with validated local analysis, then emits schema-versioned `ClipHelmEditSpec`. Source-time trim/remove segments, crop paths, layout, audio operation, and caption cues are validated before use. `EditTimeline` maps retained source intervals to edited time. `EditHistory` provides typed edits with in-memory undo/redo. The app does not render or persist edit history in this phase.

## Data flow

```text
SourceIngestor → Media → Transcription + Analysis → Moments
                                                ↘ OpenRouter (small excerpts/keyframes)
Moments → typed ClipProposal / AIEditIntent → semantic checks → ClipPlanner
ClipPlanner + Framing + Layouts + Pacing + Captions → Editing → ClipHelmEditSpec
ClipHelmEditSpec → Rendering → preview/review/export
Projects persists user choices and edit specs; caches can be rebuilt.
```

Clip discovery may ask OpenRouter for meaning and ranking, but local evidence supplies candidate windows first. Vision is an uncertainty fallback on selected keyframes. Neither model output nor a URL can inject a path, shell command, FFmpeg argument, or filter graph into a render job.

## Runtime contracts for later phases

- Long operations report phase and progress, honor cancellation, and return typed recoverable errors. UI updates occur on the main actor; media work does not.
- Original media is read-only. Every cut, crop, and caption is a project decision that can be changed or removed.
- Project commits are atomic and versioned. Interrupted work resumes from the last committed manifest; caches and partial exports are disposable.
- `ClipHelmCore` has no I/O, AI, platform UI, or source paths. Its persisted times are integer microseconds and ranges are half-open.
- V1 UI offers 9:16 and 16:9. `OutputFormat` stores dimensions so 1:1, 4:5, and custom canvases can be added without changing the time model.
- Captions are based on word timings and may animate per word or blur in. When no meaningful speech exists, the planner leaves captions disabled by default.

Final crop smoothing, filler cleanup, clip rendering, and final export remain later phases.
