# Privacy and data flow

## Local processing

ClipHelm reads the video the user selects without modifying the original. Media probing, proxy preparation, local transcription, analysis, framing, pacing, captions, rendering, and export run on the Mac. Projects store configuration, transcripts, analysis-derived edit decisions, and generated clip references under Application Support. Analysis caches and proxies are regeneratable. Exported copies go to the destination the user chooses.

## OpenRouter

OpenRouter is the only external AI gateway. When the user starts an AI-assisted action, ClipHelm may send bounded transcript excerpts and metadata, short extracted audio chunks for selected transcription models, or a small set of reduced JPEG keyframes for enabled uncertain-shot vision. Original full videos are not uploaded. Provider retention and billing depend on the selected OpenRouter model and its provider; review those terms before processing sensitive media.

## Remote sources

Direct video URL import is disabled because the dormant downloader cannot guarantee that the connected IP matches its preflight DNS validation. Authorized public YouTube imports may download the selected video and audio through `yt-dlp` (installed by ClipHelm from its official GitHub release, or an existing Homebrew copy). ClipHelm does not provide cookies or sign-in credentials to that tool, and it does not bypass DRM or private access controls. Temporary downloads are removed after failure/cancellation and eventually swept if abandoned.

## Credentials and diagnostics

The OpenRouter API key is stored only as a non-synchronizable macOS Keychain item. It is not written to projects, preferences, logs, analytics, or subprocess arguments. ClipHelm has no analytics or app-managed crash-upload SDK. A full operating-system memory dump may capture a credential while a request is in flight; do not send one to support without review and redaction. See [SECURITY.md](SECURITY.md) for controls and limits.

Deleting a project removes its local project package, including saved transcripts and generated files. Copies exported to another folder remain there until the user deletes them.
