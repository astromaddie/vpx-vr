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
with the same helper used for user tables. Copy the example pack into persistent table storage
first, so its saves and cache do not go into the versioned application bundle:

```bash
mkdir -p ~/Documents/VPXFrame/Tables
cp -a ~/devkit-game/VPXFrame/current/assets/exampleTable.vpz \
  ~/Documents/VPXFrame/Tables/
bash ~/devkit-game/VPXFrame/current/tools/frame/add-table-entry.sh \
  ~/Documents/VPXFrame/Tables/exampleTable.vpz "Example Table"
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

The script writes a small wrapper under `~/devkit-game/VPX_<table_name>/` and registers a
readable alphanumeric `VPX_<table_name>` library title through the Frame's native Steam
helper. It sets `SteamLinuxRuntime_4-arm64` and `steam_play=0` for the entry. Each launch opens
the supplied table from its original folder, retains table-local companions and forces OpenXR
mode through the separate Frame preferences file. No table or ROM is copied into the app
bundle, and no custom launcher UI is added.

Use the existing in-game Menu button to open VR settings. A new Frame configuration applies the
usable default layout automatically. If saved Frame action or sensor mappings differ, VPX keeps
them and presents its existing layout proposal so defaults are applied only if chosen.
Preferences and saves are isolated from other VPX builds and persist in
`$XDG_DATA_HOME/VPXFrame/10.8`.

## Off-head render diagnostic

To render while the headset is off-head, add `VPX_VR_FORCE_RENDER_FRAMES=240 %command%` to
the Steam entry's launch options. This opt-in diagnostic only forces frames while OpenXR is
in the synchronized state and reports `shouldRender=false`; it uses a synthetic 1.60 m stereo
pose and stops forcing after the requested number of attempts, at most 3600 (30 s at 120 Hz). Normal launches are unchanged when the
variable is unset. Logs identify when the diagnostic starts, its first successful BGFX
submission, and when its attempt limit is reached. If `VK_LAYER_LUNARG_api_dump` is
installed, prefix the same launch with `VK_INSTANCE_LAYERS=VK_LAYER_LUNARG_api_dump
VK_APIDUMP_FILE=true VK_APIDUMP_LOG_FILENAME=/tmp/vpx-vulkan-api.log VK_APIDUMP_DETAILED=true`
to capture detailed Vulkan call arguments.

For timing runs, add `VPX_VR_PERF=5` as well. Every 5 seconds the log then shows the frame rate,
BGFX's average and peak GPU time per frame, the logic and render thread sections (script,
physics, frame preparation, render waits, submission) and the GPU time of each named pass.
The profiler adds GPU timer queries, so compare runs that both have it on.

## Descriptor pool probe

`tools/frame/vulkan_sampler_descriptor_probe.py` checks the Turnip descriptor pool fault
described in [VR_ARCHITECTURE.md](VR_ARCHITECTURE.md#turnip-descriptor-pool-workaround)
without VPX. Copy it to the Frame and run it inside the installed Steam Linux Runtime:

```bash
~/.local/share/Steam/steamapps/common/SteamLinuxRuntime_4-arm64/run -- \
  /usr/bin/python3 vulkan_sampler_descriptor_probe.py --suite
```

It uses the system Vulkan loader, checks for the Frame's Adreno 750 / Mesa Turnip device and
runs each case in a child process with a 30-second limit and core dumps disabled. Every case
creates BGFX's captured 1,024-set pool and the descriptor-set layout of the first crashing
write, allocates one set and writes its sampler. The first four cases vary the layout and the
device creation payload on a fresh pool and all return normally. `reset_free_set_pool` resets
the pool first, as BGFX does each frame, and ends with SIGSEGV while the driver still has the
bug. `reset_linear_pool` does the same with the pool created without
`FREE_DESCRIPTOR_SET_BIT`, as the patched BGFX does, and returns normally. The probe creates
no shaders, swapchain or XR session.

## Table acceptance list

Black Hole BigusMOD 2.0 and 4 Queens 1.2 are stored under
`~/Documents/VPXFrame/Tables/` on the Frame. Transfer sizes and SHA-256 hashes match the
extracted iCloud originals. These are compatibility gates, not passing claims. Use each
table's own script and companion files as authoritative for ROM requirements; do not
substitute a ROM set by name alone.

| Target | Known setup | Acceptance gate |
| --- | --- | --- |
| Black Hole (Gottlieb, 1981) | User's BigusMOD 2.0 table defaults to `RomSet = 2`, requiring `blkhole2.zip`; that ROM file is pending | Load the supplied file and verify playfield rendering and gameplay |
| Time Machine (Data East, 1988) | User confirmed Data East version; common set is `tmac_a24`, but its exact table file is pending | Inspect the supplied table script, verify its ROM requirement and gameplay |
| 4 Queens (Bally, 1970) | User's 1.2 table is electromechanical; embedded game name is `Bally4Queens_1970` and no ROM is referenced | Verify the exact VPX file loads and its controller script works in standalone mode |
| Attack from Mars (Bally, 1995) | PinMAME ROM table; common set is `afm_113b`, but its exact table file is pending | Inspect the supplied table script, verify its ROM requirement and gameplay |

## Remaining acceptance gates

- Run the example table through its Steam entry on the current build.
- Bring GPU time within the 72 Hz frame budget: 4 Queens currently averages 17.9 ms of
  application GPU time per frame, and the compositor reprojects most frames.
- Confirm both projected eye images using runtime capture or wearer inspection.
- Exercise triggers, squeeze values, right ABXY, Menu, View short press and 1-second hold, vector2
  plunger/nudge input, focus loss and return from standby.
- Test each exact table version with its locally supplied dependencies, then complete wearer
  comfort and play acceptance.
