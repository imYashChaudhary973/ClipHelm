# Long-form performance results

No authorized long-form 1080p or 4K source was available on 2026-09-25. **No full-pipeline resource or timing measurements exist.** One-second render and metadata-only planning measurements in [QUALITY_BENCHMARK.md](QUALITY_BENCHMARK.md) are not long-video results.

The available profiling host is a MacBook Pro (Mac17,2, Apple M5, 10 CPU cores, 24 GB RAM) running macOS 27.2. The current reviewed build is `main` after PR #18; record the exact commit and signature for every future run.

| Source | Codec / duration / FPS | Proxy | Peak / sustained RSS | CPU | GPU / VideoToolbox | Peak temporary disk | Prepare / proxy | Transcribe | Analyze | Moments | Preview render | Final export | Bottleneck |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1080p | No authorized source | — | Unmeasured | Unmeasured | Unmeasured | Unmeasured | Unmeasured | Unmeasured | Unmeasured | Unmeasured | Unmeasured | Unmeasured | BLOCKED |
| 4K | No authorized source | — | Unmeasured | Unmeasured | Unmeasured | Unmeasured | Unmeasured | Unmeasured | Unmeasured | Unmeasured | Unmeasured | Unmeasured | BLOCKED |

Use Instruments Time Profiler, Allocations, Metal System Trace, and Activity Monitor during the **complete** jobs. Record stage wall time from the app, peak and sustained process RSS, CPU, GPU/VideoToolbox attribution, output size, and peak temporary storage. Compare only runs with their proxy setting labeled. Profile a bottleneck before editing it, then repeat the same source and settings after the change.
