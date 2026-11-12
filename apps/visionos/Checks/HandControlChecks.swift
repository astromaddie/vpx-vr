import Foundation
// license:GPLv3+

import simd

@main
struct HandControlChecks {
    static func main() {
        if let index = CommandLine.arguments.firstIndex(of: "--recordings"), CommandLine.arguments.indices.contains(index + 1) {
            checkRecordings(CommandLine.arguments[index + 1])
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--replay") {
            replay(CommandLine.arguments.dropFirst(index + 1).map { $0 })
            return
        }
        let layout = CabinetControlsLayout()
        var controls = CabinetHandControls(layout: layout)
        var time = 0.0

        func feed(_ side: CabinetHandSide, _ sample: CabinetHandSample?, after delta: Double = 0.016) -> [CabinetInput] {
            time += delta
            return controls.update(side, sample: sample, at: time)
        }

        func palm(_ side: CabinetHandSide, _ offset: Float) -> CabinetHandSample {
            .init(palm: layout.flipper(side) + [offset * side.sign, 0, 0])
        }

        // Finding the hand inside the cabinet doesn't count as a press. The movement
        // from outside to inside makes one edge, and jitter inside the band is ignored.
        precondition(feed(.left, palm(.left, -0.024)).isEmpty)
        precondition(feed(.left, palm(.left, 0.024)).isEmpty)
        precondition(feed(.left, palm(.left, -0.024)) == [.flipper(.left, pressed: true)])
        precondition(feed(.left, palm(.left, 0.008)).isEmpty)
        precondition(feed(.right, palm(.right, 0.025)).isEmpty)
        precondition(feed(.right, palm(.right, -0.025)) == [.flipper(.right, pressed: true)])
        precondition(feed(.left, palm(.left, 0.024)) == [.flipper(.left, pressed: false)])
        precondition(controls.expire(at: time + 0.15) == [.flipper(.right, pressed: false)])
        time += 0.15
        precondition(feed(.right, palm(.right, -0.024)).isEmpty)
        precondition(feed(.right, palm(.right, 0.024)).isEmpty)
        precondition(feed(.right, palm(.right, -0.024)) == [.flipper(.right, pressed: true)])
        precondition(feed(.right, nil) == [.flipper(.right, pressed: false)])

        func start(_ z: Float) -> CabinetHandSample {
            .init(index: layout.start + [0, 0, z])
        }

        precondition(feed(.left, start(-0.003)).isEmpty)
        precondition(feed(.left, start(0.04)).isEmpty)
        precondition(feed(.left, start(-0.039)) == [.pressStart])
        precondition(feed(.left, start(-0.003)).isEmpty)
        precondition(feed(.left, start(0.04)).isEmpty)
        precondition(controls.reset().isEmpty)
        precondition(feed(.left, start(-0.003)).isEmpty)

        func coin(_ z: Float, x: Float = 0.035, y: Float = 0.025) -> CabinetHandSample {
            .init(index: layout.coin + [x, y, z])
        }

        // The coin box accepts a fingertip near its edge, once per approach.
        precondition(feed(.right, coin(0)).isEmpty)
        precondition(feed(.right, coin(0.04)).isEmpty)
        precondition(feed(.right, coin(0)) == [.insertCoin])
        precondition(feed(.right, coin(0)).isEmpty)
        precondition(feed(.right, coin(0.012)).isEmpty)
        precondition(feed(.right, coin(0)).isEmpty)
        precondition(feed(.right, coin(0.04)).isEmpty)
        precondition(feed(.right, coin(0)) == [.insertCoin])

        // Leaving the target or losing the fingertip cancels the approach.
        precondition(feed(.right, coin(0.04)).isEmpty)
        precondition(feed(.right, coin(0, x: 0.055)).isEmpty)
        precondition(feed(.right, coin(0)).isEmpty)
        precondition(feed(.right, coin(0.04)).isEmpty)
        precondition(feed(.right, .init()).isEmpty)
        precondition(feed(.right, coin(0)).isEmpty)
        precondition(feed(.right, coin(0.04)).isEmpty)
        precondition(feed(.right, coin(0), after: 0.16).isEmpty)
        print("Hand controls passed: independent flippers, loss and re-arm, Start and coin pokes")
        checkWristTurns()
        checkMappedFlippers()
        checkGestureFlippers()
        checkWristFlickTiming()
        checkShoves()
        checkFlipperHolds()
        checkOccludedFistInputs()
        checkPlacement()
        checkRoomGrab()
        checkWristMenu()
        checkPlunger()
        checkLaunchButton()
    }

    static func checkLaunchButton() {
        // The neutral cabinet's launch button, roughly where Attack from Mars puts it.
        let face = CabinetButtonFace(position: [0.24, -0.12, 0.08], halfSize: [0.044, 0.044])
        let layout = CabinetControlsLayout(
            startFace: CabinetButtonFace(position: [-0.24, -0.20, 0.06], halfSize: [0.032, 0.032]),
            coinFace: CabinetButtonFace(position: [0, -0.20, 0.07], halfSize: [0.087, 0.033]),
            launchFace: face, usesWristGestures: true)
        var controls = CabinetHandControls(layout: layout)
        var time = 0.0
        func poke(_ offset: SIMD3<Float>, pose: CabinetHandPose = .unknown) -> [CabinetInput] {
            time += 0.016
            return controls.update(.right, sample: .init(index: face.position + offset, pose: pose), at: time)
        }
        precondition(CabinetInput.pressLaunchBall.action == .launchBall)
        precondition(poke([0, 0, 0.04]).isEmpty)
        precondition(poke([0.03, -0.02, 0.006]) == [.pressLaunchBall])
        precondition(poke([0.03, -0.02, 0]).isEmpty)
        precondition(poke([0, 0, 0.012]).isEmpty)
        precondition(poke([0, 0, 0.04]).isEmpty)
        precondition(poke([0, 0, 0.004]) == [.pressLaunchBall])
        // Beside the button, or with a closed fist, nothing fires.
        precondition(poke([0, 0, 0.04]).isEmpty)
        precondition(poke([0.06, 0, 0.004]).isEmpty)
        precondition(poke([0, 0, 0.04]).isEmpty)
        precondition(poke([0, 0, 0.004], pose: .fist).isEmpty)
        // Without a launch face the same pokes do nothing.
        var plain = CabinetHandControls(layout: CabinetControlsLayout(usesWristGestures: true))
        precondition(plain.update(.right, sample: .init(index: face.position + [0, 0, 0.04]), at: 1).isEmpty)
        precondition(plain.update(.right, sample: .init(index: face.position), at: 1.016).isEmpty)
        print("Hand controls passed: launch button poke, re-arm, edge and closed-fist rejection")
    }

