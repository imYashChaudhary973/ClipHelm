# Edit spec contract

`ClipHelmEditSpec` is a versioned, non-destructive description of one clip. It contains IDs, retained source intervals, crop paths, layout, audio operation, and caption cues. It contains no file path, URL, executable command, filter graph, or model ID. `schemaVersion` is currently `3`; versions 1 and 2 decode with empty shot-layout cues. Unknown versions fail decoding.

## Version 3 fields

| Field | Rule |
| --- | --- |
| `clipID` | Stable typed clip ID |
| `sourceAssetID` | Must resolve to a project asset |
| `segments` | Non-empty retained source ranges in output order; positive, sorted, non-overlapping, half-open. Trims and removals change only these ranges. |
| `outputFormat` | Positive canvas width/height, bounded to 16,384 pixels per axis |
| `framingMode` | `smartAuto`, `fullFrame`, `classicFullFrame`, `blurred` |
| `pacingMode` | `natural`, `balanced`, `tight`, `fast` |
| `layout` | `fill` for Smart Auto/Full Frame, `fit` for Classic Full Frame, `blurredBackground` for Blurred |
| `layoutCues` | Optional ordered, non-overlapping source-time choices: original, speaker focus, stacked speakers, side-by-side, screen focus, screen + speaker, or picture-in-picture. Each cue is contained in a retained segment and records automatic or manual origin. |
| `cropPaths` | Optional static or animated normalized source-frame rectangles, keyed by source time and contained in retained ranges; only valid with `fill` |
| `audioOperation` | `original`, `normalize`, or `mute`; no provider filter or command text |
| `captionStyle` / `captionTrack` | Optional style and ordered, non-overlapping source-time text cues with word animation and blur-in flags |

All range endpoints are integer microseconds relative to the original asset. `EditTimeline` maps each retained interval to a gapless edited interval without floating-point accumulation. At a cut boundary, edited time maps to the next retained source span; deleted source time has no edited position. The final output endpoint maps to the final retained source endpoint. Range queries split across cuts.

`ClipPlanner` validates the proposal, optional `AIEditIntent`, local analysis, and optional transcript against the source asset. `PacingPlanner` first proposes typed dead-air, long-pause, and isolated filler removals. It rejects removals overlapping other transcript words, audible activity, or protected demo content, keeps a short onset/ending shoulder, and retains different pause lengths by pacing mode and sentence/speaker context. Accepted removals become gaps between `ClipHelmEditSpec.segments`; no separate command or model output enters the spec. Smart Auto Frame uses local scene-aware animated crops only during speaker-focus cues; other shot layouts take precedence over crop paths. `screenFocus` means preserving readable source content in the future renderer. Full Frame uses a centered static fill crop. One retained segment may contain several crop paths because scene cuts and long shots are separate trajectories. Optional validated AI Vision labels may guide local content selection but never provide crop coordinates or layout commands. Captions are emitted only for retained transcript words.

`EditSpecValidator` checks source/proposal bounds, layout compatibility, timed operation containment, and crop aspect against source and output dimensions. `EditHistory` applies typed trim, remove, crop, shot-layout override, audio, and caption operations to validated snapshots. Undo/redo is in memory, capped at 100 snapshots. A trim or removal clamps layout cues to retained source ranges and drops crop paths or caption cues that no longer fit. Manual overrides are allowed within a retained range when the canvas mode is `fill`; automatic minimum-duration rules do not constrain deliberate user edits. Neither history nor specs modify original media. Rendering and persistent edit history come later.

`CaptionTrack` keeps word-level source times. `ClipHelmCaptions` derives short phrases and per-frame placement without changing the persisted EditSpec schema. The same `CaptionProgram.frame(at:canvasSize:)` and `CaptionRenderer.render(_:canvasSize:)` produce workspace preview overlays and transparent output overlays. Export composition must map edited time through `EditTimeline` before asking for a source-time caption frame. Silent or disabled captions produce no track and no overlay. The current source preview does not display final crop/layout decisions; final video composition is a later phase.

## AI boundary

```text
untrusted JSON → typed ClipProposal / AIEditIntent → schema checks
→ source-bound and proposal-bound semantic checks → ClipPlanner
→ user-reviewable decisions → ClipHelmEditSpec → renderer compiler
```

`ClipProposal` and `AIEditIntent` may suggest meaning and intervals. The planner validates them against actual asset metadata and local evidence. User framing configuration takes precedence over an intent's framing preference. Unknown JSON fields are ignored by Swift decoding and have no executable sink. A proposal outside its asset or an intent outside its proposal is rejected. The future render compiler receives only trusted asset handles resolved within the project, never a path from AI.
