# Real-video quality results

2026-09-25, branch `fix/release-youtube-dependency`. Sources and licenses are in [QA_ASSETS.md](QA_ASSETS.md). This is partial QA: no speech-based candidate ranking, captions, Smart Auto Frame, pacing review, or independent player playback was completed. Do not score the clips as publishable from these checks.

| Source | Configuration / actual path | Observed result | What remains |
| --- | --- | --- | --- |
| QA-SPRING-SILENT | 7:44 local MP4 without audio; default silent processing, vertical 1080×1920 classic full frame | `ProcessingCoordinator` completed prepare → transcribe/no speech → analyze → moments → plan → preview → final. Generated one 12.04-second H.264 clip from source 03:28–03:40. A contact sheet and frames at 2 and 10 seconds were inspected: original image remained visible with expected bars. FFprobe found 1080×1920 H.264 and no audio; FFmpeg decoded the entire output without error. | This is an animation with its soundtrack removed, not a representative silent demo. Moment usefulness, motion quality, and independent player review remain open. |
| QA-STORY-4K | Local 12:03 MP4; manual validated 01:00–01:12 edit; 3840×2160 classic full frame, original sound | Renderer produced a 12.00-second H.264/AAC clip. FFprobe showed 3840×2160, 24 fps, both streams starting at 0 and lasting 12 seconds. FFmpeg decoded the entire file without error. The 6-second frame was inspected and showed the complete source image. | This validates a real 4K render segment, not AI clip choice, moving crop, captions, subjective audio sync, or full workflow. |
| QA-LECTURE-1080 | 32:56 local AV1/AAC MP4 | Media probing and local video/audio analysis completed; no clip generated. | Full speech transcription, semantic ranking, caption and publishability review remain open. |
| QA-SPRING | Authorized public YouTube URL using verified `yt-dlp` executable | `SourceIngestor` acquired and validated a 7:44, 2048×858 copy. | Distributed-app import with installed prerequisite, network-loss behavior, and full workflow remain open. |

## Issue log

| Source asset | Generated clip | Severity | Subsystem | Reproduction | Expected | Actual | Evidence/timecode | Fix status |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| — | — | — | — | — | — | No confirmed quality defect from the limited checks above. Unreviewed areas are not passes. | — | OPEN QA |

For each representative source, follow [QA_PROTOCOL.md](QA_PROTOCOL.md): inspect playback, compare human-selected moments, score boundaries/framing/demos/pacing/captions/audio, log defects here, and rerun after fixes.