    static func plungerPose(
        _ side: CabinetHandSide = .right, roll: Float = 0, thumbUntucked: Bool = false, palmTracked: Bool = true
    ) -> CabinetPlungerPose {
        let radians = roll * .pi / 180
        let index = -side.sign * SIMD3<Float>(0.03 * cos(radians), 0.03 * sin(radians), 0)
        let thumb = thumbUntucked ? index * 1.6 : SIMD3<Float>(0, -0.015, 0)
        return CabinetPlungerGeometry(
            side: side, wrist: .init(point: [0, 0, 0.06], isTracked: palmTracked),
            palm: .init(point: .zero, isTracked: palmTracked),
            index: .init(point: index, isTracked: false), little: .init(point: -index, isTracked: false),
            indexTip: .init(point: index + [0, 0, -0.07], isTracked: true),
            thumb: .init(point: thumb, isTracked: true)
        ).pose
    }

    static func checkPlunger() {
        let handle = SIMD3<Float>(0.24, -0.095, 0.040)
        var preview = CabinetHandControls()
        var player = CabinetHandControls(layout: CabinetControlsLayout(plunger: handle))
        let thumbRelease = plungerPose(thumbUntucked: true)
        let sidewaysRelease = plungerPose(roll: 90)
        let rolling = plungerPose(roll: 57)
        precondition(plungerPose(.right).tuck == .grab && plungerPose(.left).tuck == .grab)
        precondition(thumbRelease.tuck == .release && sidewaysRelease.tuck == .release)
        precondition(plungerPose(roll: 180).tuck == .release && rolling.tuck == .uncertain)
        precondition(plungerPose(palmTracked: false).tuck == .uncertain)
        func grip(_ depth: Float, pose: CabinetPlungerPose = .init(tuck: .grab), side: Float = 0) -> CabinetHandSample {
            .init(palm: handle + [side, 0, depth + 0.05], plungerPose: pose)
        }
        precondition(preview.update(.right, sample: grip(0), at: 0).isEmpty)
        precondition(player.update(.right, sample: grip(0.16), at: 0).isEmpty)
        precondition(player.update(.right, sample: grip(0, pose: thumbRelease), at: 0.01).isEmpty)
        precondition(player.update(.right, sample: grip(0), at: 0.016) == [.pullPlunger(0)])
        precondition(player.update(.left, sample: grip(0), at: 0.02).isEmpty)
        let halfDepth = CabinetHandControls.plungerStroke / 2
        let half = player.update(.right, sample: grip(halfDepth), at: 0.032)
        guard half.count == 1, case let .pullPlunger(pull) = half[0] else { preconditionFailure("Missing half pull") }
        precondition(abs(pull - 0.5) < 0.01)
        for frame in 1...4 {
            precondition(player.update(.right, sample: grip(0, pose: rolling), at: 0.032 + Double(frame) * 0.08).isEmpty)
        }
        precondition(player.update(.right, sample: grip(0, pose: thumbRelease), at: 0.37) == [.releasePlunger(pull)])
        precondition(player.update(.right, sample: grip(0, pose: thumbRelease), at: 0.39).isEmpty)

        player = CabinetHandControls(layout: CabinetControlsLayout(plunger: handle))
        precondition(player.update(.right, sample: grip(0), at: 0.128) == [.pullPlunger(0)])
        precondition(player.update(.right, sample: grip(0.10), at: 0.144) == [.pullPlunger(1)])
        precondition(player.update(.right, sample: grip(halfDepth, side: 0.12), at: 0.160) == half)
        precondition(player.expire(at: 0.30) == [.cancelPlunger])
        // A lost hand must show a release before it can grab again.
        precondition(player.update(.right, sample: grip(0), at: 0.32).isEmpty)
        precondition(player.update(.right, sample: grip(0, pose: thumbRelease), at: 0.34).isEmpty)
        precondition(player.update(.right, sample: grip(0), at: 0.36) == [.pullPlunger(0)])
        precondition(player.update(.right, sample: grip(0.10), at: 0.38) == [.pullPlunger(1)])
        precondition(player.update(.right, sample: nil, at: 0.40).isEmpty)
        precondition(player.expire(at: 0.48).isEmpty)
        precondition(player.expire(at: 0.52) == [.cancelPlunger])
        precondition(player.expire(at: 0.55).isEmpty)
        precondition(player.update(.right, sample: grip(0, pose: thumbRelease), at: 0.56).isEmpty)

        // Incomplete finger tracking can recover before the grace period.
        precondition(player.update(.right, sample: grip(0), at: 0.58) == [.pullPlunger(0)])
        precondition(player.update(.right, sample: grip(0.10), at: 0.60) == [.pullPlunger(1)])
        precondition(player.update(.right, sample: grip(0, pose: rolling), at: 0.64).isEmpty)
        precondition(player.update(.right, sample: grip(0.10), at: 0.69).isEmpty)
        precondition(player.expire(at: 0.76).isEmpty)
        precondition(player.update(.right, sample: grip(0, pose: sidewaysRelease), at: 0.78) == [.releasePlunger(1)])
        precondition(player.update(.right, sample: grip(0, pose: sidewaysRelease), at: 0.80).isEmpty)
        precondition(player.update(.right, sample: grip(0), at: 0.82) == [.pullPlunger(0)])
        precondition(player.reset() == [.cancelPlunger])
        precondition(player.expire(at: 0.90).isEmpty)

        precondition(player.update(.right, sample: grip(0), at: 0.92) == [.pullPlunger(0)])
        precondition(player.update(.right, sample: grip(0.003), at: 0.94).count == 1)
        precondition(player.expire(at: 1.08) == [.cancelPlunger])
        var tuck = CabinetHandControls(layout: CabinetControlsLayout(plunger: handle))
        precondition(tuck.update(.right, sample: grip(0), at: 1.2) == [.pullPlunger(0)])
        precondition(tuck.update(.right, sample: grip(0.06, pose: plungerPose(roll: 53)), at: 1.22) == [.pullPlunger(1)])
        let overlap = CabinetPlungerPose(tuck: .release, pinch: .grab)
        precondition(tuck.update(.right, sample: grip(0, pose: overlap), at: 1.24) == [.releasePlunger(1)])
        precondition(tuck.update(.right, sample: grip(0, pose: overlap), at: 1.26).isEmpty)

        func pinch(_ gap: Float) -> CabinetPlungerPose {
            .classify(angle: 72, across: 19, gapMM: gap, trackedPalmJoints: 2)
        }
        precondition(tuck.update(.right, sample: grip(0, pose: pinch(25)), at: 1.28).isEmpty)
        precondition(tuck.update(.right, sample: grip(0, pose: pinch(15)), at: 1.30) == [.pullPlunger(0)])
        precondition(tuck.update(.right, sample: grip(halfDepth, pose: pinch(20)), at: 1.32) == half)
        precondition(tuck.update(.right, sample: grip(0, pose: pinch(25)), at: 1.34) == [.releasePlunger(pull)])
        print("Plunger passed: thumb geometry with a tracked tip, tilted pull, roll and untuck release, pinch hysteresis and tracking loss")
    }

