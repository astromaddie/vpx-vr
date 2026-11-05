# VPX Hand Controls

This visionOS preview is for trying hand controls on a room-locked cabinet. It reports gesture events against a standalone model. Live tables and PinMAME require the native VPX player.

Open `CabinetHands.xcodeproj`, select the **CabinetHands** scheme, and run on a visionOS destination. Choose **Open Cabinet**. The preview asks for hand tracking on a supported device. Look toward the space in front of you and hold steady for placement. The cabinet appears 25 cm below that tracked eye level with its front edge level. Close and reopen it to place it again.

- Put a hand by each red side button. Turn or move a hand inward to flip. Hold that pose to keep the flipper up, and relax the hand to release it.
- Poke the gold coin box with your index finger. It flashes and **Coins** increases once. Pull back before poking it again.
- Push the green Start button with your index finger. It flashes and **Start Presses** increases once. Pull back before pressing it again.

The cabinet keeps the real hands visible in mixed immersion. The simulator can show the layout. Live hand tracking, reach and timing need a headset check.

The gesture recognizer takes tracked joints in metres relative to the cabinet. The ARKit adapter turns world-space samples into those local coordinates. The native player measures the bend against the forearm when those joints are tracked and follows the hand direction when they are unavailable. The flipper presses at an 8-degree bend and releases at 3 degrees. The player sends its held flippers and button presses through VPX's input manager. On Time Machine, loosely close your hand near the plunger knob, pull it toward you, then open your hand. Your other hand can move without interrupting the pull. Palm travel sets the strength, with a full pull at about 6 cm. Incomplete finger tracking holds the saved pull while the palm is visible. Losing the whole hand for more than 120 ms or leaving play cancels the grip.

To check the recognizer on the Mac from this directory:

```sh
check_dir=$(mktemp -d)
trap 'rm -rf "$check_dir"' EXIT
xcrun swiftc CabinetHands/CabinetHandControls.swift CabinetHands/CabinetPlacement.swift Checks/HandControlChecks.swift -o "$check_dir/check"
"$check_dir/check"
```

The checks cover independent flippers, wrist turns with the palm held still, jitter around a held position, release on tracking loss, re-arming, one action per coin or Start poke, and placement after head tracking settles. The app logs the vertical offset from the tracked head, heading error and the rise along the rendered front edge.

## Cabinet fit

The supplied Data East Time Machine example (VPX file version 1060) has a 1,000 × 1,910 VP-unit playfield, separate room surfaces, and authored cabinet, backbox, backglass and coin-door primitives. Its `PinCab_Buttons` primitive groups buttons in one mesh, so its origin can't locate each button. The preview takes its dimensions from that playfield and draws a generic cabinet with separate controls.

The native player resolves front-panel input in the same transform as the cabinet geometry. Time Machine, Gorgar and Meteor use their authored Start controls. Time Machine and Meteor use the original coin slots. Gorgar keeps its cabinet and gets a stock coin door fitted to its front panel. The other four tables use the cabinet controls from VPX's `blankTable.vpz`, scaled with the stock cabinet. VPX already distinguishes cabinet, playfield and room transforms. The native player uses those references to omit room geometry in passthrough. It keeps the supplied Time Machine, Gorgar, and Meteor cabinets and separates their legacy room parts. Tables without a cabinet use the stock VPX cabinet, backbox, and legs fitted to the width and length of the playfield. A virtual room stays in place when the cabinet moves.

## Native VPX bring-up

The native player builds VPX and its plugins for ARM64 visionOS. Its Compositor Services thread requests eye poses and presents the most recent picture VPX has queued. VPX alternates between two stereo color and depth buffers. Both threads use the same Metal queue, so a buffer can be reused as soon as its compositor copy is queued. Table loading and Metal shader compilation happen on the engine's threads, outside compositor submissions. The standalone hand-control preview remains a separate Xcode scheme.

Build the dependencies with CMake, Ninja, and Bison 3.8.2 or newer on the path, using the full Xcode SDK.

```sh
BUILD_TYPE=Release CMAKE_GENERATOR=Ninja platforms/visionos-arm64/external.sh
cmake -S . -B build-visionos -G Ninja -DPLATFORM=visionos -DARCH=arm64 -DCMAKE_BUILD_TYPE=Release
cmake --build build-visionos --target vpinball --parallel 2
```

