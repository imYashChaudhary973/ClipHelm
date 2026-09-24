# Security and privacy boundaries

## OpenRouter credential

The only external AI credential is an OpenRouter API key. `OpenRouterSecretVault` stores it as a macOS data-protection Keychain generic-password item with a dedicated service/account identifier and `WhenUnlockedThisDeviceOnly` accessibility. The key is never serialized into UserDefaults, project files, databases, JSON, plist, logs, telemetry, crash reports, source code, or subprocess arguments. Authorization headers and response bodies are never logged. A missing or inaccessible key fails closed with a user-facing error.

`LiveOpenRouterGateway` obtains the key from the vault at request time and injects it into the HTTPS header in process memory. It uses an ephemeral URL session, fixed OpenRouter HTTPS endpoints, refuses redirects, bounds response bytes, and maps HTTP/network failures to sanitized errors without returning server text. The Settings Test action uses only the key-inspection endpoint; it does not run a model. Model IDs and task capabilities are fetched/configured through the gateway, not frozen into core models. Tests inject a fake vault and a mocked gateway; tests make no paid calls.

## Untrusted boundaries

| Boundary | Required control |
| --- | --- |
| Local/remote source → `SourceIngestor` | User authorization, supported format, size/duration limits, safe file access; no DRM, access-control, or private-media bypass |
| URL → remote acquisition | HTTPS only; block local/private addresses, redirects, URL credentials, and oversized downloads; keep provider-specific handling behind `SourceIngestor` |
| Media bytes → decoder | Treat as malformed; isolate failures and never modify source |
| AI JSON → typed models | Decode, validate ranges/scores/IDs, then check against asset/proposal/project context |
| Typed edit spec → renderer | Resolve asset IDs internally; validate version, times, output size, permissions and destination; do not execute AI-supplied strings |
| Project manifest → runtime | Version check, bounded decode, validate IDs/references; reject corrupt or unsupported data without destroying originals |

Only transcript excerpts, necessary metadata, and selected keyframes may leave the device. Entire original videos never go to AI. Vision runs as fallback for difficult shots. User-owned or authorized YouTube media only; no extraction workaround is authorized by this architecture.

Phase 3 direct-video downloads accept HTTPS without URL credentials, reject local/IP-literal hosts, check every resolved address for private and special-use ranges, refuse redirects, omit cookies, and stop at 2 GB. The downloaded file is validated with AVFoundation under `forbidAll` external-media references. YouTube accepts a canonical video ID and runs a trusted local `yt-dlp` executable with fixed arguments, isolated HOME, disabled configuration/plugins/cookies, no shell, and no private-media workarounds. Download output is kept in a private temporary directory and removed on failure or cancellation; abandoned session directories older than one day are swept before the next remote import. DNS can change after the preflight lookup, so DNS rebinding remains a limitation of the current `URLSession` transport; do not use direct URLs from untrusted parties on privileged networks until a pinned-address transport is added.

Phase 4 media jobs accept local file URLs from `SourceIngestor` and use security-scoped access while reading. AVFoundation assets forbid external media references. The optional FFmpeg fallback resolves only fixed local executable paths, passes built arguments directly to `Process`, restricts input protocols to local files/pipes, discards subprocess stderr, and never receives an AI response. Media derivatives use private directories and file permissions, are disposable, and are removed after failed or canceled jobs. Original source bytes are never an output target.

Phase 5 on-device transcription requests macOS Speech permission and sets `requiresOnDeviceRecognition`; it fails when that mode is unavailable. OpenRouter transcription is an explicit paid action, uses the existing Keychain credential and fixed HTTPS gateway endpoint, and sends at most one short, extracted audio chunk per request. Responses are bounded and parsed into validated word times; server error bodies are discarded. Temporary audio is deleted after each chunk or cancellation. Transcripts are local project data, not credentials, and are saved in private project manifests. A matching local source must be selected again after relaunch for playback; the source URL itself is not persisted.

Phase 6 local analysis reads only the user-selected media file. AVFoundation forbids external media references; Vision runs on decoded local frames. `ClipHelmAnalysis` has no OpenRouter or network dependency, and analysis starts only from a workspace action. The cache stores bounded numerical evidence and tentative labels, with no raw frame, audio, source URL, or credential. Cache reads enforce size, version, source fingerprint, asset identity, and timeline bounds before use. Cache writes are atomic with private permissions.

## Verification status

Core decoding rejects malformed timing, geometry, scores, unsupported spec versions, and invalid proposals. Phase 2 tests check the gateway's fixed endpoint, authorization placement, sanitized error, catalog capability selection, and rejected malformed key input. The live Keychain save/replace/remove test is skipped when macOS reports `errSecNotAvailable` for this test process; it must pass in an unrestricted signed macOS app/test environment before Keychain behavior is considered verified.