    static func checkWristTurns() {
        let layout = CabinetControlsLayout()
        var controls = CabinetHandControls(layout: layout)
        var time = 0.0

        func turn(_ side: CabinetHandSide, _ degrees: Float, roll: Bool = false, far: Bool = false) -> [CabinetInput] {
            time += 0.016
            let radians = degrees * .pi / 180
            let inward = -side.sign * sin(radians)
            let palm = layout.flipper(side) + [side.sign * 0.035, 0, far ? 0.25 : 0]
            return controls.update(side, sample: .init(
                palm: palm,
                fingerDirection: roll ? [0, 0, -1] : [inward, 0, -cos(radians)],
                palmNormal: roll ? [inward, -cos(radians), 0] : nil
            ), at: time)
        }

        // The palm stays outside the cabinet. Only the angle changes.
        precondition(turn(.left, 0).isEmpty)
        precondition(turn(.left, -11).isEmpty)
        precondition(turn(.left, 0).isEmpty)
        precondition(turn(.left, 6).isEmpty)
        precondition(turn(.left, 9) == [.flipper(.left, pressed: true)])
        precondition(turn(.left, 5).isEmpty)
        precondition(turn(.right, 0, roll: true).isEmpty)
        precondition(turn(.right, 9, roll: true) == [.flipper(.right, pressed: true)])
        precondition(turn(.left, 2) == [.flipper(.left, pressed: false)])
        precondition(turn(.right, 9, roll: true, far: true) == [.flipper(.right, pressed: false)])
        precondition(turn(.right, 9, roll: true, far: true).isEmpty)
        precondition(turn(.right, 0, roll: true).isEmpty)
        precondition(turn(.right, 9, roll: true) == [.flipper(.right, pressed: true)])
        precondition(controls.expire(at: time + 0.13) == [.flipper(.right, pressed: false)])
        print("Wrist turns passed: stationary palm, mirrored inward turns, hold and release")
    }

    static func checkMappedFlippers() {
        let layout = CabinetControlsLayout(
            leftFlipperCap: [-0.29, -0.16, -0.02], rightFlipperCap: [0.29, -0.16, -0.02])
        var controls = CabinetHandControls(layout: layout)
        var time = 0.0
        func feed(_ side: CabinetHandSide, _ x: Float, _ direction: SIMD3<Float>?) -> [CabinetInput] {
            time += 0.016
            let palm = layout.flipper(side) + [side.sign * x, 0.075, 0.12]
            return controls.update(side, sample: .init(palm: palm, fingerDirection: direction), at: time)
        }
        precondition(feed(.left, -0.018, [0, 0, -1]).isEmpty)
        precondition(feed(.left, -0.018, [0.18, 0, -1]) == [.flipper(.left, pressed: true)])
        precondition(feed(.left, -0.018, [0, 0, -1]) == [.flipper(.left, pressed: false)])
        precondition(feed(.right, 0.014, nil).isEmpty)
        precondition(feed(.right, -0.008, nil) == [.flipper(.right, pressed: true)])
        precondition(feed(.right, 0.014, nil) == [.flipper(.right, pressed: false)])
        print("Mapped flippers passed: wider reach, wrist arming at the cap, and a shorter inward press")
    }

