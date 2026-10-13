#!/bin/bash
# Runs the unit tests. With only the Command Line Tools installed, swift-testing lives outside the default
# framework search path, so point the compiler and the test runner at it.
set -euo pipefail
cd "$(dirname "$0")/.."

CLT=/Library/Developer/CommandLineTools/Library/Developer
args=()
if [[ -d "$CLT/Frameworks/Testing.framework" ]]; then
    args=(-Xswiftc -F -Xswiftc "$CLT/Frameworks"
          -Xlinker -F -Xlinker "$CLT/Frameworks"
          -Xlinker -rpath -Xlinker "$CLT/Frameworks"
          -Xlinker -rpath -Xlinker "$CLT/usr/lib")
fi
exec swift test ${args[@]+"${args[@]}"} "$@"
