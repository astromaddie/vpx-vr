# Steam Frame build, install and table entries

This is a native standalone Linux ARM64 build for the Steam Frame. It uses BGFX/Vulkan and
OpenXR and is intended to run as a normal Steam library entry under Steam Linux Runtime 4.
The build is a development artifact; it is not a published release.

## Build

From GitHub, run **Actions → Steam Frame ARM64 → Run workflow** on the branch to build. The
workflow is manual-only and uses `ubuntu-24.04-arm`; it runs the existing
`platforms/linux-aarch64/external.sh`, then configures BGFX with `ENABLE_XR=ON`,
`BUILD_RPI=OFF` and `BUILD_RK3588=OFF`. It verifies the executable is AArch64 and the XR
option is enabled before uploading `VPXFrame-linux-aarch64-<commit>.tar.gz`.

The archive contains the executable, copied shared libraries, assets, scripts, plugins,
documentation, the two Frame setup helpers, build metadata and a per-file `SHA256SUMS` list.
The workflow artifact also includes a checksum for the archive itself. It contains the upstream
example table for initial startup validation, but no user or commercial tables, ROMs,
colorizations or other user-owned table content.

## Install on the Frame

Download the workflow artifact on the Frame or transfer the archive, its `.sha256` file and
the two helper scripts to the Frame. From the folder containing those downloads, verify the
archive and install it:

```bash
sha256sum -c VPXFrame-linux-aarch64-<commit>.tar.gz.sha256
bash install-bundle.sh VPXFrame-linux-aarch64-<commit>.tar.gz
```

The installer requires `uname -m` to report `aarch64`. It places each build in an immutable
folder under `~/devkit-game/VPXFrame/releases/` and atomically moves the `current` symlink to
the new build after checking every packaged file hash. Set `VPX_FRAME_INSTALL_ROOT` to use a
different install location. VPX settings, saves and other preferences use the isolated
`$XDG_DATA_HOME/VPXFrame/10.8` directory (defaulting to `~/.local/share/VPXFrame/10.8`). Each
table entry passes this directory as `-prefpath` and ensures OpenXR mode is enabled there.

For a startup check before importing user tables, register the bundled upstream example table
with the same helper used for user tables:

```bash
bash ~/devkit-game/VPXFrame/current/tools/frame/add-table-entry.sh \
  ~/devkit-game/VPXFrame/current/assets/exampleTable.vpz "VPX Example Table"
```

The helper creates and registers a Steam library entry with `steam-client-create-shortcut`,
`SteamLinuxRuntime_4-arm64` and `steam_play=0`. Steam must be running and
`~/devkit-utils/steam-client-create-shortcut` must be installed. This checks process startup
and table loading only; it does not establish controller input, stereo output, frame pacing,
headset comfort or table compatibility.

## User table folders and Steam entries

Copy each user-owned table folder to the Frame, keeping its companion files together. For
example, a table may live under `~/Downloads/VPX-Tables/<table folder>/`. Do not merge its
ROMs or companion files into the application bundle. Direct table-file launch keeps VPX's
normal per-table file lookup working in the original folder.

Create and register a per-table Steam library entry for each table file:

```bash
bash add-table-entry.sh \
  "$HOME/Downloads/VPX-Tables/<table folder>/<table file>.vpx" \
  "<table name>"
```

The script writes a small wrapper under `~/devkit-game/VPXFrame/launchers/` and registers a
readable alphanumeric `VPX_<table_name>` library title through the Frame's native Steam
helper. It sets `SteamLinuxRuntime_4-arm64` and `steam_play=0` for the entry. Each launch opens
the supplied table from its original folder, retains table-local companions and forces OpenXR
mode through the separate Frame preferences file. No table or ROM is copied into the app
bundle, and no custom launcher UI is added.

Use the existing in-game Menu button to open VR settings. Saved input bindings are retained;
the default mapping proposal can be applied through VPX's existing input settings if needed.
Preferences and saves are isolated from other VPX builds and persist in
`$XDG_DATA_HOME/VPXFrame/10.8`.

## Table acceptance list

Exact user versions have not yet been copied to the Frame, so these are compatibility gates,
not passing claims. Use each table's own script and companion files as authoritative for ROM
requirements; do not substitute a ROM set by name alone.

| Target | Known setup | Acceptance gate |
| --- | --- | --- |
| Black Hole (Gottlieb, 1981) | User's BigusMOD 2.0 table; its script selects ROM names `blckhole`, `blkhole2`, `bhol_ltd`, `blkholea`, `blkhole7` or `blkhol7s` by its ROM-set choice | Load the supplied file, confirm the selected ROM set and playfield rendering |
| Time Machine (Data East, 1988) | User confirmed Data East version; common set is `tmac_a24`, but its exact table file is pending | Inspect the supplied table script, verify its ROM requirement and gameplay |
| 4 Queens (Bally, 1970) | User's 1.2 table is electromechanical; embedded game name is `Bally4Queens_1970` and no ROM is referenced | Verify the exact VPX file loads and its controller script works in standalone mode |
| Attack from Mars (Bally, 1995) | PinMAME ROM table; common set is `afm_113b`, but its exact table file is pending | Inspect the supplied table script, verify its ROM requirement and gameplay |

## Remaining acceptance gates

- Build from the final Frame source and verify the artifact hash and AArch64/OpenXR metadata.
- Install and launch through Steam Linux Runtime 4; capture OpenXR runtime, instance/session
  timing and session-state logs.
- Confirm both projected eye images using runtime capture or wearer inspection. The current
  code logs stereo view count and eye dimensions but does not read back eye images.
- Exercise triggers, squeeze values, right ABXY, Menu, View short press and 1-second hold, vector2
  plunger/nudge input, focus loss and return from standby.
- Test each exact table version with its locally supplied dependencies, then complete wearer
  comfort and play acceptance.