    static func checkGestureFlippers() {
        let layout = CabinetControlsLayout(usesWristGestures: true)
        var controls = CabinetHandControls(layout: layout)
        var time = 0.0
        let straight: SIMD3<Float> = [0, 0, -1]
        func feed(_ side: CabinetHandSide, _ direction: SIMD3<Float>, arm: SIMD3<Float>? = [0, 0, -1],
                  roll: Bool = false, fist: Bool = false) -> [CabinetInput] {
            time += 0.016
            let sample = CabinetHandSample(palm: [side.sign * 0.75, 0.35, 0.42], fingerDirection: direction,
                                           palmNormal: roll ? [side.sign, 0, 0] : [0, -1, 0],
                                           forearmDirection: arm, pose: fist ? .fist : .open)
            return controls.update(side, sample: sample, at: time)
        }
        precondition(feed(.left, straight).isEmpty)
        precondition(feed(.right, straight, roll: true).isEmpty)
        // Moving the entire arm inward or rolling the palm leaves the wrist straight.
        precondition(feed(.left, [0.28, 0, -1], arm: [0.28, 0, -1]).isEmpty)
        precondition(feed(.left, straight, roll: true).isEmpty)
        precondition(feed(.left, [0.18, 0, -1], roll: true) == [.flipper(.left, pressed: true)])
        precondition(feed(.right, [0.18, 0, -1], roll: true).isEmpty)
        precondition(feed(.right, [-0.18, 0, -1], roll: true) == [.flipper(.right, pressed: true)])
        precondition(feed(.left, [0.12, 0, -1], arm: nil, roll: true).isEmpty)
        // The hold reads the median of three samples, so a reference change takes one more.
        precondition(feed(.left, straight).isEmpty)
        precondition(feed(.left, straight) == [.flipper(.left, pressed: false)])
        precondition(feed(.right, [-0.18, 0, -1], fist: true).isEmpty)
        precondition(feed(.right, straight, fist: true).isEmpty)
        precondition(feed(.right, straight, fist: true) == [.flipper(.right, pressed: false)])
        precondition(feed(.right, [-0.18, 0, -1], fist: true) == [.flipper(.right, pressed: true)])
        precondition(feed(.right, straight, fist: true).isEmpty)
        precondition(feed(.right, straight, fist: true) == [.flipper(.right, pressed: false)])
        precondition(controls.reset().isEmpty)
        precondition(feed(.left, straight, arm: nil).isEmpty)
        precondition(feed(.left, [0.18, 0, -1], arm: nil) == [.flipper(.left, pressed: true)])
        // A held wrist flipper rides out a short gap and drops after 250 ms.
        precondition(controls.expire(at: time + 0.13).isEmpty)
        precondition(controls.expire(at: time + 0.26) == [.flipper(.left, pressed: false)])

        let knob: SIMD3<Float> = [0.24, -0.15, 0.109]
        controls = CabinetHandControls(layout: CabinetControlsLayout(plunger: knob, usesWristGestures: true))
        func grip(_ pull: Float, direction: SIMD3<Float>, pose: CabinetPlungerPose) -> [CabinetInput] {
            time += 0.016
            return controls.update(.right, sample: .init(palm: knob + [0, 0, 0.05 + pull],
                                                         fingerDirection: direction, forearmDirection: straight,
                                                         pose: .looseFist, plungerPose: pose), at: time)
        }
        // This sideways loose fist used to grab at this position. It can
        // now make and hold a normal inward wrist press right by the knob.
        let sideways = plungerPose(roll: 90)
        let palmDown = plungerPose()
        let inward: SIMD3<Float> = [-0.20, 0, -1]
        precondition(grip(0, direction: straight, pose: sideways).isEmpty)
        precondition(grip(0, direction: inward, pose: sideways) == [.flipper(.right, pressed: true)])
        precondition(grip(0, direction: inward, pose: palmDown).isEmpty)
        precondition(grip(0, direction: straight, pose: sideways).isEmpty)
        precondition(grip(0, direction: straight, pose: sideways) == [.flipper(.right, pressed: false)])
        precondition(grip(0, direction: straight, pose: palmDown) == [.pullPlunger(0)])
        precondition(grip(0.07, direction: inward, pose: palmDown) == [.pullPlunger(1)])
        precondition(grip(0, direction: inward, pose: sideways) == [.releasePlunger(1)])
        precondition(grip(0, direction: straight, pose: sideways).isEmpty)
        precondition(grip(0, direction: inward, pose: sideways) == [.flipper(.right, pressed: true)])
        precondition(controls.reset() == [.flipper(.right, pressed: false)])
        print("Gesture flippers passed: distance-independent bends, palm roll, arm motion rejection, independent holds and forearm fallback")
    }

    static func checkWristFlickTiming() {
        let layout = CabinetControlsLayout(usesWristGestures: true)
        var controls = CabinetHandControls(layout: layout)
        var time = 0.0
        func feed(_ degrees: Float, after delay: Double = 0.016) -> [CabinetInput] {
            time += delay
            let angle = degrees * .pi / 180
            return controls.update(.right, sample: .init(
                fingerDirection: [-sin(angle), 0, -cos(angle)], forearmDirection: [0, 0, -1]
            ), at: time)
        }

        // Slow drift crosses eight degrees from the starting angle without a press.
        for angle in 0...12 { precondition(feed(Float(angle), after: 0.032).isEmpty) }
        precondition(feed(21) == [.flipper(.right, pressed: true)])
        for _ in 0..<20 { precondition(feed(21).isEmpty) }
        // A slow relaxation releases once the median of three samples is 5 degrees down.
        precondition(feed(17).isEmpty)
        precondition(feed(15).isEmpty)
        precondition(feed(13) == [.flipper(.right, pressed: false)])
        // A flick that overshoots and settles 8 degrees back onto a held bend stays down,
        // as the build 30 hold recordings did. Relaxing 5 degrees from there releases.
        precondition(feed(24) == [.flipper(.right, pressed: true)])
        for angle: Float in [32, 33, 29, 27, 25] { precondition(feed(angle).isEmpty) }
        for _ in 0..<8 { precondition(feed(26).isEmpty) }
        precondition(feed(22).isEmpty)
        precondition(feed(20).isEmpty)
        precondition(feed(19) == [.flipper(.right, pressed: false)])
        precondition(feed(36) == [.flipper(.right, pressed: true)])
        // Once settled, a quick relaxation of 10 degrees releases at once.
        for _ in 0..<10 { precondition(feed(36).isEmpty) }
        precondition(feed(25) == [.flipper(.right, pressed: false)])
        precondition(feed(36) == [.flipper(.right, pressed: true)])
        // A held wrist flipper rides out a short gap and drops after 250 ms.
        precondition(controls.expire(at: time + 0.13).isEmpty)
        precondition(controls.expire(at: time + 0.26) == [.flipper(.right, pressed: false)])

        // Speed alone is insufficient for small jumps.
        time += 0.26
        precondition(feed(-4).isEmpty)
        precondition(feed(1, after: 0.01).isEmpty)
        precondition(feed(-9).isEmpty)
        precondition(feed(4) == [.flipper(.right, pressed: true)])
        precondition(feed(0).isEmpty)
        precondition(feed(-2).isEmpty)
        precondition(feed(-3) == [.flipper(.right, pressed: false)])

        print("Wrist flick timing passed: slow drift, angular speed and bend, sustained hold and backswing release")
    }

