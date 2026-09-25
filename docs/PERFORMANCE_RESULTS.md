# Long-form performance results

2026-09-25, branch `fix/release-youtube-dependency`. Host: MacBook Pro Mac17,2, Apple M5 (10 CPU cores), 24 GB RAM, macOS 27.2, Xcode 27 beta. These are measured **component/test-runner** results, not complete app profiles. GPU use, sustained memory, peak temporary storage, full transcription/moment/render timings, and UI responsiveness are unmeasured. Full-pipeline 1080p and long-form 4K gates remain open.

| Source | Probe | Local analysis | Cache / reuse | Proxy | Test-runner peak RSS | Test-runner CPU | Scope |
| --- | --- | --- | --- | --- | --- | --- | --- |
| QA-LECTURE-1080, 32:56, 1920×1080, 25 fps, AV1/AAC working MP4 (138,312,250 B) | 0.033 s | 76.536 s; 17 scenes, 14,088 signals | 2,376,726 B; 0.033 s reload | Not run | 113,672,192 B | 12.917 s user + 7.751 s system | `AnalysisEngine` opt-in Release test; no transcription, model request, or render. |
| QA-STORY-4K, 12:03, 3840×2160, 24 fps, H.264/AAC working MP4 (1,100,336,966 B) | 0.024 s | 14.921 s; 11 scenes, 5,203 signals | 1,199,199 B; 0.018 s reload | 32.803 s; 593,483,506 B output | 124,944,384 B | 9.642 s user + 11.374 s system | `AnalysisEngine` and separately invoked `ProxyEngine`; proxy is not used in the current `ProcessingCoordinator` path. |

Test-runner peak RSS includes harness/runtime, and CPU values cover the whole test process. They are not app-process resource measurements. Source preparation from WebM to MP4 happened before these profiles and is not included.

| Additional run | Actual measurement | Limits |
| --- | --- | --- |
| QA-SPRING-SILENT, 7:44, local processing | 6.975 s total; analysis 5.446 s; preview 0.411 s; final render 1.116 s | No speech/model work, one 12-second 1080×1920 clip; not a long-video full speech pipeline. |
| QA-STORY-4K, 12-second 3840×2160 manual edit | Render 4.252 s; test-runner CPU 1.566 s, peak RSS 70,647,808 B; output 31,117,666 B | Short manual render, not 12-minute full export or complete processing. |
| QA-SPRING YouTube acquisition | 13.836 s to download and validate 7:44 video | Source ingestion test, not shipped-app or network-interruption profile. |

No optimization was made from these partial measurements. To close the gate, profile the complete signed-app jobs on representative long 1080p and 4K sources with Instruments Time Profiler, Allocations, Metal System Trace and Activity Monitor; record stage times, sustained/peak app RSS, GPU/VideoToolbox attribution, peak temp disk, proxy setting, export time, and UI responsiveness. The 4K source here is 12 minutes, shorter than the requested long-form 4K case.
