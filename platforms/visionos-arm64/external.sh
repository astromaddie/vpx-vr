#!/bin/bash
set -eu

cd "$(dirname "$0")/../.."
export VPX_VISIONOS_SDK=${VPX_VISIONOS_SDK:-xros}
case "$VPX_VISIONOS_SDK" in
   xros) export VPX_APPLE_TARGET=visionos-arm64 ;;
   xrsimulator) export VPX_APPLE_TARGET=visionos-simulator-arm64 ;;
   *) echo "Expected VPX_VISIONOS_SDK=xros or xrsimulator" >&2; exit 1 ;;
esac
export VPX_BUILD_JOBS=${VPX_BUILD_JOBS:-2}
export VPX_HOST_CMAKE="$(command -v cmake)"
export PATH="$PWD/platforms/visionos-arm64/tools:$PATH"
exec bash platforms/ios-arm64/external.sh
