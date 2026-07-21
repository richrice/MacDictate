#!/bin/zsh
set -euo pipefail

cd "${0:A:h}/.."
./scripts/build.sh
open DerivedData/Build/Products/Debug/MacDictate.app

