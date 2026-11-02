#!/usr/bin/env bash
# Set SteamVR's per-app refresh rate and eye resolution for a Steam library entry.
# usage: set-vr-display.sh <shortcut appid> [refresh Hz, default 72] [eye size px, default 1760]
# SteamVR applies the values at the entry's next launch.
set -euo pipefail

appid=${1:?usage: set-vr-display.sh <shortcut appid> [refresh Hz] [eye size px]}
refresh=${2:-${VPX_FRAME_REFRESH:-72}}
eye_size=${3:-${VPX_FRAME_EYE_SIZE:-1760}}
vrcmd=${VPX_FRAME_VRCMD:-/opt/steamvr/bin/linuxarm64/vrcmd}

if [[ ! "$appid" =~ ^[0-9]+$ ]]; then
   echo "Not a shortcut appid: $appid" >&2
   exit 1
fi
if [[ ! -x "$vrcmd" ]]; then
   echo "SteamVR's vrcmd was not found ($vrcmd); refresh rate and resolution left unchanged." >&2
   exit 0
fi
timeout 10 "$vrcmd" --set-settings-float "steam.app.$appid.preferredRefreshRate" "$refresh" >/dev/null
timeout 10 "$vrcmd" --set-settings-int "steam.app.$appid.resolutionOverride" "$eye_size" >/dev/null
echo "SteamVR settings for steam.app.$appid: $refresh Hz, $eye_size px eyes (applied at next launch)."
