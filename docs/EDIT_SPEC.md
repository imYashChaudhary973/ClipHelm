# Edit spec contract

`ClipHelmEditSpec` is a versioned, non-destructive description of one clip. It contains IDs, source intervals, target canvas, and editing modes. It contains no file path, URL, executable command, filter graph, or model ID. `schemaVersion` is currently `1`; unknown versions fail decoding.

## V1 fields

| Field | Rule |
| --- | --- |
| `clipID` | Stable typed clip ID |
| `sourceAssetID` | Must resolve to a project asset |
| `segments` | Non-empty retained source ranges in output order; positive, sorted, non-overlapping, half-open |
| `outputFormat` | Positive canvas width/height, bounded to 16,384 pixels per axis |
| `framingMode` | `smartAuto`, `fullFrame`, `classicFullFrame`, `blurred` |
| `pacingMode` | `natural`, `balanced`, `tight`, `fast` |
| `soundMode` | `source`, `normalize`, or `mute`; Phase 8 setup offers original and normalize |
| `captionStyle` | One of eight V1 styles, or `null` for no captions |

All range endpoints are integer microseconds relative to the original asset. A segment's output start is the sum of preceding segment durations. The compiler must check each segment against the resolved asset duration before rendering. Rendering may also reject unsupported codecs, odd frame sizes, missing source media, or unavailable output destinations with typed errors.

`smartAuto` follows important subjects and content dynamically. `fullFrame` fills the target while minimizing important-content loss. `classicFullFrame` keeps the complete source image with bars where needed. `blurred` keeps the complete source image over a blurred fill. These are planning/rendering contracts; Phase 0 does not calculate crops or layouts.

Phase 0 validates schema shape and basic semantics (`init`, JSON decode, and `validate(for:)`). Later editing phases will add explicit shot-level crop paths, layouts, caption cues, and audio edits under a new schema version with migrations. Do not infer a crop trajectory from this V1 schema or treat AI text as one.

## AI boundary

```text
untrusted JSON → typed ClipProposal / AIEditIntent → schema checks
→ source-bound and proposal-bound semantic checks → ClipPlanner
→ user-reviewable decisions → ClipHelmEditSpec → renderer compiler
```

`ClipProposal` and `AIEditIntent` may suggest meaning, intervals, and preferences. The planner resolves them against actual asset metadata and local evidence. Unknown JSON fields are ignored by Swift decoding and have no executable sink. A proposal outside its asset or an intent outside its proposal is rejected. The render compiler receives only trusted asset handles resolved within the project, never a path from AI.
