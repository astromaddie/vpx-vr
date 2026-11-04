#!/bin/sh
set -eu

framework_source="${VPX_NATIVE_BUILD_DIR:?Set VPX_NATIVE_BUILD_DIR to the visionOS CMake build directory}/vpinball.framework"
framework_destination="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH/vpinball.framework"
resources="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"

ditto "$framework_source" "$framework_destination"
if [ "${CODE_SIGNING_ALLOWED:-NO}" = YES ]; then
    codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:?}" "$framework_destination"
fi
ditto "$SRCROOT/../../src/assets" "$resources/assets"
ditto "$SRCROOT/../../src/scripts" "$resources/scripts"