    static func checkOccludedFistInputs() {
        let knob: SIMD3<Float> = [0.241, -0.155, 0.109]
        let layout = CabinetControlsLayout(
            plunger: knob, leftFlipperCap: [-0.298, -0.153, -0.033],
            rightFlipperCap: [0.293, -0.153, -0.033], usesWristGestures: true
        )
        func hand(at palm: SIMD3<Float>, open: Bool = false, pointing: Bool = false) -> CabinetHandSample {
            let wrist = palm + [0, 0, 0.06]
            func joint(_ point: SIMD3<Float>, tracked: Bool = false) -> CabinetHandJoint {
                .init(point: point, isTracked: tracked)
            }
            let fingers: [CabinetHandPose.Finger] = (0..<4).map { finger in
                let knuckle = palm + [Float(finger) * 0.02 - 0.02, 0, 0]
                let pointingIndex = pointing && finger == 0
                let straight = open || pointingIndex
                return .init(knuckle: joint(knuckle),
                             bend: joint(knuckle + (straight ? [0, 0, -0.028] : [0, -0.026, -0.008]),
                                         tracked: pointingIndex),
                             next: joint(knuckle + (straight ? [0, 0, -0.051] : [0, -0.040, 0.008])))
            }
            let palmJoint = joint(palm)
            var sample = CabinetHandSample(palm: palmJoint.trackedPosition)
            sample.recognizeGrip(wrist: wrist, palm: palmJoint, fingers: fingers)
            return sample
        }

        // The hand anchor is tracked while the palm and curled finger joints
        // are estimated. The same sample policy is used by the ARKit adapter.
        let grab = knob + [0, 0, 0.05]
        let closed = hand(at: grab)
        precondition(closed.palm == nil && closed.gripPosition == grab && closed.pose == .fist)
        var player = CabinetHandControls(layout: layout)
        // Curl evidence alone cannot acquire or release the plunger.
        precondition(player.update(.right, sample: closed, at: 0.016).isEmpty)
        precondition(player.update(.right, sample: hand(at: grab + [0, 0, 0.065]), at: 0.032).isEmpty)
        precondition(player.update(.right, sample: hand(at: grab, open: true), at: 0.048).isEmpty)

        var time = 0.1
        let left = layout.flipper(.left) + [-0.07, 0.06, -0.08]
        _ = player.reset()
        time += 0.016
        var pointing = hand(at: left, pointing: true)
        precondition(pointing.pose == .unknown)
        pointing.index = layout.start + [0, 0, 0.04]
        precondition(player.update(.left, sample: pointing, at: time).isEmpty)
        pointing.index = layout.start
        precondition(player.update(.left, sample: pointing, at: time + 0.02) == [.pressStart])
        let invalidJoint = CabinetHandJoint(point: [.nan, 0, 0], isTracked: true)
        precondition(invalidJoint.trackedPosition == nil && invalidJoint.estimatedPosition == nil)
        print("Occluded joints passed: estimated fists and tracked index poke")
    }

    static func checkPlacement() {
        func head(y: Float, yaw: Float, pitch: Float = 0, roll: Float = 0) -> simd_float4x4 {
            let rotation = simd_quatf(angle: yaw, axis: [0, 1, 0])
                * simd_quatf(angle: pitch, axis: [1, 0, 0])
                * simd_quatf(angle: roll, axis: [0, 0, 1])
            var transform = simd_float4x4(rotation)
            transform.columns.3 = [0.35, y, 0.2, 1]
            return transform
        }

        let early = head(y: 1.32, yaw: .pi / 6 + .pi / 18)
        let settled = head(y: 1.60, yaw: .pi / 6, pitch: -.pi / 5, roll: -.pi / 18)
        var placement = CabinetPlacement()
        for step in 0 ..< 5 {
            precondition(placement.sample(early, at: Double(step) / 10) == nil)
        }
        for step in 5 ..< 10 {
            precondition(placement.sample(settled, at: Double(step) / 10) == nil)
        }
        guard let cabinet = placement.sample(settled, at: 1) else {
            preconditionFailure("A stable, fully tracked pose should place the cabinet")
        }

        // The lockbar is in front of the head and horizontal in room space,
        // with a pure heading rotation despite the pitched and rolled test pose.
        let close = { (a: Float, b: Float) in abs(a - b) < 0.0001 }
        precondition(close(cabinet.columns.3.y, 1.35))
        precondition(close(cabinet.columns.3.x, 0.35 - 0.53 * 0.5))
        precondition(close(cabinet.columns.3.z, 0.2 - 0.53 * cos(.pi / 6)))
        precondition(close(cabinet.columns.0.y, 0) && close(cabinet.columns.2.y, 0))
        precondition(cabinet.columns.1 == SIMD4<Float>(0, 1, 0, 0))
        precondition(close(cabinet.columns.2.x, 0.5))

        precondition(placement.sample(nil, at: 1.1) == nil)
        precondition(placement.sample(settled, at: 1.2) == nil)
        precondition(placement.sample(settled, at: 1.9) == nil)
        // A ten-degree heading change alone is enough to discard the old window.
        placement = CabinetPlacement()
        for step in 20 ..< 25 {
            precondition(placement.sample(head(y: 1.60, yaw: .pi / 6 + .pi / 18), at: Double(step) / 10) == nil)
        }
        precondition(placement.sample(settled, at: 2.5) == nil)
        print("Placement passed: rejected a low and 10° off-heading opening pose; settled lockbar at 1.35 m, zero heading error and roll")
    }

    static func checkRoomGrab() {
        let width: Float = 0.6
        var initial = matrix_identity_float4x4
        initial.columns.3 = [0.2, 1.08, -0.53, 1]
        var room = CabinetRoomPlacement(pose: initial)
        var time = 0.0
        let left: SIMD3<Float> = [-0.1, 1.19, -0.65]
        let right: SIMD3<Float> = [0.5, 1.19, -0.65]
        func feed(_ side: CabinetHandSide, _ wrist: SIMD3<Float>) {
            time += 0.015
            room.update(side, wrist: wrist, at: time)
        }

        for _ in 0..<12 {
            feed(.left, left - [0, 0.15, 0])
            feed(.right, right - [0, 0.15, 0])
        }
        precondition(!room.isMoving)
        for _ in 0..<9 {
            feed(.left, left)
            feed(.right, right)
            precondition(!room.isMoving)
        }
        for _ in 0..<3 {
            feed(.left, left)
            feed(.right, right)
        }
        precondition(room.isMoving && room.pose == initial)

        // Move the wrist center 30 cm right, lift both hands, and turn 30 degrees.
        let center: SIMD3<Float> = [0.5, 1.40, -0.65]
        let angle: Float = .pi / 6
        let span = SIMD3(width * 0.5 * cos(angle), 0, -width * 0.5 * sin(angle))
        feed(.left, center - span)
        precondition(room.pose == initial)
        feed(.right, center + span)
        let moved = room.pose
        precondition(abs(moved.columns.3.x - (0.5 + 0.12 * sin(angle))) < 0.0001)
        precondition(moved.columns.3.y == initial.columns.3.y)
        precondition(moved.columns.1 == initial.columns.1)
        precondition(abs(moved.columns.0.z + sin(angle)) < 0.0001)
        precondition(abs(simd_length(moved.columns.0) - 1) < 0.0001)
        precondition(room.original == initial)

        feed(.left, center - span - [0, 0.4, 0])
        precondition(!room.isMoving && room.pose == moved)
        feed(.left, center - span)
        feed(.right, center + span)
        precondition(!room.isMoving && room.pose == moved)
        for _ in 0..<12 {
            feed(.left, center - span)
            feed(.right, center + span)
        }
        precondition(room.isMoving)
        let beforeLoss = room.pose
        room.expire(at: time + 0.19)
        precondition(!room.isMoving && room.pose == beforeLoss)
        print("Room placement passed: paired wrist dwell, yaw, translation, fixed scale and height, and tracking-loss lock")
    }

