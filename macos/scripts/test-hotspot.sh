#!/bin/sh
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_dir"
output="$project_dir/tests/run-hotspot-$(date '+%Y%m%d-%H%M%S')-$$"
mkdir -p "$output/module-cache"
if [ "$(uname -s)" = Darwin ]; then
    xcrun swiftc -swift-version 5 -module-cache-path "$output/module-cache" \
        Sources/HotspotPolicy.swift tests/HotspotTests.swift -o "$output/hotspot-tests"
else
    swiftc -swift-version 5 -module-cache-path "$output/module-cache" \
        Sources/HotspotPolicy.swift tests/HotspotTests.swift -o "$output/hotspot-tests"
fi
"$output/hotspot-tests"
/bin/sh -n scripts/build-hotspot.sh
echo "test_output=$output"
