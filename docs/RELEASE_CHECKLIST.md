# External release gate

Status on 2026-09-25: **NOT RELEASE READY**. `PASS` means verified in this checkout; `FAIL` or `PENDING` blocks an external release. Each manual run must record source rights, Mac model, macOS version, result, and reviewer in [QA_PROTOCOL.md](QA_PROTOCOL.md).

## Audit findings

- Direct HTTPS import had a DNS preflight/connection race. The public source path is now gated before DNS and network access; the downloader remains unsafe to re-enable.
- Keychain and gateway boundaries are covered by mocked tests. OS memory-dump handling and the installed third-party YouTube downloader still need distribution review.
- Local rendering, cancellation, and project persistence have automated fixture coverage. Full-length perceptual quality, resource use, force-quit recovery, and clean-machine behavior have not been established.

| Area | Gate | Status | Evidence or required verification |
| --- | --- | --- | --- |
| Security | OpenRouter key stays in Keychain and out of project/preferences/logs/arguments | PASS | Vault and mocked gateway tests; source audit. Full OS dump policy remains pending. |
| Security | Direct URL import cannot reach unsafe destinations | PASS (gated) | Public `SourceIngestor` rejects before DNS/network; UI hides option; regression test. Dormant downloader must not be re-enabled without connection-address validation. |
| Security | Direct URL redirect/DNS rebinding policy supports enabled import | PENDING | Build a transport that verifies actual peer addresses on every connection and redirect, then run adversarial tests. Optional while feature remains off. |
| Security | No known high-severity issue remains reachable in the external build | PENDING | Re-audit the signed distribution build, including `yt-dlp` and media decoding. |
| Functionality | Local import, transcript, moment selection, framing, captions, preview, edit, export | PENDING | Exercise one complete rights-cleared 1080p user workflow interactively. |
| Functionality | Authorized YouTube import and failure UX | PENDING | Test owned/public media with installed downloader, no credentials or access-control bypass. |
| Quality | Real-video QA across representative content types | PENDING | Use the rights-cleared library and score the rubric in QA_PROTOCOL.md. |
| Quality | 1080p and 4K output, AV sync, and visual inspection | PENDING | Inspect finished MP4s in ClipHelm and an independent player. |
| Performance | 30/60/90/120-minute 1080p CPU, memory, disk, and stage timing | PENDING | Record full-pipeline Instruments/Activity Monitor measurements on real media. |
| Performance | Representative 4K CPU, memory, GPU/VideoToolbox, disk, and stage timing | PENDING | Record full-pipeline measurements; one-second fixtures do not establish long-form performance. |
| Reliability | Cancellation and atomic save regressions | PASS | Existing and new automated tests cover direct gate, ingestion cancellation, model response cancellation, render cleanup, and project save. |
| Reliability | Force-quit recovery, disk full, and live network interruption | PENDING | Repeat on real long media; verify manifest and generated-file integrity after relaunch. |
| Distribution | Release configuration builds | PASS | `scripts/build-app.sh release` built an arm64 bundle; `codesign --verify --deep --strict` passed and Launch Services started the app on this Mac. This is an ad hoc signature, not distribution signing. |
| Distribution | Developer ID signing, notarization, App Sandbox assessment, clean-machine install | FAIL | Current script ad hoc signs a Release bundle. Configure hardened runtime and Developer ID signing, assess sandboxed source/tool access, submit with `notarytool`, staple the ticket, then install and run on a clean Mac. |

Do not change this document to `RELEASE READY` based solely on synthetic fixtures or a successful build. The detailed prior baseline is in [QUALITY_BENCHMARK.md](QUALITY_BENCHMARK.md).
