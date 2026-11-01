#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fake_bin="$tmp/bin"
home="$tmp/home"
install_root="$home/devkit-game/VPXFrame"
mkdir -p "$fake_bin" "$home" "$tmp/stage/assets" "$tmp/stage/plugins" "$tmp/stage/scripts" "$tmp/stage/tools/frame"
cat > "$fake_bin/uname" <<'EOF_UNAME'
#!/usr/bin/env bash
if [[ "${1:-}" == "-m" ]]; then echo aarch64; else exec /usr/bin/uname "$@"; fi
EOF_UNAME
chmod +x "$fake_bin/uname"

cat > "$tmp/stage/VPinballX_BGFX" <<'EOF_APP'
#!/usr/bin/env bash
printf '%s\0' "$@" > "$VPX_TEST_ARGS_FILE"
EOF_APP
chmod +x "$tmp/stage/VPinballX_BGFX"
mkdir -p "$tmp/stage/assets/exampleTable.vpz"
printf '{"version": 1}\n' > "$tmp/stage/assets/exampleTable.vpz/manifest.json"
printf 'plugin fixture\n' > "$tmp/stage/plugins/plugin.txt"
printf 'script fixture\n' > "$tmp/stage/scripts/script.vbs"
cp "$repo_root/tools/frame/install-bundle.sh" "$repo_root/tools/frame/add-table-entry.sh" "$tmp/stage/tools/frame/"
printf 'source=abcdef1234567890\narchitecture=aarch64\nopenxr=enabled\nrenderer=BGFX\n' > "$tmp/stage/BUILD-METADATA.txt"
(
   cd "$tmp/stage"
   find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS
)
tar -czf "$tmp/frame-bundle.tar.gz" -C "$tmp/stage" .
tar -tzf "$tmp/frame-bundle.tar.gz" | grep -Fx './BUILD-METADATA.txt' >/dev/null

HOME="$home" VPX_FRAME_INSTALL_ROOT="$install_root" PATH="$fake_bin:$PATH" \
   bash "$repo_root/tools/frame/install-bundle.sh" "$tmp/frame-bundle.tar.gz"
[[ -L "$install_root/current" ]]
[[ -x "$install_root/current/VPinballX_BGFX" ]]
[[ -f "$install_root/current/BUILD-METADATA.txt" ]]

mkdir -p "$tmp/corrupt-stage/assets" "$tmp/corrupt-stage/plugins" "$tmp/corrupt-stage/scripts"
cp -a "$tmp/stage/." "$tmp/corrupt-stage/"
python3 - "$tmp/corrupt-stage/BUILD-METADATA.txt" <<'PY_CORRUPT_METADATA'
from pathlib import Path
import sys

path = Path(sys.argv[1])
path.write_text(path.read_text().replace("abcdef1234567890", "bcdefa1234567890"))
PY_CORRUPT_METADATA
printf 'tampered after checksumming\n' >> "$tmp/corrupt-stage/assets/exampleTable.vpz/manifest.json"
tar -czf "$tmp/corrupt-bundle.tar.gz" -C "$tmp/corrupt-stage" .
if HOME="$home" VPX_FRAME_INSTALL_ROOT="$install_root" PATH="$fake_bin:$PATH" \
   bash "$repo_root/tools/frame/install-bundle.sh" "$tmp/corrupt-bundle.tar.gz"; then
   echo 'Installer accepted a bundle with a file hash mismatch.' >&2
   exit 1
fi
[[ ! -e "$install_root/releases/bcdefa1234567890" ]]

mkdir -p "$tmp/update-stage"
cp -a "$tmp/stage/." "$tmp/update-stage/"
python3 - "$tmp/update-stage/BUILD-METADATA.txt" <<'PY_UPDATE_METADATA'
from pathlib import Path
import sys

path = Path(sys.argv[1])
path.write_text(path.read_text().replace("abcdef1234567890", "fedcba0987654321"))
PY_UPDATE_METADATA
(
   cd "$tmp/update-stage"
   find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS
)
tar -czf "$tmp/update-bundle.tar.gz" -C "$tmp/update-stage" .
HOME="$home" VPX_FRAME_INSTALL_ROOT="$install_root" PATH="$fake_bin:$PATH" \
   bash "$repo_root/tools/frame/install-bundle.sh" "$tmp/update-bundle.tar.gz"
[[ "$(readlink "$install_root/current")" == "releases/fedcba0987654321" ]]
[[ -x "$install_root/releases/fedcba0987654321/VPinballX_BGFX" ]]
[[ -x "$install_root/releases/abcdef1234567890/VPinballX_BGFX" ]]

mkdir -p "$home/devkit-utils"
cat > "$home/devkit-utils/steam-client-create-shortcut" <<'EOF_REGISTRAR'
import json
import os
import sys

assert sys.argv[1] == "--parms"
parms = json.loads(sys.argv[2])
# Steam resolves relative argv against ~/devkit-game/<gameid>, independently of
# the directory field used by the Python helper for app-ID handling.
game_directory = os.path.join(os.environ["HOME"], "devkit-game", parms["gameid"])
assert parms["directory"] == game_directory, parms
assert os.path.isfile(os.path.join(game_directory, parms["argv"][0])), parms
with open(os.environ["VPX_TEST_REGISTRATION_FILE"], "w", encoding="utf-8") as output:
    json.dump(parms, output)
