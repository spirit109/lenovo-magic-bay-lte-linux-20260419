#!/bin/sh
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
[ "$#" = 1 ] || { echo 'usage: verify-release.sh ABSOLUTE_BUILD_DIRECTORY' >&2; exit 64; }
output=$1
case "$output" in "$project_dir"/dist/build-*) ;; *) echo 'Build directory must be inside this project.' >&2; exit 64 ;; esac
app="$output/Magic Bay LTE 2.app"
test -d "$app"
/usr/bin/codesign --verify --deep --strict "$app"
echo 'app_signature=verified_ad_hoc'
/usr/bin/plutil -lint "$app/Contents/Info.plist"
app_version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")
[ "$app_version" = "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$project_dir/resources/Info.plist")" ]
for name in MagicBayLTE2 mbim-net magic-bay-lte-v2-rootctl magicbay-proxy-compat magic-bay-device-info; do
    executable="$app/Contents/MacOS/$name"
    /usr/bin/file "$executable"
    minimum=$(/usr/bin/otool -l "$executable" | awk '/LC_BUILD_VERSION/{found=1} found && /minos/{print $2; exit}')
    [ "$minimum" = 14.0 ] || { echo "Unexpected minimum OS for $name: $minimum" >&2; exit 1; }
    if /usr/bin/otool -L "$executable" | /usr/bin/grep -q '/opt/homebrew'; then echo "Unexpected external Homebrew dependency: $name" >&2; exit 1; fi
    echo "binary=$name minimum_macos=$minimum external_homebrew_dependency=0"
done
controller_version=$("$app/Contents/MacOS/magic-bay-lte-v2-rootctl" version)
[ "$controller_version" = "version=2 app_version=$app_version" ]
echo "$controller_version"
usb_build_info=$("$app/Contents/MacOS/mbim-net" --build-info)
case "$usb_build_info" in
    'usb_library=1.0.30 usb_api='*' diagnostics=1') ;;
    *) echo "Unexpected compiled USB library: $usb_build_info" >&2; exit 1 ;;
esac
echo "$usb_build_info"
/bin/sh -n "$app/Contents/Resources/install-helper"
test -s "$app/Contents/Resources/ThirdParty/libusb-LICENSE.txt"
test -s "$app/Contents/Resources/ThirdParty/libusb-1.0.30.tar.bz2"
[ "$(/usr/bin/shasum -a 256 "$app/Contents/Resources/ThirdParty/libusb-1.0.30.tar.bz2" | awk '{print $1}')" = fea36f34f9156400209595e300840767ab1a385ede1dc7ee893015aea9c6dbaf ]
for header in mbim_readonly.h mbim_capabilities.h mbim_startup.h mbim_diagnostics.h; do
    test -s "$app/Contents/Resources/ThirdParty/$header"
done
(
    cd "$output"
    /usr/bin/shasum -a 256 -c SHA256SUMS.txt
    /usr/bin/unzip -tqq "Magic-Bay-LTE-$app_version-arm64.zip"
    cat SHA256SUMS.txt
)
echo 'archive_integrity=passed installer_executed=0 backend_launched=0'
