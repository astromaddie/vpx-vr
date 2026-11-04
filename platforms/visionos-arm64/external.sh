#!/bin/bash
set -eu

cd "$(dirname "$0")/../.."
export VPX_APPLE_TARGET=visionos-arm64
export VPX_BUILD_JOBS=${VPX_BUILD_JOBS:-2}
export VPX_HOST_CMAKE="$(command -v cmake)"
export PATH="$PWD/platforms/visionos-arm64/tools:$PATH"
exec bash platforms/ios-arm64/external.sh
