#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
   echo "Usage: $0 <table.vpx|table.vpz> [steam-entry-name]" >&2
   exit 2
fi

if ! command -v realpath >/dev/null 2>&1; then
   echo "realpath is required." >&2
   exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
   echo "python3 is required for Steam Frame shortcut registration." >&2
   exit 1
fi

table=$(realpath "$1")
if [[ ! -f "$table" && ! -f "$table/manifest.json" ]]; then
   echo "Table file or VPZ pack not found: $table" >&2
   exit 1
fi
case "${table##*.}" in
   [vV][pP][xX]|[vV][pP][zZ]) ;;
   *) echo "Expected a .vpx or .vpz table file: $table" >&2; exit 1 ;;
esac

entry_name=${2:-$(basename "${table%.*}")}
slug=$(printf '%s' "$entry_name" | sed -E 's/[^A-Za-z0-9]+/_/g; s/^_+//; s/_+$//')
if [[ -z "$slug" ]]; then
   echo "Entry name must contain at least one letter or number." >&2
   exit 1
fi
gameid="VPX_$slug"
install_root=${VPX_FRAME_INSTALL_ROOT:-"$HOME/devkit-game/VPXFrame"}
app="$install_root/current/VPinballX_BGFX"
if [[ ! -x "$app" ]]; then
   echo "VPX Frame build is not installed at $app. Install a build bundle first." >&2
   exit 1
fi
registrar="$HOME/devkit-utils/steam-client-create-shortcut"
if [[ ! -f "$registrar" ]]; then
   echo "Steam Frame shortcut helper is missing: $registrar" >&2
   exit 1
fi

if command -v sha256sum >/dev/null 2>&1; then
   table_hash=$(printf '%s' "$table" | sha256sum | cut -c1-10)
else
   table_hash=$(printf '%s' "$table" | shasum -a 256 | cut -c1-10)
fi
game_directory="$HOME/devkit-game/$gameid"
entry_marker="$game_directory/.vpx-frame-entry"
if [[ -e "$game_directory" && ! -f "$entry_marker" ]]; then
   echo "Refusing to replace an unrecognised Steam game folder: $game_directory" >&2
   exit 1
fi
mkdir -p "$game_directory"
printf '%s\n' "$install_root" > "$entry_marker"
launcher="$game_directory/launch-$table_hash.sh"
quoted_table=$(printf '%q' "$table")
quoted_root=$(printf '%q' "$install_root")

cat > "$launcher" <<EOF_LAUNCHER
#!/usr/bin/env bash
set -euo pipefail

install_root=$quoted_root
app="\$install_root/current/VPinballX_BGFX"
pref_dir="\${XDG_DATA_HOME:-\$HOME/.local/share}/VPXFrame/10.8"
if [[ ! -x "\$app" ]]; then
   echo "VPX Frame build is not installed. Install a build bundle first." >&2
   exit 1
fi
mkdir -p "\$pref_dir"
python3 - "\$pref_dir/VPinballX.ini" <<'PY_VR_CONFIG'
from pathlib import Path
import os
import re
import tempfile
import sys

path = Path(sys.argv[1])
lines = path.read_text(encoding="utf-8").splitlines(keepends=True) if path.exists() else []
section_start = next((i for i, line in enumerate(lines) if re.match(r"\s*\[PlayerVR\]\s*(?:[;#].*)?$", line, re.IGNORECASE)), None)
changed = False
if section_start is None:
    if lines and lines[-1].strip():
        lines.append("\n")
    lines.extend(["[PlayerVR]\n", "AskToTurnOn=0\n"])
    changed = True
else:
    section_end = next((i for i in range(section_start + 1, len(lines)) if re.match(r"\s*\[[^]]+\]", lines[i])), len(lines))
    key_line = next((i for i in range(section_start + 1, section_end) if re.match(r"\s*AskToTurnOn\s*=", lines[i], re.IGNORECASE)), None)
    if key_line is None:
        lines.insert(section_start + 1, "AskToTurnOn=0\n")
        changed = True
    elif re.sub(r"\s*AskToTurnOn\s*=\s*[^;#\r\n]*", "AskToTurnOn=0", lines[key_line], flags=re.IGNORECASE) != lines[key_line].rstrip("\r\n"):
        lines[key_line] = "AskToTurnOn=0\n"
        changed = True
if changed:
    fd, temporary = tempfile.mkstemp(prefix="VPinballX.ini.", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            stream.writelines(lines)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
PY_VR_CONFIG
exec "\$app" -prefpath "\$pref_dir" -play $quoted_table
EOF_LAUNCHER
chmod 755 "$launcher"

relative_launcher=$(basename "$launcher")
parms=$(python3 - "$gameid" "$game_directory" "$relative_launcher" <<'PY_PARMS'
import json
import sys

print(json.dumps({
    "gameid": sys.argv[1],
    "directory": sys.argv[2],
    "force_appid": "",
    "argv": [sys.argv[3]],
    "env": {},
    "settings": {
        "steam_play": "0",
        "compat_tool": "SteamLinuxRuntime_4-arm64",
    },
    "lepton_args": "",
}))
PY_PARMS
)
registration=$(python3 "$registrar" --parms "$parms")
python3 - "$registration" "$gameid" <<'PY_RESULT'
import json
import sys

try:
    result = json.loads(sys.argv[1])
except json.JSONDecodeError as error:
    raise SystemExit(f"Steam shortcut helper returned invalid JSON: {error}")
if "success" not in result:
    raise SystemExit(f"Steam shortcut registration failed: {result.get('error', result)}")
print(f"Registered Steam library entry {sys.argv[2]} ({result['success']}).")
PY_RESULT
printf 'Launcher: %s\n' "$launcher"
