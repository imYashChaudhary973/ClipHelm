# Project format design

A project is a versioned manifest plus regeneratable caches. Phase 5 saves draft choices, optional validated `MediaAsset` metadata, and the completed word-timed `Transcript` in `project.json`. An empty transcript also sets `captionStyle` to `null`. Source URLs, local paths, downloaded bytes, proxies, thumbnails, and editing data are not persisted. A proxy and its `MediaTimeMap` live in memory and temporary storage for the active session.

Phase 6 writes `Cache/analysis-v1.json` only after local analysis finishes. The cache envelope has an independent schema version, a source fingerprint, and validated source-timeline signals, scenes, detections, tracks, and tentative content labels. The fingerprint uses file size, modification time, and hashes of bounded bytes from both ends of the file; it is rechecked before saving. It contains no source path, source URL, original frames, audio, transcript, or API credential. Loading rejects an old version, a changed source, a mismatched asset, an oversized file, or invalid bounds, then regenerates on the next analysis request. The cache directory and file use private permissions and atomic writes. The fingerprint is a practical cache key, not a full-file integrity hash; a middle-only edit that preserves file size, modification time, and both sampled ends can evade it.

## Proposed layout

```text
Example.cliphelm/
  project.json               versioned manifest and user decisions
  Assets/                    references/bookmarks and optional imported copies
  Cache/                     thumbnails, waveforms, analysis, previews
  Exports/                   only when the user chooses this destination
```

The manifest will hold `schemaVersion`, `ProjectID`, asset metadata keyed by `AssetID`, clip configurations, accepted `ClipHelmEditSpec` values keyed by `ClipID`, and job checkpoints. Source references are resolved by `SourceIngestor` and the project store; paths and security-scoped bookmarks are never included in AI payloads or `ClipHelmEditSpec`. Remote origin URLs should be minimized, sanitized, and never include credentials or signed query strings in persisted metadata. The OpenRouter key is never in the project package.

Saves use an atomic replacement after validation. On launch, the store loads the last valid manifest, checks its version and transcript bounds, and reports recoverable missing-source errors. Phase 5 accepts older manifests without a transcript and older word-only transcript JSON. Completed transcripts survive relaunch. Local originals can be located again to restore playback and transcript seeking. Cache removal cannot remove the manifest, original media, accepted edits, or exports. Interrupted renders use disposable temporary output until a completed export is committed.

The original source file is never modified. Export destinations and source permissions are user-controlled. Projects must survive relaunches and interrupted jobs; later phases will test atomic save/recovery and migrations with fixture packages.
