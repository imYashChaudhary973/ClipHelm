# Project format design

A project is a versioned manifest plus regeneratable caches. `ClipConfiguration` inside `project.json` stores output size, framing, smart editing, pacing, length ranges, clip count, sound, and captions. An empty transcript clears caption settings. Version 1–3 manifests load with defaults for newer fields; the next save writes version 4. Source URLs, local source paths, downloaded bytes, proxies, and thumbnails are not persisted. A proxy and its `MediaTimeMap` live in memory and temporary storage for the active session.

Phase 6 writes `Cache/analysis-v1.json` only after local analysis finishes. The cache envelope has an independent schema version, a source fingerprint, and validated source-timeline signals, scenes, detections, tracks, and tentative content labels. The fingerprint uses file size, modification time, and hashes of bounded bytes from both ends of the file; it is rechecked before saving. It contains no source path, source URL, original frames, audio, transcript, or API credential. Loading rejects an old version, a changed source, a mismatched asset, an oversized file, or invalid bounds, then regenerates on the next analysis request. The cache directory and file use private permissions and atomic writes. The fingerprint is a practical cache key, not a full-file integrity hash; a middle-only edit that preserves file size, modification time, and both sampled ends can evade it.

## Proposed layout

```text
Example.cliphelm/
  project.json               versioned manifest and user decisions
  Assets/                    references/bookmarks and optional imported copies
  Cache/                     regeneratable analysis
  Exports/                   generated preview and final MP4 files
```

The manifest holds `schemaVersion`, `ProjectID`, one `ClipConfiguration`, optional source metadata and transcript, and completed clip records. Each clip record holds a validated `ClipProposal`, `ClipHelmEditSpec`, a local display title, optional user trim bounds, and relative preview/final file names. Version 3 records derive the display title from their proposal. Source references are resolved by `SourceIngestor` and the project store; paths and security-scoped bookmarks are never included in AI payloads or `ClipHelmEditSpec`. Full remote origin URLs and the OpenRouter key are never in the project package.

Saves use an atomic replacement after validation. On launch, the store checks manifest version, transcript bounds, clip specs, IDs, and relative file names. Completed transcripts and clip records survive relaunch. Local originals can be located again; remote users re-enter an authorized link because downloaded media is temporary. Cache removal cannot remove the manifest, original media, accepted edits, or exports. Interrupted renders use disposable temporary output; completed batch files are retained. Retry reuses a saved transcript and versioned analysis cache when valid, then writes new uniquely named clips.

The original source file is never modified. Generated previews and finals remain in the project package. The results view copies selected final MP4s to a user-chosen folder using safe names, without overwriting files already there; an interrupted or failed batch removes only copies created by that batch. Editing renders new files before atomically replacing a clip record, then removes superseded generated files. Deleting a clip removes its record and generated files; externally exported copies remain. Source access still requires the user after relaunch. A failed processing run may leave a completed preview or prior batch clip in `Exports`; the next run writes fresh names and does not silently reuse those files.
