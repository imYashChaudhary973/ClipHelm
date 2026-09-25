# ClipHelm

Native macOS clip editor in development. The app is not yet cleared for external release; see the [release gate](docs/RELEASE_CHECKLIST.md) and [distribution procedure](docs/DISTRIBUTION.md).

## Run

Requires macOS 14+ and Xcode with Swift 6.

```bash
scripts/build-app.sh
open build/ClipHelm.app
```

The app has Home, Recent Projects, New Clip Project, Settings, and Project Workspace. `⌘N` starts a project; `⌘1`/`⌘2` navigate Home/Recent Projects; `⌘,` opens Settings; `⌘I` toggles the workspace inspector. Use `⌘[` and `⌘]` to move through the guided flow when its buttons are enabled.

After choosing a source, set the aspect ratio and 1080p or 4K export resolution, framing, smart editing options and pacing, clip lengths, target count, sound, and caption style and effects. Review the choices before saving a project. A source without an audio track starts with captions off; a later transcript with no speech also disables them. Select **Process Clips** in the workspace to create preview and final MP4 files.

Projects are saved under `~/Library/Application Support/ClipHelm/Projects`. They contain choices, a source label, basic media metadata, completed transcripts, and generated clip specs, never source file paths or full remote URLs. Preview and final files live in each project's `Exports` directory. On relaunch, the app restores generated clips. Use **Locate Original Video** for a local source or re-enter an authorized YouTube link to restore source access. Existing direct-URL projects stay readable, but their original source cannot be reattached while direct import is gated. Remote media remains session-only.

The Source step accepts MP4 and MOV, plus MKV when AVFoundation can decode it. Choose a file or drop it into the window. Direct video URL import is temporarily disabled because its download transport cannot yet prevent DNS rebinding. YouTube import accepts public video links for content you own or may process. The fastest path is the **Clip a YouTube video** card on Home: paste an OpenRouter key once, paste a link, confirm permission, and choose Make Clips. ClipHelm downloads the video, transcribes it on this Mac, asks the OpenRouter model to rate candidate moments, and renders captioned clips using your saved clip settings. The first YouTube import installs the official `yt-dlp_macos` release into `~/Library/Application Support/ClipHelm/Tools` after checking it against the release's SHA-256 checksum (Settings › YouTube Downloader can update it). A Homebrew `yt-dlp` in `/opt/homebrew/bin` or `/usr/local/bin` also works. FFmpeg is not required: ClipHelm downloads the H.264 video and AAC audio streams separately (up to 1080p) and combines them with AVFoundation. The app does not pass cookies or sign-in credentials to the downloader, so private, members-only, age-restricted, and DRM-protected videos stay unavailable.

The media engine uses AVFoundation first. When this Mac's AVFoundation decoder cannot create frames or exports, an installed FFmpeg at `/opt/homebrew/bin/ffmpeg` or `/usr/local/bin/ffmpeg` provides a local fallback. No network protocol is enabled in that fallback. A large source creates a 720p editing proxy in temporary storage; its source timeline remains the source of truth. Original media is read only.

Settings → OpenRouter lets you add, test, replace, or remove one API key. The key is stored only in the macOS login Keychain. Test checks the key without model inference or API spend. Model discovery reads OpenRouter's live catalog; no model is hardcoded.

In a workspace, choose **Transcribe on This Mac** to use Apple's on-device speech recognition. macOS may ask for Speech Recognition permission. The transcript has word times and optional confidence/speaker metadata; search it or click a row to seek. Silent or speech-free results turn captions off. OpenRouter transcription is optional: choose it, load the catalog, select a transcription model, then explicitly start the paid request. ClipHelm sends extracted short audio chunks through its OpenRouter gateway, never the original video. Some catalog models may not provide word timing and will be rejected.

To discover moments, run **Analyze on This Mac** in the workspace. With speech, transcribe, load structured text models, select one, then choose **Find Best Moments**. The explicit discovery action uses OpenRouter credits and sends only bounded excerpts from local candidate windows. It ranks, deduplicates, checks selected lengths, and shows a reason when no strong moments remain. Click a result to seek. Without a transcript, it can suggest active visual intervals locally for manual review; no AI call is made. Discovery results are session-only in this phase.

The **Process Clips** action reuses saved transcripts and regeneratable analysis caches, finds qualified moments, checks uncertain shots with AI Vision only when enabled and a vision model is selected, builds validated edit specs, then renders preview and final files. Results appear at the top of a processed workspace with video thumbnails, title, duration, source time, and aspect ratio. Play a clip, open its focused editor to rename, adjust framing, change caption style or pacing, trim, or regenerate framing, then preview the replacement. Export one clip or select several and export them to a chosen folder. Deleting a clip removes its generated project files but leaves the original and copies exported elsewhere untouched. After relaunch, playback, rename, and export work from saved files; reattach the original before edits that require rendering. Revisions use local analysis and do not make new AI calls. A full timeline editor remains future work; see [docs/EDIT_SPEC.md](docs/EDIT_SPEC.md).

## Tests

```bash
swift test --disable-sandbox
```

The tests cover source validation, media and time mapping, transcription, local analysis, moment discovery, edit planning, project restoration, result revisions and batch export, mocked OpenRouter behavior, Keychain input validation, a network-free full processing run, and short 1080p/4K H.264 exports with crops, captions, and audio. The live Keychain CRUD test needs access to macOS Keychain. These fixtures do not establish real-video quality or long-form performance. Module contracts are in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). See the [quality baseline](docs/QUALITY_BENCHMARK.md), [security review](SECURITY.md), [privacy summary](PRIVACY.md), and [release checklist](RELEASE_CHECKLIST.md) before using ClipHelm outside development.