print(json.dumps({"success": "fixture-registration"}))
EOF_REGISTRAR
chmod +x "$home/devkit-utils/steam-client-create-shortcut"
printf 'pinball table fixture\n' > "$tmp/Table with spaces and apostrophe's.vpx"
printf 'table companion fixture\n' > "$tmp/companion.txt"
XDG_DATA_HOME="$tmp/data" HOME="$home" VPX_FRAME_INSTALL_ROOT="$install_root" \
   VPX_TEST_REGISTRATION_FILE="$tmp/registration.json" \
   bash "$repo_root/tools/frame/add-table-entry.sh" "$tmp/Table with spaces and apostrophe's.vpx" 'Test Table'

python3 - "$tmp/registration.json" "$home/devkit-game/VPX_Test_Table" <<'PY_ASSERT_REGISTRATION'
import json
import sys

parms = json.load(open(sys.argv[1], encoding="utf-8"))
assert parms["gameid"] == "VPX_Test_Table", parms
assert parms["directory"] == sys.argv[2], parms
assert parms["force_appid"] == "", parms
assert len(parms["argv"]) == 1 and parms["argv"][0].startswith("launch-"), parms
assert parms["settings"] == {"steam_play": "0", "compat_tool": "SteamLinuxRuntime_4-arm64"}, parms
assert parms["env"] == {}, parms
PY_ASSERT_REGISTRATION
[[ ! -e "$install_root/steam_appid.txt" ]]

mkdir -p "$home/devkit-game/VPX_Existing"
printf 'user-owned content\n' > "$home/devkit-game/VPX_Existing/keep.txt"
if HOME="$home" VPX_FRAME_INSTALL_ROOT="$install_root" \
   VPX_TEST_REGISTRATION_FILE="$tmp/registration.json" \
   bash "$repo_root/tools/frame/add-table-entry.sh" "$tmp/Table with spaces and apostrophe's.vpx" 'Existing'; then
   echo 'Entry generator accepted an unrecognised game folder.' >&2
   exit 1
fi
[[ $(cat "$home/devkit-game/VPX_Existing/keep.txt") == 'user-owned content' ]]
[[ ! -e "$home/devkit-game/VPX_Existing/.vpx-frame-entry" ]]

launcher=$(find "$home/devkit-game/VPX_Test_Table" -name 'launch-*.sh' -print -quit)
[[ -n "$launcher" ]]
pref_dir="$tmp/data/VPXFrame/10.8"
mkdir -p "$pref_dir"
cat > "$pref_dir/VPinballX.ini" <<'EOF_INI'
[Player]
SoundVolume=78
[PlayerVR]
AskToTurnOn=2
DisplayRefreshRate=0
EOF_INI
XDG_DATA_HOME="$tmp/data" HOME="$home" VPX_FRAME_INSTALL_ROOT="$install_root" \
   VPX_TEST_ARGS_FILE="$tmp/app-args" bash "$launcher"
python3 - "$tmp/app-args" "$tmp/Table with spaces and apostrophe's.vpx" "$pref_dir/VPinballX.ini" <<'PY_ASSERT_LAUNCH'
from pathlib import Path
import os
import sys

args = Path(sys.argv[1]).read_bytes().decode().split("\0")[:-1]
assert args == ["-prefpath", str(Path(sys.argv[3]).parent), "-play", os.path.realpath(sys.argv[2])], args
settings = Path(sys.argv[3]).read_text(encoding="utf-8")
assert "SoundVolume=78" in settings
assert "AskToTurnOn=0" in settings
assert "DisplayRefreshRate=0" in settings
PY_ASSERT_LAUNCH

# Upstream ships the example as a VPZ directory, so exercise that real layout too.
HOME="$home" VPX_FRAME_INSTALL_ROOT="$install_root" \
   VPX_TEST_REGISTRATION_FILE="$tmp/registration.json" \
   bash "$repo_root/tools/frame/add-table-entry.sh" \
   "$install_root/current/assets/exampleTable.vpz" 'VPX Example Table'
example_launcher=$(find "$home/devkit-game/VPX_VPX_Example_Table" -name 'launch-*.sh' -print -quit)
[[ -n "$example_launcher" ]]
XDG_DATA_HOME="$tmp/data" HOME="$home" VPX_TEST_ARGS_FILE="$tmp/example-args" bash "$example_launcher"
python3 - "$tmp/example-args" "$install_root/current/assets/exampleTable.vpz" <<'PY_ASSERT_EXAMPLE'
from pathlib import Path
import os
import sys

args = Path(sys.argv[1]).read_bytes().decode().split("\0")[:-1]
assert args[-2:] == ["-play", os.path.realpath(sys.argv[2])], args
PY_ASSERT_EXAMPLE

printf 'Frame install and Steam entry tool integration passed.\n'
