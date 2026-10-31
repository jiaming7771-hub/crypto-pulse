#!/bin/zsh
set -eu
cd "$(dirname "$0")"
mkdir -p .build
clang -fobjc-arc -fmodules -fmodules-cache-path=/tmp/cryptopulse-clang-cache -mmacosx-version-min=13.0 tests/reconnect.m -o .build/test-reconnect -framework Cocoa
.build/test-reconnect
if [[ "${1:-}" == "--live" ]]; then
    clang -fobjc-arc -fmodules -fmodules-cache-path=/tmp/cryptopulse-clang-cache -mmacosx-version-min=13.0 tests/live.m -o .build/test-live -framework Cocoa
    .build/test-live
fi
