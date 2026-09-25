# External release gate

Status on 2026-09-25: **NOT RELEASE READY**. Every check is `PASS`, `FAIL`, `BLOCKED`, or `NOT APPLICABLE`. `BLOCKED` identifies a missing input or environment; `FAIL` is an observed defect. Keep direct video URL import disabled until its actual-connection security policy is implemented and tested.

| Area | Gate | Status | Evidence / action to clear |
| --- | --- | --- | --- |
| Security | OpenRouter secret isolated in Keychain and sanitized gateway | PASS | Source audit and mocked gateway/vault tests passed; never collect an unredacted full process dump. |
| Security | Direct URL SSRF/DNS-rebinding exposure in external build | PASS | Compile-time gate rejects before DNS/network; option hidden. Dormant downloader is unsafe to re-enable. |
| Security | Enabled direct URL redirect/DNS-rebinding transport | NOT APPLICABLE | Direct URL feature is disabled. Require actual-peer validation and adversarial tests before enabling. |
| Security | No high-severity finding reachable in distributed build | BLOCKED | Re-audit the Developer ID-signed build and installed `yt-dlp`/media decoder boundary. |
| Functionality | Complete local import → preview → edit → export → relaunch workflow | BLOCKED | Rights-cleared long media and interactive app inspection required. |
| Functionality | Authorized YouTube import and failure UX | BLOCKED | Rights-cleared source plus supported installed downloader required. Direct URL is disabled. |
| Quality | Representative real-video moment, framing, pacing, caption review | BLOCKED | No source cleared; record in [QA_ASSETS.md](QA_ASSETS.md) and score using [QA_PROTOCOL.md](QA_PROTOCOL.md). |
| Quality | 1080p and 4K final files inspected in independent player | BLOCKED | Run both full workflows on cleared sources; record [QA_RESULTS.md](QA_RESULTS.md). |
| Performance | Long-form 1080p CPU/GPU/RSS/disk/stage profile | BLOCKED | Cleared long source required; record [PERFORMANCE_RESULTS.md](PERFORMANCE_RESULTS.md). |
| Performance | Long-form 4K CPU/GPU/RSS/disk/stage profile | BLOCKED | Cleared 4K long source required; record [PERFORMANCE_RESULTS.md](PERFORMANCE_RESULTS.md). |
| Reliability | Automated cancellation, save, export-capacity, network-error regressions | PASS | Full suite rerun on 2026-09-25: 103 passed, one optional benchmark skipped, zero failures. Release-config source tests: 4 passed. |
| Reliability | Live force quit, disk full, network interruption and recovery | BLOCKED | Controlled QA Mac, cleared source and live run required; record [RELIABILITY_RESULTS.md](RELIABILITY_RESULTS.md). |
| Distribution | Developer ID-signed Release build with hardened runtime and timestamp | PASS | Built on 2026-09-25; `codesign --verify --deep --strict` passed, Team ID `8QSM298XJ2`, runtime flag and secure timestamp present. |
| Distribution | Notarization Keychain profile available | BLOCKED | `xcrun notarytool history --keychain-profile cliphelm-release` found no item. Supply an existing profile name or store credentials in Keychain; do not put secrets in Git or arguments. |
| Distribution | Notarization accepted and ticket stapled | BLOCKED | [DISTRIBUTION.md](DISTRIBUTION.md) and `scripts/distribute-app.sh` prepare the path; submit using the Keychain notary profile, require Accepted status, staple and validate. |
| Distribution | Current signed candidate passes Gatekeeper | FAIL | `spctl -a -t exec -vv` rejected it as `Unnotarized Developer ID`. Retest after notarization and stapling. |
| Distribution | Stapling, Gatekeeper, clean install and distributed-build workflow | BLOCKED | Run on final accepted notarized artifact in clean environment; test Keychain, media access, OpenRouter, render, export, relaunch. |

The detailed synthetic baseline remains in [QUALITY_BENCHMARK.md](QUALITY_BENCHMARK.md). It does not satisfy the quality or performance gates above.