    static func checkWristMenu() {
        var gesture = CabinetWristMenu()
        let wrist: SIMD3<Float> = [0, -0.26, -0.42]
        let forward = simd_normalize(wrist)
        let head = simd_float4x4(simd_quatf(from: SIMD3(0, 0, -1), to: forward))
        let acrossBody: SIMD3<Float> = [1, 0, 0]
        func sample(_ time: Double, headPose: simd_float4x4 = head, normal: SIMD3<Float> = forward) -> Bool {
            gesture.update(head: headPose, wrist: wrist, fingers: acrossBody, palmNormal: normal, at: time)
        }
        for frame in 0..<10 {
            precondition(!sample(Double(frame) / 20, headPose: matrix_identity_float4x4))
            precondition(!sample(Double(frame) / 20, normal: -forward))
        }
        for frame in 10..<19 { precondition(!sample(Double(frame) / 20)) }
        precondition(sample(1))
        for frame in 21..<31 { precondition(!sample(Double(frame) / 20)) }
        for frame in 40..<49 { precondition(!sample(Double(frame) / 20)) }
        precondition(sample(2.5))
        print("Wrist menu passed: head alignment, back of hand, dwell, one opening, and re-arm after tracking loss")
    }

    /// Two hands resting at the cabinet sides, with wrist paths and right wrist bends, at 90 Hz.
    struct ShoveRig {
        let layout = CabinetControlsLayout(usesWristGestures: true)
        var controls: CabinetHandControls
        var time = 0.0
        var shoves: [SIMD2<Float>] = []
        var flips: [CabinetInput] = []
        let rest: [CabinetHandSide: SIMD3<Float>]

        init() {
            controls = CabinetHandControls(layout: layout)
            rest = [.left: layout.flipper(.left) + [-0.04, 0.03, 0.06], .right: layout.flipper(.right) + [0.04, 0.03, 0.06]]
        }

        mutating func hands(_ left: SIMD3<Float>, _ right: SIMD3<Float>, leftBend: Float = 0, rightBend: Float = 0,
                            leftArm: SIMD3<Float> = [0, 0, -1], rightArm: SIMD3<Float> = [0, 0, -1]) {
            for (side, offset, bend, arm) in [(CabinetHandSide.left, left, leftBend, leftArm), (.right, right, rightBend, rightArm)] {
                let angle = bend * .pi / 180
                let inward = -side.sign
                // Bend the hand inward from the forearm.
                let direction = simd_normalize(arm) * cos(angle) + SIMD3(inward * sin(angle), 0, 0)
                let sample = CabinetHandSample(fingerDirection: direction, forearmDirection: arm, wrist: rest[side]! + offset)
                for event in controls.update(side, sample: sample, at: time + (side == .left ? 0 : 0.0055)) {
                    if case let .shove(acceleration, update) = event {
                        if update { shoves[shoves.count - 1] = acceleration } else { shoves.append(acceleration) }
                    } else {
                        flips.append(event)
                    }
                }
            }
            time += 0.011
        }

        mutating func still(_ count: Int) { for _ in 0..<count { hands(.zero, .zero) } }

        static func minimumJerk(_ t: Float) -> Float { t * t * t * (10 - 15 * t + 6 * t * t) }

        /// Moves one or both wrists along a minimum-jerk path and back.
        mutating func stroke(left: SIMD3<Float> = .zero, right: SIMD3<Float> = .zero, frames: Int,
                             returnFrames: Int = 30, rightBend: (Int) -> Float = { _ in 0 }) {
            for step in 1...frames {
                let s = Self.minimumJerk(Float(step) / Float(frames))
                hands(left * s, right * s, rightBend: rightBend(step))
            }
            for step in stride(from: 1, through: returnFrames, by: 1) {
                let s = 1 - Self.minimumJerk(Float(step) / Float(returnFrames))
                hands(left * s, right * s)
            }
            if returnFrames > 0 { still(25) }
        }
    }

