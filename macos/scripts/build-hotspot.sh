#!/bin/sh
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
[ "$(uname -s)" = Darwin ] || { echo 'The hotspot adapter requires macOS Internet Sharing.' >&2; exit 69; }
cd "$project_dir"
output="$project_dir/dist/hotspot-$(date '+%Y%m%d-%H%M%S')-$$"
mkdir -p "$output/module-cache"
architecture=$(uname -m)
xcrun swiftc -swift-version 5 -target "$architecture-apple-macos14.0" -module-cache-path "$output/module-cache" -O \
    Sources/ConnectionModel.swift Sources/MacSystem.swift Sources/HotspotPolicy.swift Sources/HotspotMain.swift Sources/HotspotWatchdog.swift \
    -framework SystemConfiguration -o "$output/magicbay-hotspotctl"
/usr/bin/codesign --sign - "$output/magicbay-hotspotctl"
/usr/bin/codesign --verify --strict "$output/magicbay-hotspotctl"
app="$output/恢复 Magic Bay 上网.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp resources/HotspotRecovery-Info.plist "$app/Contents/Info.plist"
cp resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
xcrun swiftc -swift-version 5 -target "$architecture-apple-macos14.0" -module-cache-path "$output/module-cache" -O \
    -parse-as-library Sources/HotspotRecovery.swift -framework Cocoa -o "$app/Contents/MacOS/MagicBayRecovery"
/usr/bin/codesign --sign - "$app"
/usr/bin/codesign --verify --deep --strict "$app"
echo "hotspot_tool=$output/magicbay-hotspotctl"
echo "recovery_app=$app"
echo 'system_changes=0 backend_restarted=0 hotspot_enabled=0'
