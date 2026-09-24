# Project format design

A project will use a versioned manifest plus regeneratable caches. `ProjectID`, `AssetID`, `MediaAsset`, `Transcript`, and `ClipHelmEditSpec` are typed core contracts. Project I/O, migration, source references, and caches are planned for later phases.

The future manifest must never contain an OpenRouter API key. Source URLs and paths must never be accepted from AI responses. Original media stays untouched.
