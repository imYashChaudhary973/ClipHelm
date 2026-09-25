# Direct macOS distribution

This is the intended Developer ID path for **direct distribution outside the Mac App Store**. A local Developer ID-signed Release build has passed `codesign --verify` with hardened runtime and a secure timestamp. It has **not** been notarized: the `cliphelm-release` notarytool Keychain profile is absent. Gatekeeper rejects this intermediate build as `Unnotarized Developer ID`. The bundle identifier is `com.cliphelm.app` and the minimum macOS version is 14.0; confirm ownership of the identifier in the Apple Developer team before external distribution.

Apple requires a Developer ID Application signature, hardened runtime, and a secure timestamp for new notarization submissions. App Sandbox is optional for direct distribution; this build currently does not enable it. Do not add broad sandbox or hardened-runtime exception entitlements to make a failed workflow pass. Assess file access, subprocesses, Keychain, Speech, and networking on the final signed build. See [Apple's notarization requirements](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution) and [distribution preparation](https://developer.apple.com/documentation/xcode/preparing-your-app-for-distribution).

## Prerequisites

1. Install Xcode and Command Line Tools. Verify `xcodebuild -version` and `xcrun notarytool --help`.
2. Install a valid **Developer ID Application** certificate in the signing Keychain. Check `security find-identity -v -p codesigning` outside restricted build sandboxes. This Mac has a valid identity; keep its private key out of Git and build logs.
3. Store notarization credentials in macOS Keychain with `xcrun notarytool store-credentials cliphelm-release` and the appropriate interactive authentication options. Never pass an app-specific password or API private key as a shell argument.
4. Confirm `com.cliphelm.app` belongs to the intended team and set a release version/build number in `Resources/Info.plist`.
5. For the optional YouTube source flow, install `yt-dlp` on each destination Mac (`brew install yt-dlp`) and confirm `yt-dlp --version`. ClipHelm supports the Homebrew paths `/opt/homebrew/bin` and `/usr/local/bin`. Install FFmpeg (`brew install ffmpeg`) for separate high-resolution video and audio streams; without it, ClipHelm requests a single MP4 stream that may have lower resolution or be unavailable. Neither tool is bundled in this release path. Record exact versions in the QA run.

## Build, sign, notarize

Set `CLIPHELM_SIGNING_IDENTITY` to the installed Developer ID Application identity and `CLIPHELM_NOTARY_PROFILE` to the Keychain profile name, then run:

```sh
CLIPHELM_SIGNING_IDENTITY='Developer ID Application: YOUR TEAM NAME (TEAMID)' \
CLIPHELM_NOTARY_PROFILE='cliphelm-release' \
scripts/distribute-app.sh
```

The script builds Release, signs with hardened runtime and a timestamp, verifies the signature, submits a ZIP with `notarytool`, requires **Accepted** status, staples and validates the app ticket, checks local Gatekeeper assessment, then creates `build/ClipHelm-distribution.zip`. If notarization is invalid, use the submission ID from ignored `build/notary-result.json` with `xcrun notarytool log <id> --keychain-profile cliphelm-release`; fix the reported issue before retrying. `scripts/build-app.sh release` without a signing identity remains an ad hoc **local-test** build and cannot be distributed.

## Validate the shipped archive

Extract the final ZIP on a clean Mac or equivalent clean user environment; do not use the working build folder. Confirm the app is quarantined as a downloaded artifact, install it in `/Applications`, and run `codesign --verify --deep --strict --verbose=2`, `xcrun stapler validate`, and `spctl -a -t exec -vv` against the installed app. Launch through Finder to exercise Gatekeeper. Record the certificate team, bundle ID, app version, macOS version, and test result without publishing private certificate material.

In the installed build, add and test an OpenRouter key in Keychain; import user-selected authorized local media; run transcription, analysis, clip discovery, preview, and export; quit and reopen the project. Verify outgoing OpenRouter networking and Speech permission. Test authorized YouTube import after installing the documented `yt-dlp` prerequisite; test both the single-MP4 route without FFmpeg and the high-resolution merge route with FFmpeg where a cleared source provides both formats. Do not claim YouTube works on a pristine Mac before its prerequisite is installed. Direct video URL import remains disabled. A successful `spctl` result on the build Mac does not replace this clean-install test.

The upstream one-file `yt-dlp_macos` binary was evaluated for bundling. It launched before signing, but its embedded Python library was rejected by hardened-runtime library validation after Developer ID signing. A future bundled helper needs an independently signed, notarized runtime and license review. Do not enable a broad library-validation exception to package that binary.

Do not publish the archive until [RELEASE_CHECKLIST.md](RELEASE_CHECKLIST.md) says `RELEASE READY` and all blocking results have evidence.
