#!/bin/zsh
set -euo pipefail

cd "${0:A:h}/.."
./scripts/bootstrap.sh
xcodebuild -project MacDictate.xcodeproj -scheme MacDictate -configuration Debug -derivedDataPath DerivedData -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test