    static func checkShoves() {
        var rig = ShoveRig()
        rig.still(20)
        // Ordinary repositioning: 10 cm along the side in 400 ms, a 30 cm reach
        // toward Start in 450 ms, and lifting a hand 15 cm off the cabinet.
        rig.stroke(left: [0, 0, -0.10], frames: 36, returnFrames: 36)
        rig.stroke(right: [-0.18, -0.10, 0.12], frames: 41, returnFrames: 41)
        rig.stroke(left: [0, 0.15, 0], frames: 30)
        rig.stroke(left: [-0.08, 0, 0.10], frames: 25)
        precondition(rig.shoves.isEmpty && rig.flips.isEmpty, "Repositioning moved the cabinet: \(rig.shoves)")

        // A two-hand shove right, 5 cm in 120 ms. A right wrist bend in its first
        // 150 ms is the hand overrunning the arm, as in the build 30 recordings, so it
        // doesn't flip. A flick once the hands have stopped does. The way back doesn't shove.
        rig.stroke(left: [0.05, 0, 0], right: [0.05, 0, 0], frames: 11, returnFrames: 0, rightBend: { $0 >= 5 ? 24 : 0 })
        precondition(rig.shoves.count == 1 && rig.shoves[0].x > 0 && abs(rig.shoves[0].y) < 0.3 * rig.shoves[0].x)
        precondition(rig.flips.isEmpty, "Flip from the shoving hand: \(rig.flips)")
        for _ in 0..<10 { rig.hands([0.05, 0, 0], [0.05, 0, 0]) }
        rig.hands([0.05, 0, 0], [0.05, 0, 0], rightBend: 24)
        precondition(rig.flips.first == .flipper(.right, pressed: true), "No flip after the shove: \(rig.flips)")
        for step in 1...30 {
            let back = SIMD3<Float>(0.05 * (1 - ShoveRig.minimumJerk(Float(step) / 30)), 0, 0)
            rig.hands(back, back)
        }
        rig.still(25)
        let firm = simd_length(rig.shoves[0])
        // Recorded firm shoves moved each hand at 1.5 to 3.6 m/s. This one peaks near
        // 0.8 m/s per hand, so it lands at about two thirds of a strong nudge.
        precondition((3.5...6.0).contains(firm), "Medium shove strength \(firm)")
        // Forward and back with both hands.
        rig.stroke(left: [0, 0, -0.05], right: [0, 0, -0.05], frames: 11)
        precondition(rig.shoves.count == 2 && rig.shoves[1].y < 0 && abs(rig.shoves[1].x) < 0.3 * -rig.shoves[1].y)
        rig.stroke(left: [0, 0, 0.04], right: [0, 0, 0.04], frames: 11)
        precondition(rig.shoves.count == 3 && rig.shoves[2].y > 0)

        // One-hand slaps inward, from light to hard, have proportional strength.
        var slaps: [Float] = []
        for distance: Float in [0.03, 0.05, 0.08] {
            let count = rig.shoves.count
            rig.stroke(left: [distance, 0, 0], frames: 9)
            precondition(rig.shoves.count == count + 1 && rig.shoves.last!.x > 0, "Left slap \(distance) m: \(rig.shoves)")
            slaps.append(simd_length(rig.shoves.last!))
        }
        precondition(slaps[0] < slaps[1] && slaps[1] < slaps[2] && slaps[2] > 2.5 * slaps[0], "Slaps \(slaps)")
        let count = rig.shoves.count
        rig.stroke(right: [-0.04, 0, 0], frames: 9)
        precondition(rig.shoves.count == count + 1 && rig.shoves.last!.x < 0)
        // A lone hand pulling out or back is letting go, not a shove.
        rig.stroke(left: [-0.05, 0, 0], frames: 9)
        rig.stroke(right: [0, 0, 0.05], frames: 9)
        precondition(rig.shoves.count == count + 1, "Letting go shoved: \(rig.shoves)")

        // Arm translation with no wrist bend never flips, even when the hand
        // lags the arm by a few degrees at the start and overruns at the stop.
        let flipsBefore = rig.flips.count
        for step in 1...11 {
            let s = ShoveRig.minimumJerk(Float(step) / 11)
            let lag: Float = step < 4 ? -4 : (step < 9 ? 0 : 6)
            rig.hands([0.06 * s, 0, 0], [0.06 * s, 0, 0], leftBend: lag, rightBend: -lag)
        }
        rig.still(30)
        precondition(rig.flips.count == flipsBefore, "Arm translation flipped: \(rig.flips.dropFirst(flipsBefore))")
        print(String(format: "Shoves passed: repositioning ignored, two-hand shove %.1f m/s2 with the shoving hand's overrun ignored and a flick after it, return ignored, forward and back, slaps %.1f/%.1f/%.1f m/s2, letting go ignored, arm translation no flip",
                     firm, slaps[0], slaps[1], slaps[2]))
    }

    static func checkFlipperHolds() {
        var controls = CabinetHandControls(layout: CabinetControlsLayout(usesWristGestures: true))
        var time = 0.0
        var events: [CabinetInput] = []
        func feed(_ degrees: Float?, arm: Bool = true, after delay: Double = 0.011) {
            time += delay
            let sample = degrees.map { degrees -> CabinetHandSample in
                let angle = degrees * .pi / 180
                return .init(fingerDirection: [-sin(angle), 0, -cos(angle)], forearmDirection: arm ? [0, 0, -1] : nil)
            }
            events += controls.update(.right, sample: sample, at: time)
            events += controls.expire(at: time)
        }
        feed(0); feed(0); feed(12); feed(22)
        precondition(events == [.flipper(.right, pressed: true)])
        // Five seconds of holding with ±2 degree jitter, single 6 degree dips,
        // the forearm dropping out and back, and a 200 ms tracking gap.
        var seed: UInt32 = 7
        for frame in 0..<450 {
            seed = seed &* 1_103_515_245 &+ 12_345
            var angle = 22 + Float(Int(seed >> 16) % 5 - 2)
            if frame % 60 == 30 { angle = 16 }
            switch frame {
            case 100..<104: feed(angle, arm: false)
            case 200: feed(nil, after: 0.2)
            default: feed(angle)
            }
        }
        precondition(events == [.flipper(.right, pressed: true)], "Hold dropped: \(events)")
        precondition(controls.takeNotes().isEmpty)
        // Relaxing releases within two samples.
        feed(18); feed(12)
        precondition(events == [.flipper(.right, pressed: true), .flipper(.right, pressed: false)])
        // A quick re-flick after the release still presses.
        feed(13); feed(24)
        precondition(events.last == .flipper(.right, pressed: true))
        // Losing the hand for longer than 250 ms drops the hold and notes it.
        feed(nil, after: 0.3)
        precondition(events.last == .flipper(.right, pressed: false))
        let dropNotes = controls.takeNotes()
        precondition(dropNotes.count == 1, "\(dropNotes) \(events)")
        // A glitch that releases while the hand stays bent is noted as a drop.
        feed(0); feed(0); feed(12); feed(22)
        for _ in 0..<20 { feed(22) }
        feed(10)
        for _ in 0..<15 { feed(22) }
        let glitchNotes = controls.takeNotes()
        precondition(glitchNotes.count == 1 && glitchNotes[0].contains("dropped while bent"), "\(glitchNotes)")
        print("Flipper holds passed: five-second hold through jitter, dips, forearm loss and a 200 ms gap, fast release, re-flick and noted drops")
    }

