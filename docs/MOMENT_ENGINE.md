# Moment engine design

The moment engine ranks locally generated candidates; it does not send an entire transcript to an LLM for timestamp selection.

## Planned pipeline

1. Normalize word timings and sentence boundaries. Analyze scene cuts, visual activity, speaker emphasis, audio energy, pauses, and repetition locally.
2. Partition long media into topic-sized windows. Build overlapping candidate ranges around complete thoughts, then merge or split at sentence and scene boundaries. Keep source time provenance.
3. Attach `MomentSignal` evidence to each `MomentCandidate`. Positive signals include hooks, standalone meaning, emphasis, and story completion. Context dependency and repetition lower rank.
4. Send only relevant transcript excerpts, timings, small metadata, and selected keyframes to OpenRouter when semantic reasoning improves ranking. Vision is reserved for uncertain shots or demo context.
5. Decode `ClipProposal` as untrusted data. Validate asset ID, bounds, confidence, and relation to local candidates. Reject or repair only by deterministic local rules; never accept an invented timestamp as authority.
6. Rank for quality and variety. Prefer complete, understandable clips over an exact requested count. If fewer candidates clear the quality threshold, return fewer and explain the limiting evidence.

`selectedLengths` is a multi-select filter. An empty selection means unrestricted duration. `requestedClipCount == nil` means AI decides. The actual threshold, model choice, diversity weights, and cost budget are future phase decisions and must be measured on representative media before being fixed.

## Checks for implementation phases

Tests should cover timeline mapping, candidate overlap, long-video hierarchy, score stability, context dependence, demo preservation, and the fewer-than-requested result. Normal tests use gateway mocks and spend no API credit.
