#!/bin/bash
# Runs the unit tests. With only the Command Line Tools installed, swift-testing lives outside the default
# framework search path, so point the compiler and the test runner at it.
set -euo pipefail
cd "$(dirname "$0")/.."

# Only when the Command Line Tools are the selected toolchain: with Xcode (CI runners), its own compiler
# finds its own Testing module, and adding the Command Line Tools' copy would mix two versions.
CLT=/Library/Developer/CommandLineTools/Library/Developer
args=()
if [[ "$(xcode-select -p 2>/dev/null)" == /Library/Developer/CommandLineTools* && -d "$CLT/Frameworks/Testing.framework" ]]; then
    args=(-Xswiftc -F -Xswiftc "$CLT/Frameworks"
          -Xlinker -F -Xlinker "$CLT/Frameworks"
          -Xlinker -rpath -Xlinker "$CLT/Frameworks"
          -Xlinker -rpath -Xlinker "$CLT/usr/lib")
fi
exec swift test ${args[@]+"${args[@]}"} "$@"