Open `CabinetHands.xcodeproj`, select the **VPXVision** scheme and the Vision Pro, and set `VPX_NATIVE_BUILD_DIR` to the absolute path of the CMake build directory. Choose **Import Folder…** and select a folder containing VPX tables, ZIP ROMs, and any directB2S backglasses. The importer copies the folder’s tables into the app’s Documents library, puts ROMs in `pinmame/roms` alongside them, and pairs backglasses by filename. You can also copy tables and their companion directories directly into VPX Vision in Files. Existing `Documents/Time Machine/` installs appear in the library.

Choose **Your Room** or **Virtual Room**, select a table, then choose **Play Table** and look ahead. Your Room uses the real dimensions of the authored cabinet and seats its four legs on the detected floor. When a floor plane is unavailable it uses the immersive origin at floor level. Poke a coin slot or Start on the front of the cabinet. Bend your left wrist to the right or your right wrist to the left to flip. Keep the bend to hold the flipper up, then relax your wrist to release it. The gesture works away from the side buttons. Close both fists firmly, hold them still briefly, then move them together about 3 cm to nudge. Left and right use VPX’s side nudges, up nudges forward, and down nudges backward. Return your fists to the starting position between nudges. To open the table picker during play, hold your non-dominant wrist up like a watch and turn your head toward it. Choose **Edit Placement**, then raise both hands above the lockbar and hold them apart until the panel says **Moving Cabinet**. Move or turn both hands to position the cabinet. Lower either hand to stop. **Done** locks the new position for this table session and **Cancel** restores the position from before the edit. **Resume** returns to the current table. **Play Table** closes the current game and places the selected one in the chosen environment.

The gear menu sets the dominant hand and eye resolution. **High** renders at 1792 × 1792 per eye. **Standard** uses 1536 × 1536. Changes apply the next time you open a table.

The Vision Pro path uses VPX's shared stereo culling, texture budget, and spatial audio code. Set `VPX_VR_PERF=5` in the launch environment to log the same timing breakdown as the Frame. Packed HDR can be compared with `VPX_PACKED_HDR=0|1`.


### Run Time Machine in Simulator

Build the pinned Simulator dependencies and the same VPX framework against the Simulator SDK.

```sh
BUILD_TYPE=Release CMAKE_GENERATOR=Ninja VPX_VISIONOS_SDK=xrsimulator platforms/visionos-arm64/external.sh
cmake -S . -B build-visionos-sim -G Ninja -DPLATFORM=visionos -DARCH=arm64 \
  -DCMAKE_OSX_SYSROOT=xrsimulator -DCMAKE_BUILD_TYPE=Release
cmake --build build-visionos-sim --target vpinball --parallel 2
```

Build **VPXVision** for a visionOS Simulator destination with `VPX_NATIVE_BUILD_DIR` pointing to that build directory. Install the app in a test simulator. Import the folder using the picker or pass `--import-tables /absolute/path/to/pinball` on launch to exercise the same importer. Then launch with `--check-library` to run the rendered table, ROM and input checks across the imported library in a single process. For the Time Machine compositor stall and placement check, run:

```sh
xcrun simctl launch booted org.vpinball.vpxvision.player \
  --play-time-machine --check-render-stall --check-controls --check-room-placement
```

The Simulator test uses a fixed cabinet placement and can run with a single compositor view. The stall check holds VPX's first render for three seconds. The compositor should keep submitting frames during the pause, then report a completed table frame and continue showing newly rendered VPX frames. The control check waits for ROM startup, then feeds fingertip pokes and wrist bends away from the cabinet into the hand recognizer and reads the resulting input in VPX. Add `--check-nudges` to exercise all four two-fist directions. The native cabinet model should receive one impulse per 32 mm movement after the fists settle and none at 26 mm. It checks that poking the blank area under the coin slots does nothing. For a mechanical plunger, it checks that half and full fist pulls keep their strength through incomplete finger tracking and release when the hand opens. Run Time Machine with `--check-ball-launch` to follow the actual ball past the shooter-lane gate after a full pull. Run again with `--check-half-launch` to measure the half pull on a fresh ball. Check the VPX log for `tmac_a24`, `Startup done`, and the control check, and inspect a Simulator screenshot for the actual table. The room check sends paired synthetic hand samples through the placement adapter. Look for `Simulator verified edit-only translation, yaw, cancel and lock at fixed height`. Pass `--check-standard-resolution` to compare the same run with the smaller eye textures. Pass `--check-virtual-room` in place of `--check-room-placement` to check the original environment.

