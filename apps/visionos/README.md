# VPX Hand Controls

This visionOS preview is for trying hand controls on a room-locked cabinet. It reports gesture events against a standalone model. Live tables and PinMAME require the native VPX player.

Open `CabinetHands.xcodeproj`, select the **CabinetHands** scheme, and run on a visionOS destination. Choose **Open Cabinet**. The preview asks for hand tracking on a supported device. Look toward the space in front of you when opening it. Close and reopen it to place it again.

- Put a hand by each red side button. Move a hand inward and back out to flip. Keeping it in holds the flipper.
- Poke the gold coin box with your index finger. It flashes and **Coins** increases once. Pull back before poking it again.
- Push the green Start button with your index finger. It flashes and **Start Presses** increases once. Pull back before pressing it again.

The cabinet keeps the real hands visible in mixed immersion. The simulator can show the layout. Live hand tracking, reach and timing need a headset check.

The gesture recognizer takes tracked joints in metres relative to the cabinet. The ARKit adapter turns world-space samples into those local coordinates. Both the preview and a future player can consume `CabinetInput` events. The player should send those events through its existing `InputManager` as a separate input device, with held left and right flippers and button presses for Add Credit and Start. A table's render transform must also position the hit zones. Clear held buttons when the cabinet moves, play pauses or tracking is lost.

To check the recognizer on the Mac from this directory:

```sh
check_dir=$(mktemp -d)
trap 'rm -rf "$check_dir"' EXIT
xcrun swiftc CabinetHands/CabinetHandControls.swift Checks/HandControlChecks.swift -o "$check_dir/check"
"$check_dir/check"
```

The checks cover independent flippers, jitter around a held position, release on tracking loss, re-arming, and one action per coin or Start gesture.

## Cabinet fit

The supplied Data East Time Machine example (VPX file version 1060) has a 1,000 × 1,910 VP-unit playfield, separate room surfaces, and authored cabinet, backbox, backglass and coin-door primitives. Its `PinCab_Buttons` primitive groups buttons in one mesh, so its origin can't locate each button. The preview takes its dimensions from that playfield and draws a generic cabinet with separate controls.

The player can keep a table's authored cabinet and resolve control locations from an explicit table profile when the mesh doesn't identify them. For tables without a cabinet, use the playfield bounds converted to metres to fit the generic cabinet and place its controls. VPX's own `blankTable.vpz` has separate cabinet, rails, legs, backbox, Start and flipper button parts. That is a reference for a reusable cabinet whose geometry doesn't depend on a user's table artwork. VPX already distinguishes the cabinet, playfield and room transforms, which would also let the player show the cabinet in passthrough without drawing a separate room where the table identifies that room.
