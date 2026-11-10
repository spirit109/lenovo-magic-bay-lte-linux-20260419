#!/bin/sh
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
[ "$(uname -s)" = Darwin ] || { echo 'macOS is required for AppKit, IOKit and utun. See README for platform boundaries.' >&2; exit 69; }
[ "$(uname -m)" = arm64 ] || { echo 'This release targets Apple Silicon.' >&2; exit 69; }
cd "$project_dir"
/bin/sh "$script_dir/build-dependencies.sh"
libusb_prefix="$project_dir/dependencies/libusb-1.0.30-macos14"
test -f "$libusb_prefix/lib/libusb-1.0.a"
stamp=$(date '+%Y%m%d-%H%M%S')-$$
output="$project_dir/dist/build-$stamp.noindex"
app="$output/Magic Bay LTE 2.app"
app_version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' resources/Info.plist)
archive="Magic-Bay-LTE-$app_version-arm64.zip"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$output/module-cache"
mkdir -p "$app/Contents/Resources/ThirdParty"
/usr/bin/tar -xOf backend/libusb-1.0.30.tar.bz2 libusb-1.0.30/COPYING > "$app/Contents/Resources/ThirdParty/libusb-LICENSE.txt"
cp backend/libusb-1.0.30.tar.bz2 "$app/Contents/Resources/ThirdParty/"
cp backend/mbim_net.c "$app/Contents/Resources/ThirdParty/mbim_net.c"
for header in mbim_readonly.h mbim_capabilities.h mbim_startup.h mbim_diagnostics.h; do
    cp "backend/$header" "$app/Contents/Resources/ThirdParty/$header"
done
cp backend/device_info.c "$app/Contents/Resources/ThirdParty/device_info.c"
cp resources/Info.plist "$app/Contents/Info.plist"
cp resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
install -m 755 resources/install-helper "$app/Contents/Resources/install-helper"
install -m 755 resources/clean-install-helper "$app/Contents/Resources/clean-install-helper"
/usr/bin/printf '%s\n' "$project_dir" > "$app/Contents/Resources/project-root.txt"
export MACOSX_DEPLOYMENT_TARGET=14.0
xcrun clang -arch arm64 -mmacosx-version-min=14.0 -Wall -Wextra -Wpedantic -O2 -DMBIM_NET_DIAGNOSTICS=1 \
    -I"$libusb_prefix/include/libusb-1.0" backend/mbim_net.c "$libusb_prefix/lib/libusb-1.0.a" \
    -framework IOKit -framework CoreFoundation -framework Security -o "$app/Contents/MacOS/mbim-net"
xcrun clang -arch arm64 -mmacosx-version-min=14.0 -Wall -Wextra -Wpedantic -O2 \
    -I"$libusb_prefix/include/libusb-1.0" backend/device_info.c "$libusb_prefix/lib/libusb-1.0.a" \
    -framework IOKit -framework CoreFoundation -framework Security -o "$app/Contents/MacOS/magic-bay-device-info"
xcrun swiftc -swift-version 5 -target arm64-apple-macos14.0 -module-cache-path "$output/module-cache" -O \
    Sources/ConnectionModel.swift Sources/MacSystem.swift Sources/ControllerPolicy.swift Sources/RootController.swift \
    -framework SystemConfiguration -o "$app/Contents/MacOS/magic-bay-lte-v2-rootctl"
xcrun swiftc -swift-version 5 -target arm64-apple-macos14.0 -module-cache-path "$output/module-cache" -O \
    Sources/ConnectionModel.swift Sources/MacSystem.swift Sources/ControllerPolicy.swift Sources/AppController.swift Sources/MainView.swift Sources/main.swift \
    -framework Cocoa -framework SwiftUI -o "$app/Contents/MacOS/MagicBayLTE2"
xcrun swiftc -swift-version 5 -target arm64-apple-macos14.0 -module-cache-path "$output/module-cache" -O \
    Sources/ConnectionModel.swift Sources/MacSystem.swift Sources/ProxyCompatibilityMain.swift Sources/ProxyCompatibilityWatch.swift \
    -framework SystemConfiguration -o "$app/Contents/MacOS/magicbay-proxy-compat"
xcrun clang -arch arm64 -mmacosx-version-min=14.0 -Wall -Wextra -Wpedantic -O2 \
    backend/clean_install_lock.c -o "$app/Contents/Resources/clean-install-lock"
/usr/bin/codesign --force --sign - "$app/Contents/Resources/clean-install-lock"
xcrun swiftc -swift-version 5 -target arm64-apple-macos14.0 -module-cache-path "$output/module-cache" -O \
    Sources/ConnectionModel.swift Sources/MacSystem.swift Sources/CleanStopProxy.swift \
    -framework SystemConfiguration -o "$app/Contents/Resources/clean-stop-proxy"
/usr/bin/codesign --force --sign - "$app/Contents/Resources/clean-stop-proxy"
for executable in mbim-net magic-bay-lte-v2-rootctl MagicBayLTE2 magicbay-proxy-compat magic-bay-device-info; do
    /usr/bin/codesign --force --sign - "$app/Contents/MacOS/$executable"
done
/usr/bin/codesign --force --sign - "$app"
/usr/bin/codesign --verify --deep --strict "$app"
recovery="$output/恢复家庭网络.app"
/usr/bin/osacompile -o "$recovery" resources/home-recovery.applescript
cp "$app/Contents/MacOS/magic-bay-lte-v2-rootctl" "$recovery/Contents/Resources/recovery-rootctl"
/usr/libexec/PlistBuddy -c 'Add :CFBundleIdentifier string local.magicbay.home-recovery' "$recovery/Contents/Info.plist"
/usr/bin/codesign --force --sign - "$recovery"
/usr/bin/codesign --verify --deep --strict "$recovery"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app" "$output/$archive"
(
    cd "$output"
    /usr/bin/shasum -a 256 "$archive" > SHA256SUMS.txt
)
echo "build_output=$output"
echo "app=$app"
echo 'install_performed=0 network_started=0'
