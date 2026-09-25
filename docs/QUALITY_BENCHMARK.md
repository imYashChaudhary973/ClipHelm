# Phase 16 quality and performance baseline

The repository has synthetic timeline fixtures and one-second media fixtures, not a rights-cleared real-video corpus. These checks detect structural regressions. They do not establish perceptual clip quality or four-hour end-to-end performance.

## Content matrix

| Content type | Automated evidence | Human review still needed |
| --- | --- | --- |
| Podcast | Bounded transcript windows, semantic ranking, deduplication | Hook, standalone meaning, speech joins |
| Interview | Speaker transitions and question/answer fixture | Answer completeness, speaker framing |
| Talking head | Speech fixture and crop jitter regression | Face retention and composition |
| Coding video | Demo fixture and screen-preserving planning tests | Code readability at final size |
| Screen share | Screen fixture and layout hysteresis tests | UI readability and crop transitions |
| Presentation | Slide fixture and demo protection tests | Text legibility and slide changes |
| Lecture | Long explanation fixture and natural boundaries | Concept completeness and caption accuracy |
| Gameplay | Activity fixture and local gameplay classification tests | Gameplay context and visual interest |
| Silent demo | Local moment discovery without AI/captions | Whether selected action is meaningful |
| Speaker + screen | Mixed fixture and screen-priority layout tests | Balance of speaker and demo readability |

Current tests check typed times, natural boundary membership, bounded AI excerpts, deduplication, crop smoothing, demo-protected cuts, caption segmentation, H.264 dimensions, visible caption pixels, and retained audio. They cannot score subjective interest, face retention in actual scenes, legibility, audible cut naturalness, or sample-accurate AV sync. Real-video review is a release gate.

## Synthetic long-timeline profile

Run `CLIPHELM_RUN_LONG_BENCHMARKS=1 swift test --disable-sandbox --filter MomentEngineTests` to repeat. Each timeline has 120 spoken words per minute and local 30-second scene markers. OpenRouter is mocked; 24 semantic windows are evaluated. Resolution is asset metadata only; no long video is decoded or rendered. Values below were measured on a MacBook Pro (Mac17,2, Apple M5, 10 CPU cores, 24 GB RAM, macOS 27.2) on 2026-09-25. Peak RSS is the XCTest process peak up to that case, not isolated per-case allocation. CPU is user plus system process time for that case.

| Duration | Metadata size | Words | Wall s | CPU s | Peak RSS MB |
| --- | --- | ---: | ---: | ---: | ---: |
| 30 min | 1080p | 3,600 | 0.107 | 0.106 | 30.0 |
| 30 min | 4K | 3,600 | 0.174 | 0.129 | 30.6 |
| 1 h | 1080p | 7,200 | 0.246 | 0.226 | 32.1 |
| 1 h | 4K | 7,200 | 0.226 | 0.217 | 32.2 |
| 2 h | 1080p | 14,400 | 0.772 | 0.665 | 35.8 |
| 2 h | 4K | 14,400 | 0.751 | 0.641 | 35.9 |
| 4 h | 1080p | 28,800 | 2.249 | 2.050 | 43.6 |
| 4 h | 4K | 28,800 | 2.906 | 2.213 | 44.2 |

## Short-media render profile

Run `CLIPHELM_RUN_RENDER_BENCHMARKS=1 swift test --disable-sandbox --filter RendererTests` to repeat. These are one-second source fixtures, measured around the final H.264 render only. The 1080 × 1920 case includes a normalized-audio two-segment edit; the 3840 × 2160 case is a single silent segment. Peak RSS is process-wide. A bounded Metal System Trace of the 4K test completed successfully but showed no GPU intervals attributed to `xctest`; it cannot establish GPU or VideoToolbox utilization. A longer real-media trace remains required.

| Output | Source duration | Wall s | CPU s | Peak RSS MB |
| --- | ---: | ---: | ---: | ---: |
| 1080 × 1920 | 1 s | 0.276 | 0.123 | 85.7 |
| 3840 × 2160 | 1 s | 0.564 | 0.078 | 85.7 |

## Recovery checks

Direct download cancellation, detached local-analysis cancellation, backend transcription cancellation, canceled OpenRouter response, canceled preview/final batch render, and missing final file before manifest save have regression tests. Retrying the canceled render succeeds; already accepted output remains. AVFoundation's canceled proxy sidecar and the renderer's export-start cancellation crash have dedicated regressions. The project manifest is written only after all generated files exist. Long real-media interruptions, disk-full behavior, and forced process termination remain manual release checks.
