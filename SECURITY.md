# Security review

ClipHelm keeps one external AI credential in macOS Keychain through `OpenRouterSecretVault`. `LiveOpenRouterGateway` reads it only when building a fixed HTTPS request to `openrouter.ai`. The application has no analytics or crash-reporting SDK, and source review found no logging call that records the key, an Authorization header, or a request body. Gateway errors discard server response text. Tests use a fake key and require no paid API calls.

The key is not written to project manifests, UserDefaults, cache files, or subprocess arguments. Standard application errors are sanitized. A full operating-system memory dump could still contain a credential while a request is in flight; ClipHelm cannot promise otherwise. Do not attach full process dumps to support requests without reviewing and redacting them.

## Outbound network boundaries

| Initiator | Destination and data | Control |
| --- | --- | --- |
| `OpenRouterGateway` | Fixed `openrouter.ai` HTTPS paths; catalog/key check, bounded audio chunks, transcript excerpts, or selected JPEGs | Ephemeral session, no cookies/cache/redirects, bounded responses, no raw server error text |
| `SourceIngestor` direct URL | Disabled in the public application build | Compile-time policy rejects before DNS or download; dormant downloader remains testable only through a debug-only internal constructor |
| `SourceIngestor` YouTube | Public YouTube video and media hosts reached by trusted `yt-dlp` | Canonical video ID, fixed arguments, no cookies/config/plugins, isolated HOME, no shell |

Local analysis, framing, layouts, captions, and rendering have no AI network dependency. AVFoundation media readers, including results preview/playback, forbid external media references. Optional FFmpeg is restricted to local file/pipe inputs and receives no model output or credential. AI output is decoded into typed proposals, semantically checked, and converted to `ClipHelmEditSpec` before rendering.

## Open release risks

1. **Contained — direct URL DNS rebinding.** The downloader still has a DNS preflight/connection race, but external builds cannot reach it: the compiled policy is off, the public ingestion path rejects before network use, and the UI hides direct import. Re-enabling requires connection-address validation and adversarial tests.
2. **Unverified — operating-system diagnostics.** The app has no crash reporter and does not log headers, but a full memory dump may contain the in-memory Authorization value. Review diagnostic collection and support handling before release.
3. **Unverified — distribution hardening.** The current app is ad hoc signed without App Sandbox or notarization. Validate a signed, notarized, clean-machine build before external distribution.

See [detailed trust boundaries](docs/SECURITY.md) and [release gates](RELEASE_CHECKLIST.md).
