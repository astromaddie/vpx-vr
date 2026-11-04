# VPX Hand Controls

This visionOS preview is for trying hand controls on a room-locked cabinet. It reports gesture events against a standalone model. Live tables and PinMAME require the native VPX player.

Open `CabinetHands.xcodeproj`, select the **CabinetHands** scheme, and run on a visionOS destination. Choose **Open Cabinet**. The preview asks for hand tracking on a supported device. Look toward the space in front of you and hold steady for placement. The cabinet appears 25 cm below that tracked eye level with its front edge level. Close and reopen it to place it again.

- Put a hand by each red side button. Turn or move a hand inward to flip. Hold that pose to keep the flipper up, and relax the hand to release it.
- Poke the gold coin box with your index finger. It flashes and **Coins** increases once. Pull back before poking it again.
- Push the green Start button with your index finger. It flashes and **Start Presses** increases once. Pull back before pressing it again.

The cabinet keeps the real hands visible in mixed immersion. The simulator can show the layout. Live hand tracking, reach and timing need a headset check.

The gesture recognizer takes tracked joints in metres relative to the cabinet. The ARKit adapter turns world-space samples into those local coordinates. Both apps use the same Build 4 recognizer and cabinet placement. The native player sends its held flippers and button presses through VPX's input manager. Grab the plunger to the right of the coin door with your thumb and index finger. Pull it toward you, then open your fingers. A longer pull gives the ball more speed.

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

The player can keep a table's authored cabinet and resolve control locations from an explicit table profile when the mesh doesn't identify them. For tables without a cabinet, use the playfield bounds converted to metres to fit the generic cabinet and place its controls. VPX's own `blankTable.vpz` has separate cabinet, rails, legs, backbox, Start and flipper button parts. That is a reference for a reusable cabinet whose geometry doesn't depend on a user's table artwork. VPX already distinguishes the cabinet, playfield and room transforms, which would also let the player show the cabinet in passthrough without drawing a separate room where the table identifies that room.

## Native VPX bring-up

The native player builds VPX and its plugins for ARM64 visionOS. Its Compositor Services thread requests eye poses and presents the most recent picture VPX has queued. VPX alternates between two stereo color and depth buffers. Both threads use the same Metal queue, so a buffer can be reused as soon as its compositor copy is queued. Table loading and Metal shader compilation happen on the engine's threads, outside compositor submissions. The standalone hand-control preview remains a separate Xcode scheme.

Build the dependencies with CMake, Ninja, and Bison 3.8.2 or newer on the path, using the full Xcode SDK.

```sh
BUILD_TYPE=Release CMAKE_GENERATOR=Ninja platforms/visionos-arm64/external.sh
cmake -S . -B build-visionos -G Ninja -DPLATFORM=visionos -DARCH=arm64 -DCMAKE_BUILD_TYPE=Release
cmake --build build-visionos --target vpinball --parallel 2
```

Open `CabinetHands.xcodeproj`, select the **VPXVision** scheme and the Vision Pro, and set `VPX_NATIVE_BUILD_DIR` to the absolute path of the CMake build directory. Import the VR Room Time Machine table into the app's `Documents/Time Machine/` folder and put its `tmac_a24.zip` in `Documents/Time Machine/pinmame/roms/`. Choose **Play Time Machine** and hold your head steady to place the cabinet.

The Vision Pro path uses VPX's shared stereo culling, texture budget, and spatial audio code. Set `VPX_VR_PERF=5` in the launch environment to log the same timing breakdown as the Frame. Packed HDR can be compared with `VPX_PACKED_HDR=0|1`.


### Run Time Machine in Simulator

Build the pinned Simulator dependencies and the same VPX framework against the Simulator SDK.

```sh
BUILD_TYPE=Release CMAKE_GENERATOR=Ninja VPX_VISIONOS_SDK=xrsimulator platforms/visionos-arm64/external.sh
cmake -S . -B build-visionos-sim -G Ninja -DPLATFORM=visionos -DARCH=arm64 \
  -DCMAKE_OSX_SYSROOT=xrsimulator -DCMAKE_BUILD_TYPE=Release
cmake --build build-visionos-sim --target vpinball --parallel 2
```

Build **VPXVision** for a visionOS Simulator destination with `VPX_NATIVE_BUILD_DIR` pointing to that build directory. Install the app in a test simulator and put the same table and ROM in its Documents folder as above. With the test simulator booted, run:

```sh
xcrun simctl launch booted org.vpinball.vpxvision.player \
  --play-time-machine --check-render-stall --check-controls
```

The Simulator test uses a fixed cabinet placement and can run with a single compositor view. The stall check holds VPX's first render for three seconds. The compositor should keep submitting frames during the pause, then report a completed table frame and continue showing newly rendered VPX frames. The control check waits for ROM startup, then checks coin, Start, and both flippers in the input manager and checks the half-pull and rest positions in the native plunger handler. Check the VPX log for `tmac_a24`, `Startup done`, and the control check, and inspect a Simulator screenshot for the actual table.

On visionOS Simulator 26.5, the compositor submitted 180 frames during the three-second stall and recovered to a rendered table. A normal launch with fresh Time Machine NVRAM completed 720 compositor frames and queued 719 VPX frames by the final sample. The input check passed, and the backglass showed Ball 01 after the ROM accepted credit and Start.

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

Use the same SDK, deployment and architecture flags for the other dependencies. For PinMAME, copy `cmake/libpinmame/CMakeLists.txt` to the unpacked source root, then configure it and libwinevbs with `-DPLATFORM=visionos -DARCH=arm64 -DBUILD_SHARED=OFF -DBUILD_STATIC=ON`. Libwinevbs needs Bison 3.8.2 or newer. For SDL, configure with `-DSDL_SHARED=OFF -DSDL_STATIC=ON -DSDL_TEST_LIBRARY=OFF -DSDL_TESTS=OFF -DSDL_OPENGLES=OFF -DSDL_CAMERA=OFF` and build `SDL3-static`. The libraries stay in their scratch build directories.

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
