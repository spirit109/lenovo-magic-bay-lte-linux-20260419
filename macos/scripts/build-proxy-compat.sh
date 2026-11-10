#!/bin/sh
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
[ "$(uname -s)" = Darwin ] || { echo 'The proxy compatibility adapter requires macOS SystemConfiguration.' >&2; exit 69; }
cd "$project_dir"
output="$project_dir/dist/proxy-compat-$(date '+%Y%m%d-%H%M%S')-$$"
mkdir -p "$output/module-cache"
architecture=$(uname -m)
xcrun swiftc -swift-version 5 -target "$architecture-apple-macos14.0" -module-cache-path "$output/module-cache" -O \
    Sources/ConnectionModel.swift Sources/MacSystem.swift Sources/ProxyCompatibilityMain.swift Sources/ProxyCompatibilityWatch.swift \
    -framework SystemConfiguration -o "$output/magicbay-proxy-compat"
/usr/bin/codesign --sign - "$output/magicbay-proxy-compat"
/usr/bin/codesign --verify --strict "$output/magicbay-proxy-compat"
app="$output/Magic Bay 代理兼容.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp resources/ProxyCompatibility-Info.plist "$app/Contents/Info.plist"
cp resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
xcrun swiftc -swift-version 5 -target "$architecture-apple-macos14.0" -module-cache-path "$output/module-cache" -O \
    -parse-as-library Sources/ProxyCompatibilityApp.swift -framework Cocoa -framework SystemConfiguration -o "$app/Contents/MacOS/MagicBayProxyCompatibility"
/usr/bin/codesign --sign - "$app"
/usr/bin/codesign --verify --deep --strict "$app"
echo "proxy_compat_tool=$output/magicbay-proxy-compat"
echo "proxy_compat_app=$app"
echo 'network_configuration_changed=0'
