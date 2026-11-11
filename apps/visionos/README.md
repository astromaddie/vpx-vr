# VPX Hand Controls

This visionOS preview is for trying hand controls on a room-locked cabinet. It reports gesture events against a standalone model. Live tables and PinMAME require the native VPX player.

Open `CabinetHands.xcodeproj`, select the **CabinetHands** scheme, and run on a visionOS destination. Choose **Open Cabinet**. The preview asks for hand tracking on a supported device. Look toward the space in front of you and hold steady for placement. The cabinet appears 25 cm below that tracked eye level with its front edge level. Close and reopen it to place it again.

- Put a hand by each red side button. Turn or move a hand inward to flip. Hold that pose to keep the flipper up, and relax the hand to release it.
- Poke the gold coin box with your index finger. It flashes and **Coins** increases once. Pull back before poking it again.
- Push the green Start button with your index finger. It flashes and **Start Presses** increases once. Pull back before pressing it again.

The cabinet keeps the real hands visible in mixed immersion. The simulator can show the layout. Live hand tracking, reach and timing need a headset check.

The gesture recognizer takes tracked joints in metres relative to the cabinet. The ARKit adapter turns world-space samples into those local coordinates. The native player uses estimated wrist and knuckle positions while ARKit tracks the hand. It measures the bend against the forearm when it has a usable arm direction and follows the hand direction otherwise. The flipper presses after an 8-degree inward bend at 140 degrees per second or faster. While the wrist is moving fast, or for 150 ms after it shoved the cabinet, it needs 14 degrees, so the hand lagging or overrunning the arm doesn't flip. It stays up while you hold the bend. The hold follows the median of the last three samples, so one noisy sample can't drop it. It releases once that median relaxes 5 degrees from its peak, or when one sample relaxes 10 degrees. A held flipper rides out up to 250 ms of lost tracking. The recognizers run on the hand-tracking thread, not on the main thread with VPX's game loop, and read ARKit's predicted hand pose for the moment they run. The main loop sends their inputs to VPX before each tick. The player sends its held flippers and button presses through VPX's input manager. On Time Machine, tuck your thumb across your palm or pinch near the plunger knob, then pull toward you. Untuck or turn the hand sideways to release a tuck. Open the pinch to release a pinch. Palm travel sets the strength, with a full pull at about 6 cm. Losing the whole hand for more than 120 ms or leaving play cancels the grip.

To check the recognizer on the Mac from this directory:

```sh
check_dir=$(mktemp -d)
trap 'rm -rf "$check_dir"' EXIT
xcrun swiftc CabinetHands/CabinetHandControls.swift CabinetHands/CabinetPlacement.swift \
  CabinetHands/CabinetHandRecording.swift Checks/HandControlChecks.swift -o "$check_dir/check"
"$check_dir/check"
```

The checks cover independent flippers, wrist turns with the palm held still, jitter around a held position, release on tracking loss, re-arming, one action per coin or Start poke, and placement after head tracking settles. The shove checks feed minimum-jerk wrist paths at 90 Hz: ordinary reaches and lifts that must not shove, a firm two-hand shove with a flip halfway through, the way back, light to hard one-hand slaps that must grow in strength, letting go, and an arm moving with the hand lagging and overrunning it that must not flip. The hold check keeps a flipper up for five seconds through jitter, single dips, the forearm dropping out and a 200 ms gap. The app logs the vertical offset from the tracked head, heading error and the rise along the rendered front edge.

## Cabinet fit

The supplied Data East Time Machine example (VPX file version 1060) has a 1,000 × 1,910 VP-unit playfield, separate room surfaces, and authored cabinet, backbox, backglass and coin-door primitives. Its `PinCab_Buttons` primitive groups buttons in one mesh, so its origin can't locate each button. The preview takes its dimensions from that playfield and draws a generic cabinet with separate controls.

The native player resolves front-panel input in the same transform as the cabinet geometry. Time Machine, Gorgar and Meteor use their authored Start controls. Time Machine and Meteor use the original coin slots. Gorgar keeps its cabinet and gets a stock coin door fitted to its front panel. Tables without a cabinet of their own get the neutral cabinet described below, with its controls fitted together with its meshes. VPX already distinguishes cabinet, playfield and room transforms. The native player uses those references to omit room geometry in passthrough. It keeps the supplied Time Machine, Gorgar, and Meteor cabinets and separates their legacy room parts. A virtual room stays in place when the cabinet moves.

