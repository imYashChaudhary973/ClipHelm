# Authorized production QA assets

Three publicly licensed videos were acquired for release QA on 2026-09-25. Source media and MP4 working copies stay in ignored local build storage, outside Git. Locally found personal videos remain excluded because their permission scope has not been confirmed.

When permission is confirmed, add one row per source. Keep private paths and personal details in the local QA run record, not here.

| ID | Duration | Resolution | FPS | Content type | Speech | Authorization/source status | Characteristics |
| --- | --- | --- | --- | --- | --- | --- | --- |
| QA-LECTURE-1080 | 32:56 | 1920×1080 | 25 | Lecture / screen recording | Yes, English | [Wikimedia Commons, CC BY-SA 4.0](https://commons.wikimedia.org/wiki/File:GMT20260904-162424_Recording_1920x1080.webm) | Original AV1/Opus WebM; QA MP4 copies video and converts audio to AAC. Source SHA-256 `b086ee25b1d7ddec0098e7a7b3f3fb8c60ed37b856d34546746d73e37d9c69fa`. |
| QA-STORY-4K | 12:03 | 3840×2160 | 24 | Narrative / moving subjects | Yes, Yoruba | [Wikimedia Commons, CC BY 4.0](https://commons.wikimedia.org/wiki/File:Igba_Eniyan.webm) | Creator-uploaded original VP9/Opus WebM; QA MP4 transcodes to H.264/AAC with VideoToolbox. Source SHA-256 `90e624a43decd70d61655a2c98c06891b04e7a9eb9184b5311d15956c254258f`. |
| QA-SPRING | 7:44 | 2048×858 | 24 | Silent-dialogue animated film / high motion | No dialogue; soundtrack | [Blender Foundation, CC BY 4.0](https://studio.blender.org/projects/spring/pages/about/) and [reviewed Commons copy](https://commons.wikimedia.org/wiki/File:Spring_-_Blender_Open_Movie.webm) | Original VP9/Opus WebM; QA MP4 transcodes to H.264/AAC with VideoToolbox. Source SHA-256 `d691a199035cc7d295210b286f8f6734893c7d4358d228081af6f0da98a56343`. |
| QA-SPRING-SILENT | 7:44 | 2048×858 | 24 | Test-only silent derivative of QA-SPRING | No audio track | Same license and source as QA-SPRING | Audio removed locally to exercise the no-speech pipeline without an OpenRouter request. This is not an independent content type or a substitute for a real silent demonstration. |

These assets allow partial real-video QA. The 4K source is 12 minutes, so it does not close the long-form 4K performance gate. The library still lacks a two-person podcast, coding tutorial, and mixed speaker/demo source. A source license permits internal testing but does not establish publishability of any third-party clip without following its attribution and share-alike conditions.

Follow [QA_PROTOCOL.md](QA_PROTOCOL.md) for the rights record, source hash, workflow, and scoring procedure.
