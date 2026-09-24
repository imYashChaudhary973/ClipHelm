# ClipHelm

Native macOS clip editor in development. Phase 7 adds local candidate discovery with bounded OpenRouter semantic scoring and workspace review. Clip editing, rendering, and final export are still planned.

## Run

Requires macOS 14+ and Xcode with Swift 6.

```bash
scripts/build-app.sh
open build/ClipHelm.app
```

The app has Home, Recent Projects, New Clip Project, Settings, and Project Workspace. `⌘N` starts a project; `⌘1`/`⌘2` navigate Home/Recent Projects; `⌘,` opens Settings; `⌘I` toggles the workspace inspector. Use `⌘[` and `⌘]` to move through the guided flow when its buttons are enabled.

Draft projects are saved under `~/Library/Application Support/ClipHelm/Projects`. They contain choices, a source label, basic media metadata, and completed transcripts, never source file paths or full remote URLs. On relaunch, the app restores navigation, selected project, inspector visibility, and safe draft preferences. Use **Locate Original Video** in a local-source workspace after relaunch to restore playback and transcript seeking. Remote sources must be imported again because their temporary media is session-only.

The Source step accepts MP4 and MOV, plus MKV when AVFoundation can decode it. Choose a file or drop it into the window. HTTPS direct video links download into private temporary storage with progress and cancellation; repeated preparation of the same link reuses the session copy. YouTube import accepts public video links for content you own or may process. It requires `yt-dlp` installed at `/opt/homebrew/bin/yt-dlp` or `/usr/local/bin/yt-dlp`; FFmpeg is needed when its best video and audio streams require merging. ClipHelm does not pass cookies or sign-in credentials to it. A failed or protected YouTube link stays unavailable rather than bypassing access controls.

The media engine uses AVFoundation first. When this Mac's AVFoundation decoder cannot create frames or exports, an installed FFmpeg at `/opt/homebrew/bin/ffmpeg` or `/usr/local/bin/ffmpeg` provides a local fallback. No network protocol is enabled in that fallback. A large source creates a 720p editing proxy in temporary storage; its source timeline remains the source of truth. Original media is read only.

Settings → OpenRouter lets you add, test, replace, or remove one API key. The key is stored only in macOS Keychain. Test checks the key without model inference or API spend. Model discovery reads OpenRouter's live catalog; no model is hardcoded or called in this phase.

In a workspace, choose **Transcribe on This Mac** to use Apple's on-device speech recognition. macOS may ask for Speech Recognition permission. The transcript has word times and optional confidence/speaker metadata; search it or click a row to seek. Silent or speech-free results turn captions off. OpenRouter transcription is optional: choose it, load the catalog, select a transcription model, then explicitly start the paid request. ClipHelm sends extracted short audio chunks through its OpenRouter gateway, never the original video. Some catalog models may not provide word timing and will be rejected.

To discover moments, run **Analyze on This Mac** in the workspace. With speech, transcribe, load structured text models, select one, then choose **Find Best Moments**. The explicit discovery action uses OpenRouter credits and sends only bounded excerpts from local candidate windows. It ranks, deduplicates, checks selected lengths, and shows a reason when no strong moments remain. Click a result to seek. Without a transcript, it can suggest active visual intervals locally for manual review; no AI call is made. Discovery results are session-only in this phase.

## Tests

```bash
swift test --disable-sandbox
```

The tests cover source validation, 1080p/4K and 25/30/60 fps metadata, proxies, frame sampling, audio extraction, time mapping, transcript chunk mapping and silence detection, local analysis, moment discovery fixtures, project restoration, mocked OpenRouter behavior, and Keychain input validation. The live Keychain CRUD test needs access to macOS Keychain. Module contracts are in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).