### Neutral cabinet

Tables without their own cabinet get the plain black cabinet from [vpx-cabinet](https://github.com/astromaddie/vpx-cabinet), fitted at load time with the same rules as its `add-cabinet` tool. The meshes, fit spec, textures and measured control positions are in `src/assets/neutralCabinet`, with their credits in `CREDITS.md` beside them. `tools/visionos/neutral_cabinet.py pack --cabinet-repo <checkout>` rebuilds that folder from a vpx-cabinet checkout and checks each GLB against its source mesh.

- Width and length follow the playfield 9-slice style. Panels, rails and the lockbar stretch, while the coin door, buttons, plunger, launch button and legs keep their real size and only move. The side rails, lockbar and glass line run parallel to the playfield and the cabinet bottom stays level on four legs of equal length.
- A table with a visible manual plunger gets the plunger knob. A table with no plunger, or only an automatic or hidden one, gets a red launch button. Poking the button pulses Launch Ball.
- The glass at the lockbar is set 8 cm above the main playfield, or higher where a ramp or raised playfield needs room for the ball. Black Hole measures from its upper playfield. The player writes that height into the loaded table's glass fields, so the playfield depth, the fitted cabinet and the ball's glass ceiling all agree. Tables saved before VPX 10.8 have one flat glass, which gets the new height. Newer tables get it at the front and keep a higher rear glass.
- The cabinet is fitted to the playfield slope the table is played at, and it only tilts if that slope changes later.
- The lockbar's inner edge reaches 12 VP units over the playfield's front edge, so the playfield runs under it like on a real cabinet. A wall under the lockbar closes the front.
- The plunger knob follows the table's plunger rod every frame. It comes out as you pull and springs back with the rod when you let go. The flipper buttons, Start, the coin inserts and the launch button push in 4 to 5 mm while VPX sees them pressed. The coin inserts use the lit yellow reject windows from Meteor's VR coin door art and are drawn unlit, so they glow.
- A directB2S backglass fills the smoked translite. The speaker panel under it has a 37.5 × 10 cm window with a 35 × 8.8 cm DMD in it, about the size of a real 128 × 32 display. The dots are a neon orange-red. When the directB2S has a score view with score digits, as on alphanumeric machines like Bride of Pinbot, that goes in the window instead. On segment and EM tables without one the window stays dark, since PinMAME has no DMD for them, and their scores show on the backglass.
- The body and backbox have dark inner sides, so they don't disappear when you look in over the side rail or lean through a wall.
- If the pack is missing a file or the fit rejects the table (playfields narrower than about 890 VP units, or far from the usual lengths), the player logs `Vision Pro neutral cabinet not used, falling back to the stock cabinet:` with the reason and uses the stock cabinet from `blankTable.vpz` as before.

The cabinet adds 26,306 triangles with the plunger and 20,748 with the launch button, against 31,320 for the stock cabinet. Its three JPEG textures are 1024², 512² and 1024 × 818, about 8 MiB as RGBA at base level.

To compare the player's fit with the tool's own Python results from the VPX checkout:

```sh
check_dir=$(mktemp -d)
trap 'rm -rf "$check_dir"' EXIT
xcrun clang++ -std=c++20 -O1 -Ithird-party/include -Isrc/renderer \
  apps/visionos/Checks/CabinetFitChecks.cpp src/renderer/VisionCabinetFit.cpp -o "$check_dir/fit-check"
"$check_dir/fit-check" .
```

It fits the bundled GLB meshes to 24 tables, from narrow and short to wide and long, with several slopes, glass heights, offsets and the four supplied fallback tables. It compares every map, the fitted bounds of each part, the rigid hardware offsets, the inner walls, the variant choice and the glass rule against `apps/visionos/Checks/CabinetFitGolden.json`. Regenerate that file with `tools/visionos/neutral_cabinet.py golden --cabinet-repo <checkout>` when the cabinet assets change.

## Native VPX bring-up

The native player builds VPX and its plugins for ARM64 visionOS. Its Compositor Services thread requests eye poses and presents the most recent picture VPX has queued. VPX alternates between two stereo color and depth buffers. Both threads use the same Metal queue, so a buffer can be reused as soon as its compositor copy is queued. Table loading and Metal shader compilation happen on the engine's threads, outside compositor submissions. The standalone hand-control preview remains a separate Xcode scheme.

Build the dependencies with CMake, Ninja, and Bison 3.8.2 or newer on the path, using the full Xcode SDK.

```sh
BUILD_TYPE=Release CMAKE_GENERATOR=Ninja platforms/visionos-arm64/external.sh
cmake -S . -B build-visionos -G Ninja -DPLATFORM=visionos -DARCH=arm64 -DCMAKE_BUILD_TYPE=Release
cmake --build build-visionos --target vpinball --parallel 2
```

Open `CabinetHands.xcodeproj`, select the **VPXVision** scheme and the Vision Pro, and set `VPX_NATIVE_BUILD_DIR` to the absolute path of the CMake build directory. Choose **Import Folder…** and select a folder containing VPX tables, ZIP ROMs, and any directB2S backglasses. The importer copies the folder’s tables into the app’s Documents library, puts ROMs in `pinmame/roms` alongside them, and pairs backglasses by filename. You can also copy tables and their companion directories directly into VPX Vision in Files. Existing `Documents/Time Machine/` installs appear in the library.

Choose **Your Room** or **Virtual Room**, select a table, then choose **Play Table** and look ahead. Your Room uses the real dimensions of the authored cabinet and seats its four legs on the detected floor. When a floor plane is unavailable it uses the immersive origin at floor level. Poke a coin slot or Start on the front of the cabinet. On a cabinet with a red launch button instead of a plunger knob, poke the button to launch the ball. Flick your left wrist to the right or your right wrist to the left to flip. Keep the bend to hold the flipper up, then relax your wrist to release it. The gesture works away from the side buttons. To nudge, rest your hands on or beside the cabinet sides and shove, like on a real machine. Open hands or fists both work, and you can flip in the middle of a shove. Both hands together shove in any direction across the floor, and a hand alone can slap its side inward or push forward. The shove's strength and direction follow your wrists, so a firm shove gives about VPX's strong keyboard nudge and a light bump a small one. VPX's cabinet model moves the cabinet a few millimetres and springs it back, the ball feels it, and VPX's plumb decides when you tilt, as on a real cabinet. The way back after a shove doesn't count. To open the table picker during play, hold your non-dominant wrist up like a watch and turn your head toward it. Choose **Edit Placement**, then raise both hands above the lockbar and hold them apart until the panel says **Moving Cabinet**. Move or turn both hands to position the cabinet. Lower either hand to stop. **Done** locks the new position for this table session and **Cancel** restores the position from before the edit. **Resume** returns to the current table. **Play Table** closes the current game and places the selected one in the chosen environment.

The gear menu sets the dominant hand and eye resolution. The eye pictures have the same 1.25 shape as the headset's views (6261 × 5023 logical pixels on the M2), so the pixels go where the view is wider. **Highest** renders at 3152 × 2520 per eye, the pixel count of the old 2816 square, and is the default, since the M2 holds 90 Hz on Attack from Mars at that size. **Standard** uses 1720 × 1376, **High** 2000 × 1600, **Very High** 2584 × 2064 and **Maximum** 3432 × 2744, about a 3072 square's worth, to try with the timing line. A level you picked before stays picked. Changes apply the next time you open a table. The log's `View aspect` line gives the view's shape next to the eye targets.

VPX renders a picture for each eye and the player copies it into the compositor's drawable. When the headset supports foveation, the player turns it on and asks for full render quality. The drawable then comes with a rasterization rate map that puts more pixels in the middle of the view, so the larger eye sizes show up as real detail there. The copy draws both eyes in one layered pass through that map and keeps its UVs in the logical view. Where one drawable pixel covers more than one VPX texel, it averages four taps so the periphery doesn't shimmer. Without foveation the copy goes into the uniform drawable as before. Launch with `-Foveation NO` to force that path, or with `-RenderQuality 0.5` to try a smaller drawable. The log says which path ran: `Compositor path: foveated` with the logical and physical rate map sizes, or `Compositor path: uniform`.

Every five seconds the player logs a line starting with `Timing over 5.0 s:`. It has the presented frame rate, frames the compositor missed, copies that finished after the rendering deadline, how many new VPX frames arrived per second, the copy pass's GPU time, the copy's whole command buffer, and VPX's own GPU time from BGFX's frame stats (average and worst for both). The player also writes these lines, with the layer, eye size and compositor path lines, into VPX's own `vpinball.log` once the table's first frame is on screen. VPX starts that file fresh for each table, so after an unattended session you can pull it from the app container and read the last table's timing. To read the lines live from the headset over Wi-Fi, launch the app with `xcrun devicectl device process launch --console --environment-variables '{"OS_ACTIVITY_DT_MODE": "enable"}' --device <name> org.vpinball.vpxvision.player`, which copies the app's log to the terminal.

The copy pass time comes from GPU timestamps at the start of its vertex stage and the end of its fragment stage. On the M2 that span still overlaps VPX's own GPU work, so it reads 5 to 8 ms while the copy alone costs about 1 ms. The command buffer time also counts waiting behind VPX's frame on the shared queue. To time the copy alone on a Mac at the M2's view and rate map sizes, from this directory:

```sh
check_dir=$(mktemp -d)
trap 'rm -rf "$check_dir"' EXIT
xcrun swiftc -O -parse-as-library NativePlayer/CompositorShaders.swift Checks/CopyCostBench.swift -o "$check_dir/bench"
"$check_dir/bench"
```

On an M4 Mac with 2916 × 2657 physical pixels per eye, the pass took 0.88 ms with the four-tap periphery and 0.64 ms with one tap, and the eye size barely changed it.

To check the foveated copy on the Mac from this directory:

```sh
check_dir=$(mktemp -d)
trap 'rm -rf "$check_dir"' EXIT
xcrun swiftc NativePlayer/CompositorShaders.swift Checks/FoveatedCopyCheck.swift -o "$check_dir/check"
"$check_dir/check" "$check_dir"
```

It draws a two-eye test picture with the player's layered copy into a two-layer rate map, maps the result back to the logical view and compares it with the uniform copy. Each layer has its own sharp area, so an eye drawn through the other eye's layer would land in the wrong place. Full-rate areas should match within 2 of 255, the smooth ramp should stay within 2 everywhere, and each eye should differ from the other by far more than that. On an M-series Mac the GPU leaves the last physical column unrendered when a layer's physical width isn't a multiple of the map's 32-pixel granularity, so the ramp test skips the outer 8 logical pixels. Pass a folder to save PNGs of each stage.

The Vision Pro path uses VPX's shared stereo culling, texture budget, and spatial audio code. Set `VPX_VR_PERF=5` in the launch environment to log the same timing breakdown as the Frame. Packed HDR can be compared with `VPX_PACKED_HDR=0|1`.


### Record Hands

Open a table and use the non-dominant wrist menu to choose **Record Hands**. Pick a take and choose **Record Take**. Use the two-second **Get Ready** cue to move your hands into position, then do what the take says until the **Recording** cue ends, after 5 to 8 seconds. The next take is picked after each save, and you can redo any take. The table ignores your gestures while the panel is open. **Done** returns to the menu and **Resume** returns to play.

Each take saves every hand sample the recognizers read: the time, which joints ARKit tracked, and the wrist, forearm, thumb tip and finger joints in cabinet space, to the tenth of a millimetre. It also keeps what the recognizers decided live, and the cabinet layout. The files are in **Files → On My Vision Pro → VPX Vision → Hand Recordings → Build 30**, one per take, about half a megabyte each. **Clear Recordings** deletes them. To replay a folder of takes through the current recognizers on the Mac, build the hand check above and run `"$check_dir/check" --replay <folder>`. It prints each flip, shove and dropped hold with its time. `Checks/CalibrationCheck.swift` records a take through the panel's model, reads it back and replays it:

```sh
check_dir=$(mktemp -d)
trap 'rm -rf "$check_dir"' EXIT
xcrun swiftc -parse-as-library CabinetHands/CabinetCalibration.swift CabinetHands/CabinetHandRecording.swift \
  CabinetHands/CabinetHandControls.swift Checks/CalibrationCheck.swift -o "$check_dir/check"
"$check_dir/check" "$check_dir"
```

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

The Simulator test uses a fixed cabinet placement and can run with a single compositor view. The stall check holds VPX's first render for three seconds. The compositor should keep submitting frames during the pause, then report a completed table frame and continue showing newly rendered VPX frames. The control check waits for ROM startup, then feeds fingertip pokes and wrist bends away from the cabinet into the hand recognizer and reads the resulting input in VPX. Add `--check-nudges` to feed shoves through the same path. A 10 cm reach must leave the cabinet alone. A firm two-hand shove to the right, with the right flipper flicked halfway, must move the cabinet and raise the flipper. A light and a firm one-hand slap must both shove, the firm one at least 1.8 times harder. The log gives each shove's peak acceleration, how far the cabinet moved, the plumb's swing and the ball's position. It checks that poking the blank area under the coin slots does nothing. For a mechanical plunger, it checks that half and full palm-down pulls keep their strength through the turn and release when the hand goes sideways. Run Time Machine with `--check-ball-launch` to follow the actual ball past the shooter-lane gate after a full pull. Run again with `--check-half-launch` to measure the half pull on a fresh ball. Check the VPX log for `tmac_a24`, `Startup done`, and the control check, and inspect a Simulator screenshot for the actual table. The room check sends paired synthetic hand samples through the placement adapter. Look for `Simulator verified edit-only translation, yaw, cancel and lock at fixed height`. Pass `--check-standard-resolution` to compare the same run with the smaller eye textures. Pass `--check-eye-size 2816`, or any other size from the menu, to pick that size instead. Pass `--check-virtual-room` in place of `--check-room-placement` to check the original environment.

On visionOS Simulator 26.5, both modes loaded the supplied Time Machine table and the `tmac_a24` ROM and reached Ball 01. During the mixed-reality stall, the compositor submitted 180 frames in three seconds and recovered. The final sample showed 960 compositor frames and 954 VPX submissions. The room capture showed the cabinet and playfield against the Simulator room before and after a 20-degree turn. The test injected hand samples and used a fixed Simulator floor. The engine measured a 1.088 m cabinet origin and corrected the original 36 mm front-to-back difference in foot height.

In the Build 8 Simulator run, Standard and High each submitted 600 new VPX frames in about ten seconds between compositor frames 120 and 720. The Simulator used one 3840 × 2160 compositor view. Time Machine's native half pull moved the ball 269 VP units along the shooter lane. The placement check moved and turned the cabinet 20 degrees at fixed height, restored it with Cancel, and retained the new pose with Done.

In Build 9 the Time Machine flipper caps measured 153 mm below the cabinet origin and 33 mm behind it. The old wrist targets were 65 mm below and 55 mm behind. I replayed a grip opening that reduced Build 8’s full pull to zero before a fingertip dropped out. Build 9 held the pull through the same opening. In Simulator the 30 mm pull moved the ball 514 VP units. The 60 mm pull moved it 1,730 VP units past the gate, with about twice the peak up-lane speed. Both runs started with a ball at Y ≈ 1782 VPU.

The Build 9 Time Machine log on the M2 recorded four plunger cancellations at 99.8–100% pull. The visionOS bridge returned the rod to rest with zero launch strength on cancellation. I replayed both a lost hand and a lost thumb with the pinch still closed against the Build 9 recognizer and reproduced the cancellation. The Build 10 control check uses those inputs with the play watchdog. In the full-pull Simulator run the entire hand disappeared with the last grip still closed. The bridge logged a 100% release after the grace period, and the ball travelled 1,731 VP units past the gate.

In Build 11 I replayed independent inward wrist bends with the palms 0.65 m to each side of the cabinet center. Both flippers registered in VPX. The two-fist check sent one cabinet impulse in each of the four directions. The same Time Machine run dropped the plunger hand at full pull and the ball travelled 1,728 VP units past the gate.

For Build 12 I launched the supplied Time Machine VPX and `tmac_a24` with `--play-time-machine --check-controls --check-standard-resolution --check-ball-launch --check-nudges`. I ran it again with `--check-half-launch` in place of the last two flags. A 30 mm fist pull moved the ball 513 VP units. A 60 mm pull moved it 1,729 units past the gate. Both released when the synthetic hand opened after an incomplete finger sample. The cabinet model registered one impulse per direction at 27 mm and stayed quiet at 22 mm.

For Build 13 I used ARKit’s estimated finger and palm positions for fist gestures when the hand anchor is still tracked. Button pokes still need a tracked fingertip. I added a Mac replay that feeds occluded joint samples through the same fist classifier and checks a pull and open-hand release, a two-fist nudge, and a Start poke with the other fingers curled.

For Build 14 I widened the plunger grab from 9 to 13 cm around the knob and let a loose fist keep the grip even when the other hand closes. The nudge check now holds two firm fists still for 140 ms before measuring a 30 mm shared move. The Mac replay checks that moving into position, one loose fist, and uneven movement stay quiet. It also checks a full shot from 11 cm beside the knob and 16 cm in front of it.

For Build 15 I based the nudge area on each table’s flipper positions. The Mac check accepts a shove by Time Machine’s two side rails. It rejects crossed hands, a fist in front of the cabinet, and a fist too high or too far to the side. Leaving a rail clears the starting position.

For Build 16 I removed the 140 ms hold before the first nudge. The Mac replay shoves on the very next hand-sample pair, 32 ms later in the fixture. Returning both fists to center re-arms the gesture without the old 300 ms cooldown.

For Build 17 I made the plunger grab depend on a palm-down hand and a hidden thumb. It releases when the thumb comes back into view or the palm turns sideways. The Mac check replays that geometry for both hands and exercises a sideways right flipper press inside the same area, a pull, and a separate wrist press after release.

For Build 19 I used the Build 18 calibration to set a tuck grab at 30% across the palm and within 55° of face-down. The thumb can stay tracked. A pinch closes at 15 mm and opens at 25 mm. The nudge detector measures shared movement over the last 100 ms, including movement forward or back, and re-arms where the fists settle. The first shove can fire on the next paired sample beside the rails. I replayed the rounded Build 18 report through the hand controls. Both pinches released at full pull. The first tuck released at full pull and the second was still held when recording ended. The early up event became a left event at 1.102 s, and the forward movement registered at 4.780 s.

For Build 20 I replayed the rounded Build 19 wrist angles through both recognizers. I used the second attempt for gestures recorded twice. The right trace kept 11 presses and the left trace went from two to ten. Both traces released every press. The resting trace and the six nudge traces had zero flipper presses with the new detector. The nudge events matched between replays.

For Build 21 I added 6 cm of forward reach and 2.5 cm of inward reach around the side rails. A nudge needs about 3 cm of shared travel and acceleration in the same direction. The first shove can still fire on the next paired sample. The detector remembers the shove through the return, even if a fist briefly leaves its rail. Calibration records the physical axis separately from the pinball input so a forward push can be distinguished from a lift. I replayed the last attempt for each gesture from Builds 19 and 20 through the Swift controls. The Build 20 replay kept all 38 intended shoves, removed 13 opposite-direction events, and had no flipper presses during the six nudge attempts. The older Back recording still included two upward inputs.

### Seven-table library check

I imported Attack from Mars, Black Hole, Gorgar, Meteor, Middle Earth, The Machine: Bride of Pinbot, and Time Machine in visionOS Simulator 26.5. The library check rendered each table in one app session and checked that PinMAME was running. It checked coin, Start, both flippers, and a half plunger pull in VPX's input manager. The backglass files for Black Hole, Middle Earth, and Bride of Pinbot were imported next to their tables. The stock cabinet covered playfield widths from 0.514 m to 0.685 m. Build 8 completed the same seven-table sequence with the new cabinet button faces and wrist input path.

Black Hole's table script defaults to the seven-digit conversion. The player uses the original ROM when the conversion is absent and `blckhole.zip` is beside the imported table in `pinmame/roms`. Middle Earth needs `20252-01.bin` in `midearth.zip` (CRC-32 `3D44551D`). The library check used the complete archive. The test also reopened Attack from Mars with its existing texture cache to exercise texture uploads before an immersive eye frame.

For Build 22 I fixed an uninitialized position on the stock meshes. I ran Attack from Mars and Middle Earth separately with their matching directB2S files and complete ROMs. I launched each with `--check-library --check-standard-resolution` and took a `xcrun simctl io <device> screenshot <file>` capture after the library pass. Both captures showed the fitted cabinet, legs, front controls, and artwork in Your Room. The earlier Attack from Mars capture showed only the playfield even though the input check passed.

For Build 23 I set the stock playfield depth from `blankTable.vpz`. The front of the playfield now sits about 6.4 cm below the lockbar on Attack from Mars and Middle Earth. It had been 16.2 cm and 21.6 cm on those tables. I also hid the desktop sidewall overlays on this Attack from Mars table so the stock rails can frame the raised playfield.

I checked Attack from Mars with `--check-library --check-standard-resolution --check-attack-from-mars-launch`, its `afm_113b.zip` ROM and a copy of the M2's initialized `afm_113b.nv`. A fresh Simulator NVRAM did not serve a ball. With the saved state, the hand release pressed Launch Ball and moved the same ball 1,990 VP units up the shooter lane. Time Machine's `--check-ball-launch` still took the ball past the authored gate with a mechanical pull.

For Build 24 the four fallback tables use the neutral cabinet. In visionOS Simulator 26.5 the player chose the same variant and glass height as `add-cabinet` did for these files: the launch button and 299 VP units (16.1 cm, held up by a ramp) on Attack from Mars, and the plunger with 598 on Black Hole (from the upper playfield), 259 on Bride of Pinbot and 156 on Middle Earth (8.4 cm). Each fit logged rails at the playfield slope with equal depth front and back. I ran each table on its own with `--check-library --only-table "<title>" --check-standard-resolution` and took a screenshot in Your Room. Each showed the fitted cabinet with its textures, four legs on the floor, the backglass or DMD on the translite and no stock parts. Coin, Start, both wrist flippers and the plunger checks passed on all four, and the nudge check passed on Black Hole. Middle Earth's library check stopped at the ROM gate because the supplied `midearth.zip` lacks `20252-01.bin`. On Attack from Mars, `--check-attack-from-mars-launch` poked the launch button, saw Launch Ball pressed and released, and followed the ball 1,990 VP units up the shooter lane. A fresh NVRAM can make the table clear its totals before serving a ball, so the check credits and starts again until the ball reaches the shooter. With a mesh removed from the app bundle, Bride of Pinbot logged the fallback line and passed its checks on the stock cabinet. Time Machine, Gorgar and Meteor kept their authored cabinets and passed the same checks. Time Machine measured the same 1.088 m cabinet origin as before, and its full pull moved the ball 1,729 VP units past the gate.

For the foveated copy I ran Bride of Pinbot on its own with `--check-library --only-table "The Machine: Bride of Pinbot"` at Highest (`--check-eye-size 2816`), High and Standard. visionOS Simulator 26.5 doesn't support foveation, so all three logged `Compositor path: uniform` with one 3840 × 2160 view, and the library check passed each time. At the same pose, the Highest capture showed clearly sharper playfield lettering, inserts and cabinet edges than High. The timing line held 60 Hz with no missed frames once the table was running. The Simulator's GPU times stayed at about 0.4 ms for VPX and 0.1 ms for the copy at every size, so they don't say anything about the headset's cost.

For Build 26 I looked at the gap the M2 showed at the front of Bride of Pinbot. The cabinet's length already followed the table, but the donor cabinet's playfield stopped 59 VP units (3.1 cm) short of the lockbar's inner edge, and the inner front wall stood 40 VP units past the playfield. With nothing under that strip, you could look down past the apron and see the floor. Now the front of the cabinet sits so the lockbar reaches over the playfield edge, which makes it 71 VP units (3.8 cm) shorter for every table, and the front wall closes the edge. The same change went into `add-cabinet`, and the fit check passed all 18,650 comparisons against the regenerated golden. In visionOS Simulator 26.5 I captured Bride of Pinbot before and after at the same pose, tipped back with `--check-view top`. The floor showed through below the apron before and was gone after. Black Hole, Attack from Mars and Middle Earth showed the lockbar meeting the playfield too.

To check the moving controls in Simulator, add `--check-hold left-flipper`, `right-flipper`, `start`, `coin`, `launch` or `plunger` to a library run. It holds that input for 40 seconds after the checks, and `--check-view side`, `front`, `corner`, `top` or `head` poses the cabinet for a screenshot. Holding the plunger at 60% moved the knob out of its housing, and holding the right flipper or Start pushed the button in. Bride of Pinbot, Black Hole and Time Machine passed their checks, and Time Machine's full pull still moved the ball 1,729 VP units past the gate. Attack from Mars poked the launch button and saw Launch Ball, but a fresh Simulator NVRAM never served a ball, so the shot couldn't be measured.

For Build 27 I gave the neutral cabinet's body and backbox inner sides. They were single surfaces, so looking in over the side rail showed the room through the far wall under the rail. In the Simulator's side view that strip is black now. The coin inserts use Meteor's lit reject window art. Time Machine, Gorgar and Meteor all move one plunger mesh, knob, rod and spring together, along Y with `Plunger.Position`, and the neutral cabinet uses that same mesh. So the spring rides out with the knob there too, and I left it that way.

The DMD moved into the speaker panel at a real 128 × 32 size, with the backglass kept in the glass above. In the Simulator, Attack from Mars showed live DMD frames there and logged `Vision Pro cabinet DMD source: 128 x 32`. Bride of Pinbot never got a DMD source in the Simulator: none showed up in the run with its directB2S, and the run without it logged none after 30 seconds. Its panel stayed dark while the backglass showed. Black Hole's backglass showed its credit and ball-in-play digits. The player now logs that DMD source line on the headset too, which should tell whether PinMAME's frames reach the panel there. Bride of Pinbot, Black Hole, Time Machine and Attack from Mars passed their library checks, and the fit check passed all 18,928 comparisons.

For Build 28 I looked at why Bride of Pinbot's panel stayed dark. It's an alphanumeric machine, so PinMAME has no DMD for it, and the resolver's display list was empty. Its two 16-character displays live in the directB2S score view, so the panel now shows that. In the Simulator the panel showed "FACTORY SETTINGS RESTORED" in the score view's orange segments, and Attack from Mars showed the same message in orange-red dots. Black Hole kept its scores on the backglass. Middle Earth's directB2S has no score digits at all. The table draws its four player scores, ball and credit as 7-segment lights (`Light1` to `Light196`) on its own apron, set from `Controller.ChangedLEDs` in `DisplayTimer_Timer`, with apron flashers for Game Over, Ball, Match and Tilt. Those show on the neutral cabinet as they are. With the complete ROM (the one with `20252-01.bin`) and the headset's NVRAM, the library check passed, and the apron went from the power-on test's 8s to 5,100 points on ball 2 with one credit.

The eye pictures are 3152 × 2520 at Highest now. Bride of Pinbot's center wheel kept the same shape at the same pose as in the Build 26 capture with square Standard pictures, only sharper.

For Build 29 the player keeps the last three table sessions' logs as `vpinball-1.log` (newest) to `vpinball-3.log` next to `vpinball.log`, so a session that went wrong survives opening the next table. Each log starts with a `Vision Pro session:` line giving the build, table, eye size, room and the memory left to the app. After 300 frames it logs BGFX's render target and texture memory. It also logs these when they happen:

- `Vision Pro main loop blocked`: VPX's game loop, which also takes the hand input, hasn't come back for a second. `Vision Pro main loop resumed` follows. A table load blocks it for a few seconds too.
- `VPX frames stopped for 1 s while the compositor keeps presenting`: the picture froze but the head still tracks. It says whether VPX is holding a frame, when it last asked for and handed back one, and the memory left. `VPX frames resumed` follows.
- `no table frame 20 s after opening`, written straight to the log.
- `Vision Pro input not reaching VPX`: a flipper or button press didn't show up in VPX's input state within 300 ms.
- `Vision Pro hand tracking stopped updating`, and resumed.
- `Vision Pro flip L down` or `R up after 412 ms`, with how old the hand data was when the press reached VPX, how far ARKit predicted past the last tracked pose, and how long the press waited for the main thread.
- `Vision Pro shove right 5.1, 0.2 m/s2 (75% of a strong nudge)`, and `shove raised` when a shove still growing pushes harder.
- `Vision Pro Right flipper hold dropped`: the hand stayed bent after a release, or tracking was lost for more than 250 ms while it was held.
- `Vision Pro plumb tilt 1`, with the plumb's largest swing against the tilt angle.
- `Copy command buffer failed`, with the Metal error.

In the Simulator, Attack from Mars and Bride of Pinbot both passed their library checks at Maximum. Bride of Pinbot logged 578 MB of render targets and 85 MB of textures after 300 frames. On top of that come 287 MB for the two eye pictures. VPX's scene, reflection and bloom targets now use packed HDR by default on the Vision Pro, as on the Frame. That halves their memory traffic. On a 600 × 360 crop of Attack from Mars at the same pose, the two formats differed by 2 of 255 on average, and only 1.5% of pixels by more than 8, which includes the lights that were flashing. Launch with `VPX_PACKED_HDR=0` to compare.

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
