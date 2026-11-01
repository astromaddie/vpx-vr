#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
   echo "Usage: $0 <VPXFrame-linux-aarch64-<commit>.tar.gz>" >&2
   exit 2
fi

bundle=$(realpath "$1")
if [[ ! -f "$bundle" ]]; then
   echo "Build bundle not found: $bundle" >&2
   exit 1
fi
if [[ "$(uname -m)" != "aarch64" ]]; then
   echo "Steam Frame install requires a native aarch64 Linux host (found $(uname -m))." >&2
   exit 1
fi

install_root=${VPX_FRAME_INSTALL_ROOT:-"$HOME/devkit-game/VPXFrame"}
releases="$install_root/releases"
mkdir -p "$releases"

# The CI archive is created with `tar -C stage .`, so GNU tar stores this as
# `./BUILD-METADATA.txt`.
metadata=$(tar -xOf "$bundle" ./BUILD-METADATA.txt)
source_revision=$(sed -n 's/^source=//p' <<< "$metadata")
if [[ ! "$metadata" =~ (^|$'\n')architecture=aarch64($|$'\n') || ! "$metadata" =~ (^|$'\n')openxr=enabled($|$'\n') ]]; then
   echo "Bundle is not marked as a native ARM64 OpenXR build." >&2
   exit 1
fi
if [[ ! "$source_revision" =~ ^[0-9a-f]{7,40}$ ]]; then
   echo "Bundle has invalid source revision metadata." >&2
   exit 1
fi

release="$releases/$source_revision"
if [[ -e "$release" ]]; then
   echo "Build $source_revision is already installed at $release" >&2
   exit 1
fi
if [[ -e "$install_root/current" && ! -L "$install_root/current" ]]; then
   echo "Refusing to replace a non-symlink install path: $install_root/current" >&2
   exit 1
fi

stage=$(mktemp -d "$install_root/.stage.XXXXXX")
next_link="$install_root/.current.new.$$"
cleanup()
{
   [[ -z "${stage:-}" ]] || rm -rf "$stage"
   rm -f "$next_link"
}
trap cleanup EXIT

tar -xzf "$bundle" -C "$stage"
if [[ ! -x "$stage/VPinballX_BGFX" || ! -d "$stage/assets" || ! -d "$stage/plugins" || ! -d "$stage/scripts" ]]; then
   echo "Bundle is missing the executable or required runtime data directories." >&2
   exit 1
fi
if [[ ! -f "$stage/BUILD-METADATA.txt" ]]; then
   echo "Bundle is missing BUILD-METADATA.txt." >&2
   exit 1
fi
if [[ ! -f "$stage/SHA256SUMS" ]]; then
   echo "Bundle file checksums are missing." >&2
   exit 1
fi
if command -v sha256sum >/dev/null 2>&1; then
   if ! (cd "$stage" && sha256sum --strict --check SHA256SUMS); then
      echo "Bundle file checksums are missing or invalid." >&2
      exit 1
   fi
elif command -v shasum >/dev/null 2>&1; then
   if ! (cd "$stage" && shasum -a 256 --check SHA256SUMS); then
      echo "Bundle file checksums are missing or invalid." >&2
      exit 1
   fi
else
   echo "No SHA-256 checker is available on this system." >&2
   exit 1
fi

mv "$stage" "$release"
stage=""
ln -s "releases/$source_revision" "$next_link"
python3 - "$next_link" "$install_root/current" <<'PY_REPLACE_LINK'
import os
import sys

os.replace(sys.argv[1], sys.argv[2])
PY_REPLACE_LINK
echo "Installed $source_revision at $install_root/current"
