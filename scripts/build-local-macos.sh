#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

# Build for this Mac with a separate app identity and an ad-hoc signature.
# Keep the normal sandbox entitlements; no Apple account or upstream profile is needed.
xcodebuild -project FSNotes.xcodeproj -scheme FSNotes \
    -configuration Release -destination "platform=macOS,arch=$(uname -m)" \
    -derivedDataPath build/DerivedData \
    -disableAutomaticPackageResolution -skipPackageUpdates \
    CODE_SIGNING_ALLOWED=YES CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM='' \
    PROVISIONING_PROFILE='' PROVISIONING_PROFILE_SPECIFIER='' \
    PRODUCT_BUNDLE_IDENTIFIER=io.github.sebiimaks.consolinotes \
    build

app_path="$repo_root/build/DerivedData/Build/Products/Release/consolinotes.app"
codesign --verify --deep --strict --verbose=2 "$app_path"
python3 scripts/check-license-distribution.py --app "$app_path" --require-tracked
printf '\nLocal app: %s\n' "$app_path"
