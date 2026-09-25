# Project format design

A project is a versioned manifest plus regeneratable caches. `ClipConfiguration` inside `project.json` stores output size, framing, smart editing, pacing, length ranges, clip count, sound, and captions. An empty transcript clears caption settings. Version 1 and 2 manifests load with defaults for newer fields; the next save writes version 3. Source URLs, local source paths, downloaded bytes, proxies, and thumbnails are not persisted. A proxy and its `MediaTimeMap` live in memory and temporary storage for the active session.

Phase 6 writes `Cache/analysis-v1.json` only after local analysis finishes. The cache envelope has an independent schema version, a source fingerprint, and validated source-timeline signals, scenes, detections, tracks, and tentative content labels. The fingerprint uses file size, modification time, and hashes of bounded bytes from both ends of the file; it is rechecked before saving. It contains no source path, source URL, original frames, audio, transcript, or API credential. Loading rejects an old version, a changed source, a mismatched asset, an oversized file, or invalid bounds, then regenerates on the next analysis request. The cache directory and file use private permissions and atomic writes. The fingerprint is a practical cache key, not a full-file integrity hash; a middle-only edit that preserves file size, modification time, and both sampled ends can evade it.

## Proposed layout

```text
Example.cliphelm/
  project.json               versioned manifest and user decisions
  Assets/                    references/bookmarks and optional imported copies
  Cache/                     regeneratable analysis
  Exports/                   generated preview and final MP4 files
```

The manifest holds `schemaVersion`, `ProjectID`, one `ClipConfiguration`, optional source metadata and transcript, and completed clip records. Each clip record holds a validated `ClipProposal`, `ClipHelmEditSpec`, and relative preview/final file names. Source references are resolved by `SourceIngestor` and the project store; paths and security-scoped bookmarks are never included in AI payloads or `ClipHelmEditSpec`. Full remote origin URLs and the OpenRouter key are never in the project package.

Saves use an atomic replacement after validation. On launch, the store checks manifest version, transcript bounds, clip specs, IDs, and relative file names. Completed transcripts and clip records survive relaunch. Local originals can be located again; remote users re-enter an authorized link because downloaded media is temporary. Cache removal cannot remove the manifest, original media, accepted edits, or exports. Interrupted renders use disposable temporary output; completed batch files are retained. Retry reuses a saved transcript and versioned analysis cache when valid, then writes new uniquely named clips.

The original source file is never modified. Exports are stored inside the project package and can be revealed in Finder. Source access still requires the user after relaunch. A failed render may leave a completed preview or prior batch clip in `Exports`; the next run writes fresh names and does not silently reuse those files.
