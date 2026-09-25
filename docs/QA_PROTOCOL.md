# Rights-cleared production QA protocol

The initial publicly licensed test set is listed in [QA_ASSETS.md](QA_ASSETS.md). It covers a 33-minute 1080p lecture, a 12-minute 4K story, and an animated film. It does not yet cover every representative content type or full 4K long-form processing. Do not import arbitrary downloaded videos into this library without permission.

## Source manifest

Keep source media outside Git. For each authorized asset record: local path (in a private QA record), owner or license, permission scope, content type, duration, dimensions, frame rate, audio/speech status, and SHA-256. Cover talking head, two-person podcast, multi-person discussion, coding, screen recording, slides, interview, lecture, silent demo, gameplay, and mixed speaker/screen. Use useful 5/15/30/60/90/120-minute samples rather than forcing every type into every duration. Include 1080p and 4K, portrait and landscape, and representative 24/30/60 fps.

## Per-source review

Record the exact configuration, app commit, model IDs, Mac and macOS version, source duration, selected candidate time ranges, human-selected reference moments, and generated clip paths. Score each item 0–3 (0 unusable, 1 major correction, 2 minor correction, 3 publishable): moment usefulness, natural start/end, context completeness, framing stability and face retention, demo readability, layout stability, pacing/speech joins, caption text/timing/safe zones, audio sync, and final visual quality. Record missed high-value moments, false positives, duplicate ideas, and a concrete defect timestamp. Preserve a minimized rights-cleared fixture for recurring failures.

## Performance and recovery

For complete 1080p and 4K jobs, record wall time and CPU time per stage; peak and sustained resident memory; GPU and VideoToolbox usage from Instruments; peak temporary storage and final file size; UI responsiveness; cancellation latency; and cleanup. Repeat with force quit during download, transcription, analysis, OpenRouter request, render, and save. Reopen the project, check accepted clips and manifest integrity, and retry. Simulate disk full and network loss without using a production credential. A one-second render or synthetic transcript is not a substitute.

## Current evidence

The synthetic baseline is in [QUALITY_BENCHMARK.md](QUALITY_BENCHMARK.md). Partial real-media observations are in [QA_RESULTS.md](QA_RESULTS.md) and [PERFORMANCE_RESULTS.md](PERFORMANCE_RESULTS.md). Neither establishes publishable clip quality or complete long-form profiling yet.
