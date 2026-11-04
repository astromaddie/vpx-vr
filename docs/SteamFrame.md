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

Registration also sets SteamVR's per-app refresh rate and eye size for the entry to the Frame
target of 72 Hz at 2160x2160 per eye (`set-vr-display.sh <appid> [Hz] [px]` changes them later;
SteamVR applies them at the entry's next launch). On the Frame build the desktop mirror and the
OpenXR depth layer default off, reflections default to balls only, the Turnip driver renders
without tiling (`[PlayerVR] GPUTiling` off, which sets `TU_DEBUG=sysmem`) and textures get a
3072 MB budget (`[Player] GPUMemoryBudget`); all of these remain settings. With these defaults,
including packed HDR render targets and frustum culling, 4 Queens holds 72 fps at 2160x2160 per
eye at about 10.5 ms of GPU time per frame (8.0 ms at 1728x1728).

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

## Installed Table Library

The Frame keeps the tables in `~/Documents/VPXFrame/Tables/`, separate from the versioned
application bundle. On 4 November 2026 I added seven tables from the supplied `pinball`
folder, alongside 4 Queens. The installed engine is build `c8b2607`.

| Table | Supplied Version | ROM Set | Steam Entry |
| --- | --- | --- | --- |
| 4 Queens | 1.2 | Electromechanical; no ROM | `VPX_4_Queens` |
| Attack from Mars | g5k 1.3.11 | `afm_113b` | `VPX_Attack_from_Mars` |
| Black Hole | 1981 table | `blckhole` | `VPX_Black_Hole` |
| Gorgar | 2.0 | `grgar_l1` | `VPX_Gorgar` |
| Meteor | Stern 1979 table | `meteorb` | `VPX_Meteor` |
| Middle Earth | 1.00 Flipperspiel | `midearth` | `VPX_Middle_Earth` |
| The Machine: Bride of Pinbot | 2.1 Flipperspiel | `bop_l7` | `VPX_Bride_of_Pinbot` |
| Time Machine | Data East VR Room 1.0 Flipperspiel | `tmac_a24` | `VPX_Time_Machine` |

Steam displays these entries with its `Devkit Game: ` prefix. The seven new entries have
72 Hz and 2160x2160 per-eye targets. The existing 4 Queens entry retains its saved 120 Hz
and 2160x2160 targets; a refresh-rate setting alone does not establish achieved frame rate.

The supplied ROM ZIPs are unchanged in `~/Documents/VPXFrame/PinMAME/roms/`. Each new table
folder has a `pinmame` symlink to that shared root, so PinMAME can find the ROMs and keep its
writable data outside the application bundle. Black Hole, Bride of Pinbot and Middle Earth
also have their supplied backglasses, with `AddBackglass=1` in their table-local VR settings.
Middle Earth's backglass uses the table's full filename stem for automatic lookup. I checked
its XML and embedded image data, verified its installed SHA-256 hash, and preserved every
existing table setting while enabling the backglass.

Black Hole's embedded script defaults to `RomSet = 5` (`blkhole7`). I installed a table-local
`.vbs` override that changes only the supported selector to `RomSet = 1`, matching the
supplied `blckhole.zip`. The VPX file is unchanged. The earlier BigusMOD 2.0 table remains in
its separate folder; it defaults to `blkhole2` and is not the target of the new Steam entry.

I checked the original 16 transferred files against their source SHA-256 hashes. All seven
ROM sets now pass the installed native PinMAME library's audit. Middle Earth uses the
complete archive supplied at `/Users/mads/Downloads/midearth.zip`, including the previously
missing `20252-01.bin` (512 bytes, CRC32 `3d44551d`). I installed the archive unchanged, with
SHA-256 `fa3d377e3e5879cad9b0a0048911067807836c6f2407e47fdbb0f6149d5fa76f`.

The Middle Earth audit uses `PinmameGetGameRoms` and `PinmameAuditGameRom` with strict filename
and checksum verification inside Steam Linux Runtime 4. All three required files report
state `OK`. The receipt and `rom-audit.json` are in
`~/Documents/VPXFrame/imports/20261104T072853Z-middle-earth-rom-fix/`. A normal Steam startup
check timed out while computing environment map radiance, before scripts and ROM loading.
I stopped that test process and restored its saved preferences; the log extract is in
`startup-summary.txt` beside the receipt. The backglass installation receipt and prior table
settings are in `~/Documents/VPXFrame/imports/20261104T072501Z-middle-earth-backglass/`.

The import record is in `~/Documents/VPXFrame/imports/20261104-20261104T061009Z/` on the
Frame. `install-receipt.json` records source hashes, table paths, Steam AppIDs and verified
display settings; `rom-audit.json` records the native ROM audit. The same folder retains the
pre-install configuration backup. Launcher syntax, entry paths, ROM links and saved display
settings passed the installation checks.

## Table Compatibility Checks

For each exact table version, check script startup, playfield and backglass rendering, then
exercise the table's controls and gameplay. Check triggers, squeeze values, right ABXY,
Menu, View short press and 1-second hold, vector2 plunger/nudge input, focus loss and return
from standby. Use the performance logging described above to measure each table at its
chosen display settings.
