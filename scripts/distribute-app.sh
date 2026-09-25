#!/bin/bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -z "${CLIPHELM_SIGNING_IDENTITY:-}" || "$CLIPHELM_SIGNING_IDENTITY" == "-" ||
      -z "${CLIPHELM_NOTARY_PROFILE:-}" ]]; then
  echo "Set CLIPHELM_SIGNING_IDENTITY to a Developer ID Application identity and CLIPHELM_NOTARY_PROFILE to a notarytool Keychain profile." >&2
  exit 2
fi

"$repo_dir/scripts/build-app.sh" release
app="$repo_dir/build/ClipHelm.app"
codesign --verify --deep --strict --verbose=2 "$app"
signature=$(codesign -dv --verbose=4 "$app" 2>&1)
if [[ "$signature" != *"Authority=Developer ID Application:"* ||
      "$signature" != *"(runtime)"* ]]; then
  echo "The app is not signed with a Developer ID Application identity and hardened runtime." >&2
  exit 1
fi

notary_zip="$repo_dir/build/ClipHelm-notary.zip"
ditto -c -k --keepParent "$app" "$notary_zip"
xcrun notarytool submit "$notary_zip" --keychain-profile "$CLIPHELM_NOTARY_PROFILE" \
  --wait --output-format json > "$repo_dir/build/notary-result.json"
python3 - "$repo_dir/build/notary-result.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as result:
    status = json.load(result).get("status")
if status != "Accepted":
    raise SystemExit(f"Notarization status: {status}; inspect the notary log before distributing.")
PY
xcrun stapler staple "$app"
xcrun stapler validate "$app"
codesign --verify --deep --strict --verbose=2 "$app"
spctl -a -t exec -vv "$app"

artifact="$repo_dir/build/ClipHelm-distribution.zip"
ditto -c -k --keepParent "$app" "$artifact"
echo "$artifact"
