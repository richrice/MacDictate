#!/bin/zsh
set -euo pipefail

cd "${0:A:h}/.."

if ! command -v xcodegen >/dev/null 2>&1; then
  print -u2 "XcodeGen is required. Install it with: brew install xcodegen"
  exit 1
fi

xcodegen generate
print "Generated MacDictate.xcodeproj"

