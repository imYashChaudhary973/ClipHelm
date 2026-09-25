# Edit spec contract

`ClipHelmEditSpec` is a versioned, non-destructive description of one clip. It contains IDs, retained source intervals, crop paths, layout, audio operation, and caption cues. It contains no file path, URL, executable command, filter graph, or model ID. `schemaVersion` is currently `2`; version 1 decodes with default layout and no crop or caption track. Unknown versions fail decoding.

## Version 2 fields

| Field | Rule |
| --- | --- |
| `clipID` | Stable typed clip ID |
| `sourceAssetID` | Must resolve to a project asset |
| `segments` | Non-empty retained source ranges in output order; positive, sorted, non-overlapping, half-open. Trims and removals change only these ranges. |
| `outputFormat` | Positive canvas width/height, bounded to 16,384 pixels per axis |
| `framingMode` | `smartAuto`, `fullFrame`, `classicFullFrame`, `blurred` |
| `pacingMode` | `natural`, `balanced`, `tight`, `fast` |
| `layout` | `fill` for Smart Auto/Full Frame, `fit` for Classic Full Frame, `blurredBackground` for Blurred |
| `cropPaths` | Optional static or animated normalized source-frame rectangles, keyed by source time and contained in retained ranges; only valid with `fill` |
| `audioOperation` | `original`, `normalize`, or `mute`; no provider filter or command text |
| `captionStyle` / `captionTrack` | Optional style and ordered, non-overlapping source-time text cues with word animation and blur-in flags |

All range endpoints are integer microseconds relative to the original asset. `EditTimeline` maps each retained interval to a gapless edited interval without floating-point accumulation. At a cut boundary, edited time maps to the next retained source span; deleted source time has no edited position. The final output endpoint maps to the final retained source endpoint. Range queries split across cuts.

`ClipPlanner` validates the proposal, optional `AIEditIntent`, local analysis, and optional transcript against the source asset. It uses the user configuration for layout and audio, conservatively cuts high-confidence local pause signals, preserves classified demos when requested, and derives static or two-keyframe linear crops from local subject tracks. Captions are emitted only for retained transcript words. Filler-word edits and AI vision are later-phase work.

`EditSpecValidator` checks source/proposal bounds, layout compatibility, timed operation containment, and crop aspect against source and output dimensions. `EditHistory` applies typed trim, remove, crop, layout, audio, and caption operations to validated snapshots. Undo/redo is in memory for this phase, capped at 100 snapshots. A trim or removal drops crop paths or caption cues that no longer fit a retained segment. Neither history nor specs modify original media. Rendering and persistent edit history come later.

## AI boundary

```text
untrusted JSON → typed ClipProposal / AIEditIntent → schema checks
→ source-bound and proposal-bound semantic checks → ClipPlanner
→ user-reviewable decisions → ClipHelmEditSpec → renderer compiler
```

`ClipProposal` and `AIEditIntent` may suggest meaning and intervals. The planner validates them against actual asset metadata and local evidence. User framing configuration takes precedence over an intent's framing preference. Unknown JSON fields are ignored by Swift decoding and have no executable sink. A proposal outside its asset or an intent outside its proposal is rejected. The future render compiler receives only trusted asset handles resolved within the project, never a path from AI.
