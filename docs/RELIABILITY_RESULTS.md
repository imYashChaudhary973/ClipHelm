# Reliability results

Automated regression evidence exists for cancellation, atomic project saves, a simulated export capacity failure, and sanitized OpenRouter network errors. The full suite rerun on 2026-09-25 passed 103 tests with one optional benchmark skipped; Release-config source tests passed 4/4. These checks do **not** establish live interruption behavior.

| Scenario | Live result | Evidence / next action |
| --- | --- | --- |
| Force quit during preparation, transcription, local analysis, moments, OpenRouter, preview, export | BLOCKED | Requires an authorized long source, a running interactive app, and an observer. Relaunch after each interruption; inspect manifest, source reattachment, cache rebuild, and partial outputs. |
| Disk full during remote download, proxy, cache, preview, export | BLOCKED | Use a disposable, size-limited APFS disk image on a QA Mac for temporary and output storage. Do not fill the system disk. Verify a useful error, cleanup, and recovery after freeing space. Direct URL import is gated; test authorized YouTube only if the downloader is installed and the source is cleared. |
| Network loss during remote ingestion and OpenRouter request | BLOCKED | On an isolated QA Mac, interrupt the network after the operation starts, then restore it. Confirm no partial media is accepted, no project corruption, and a manual retry path. An actual OpenRouter call requires a user-provided key and cost approval. |
| Cancellation and recovery regression tests | PASS | Existing `ProcessingTests`, `SourceIngestorTests`, `ClipResultsTests`, and project-state tests. |
| Export capacity preflight regression | PASS | `ClipResultsTests.testBatchExportRejectsInsufficientDiskSpaceWithoutPartialFile`; injected capacity is not a live full-volume failure. |
| Gateway error sanitization regression | PASS | Mocked OpenRouter tests cover network loss, status failures, and malformed responses; no paid call. |
| Complete external-user workflow | BLOCKED | Requires authorized media, interactive app access, and a real OpenRouter key for speech-based clip discovery. |

For each live case, record the asset ID, app commit, exact interruption point, expected and observed behavior, files left behind, relaunch result, and corrective action. Follow [QA_PROTOCOL.md](QA_PROTOCOL.md).