On visionOS Simulator 26.5, both modes loaded the supplied Time Machine table and the `tmac_a24` ROM and reached Ball 01. During the mixed-reality stall, the compositor submitted 180 frames in three seconds and recovered. The final sample showed 960 compositor frames and 954 VPX submissions. The room capture showed the cabinet and playfield against the Simulator room before and after a 20-degree turn. The test injected hand samples and used a fixed Simulator floor. The engine measured a 1.088 m cabinet origin and corrected the original 36 mm front-to-back difference in foot height.

In the Build 8 Simulator run, Standard and High each submitted 600 new VPX frames in about ten seconds between compositor frames 120 and 720. The Simulator used one 3840 × 2160 compositor view. Time Machine's native half pull moved the ball 269 VP units along the shooter lane. The placement check moved and turned the cabinet 20 degrees at fixed height, restored it with Cancel, and retained the new pose with Done.

In Build 9 the Time Machine flipper caps measured 153 mm below the cabinet origin and 33 mm behind it. The old wrist targets were 65 mm below and 55 mm behind. I replayed a grip opening that reduced Build 8’s full pull to zero before a fingertip dropped out. Build 9 held the pull through the same opening. In Simulator the 30 mm pull moved the ball 514 VP units. The 60 mm pull moved it 1,730 VP units past the gate, with about twice the peak up-lane speed. Both runs started with a ball at Y ≈ 1782 VPU.

The Build 9 Time Machine log on the M2 recorded four plunger cancellations at 99.8–100% pull. The visionOS bridge returned the rod to rest with zero launch strength on cancellation. I replayed both a lost hand and a lost thumb with the pinch still closed against the Build 9 recognizer and reproduced the cancellation. The Build 10 control check uses those inputs with the play watchdog. In the full-pull Simulator run the entire hand disappeared with the last grip still closed. The bridge logged a 100% release after the grace period, and the ball travelled 1,731 VP units past the gate.

In Build 11 I replayed independent inward wrist bends with the palms 0.65 m to each side of the cabinet center. Both flippers registered in VPX. The two-fist check sent one cabinet impulse in each of the four directions. The same Time Machine run dropped the plunger hand at full pull and the ball travelled 1,728 VP units past the gate.

For Build 12 I launched the supplied Time Machine VPX and `tmac_a24` with `--play-time-machine --check-controls --check-standard-resolution --check-ball-launch --check-nudges`. I ran it again with `--check-half-launch` in place of the last two flags. A 30 mm fist pull moved the ball 513 VP units. A 60 mm pull moved it 1,729 units past the gate. Both released when the synthetic hand opened after an incomplete finger sample. The cabinet model registered one impulse per direction at 27 mm and stayed quiet at 22 mm.

For Build 13 I used ARKit’s estimated finger and palm positions for fist gestures when the hand anchor is still tracked. Button pokes still need a tracked fingertip. I added a Mac replay that feeds occluded joint samples through the same fist classifier and checks a pull and open-hand release, a two-fist nudge, and a Start poke with the other fingers curled.

For Build 14 I widened the plunger grab from 9 to 13 cm around the knob and let a loose fist keep the grip even when the other hand closes. The nudge check now holds two firm fists still for 140 ms before measuring a 30 mm shared move. The Mac replay checks that moving into position, one loose fist, and uneven movement stay quiet. It also checks a full shot from 11 cm beside the knob and 16 cm in front of it.

### Seven-table library check

