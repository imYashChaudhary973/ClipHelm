# Moment discovery engine

Phase 7 discovers candidate clips. It does not edit or render video.

1. Local segmentation takes transcript segment/sentence edges, gaps, speaker and topic transitions, scene cuts, pauses, and strong audio/visual signal edges. All times remain source-media microseconds.
2. Local candidate generation chooses natural start/end boundaries near each selected `ClipLength` midpoint. Empty length selection considers every supported duration category and does not filter final duration. Strong candidates are retained across five-minute chapters before the semantic request cap (default 40), preserving coverage on long sources.
3. A structured-output OpenRouter model evaluates each spoken candidate independently. The request contains only its IDs, range, local content labels, and at most 120 transcript words sampled from the beginning, middle, and end (also capped at 2,400 characters). The full source transcript or original video is never sent. This sampling can miss context in long clips.
4. The model returns only a `ClipProposal` with a `MomentScore`: hook, standalone completeness, insight, story, question/answer completion, educational value, interest, context dependency, and repetition. Each dimension is validated in 0–1. Local evidence is computed and inserted by ClipHelm. A proposal is rejected if it changes the candidate ID, asset, time range, schema, or source bounds.
5. ClipHelm ranks by weighted quality, removes time-overlapping or highly similar transcript ideas, checks natural boundaries and selected duration categories, and returns only moments over the threshold. A requested count is a maximum; the result explains when fewer distinct high-quality moments exist.

Silent or non-speech demos use local motion/screen evidence only. They require manual semantic review and do not call OpenRouter. The engine currently does not run vision AI, persist discovered moments, calibrate score dimensions against human ratings, or build an `EditSpec`. Local subject and scene classifications are uncertain estimates. Normal tests use gateway mocks and never spend credits.