    /// Replays recorded takes through the recognizers and prints what they decide.
    static func replay(_ paths: [String]) {
        var files: [URL] = []
        for path in paths {
            let url = URL(filePath: path)
            if let names = try? FileManager.default.contentsOfDirectory(atPath: path) {
                files += names.filter { $0.hasSuffix(".json") }.sorted().map { url.appending(path: $0) }
            } else {
                files.append(url)
            }
        }
        for file in files {
            guard let data = try? Data(contentsOf: file),
                  let take = try? JSONDecoder().decode(CabinetHandRecording.self, from: data) else {
                print("\(file.lastPathComponent): not a hand recording")
                continue
            }
            var controls = CabinetHandControls(layout: take.layout)
            let samples = take.decoded
            var lines: [String] = []
            for sample in samples {
                let hand = sample.frame.map { CabinetHandSample(sample.side, frame: $0, layout: take.layout) }
                let events = controls.update(sample.side, sample: hand, at: sample.time) + controls.expire(at: sample.time)
                lines += events.map { String(format: "%6.0f ms  ", sample.time * 1000) + CabinetHandRecording.describe($0) }
                lines += controls.takeNotes().map { String(format: "%6.0f ms  ", sample.time * 1000) + $0 }
            }
            let tracked = samples.filter { $0.frame != nil }.count
            print("\(take.take.title) (build \(take.build), \(samples.count) samples, \(tracked) tracked)")
            lines.forEach { print("  " + $0) }
            if !take.events.isEmpty { print("  live: " + take.events.joined(separator: "; ")) }
        }
    }

    /// Replays the build 30 headset takes and checks each against what its label asks.
    /// Takes where ARKit lost the hands (both slap takes and Flip During Shoves) are
    /// listed but not checked.
    static func checkRecordings(_ folder: String) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder))?.filter { $0.hasSuffix(".json") }.sorted() ?? []
        precondition(!names.isEmpty, "No recordings in \(folder)")
        let strong = CabinetHandControls.Shove.strongNudge
        var medians: [HandTake: Float] = [:]
        for name in names {
            let data = try! Data(contentsOf: URL(filePath: folder).appending(path: name))
            let take = try! JSONDecoder().decode(CabinetHandRecording.self, from: data)
            var controls = CabinetHandControls(layout: take.layout)
            var shoves: [SIMD2<Float>] = []
            var downAt: [CabinetHandSide: Double] = [:]
            var presses: [(side: CabinetHandSide, length: Double)] = []
            var bentDrops = 0
            for sample in take.decoded {
                let hand = sample.frame.map { CabinetHandSample(sample.side, frame: $0, layout: take.layout) }
                for event in controls.update(sample.side, sample: hand, at: sample.time) + controls.expire(at: sample.time) {
                    switch event {
                    case let .shove(acceleration, update):
                        if update, !shoves.isEmpty { shoves[shoves.count - 1] = acceleration } else { shoves.append(acceleration) }
                    case let .flipper(side, pressed):
                        if pressed { downAt[side] = sample.time } else if let start = downAt.removeValue(forKey: side) {
                            presses.append((side, sample.time - start))
                        }
                    default: break
                    }
                }
                bentDrops += controls.takeNotes().filter { $0.contains("dropped while bent") }.count
            }
            let end = take.decoded.last?.time ?? 0
            for (side, start) in downAt { presses.append((side, end - start)) }
            let strengths = shoves.map { simd_length($0) / strong }.sorted()
            let median = strengths.isEmpty ? 0 : strengths[strengths.count / 2]
            var verdict = "checked"
            func expect(_ condition: Bool, _ message: String) {
                precondition(condition, "\(take.take.title): \(message)")
            }
            switch take.take {
            case .rest, .reposition, .quickFlips, .holdLeftFlipper, .holdRightFlipper, .thumbTuck, .pinch:
                expect(shoves.isEmpty, "\(shoves.count) shoves")
                if take.take == .rest { expect(presses.isEmpty, "\(presses.count) flips at rest") }
                if take.take == .holdLeftFlipper || take.take == .holdRightFlipper {
                    let side: CabinetHandSide = take.take == .holdLeftFlipper ? .left : .right
                    let longest = presses.filter { $0.side == side }.map(\.length).max() ?? 0
                    expect(longest >= 3.5, String(format: "longest hold %.2f s", longest))
                    expect(bentDrops == 0, "\(bentDrops) holds dropped while bent")
                }
                if take.take == .quickFlips {
                    let lengths = presses.map(\.length).sorted()
                    expect(lengths.count >= 8 && lengths[lengths.count / 2] <= 0.15,
                           "\(lengths.count) flips, median \(lengths.isEmpty ? 0 : lengths[lengths.count / 2]) s")
                    expect(bentDrops == 0, "\(bentDrops) holds dropped while bent")
                }
            case .lightShoveLeft, .firmShoveLeft, .lightShoveRight, .firmShoveRight, .lightShoveForward, .firmShoveForward:
                let labelled = shoves.filter { shove in
                    switch take.take {
                    case .lightShoveLeft, .firmShoveLeft: shove.x < 0 && abs(shove.x) > abs(shove.y)
                    case .lightShoveRight, .firmShoveRight: shove.x > 0 && abs(shove.x) > abs(shove.y)
                    default: shove.y < 0 && abs(shove.y) > abs(shove.x)
                    }
                }
                expect(labelled.count >= 3 && labelled.count * 4 >= shoves.count * 3, "\(labelled.count) of \(shoves.count) shoves in the labelled direction")
                expect(presses.isEmpty, "\(presses.count) flips while shoving")
                medians[take.take] = median
            default:
                verdict = "not checked, the hands were mostly out of tracking"
            }
            print(String(format: "  %@: %d shoves (median %.0f%% of a strong nudge), %d flips, %d dropped while bent, %@",
                         take.take.title, shoves.count, median * 100, presses.count, bentDrops, verdict))
        }
        for (light, firm) in [(HandTake.lightShoveLeft, HandTake.firmShoveLeft), (.lightShoveRight, .firmShoveRight),
                              (.lightShoveForward, .firmShoveForward)] {
            guard let lightMedian = medians[light], let firmMedian = medians[firm] else { continue }
            precondition(lightMedian < firmMedian && (0.85...1.35).contains(firmMedian),
                         "\(firm.title) median \(firmMedian) against \(light.title) \(lightMedian)")
        }
        print("Recordings passed: no shoves at rest, moving around, flipping or plunging; shoves in each labelled direction with light below firm and firm near a strong nudge; no flips while shoving; holds unbroken; quick flips release promptly")
    }
}
