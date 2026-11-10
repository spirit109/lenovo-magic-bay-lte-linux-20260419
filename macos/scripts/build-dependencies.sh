#!/bin/sh
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
[ "$(uname -s)" = Darwin ] || { echo 'macOS dependency adapter only' >&2; exit 69; }
archive="$project_dir/backend/libusb-1.0.30.tar.bz2"
expected=fea36f34f9156400209595e300840767ab1a385ede1dc7ee893015aea9c6dbaf
[ "$(shasum -a 256 "$archive" | awk '{print $1}')" = "$expected" ] || { echo 'libusb source checksum mismatch' >&2; exit 65; }
prefix="$project_dir/dependencies/libusb-1.0.30-macos14"
if [ -f "$prefix/lib/libusb-1.0.a" ] && [ -f "$prefix/build-complete" ]; then
    echo "libusb_prefix=$prefix"
    exit 0
fi
mkdir -p "$project_dir/dependencies"
work=$(mktemp -d "$project_dir/dependencies/.libusb-build-XXXXXXXX")
tar -xjf "$archive" -C "$work"
cd "$work/libusb-1.0.30"
MACOSX_DEPLOYMENT_TARGET=14.0 CFLAGS='-O2 -arch arm64 -mmacosx-version-min=14.0' \
    ./configure --prefix="$prefix" --disable-shared --enable-static --disable-tests-build --disable-examples-build
make -j2
make install
printf '%s\n' 'libusb=1.0.30 macos_target=14.0 architecture=arm64 source_sha256=fea36f34f9156400209595e300840767ab1a385ede1dc7ee893015aea9c6dbaf' > "$prefix/build-complete"
echo "libusb_prefix=$prefix"
