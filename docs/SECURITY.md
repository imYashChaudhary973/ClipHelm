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

## Verification status

Core decoding rejects malformed timing, geometry, scores, unsupported spec versions, and invalid proposals. Phase 2 tests validate Keychain input, the fixed HTTPS gateway, sanitized errors, and model capability filtering. Media and transcription are planned for later phases.
