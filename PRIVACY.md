# Privacy

ClipHelm edits locally. Original media is read, not modified. Projects save configuration, transcripts, validated edit specs, and generated clip names under the user's Application Support directory. Analysis caches and editing proxies can be regenerated. Exported MP4 copies go only to the folder the user chooses.

ClipHelm sends data to OpenRouter only for an action that needs a selected model: word-timed transcription where supported, spoken-moment reasoning, or optional AI Vision for uncertain shots. Those requests contain short extracted audio chunks, bounded transcript excerpts and metadata, or selected reduced JPEG frames. Original full videos are not sent to OpenRouter. The OpenRouter key lives in macOS Keychain; model choices may be saved in preferences, but the key is not.

Direct video URL import is currently disabled while its connection security is improved. Authorized YouTube import makes a network request to YouTube and its media hosts through the local downloader. On-device transcription uses Apple's on-device speech recognition mode. ClipHelm has no analytics, advertising, or application crash-upload service.

Deleting a clip removes its generated files from the project; copies exported elsewhere remain. Removing a project package removes its saved transcript, edit decisions, and generated files. Remote downloads and temporary transcription/vision material are cleaned after use or cancellation; abandoned remote import directories are swept on a later import. Removing the OpenRouter key in Settings deletes its Keychain item.

See [security review](SECURITY.md) for outbound controls and diagnostic limits.