I imported Attack from Mars, Black Hole, Gorgar, Meteor, Middle Earth, The Machine: Bride of Pinbot, and Time Machine in visionOS Simulator 26.5. The library check rendered each table in one app session and checked that PinMAME was running. It checked coin, Start, both flippers, and a half plunger pull in VPX's input manager. The backglass files for Black Hole, Middle Earth, and Bride of Pinbot were imported next to their tables. The stock cabinet covered playfield widths from 0.514 m to 0.685 m. Build 8 completed the same seven-table sequence with the new cabinet button faces and wrist input path.

Black Hole's table script defaults to the seven-digit conversion. The player uses the original ROM when the conversion is absent and `blckhole.zip` is beside the imported table in `pinmame/roms`. Middle Earth needs `20252-01.bin` in `midearth.zip` (CRC-32 `3D44551D`). The library check used the complete archive. The test also reopened Attack from Mars with its existing texture cache to exercise texture uploads before an immersive eye frame.

### Build the pinned libraries

Use the versions in `platforms/config.sh`. Unpack the `bgfx.cmake` release and replace its `bgfx` directory with the pinned VPX fork, as in the iOS dependency script. From the VPX checkout, set `bgfx_cmake` to the path of that unpacked directory.

```sh
patch -p1 -d "$bgfx_cmake" < platforms/visionos-arm64/bgfx-cmake-visionos.patch
patch -p1 -d "$bgfx_cmake/bgfx" < platforms/visionos-arm64/bgfx-metal-command-queue.patch
patch -p1 -d "$bgfx_cmake/bgfx" < platforms/visionos-arm64/bgfx-metal-layer-topology.patch
cmake -S "$bgfx_cmake" -B "$bgfx_cmake/build-xros" -G Ninja \
  -DCMAKE_SYSTEM_NAME=visionOS -DCMAKE_OSX_SYSROOT=xros \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=2.0 -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_BUILD_TYPE=Debug -DBGFX_BUILD_EXAMPLES=OFF -DBGFX_BUILD_TOOLS=OFF \
  -DBGFX_CONFIG_MULTITHREADED=ON -DBGFX_CONFIG_MAX_FRAME_BUFFERS=256
cmake --build "$bgfx_cmake/build-xros" --target bgfx --parallel 2
```

Use the same SDK, deployment and architecture flags for the other dependencies. For PinMAME, apply `platforms/visionos-arm64/pinmame-time-fence.patch` to the unpacked source to synchronize semaphore creation, signaling and teardown, then copy `cmake/libpinmame/CMakeLists.txt` to the unpacked source root. Configure it and libwinevbs with `-DPLATFORM=visionos -DARCH=arm64 -DBUILD_SHARED=OFF -DBUILD_STATIC=ON`. Libwinevbs needs Bison 3.8.2 or newer. For SDL, configure with `-DSDL_SHARED=OFF -DSDL_STATIC=ON -DSDL_TEST_LIBRARY=OFF -DSDL_TESTS=OFF -DSDL_OPENGLES=OFF -DSDL_CAMERA=OFF` and build `SDL3-static`. The libraries stay in their scratch build directories.

### Verify the Metal handoff

Configure the same patched BGFX source for the Mac, with the BGFX flags above and without the visionOS system name, SDK or deployment target. Set `bgfx_host` to that Mac build directory and run this from the VPX checkout.

```sh
xcrun clang++ -std=c++20 -fobjc-arc -I"$bgfx_cmake/bgfx/include" \
  apps/visionos/Checks/MetalTextureHandoff.mm \
  "$bgfx_host/cmake/bgfx/libbgfx.a" "$bgfx_host/cmake/bimg/libbimg.a" \
  "$bgfx_host/cmake/bx/libbx.a" \
  -framework Metal -framework Foundation -framework Cocoa -framework QuartzCore \
  -framework CoreGraphics -framework IOKit -framework CoreFoundation -framework OpenGL \
  -framework VideoToolbox -framework CoreMedia -framework CoreVideo \
  -o "$bgfx_host/metal-handoff"
"$bgfx_host/metal-handoff"
```

The check renders two frames into two app-owned Metal textures and checks all four expected colors. BGFX commits on the app's queue, and the next GPU command buffer sees the matching frame. The test reads the result once at the end. The intended player path keeps this on the GPU and hands color and depth to Compositor Services after VPX submits the frame. The cabinet's gesture edges go through VPX's existing `InputManager` as left and right flipper, Add Credit and Start.
