// license:GPLv3+

import simd

@main
struct HandControlChecks {
    static func main() {
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
        checkFistNudges()
        checkOccludedFistInputs()
        checkPlacement()
        checkRoomGrab()
        checkWristMenu()
        checkPlunger()
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
        precondition(feed(.left, straight) == [.flipper(.left, pressed: false)])
        precondition(feed(.right, [-0.18, 0, -1], fist: true).isEmpty)
        precondition(feed(.right, straight, fist: true) == [.flipper(.right, pressed: false)])
        precondition(feed(.right, [-0.18, 0, -1], fist: true) == [.flipper(.right, pressed: true)])
        precondition(feed(.right, straight, fist: true) == [.flipper(.right, pressed: false)])
        precondition(controls.reset().isEmpty)
        precondition(feed(.left, straight, arm: nil).isEmpty)
        precondition(feed(.left, [0.18, 0, -1], arm: nil) == [.flipper(.left, pressed: true)])
        precondition(controls.expire(at: time + 0.13) == [.flipper(.left, pressed: false)])

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
        precondition(feed(17).isEmpty)
        precondition(feed(15) == [.flipper(.right, pressed: false)])
        precondition(feed(24) == [.flipper(.right, pressed: true)])
        precondition(feed(32).isEmpty)
        precondition(feed(28).isEmpty)
        precondition(feed(26) == [.flipper(.right, pressed: false)])
        precondition(feed(35) == [.flipper(.right, pressed: true)])
        precondition(controls.expire(at: time + 0.13) == [.flipper(.right, pressed: false)])

        // Speed alone is insufficient for small jumps.
        time += 0.13
        precondition(feed(-4).isEmpty)
        precondition(feed(1, after: 0.01).isEmpty)
        precondition(feed(-9).isEmpty)
        precondition(feed(4) == [.flipper(.right, pressed: true)])
        precondition(feed(0).isEmpty)
        precondition(feed(-2) == [.flipper(.right, pressed: false)])

        // Both fists beside the cabinet suppress an otherwise valid flick.
        _ = controls.reset()
        let leftRail = layout.flipper(.left) + [-0.08, 0.06, -0.08]
        let rightRail = layout.flipper(.right) + [0.08, 0.06, -0.08]
        precondition(controls.update(.left, sample: .init(palm: leftRail, pose: .fist), at: 2.0).isEmpty)
        precondition(controls.update(.right, sample: .init(palm: rightRail, fingerDirection: [0, 0, -1],
                                                         pose: .fist), at: 2.01).isEmpty)
        precondition(controls.update(.left, sample: .init(palm: leftRail, pose: .fist), at: 2.02).isEmpty)
        precondition(controls.update(.right, sample: .init(palm: rightRail, fingerDirection: [-0.2, 0, -1],
                                                         pose: .fist), at: 2.03).isEmpty)
        // A fist slightly ahead of the rail blocks the paired flick
        // without allowing an off-rail nudge.
        _ = controls.reset()
        let justAhead = SIMD3(leftRail.x, leftRail.y, 0.055)
        precondition(controls.update(.left, sample: .init(palm: justAhead, pose: .fist), at: 3.0).isEmpty)
        precondition(controls.update(.right, sample: .init(palm: rightRail, fingerDirection: [0, 0, -1],
                                                         pose: .fist), at: 3.01).isEmpty)
        precondition(controls.nudgePhase == "waitingForFists")
        precondition(controls.update(.right, sample: .init(palm: rightRail, fingerDirection: [-0.2, 0, -1],
                                                         pose: .fist), at: 3.03).isEmpty)
        precondition(controls.update(.left, sample: .init(palm: justAhead, pose: .open), at: 3.04).isEmpty)
        precondition(controls.update(.right, sample: .init(palm: rightRail, fingerDirection: [0, 0, -1],
                                                         pose: .fist), at: 3.05).isEmpty)
        precondition(controls.update(.right, sample: .init(palm: rightRail, fingerDirection: [-0.2, 0, -1],
                                                         pose: .fist), at: 3.07) == [.flipper(.right, pressed: true)])
        print("Wrist flick timing passed: slow drift, angular speed and bend, sustained hold, backswing release and nudge priority")
    }

    static func checkFistNudges() {
        let wrist: SIMD3<Float> = [0, 0, 0]
        let knuckle: SIMD3<Float> = [0, 0, -0.06]
        func joint(_ point: SIMD3<Float>) -> CabinetHandJoint { .init(point: point, isTracked: true) }
        let curled = CabinetHandPose.Finger(knuckle: joint(knuckle), bend: joint([0, -0.025, -0.065]), next: nil)
        let open = CabinetHandPose.Finger(knuckle: joint(knuckle), bend: joint([0, 0, -0.09]), next: joint([0, 0, -0.114]))
        let missing = CabinetHandPose.Finger(knuckle: joint(knuckle), bend: nil, next: nil)
        let curledAtMiddle = CabinetHandPose.Finger(knuckle: joint(knuckle), bend: joint([0, 0, -0.09]), next: joint([0, -0.025, -0.09]))
        precondition(CabinetHandPose.classify(wrist: wrist, fingers: [curled, curledAtMiddle, missing, missing]) == .looseFist)
        precondition(CabinetHandPose.classify(wrist: wrist, fingers: [open, open, missing, missing]) == .open)
        precondition(CabinetHandPose.classify(wrist: wrist, fingers: [open, open, open, curled]) == .open)
        precondition(CabinetHandPose.classify(wrist: wrist, fingers: [curled, open, open, missing]) == .unknown)
        precondition(CabinetHandPose.classify(wrist: nil, fingers: [curled, missing, missing, missing]) == .unknown)

        let directions: [(CabinetNudgeDirection, SIMD3<Float>)] = [
            (.left, [-0.032, 0, 0]), (.right, [0.032, 0, 0]), (.up, [0, 0.032, 0]), (.down, [0, -0.032, 0]),
            (.up, [0, 0, -0.032]), (.down, [0, 0, 0.032])
        ]
        for (direction, offset) in directions {
            let layout = CabinetControlsLayout(usesWristGestures: true)
            var controls = CabinetHandControls(layout: layout)
            let leftRail = layout.flipper(.left) + [-0.08, 0.06, -0.08]
            let rightRail = layout.flipper(.right) + [0.08, 0.06, -0.08]
            var time = 0.0
            func pair(_ left: SIMD3<Float> = .zero, _ right: SIMD3<Float> = .zero, rightPose: CabinetHandPose = .fist) -> [CabinetInput] {
                time += 0.016
                let first = controls.update(.left, sample: .init(palm: leftRail + left, pose: .fist), at: time)
                time += 0.016
                return first + controls.update(.right, sample: .init(palm: rightRail + right, pose: rightPose), at: time)
            }
            for _ in 0..<9 { precondition(pair(offset, offset, rightPose: .open).isEmpty) }
            for _ in 0..<9 { precondition(pair(offset, offset, rightPose: .looseFist).isEmpty) }
            // Arm on the first firm pair. The very next pair can nudge.
            precondition(pair().isEmpty)
            let armedAt = time
            precondition(pair(offset, offset) == [.nudge(direction)])
            precondition(time - armedAt < 0.04)
            precondition(controls.nudgePhase == "latched")
            // The next shove starts from a new resting position.
            for _ in 0..<4 { precondition(pair(offset, offset).isEmpty) }
            precondition(controls.nudgePhase == "armed")
            precondition(pair(offset * 2, offset * 2) == [.nudge(direction)])

            precondition(controls.reset().isEmpty)
            precondition(pair().isEmpty)
            precondition(pair(offset * 0.8, offset * 0.8).isEmpty)
            precondition(pair(offset * 1.6, offset * 0.4).isEmpty)
            precondition(pair(offset, -offset).isEmpty)
            precondition(pair(offset * 2, .zero).isEmpty)
            precondition(controls.reset().isEmpty)
            precondition(pair().isEmpty)
            precondition(pair(offset, offset, rightPose: .unknown) == [.nudge(direction)])
            precondition(controls.expire(at: time + 0.15).isEmpty)
            time += 0.15
            precondition(pair().isEmpty)
            precondition(pair(offset, offset) == [.nudge(direction)])
        }
        let knob: SIMD3<Float> = [0.24, -0.15, 0.109]
        var controls = CabinetHandControls(layout: CabinetControlsLayout(plunger: knob, usesWristGestures: true))
        // The wider grab area still works. An opposite fist arriving
        // during the first millimetres cannot steal a palm-down grip.
        let grab = knob + [0.11, 0, 0.16]
        let right = CabinetHandSample(palm: grab, plungerPose: plungerPose())
        let left = CabinetHandSample(palm: [-0.3, -0.15, 0.109], pose: .fist)
        precondition(controls.update(.right, sample: right, at: 0.01) == [.pullPlunger(0)])
        precondition(controls.update(.left, sample: left, at: 0.02).isEmpty)
        let pulled = CabinetHandSample(palm: grab + [0, 0, 0.07], plungerPose: plungerPose())
        precondition(controls.update(.right, sample: pulled, at: 0.04) == [.pullPlunger(1)])
        precondition(controls.update(.left, sample: left, at: 0.06).isEmpty)
        precondition(controls.update(.right, sample: .init(plungerPose: plungerPose(thumbUntucked: true)), at: 0.08) == [.releasePlunger(1)])
        print("Nudges passed: next paired sample on all axes, shared motion, re-arm at a new position, plunger priority")
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

        let left = layout.flipper(.left) + [-0.07, 0.06, -0.08]
        let right = layout.flipper(.right) + [0.07, 0.06, -0.08]
        var time = 0.1
        func pair(_ left: SIMD3<Float>, _ right: SIMD3<Float>) -> [CabinetInput] {
            time += 0.016
            let events = player.update(.left, sample: hand(at: left), at: time)
            time += 0.016
            return events + player.update(.right, sample: hand(at: right), at: time)
        }

        let shove: SIMD3<Float> = [0.032, 0, 0]
        let outOfPosition: [(SIMD3<Float>, SIMD3<Float>)] = [
            (left, right + [0, 0, 0.52]), (right, left),
            (left + [-0.24, 0, 0], right), (left, right + [0, 0.30, 0])
        ]
        for (offLeft, offRight) in outOfPosition {
            for _ in 0..<8 { precondition(pair(offLeft, offRight).isEmpty) }
            precondition(pair(offLeft + shove, offRight + shove).isEmpty)
        }

        precondition(pair(left, right).isEmpty)
        precondition(pair(left + shove * 0.8, right + shove * 0.8).isEmpty)
        precondition(pair(left + shove, right + shove) == [.nudge(.right)])
        precondition(pair(left, right + [0, 0, 0.52]).isEmpty)
        // A shove while the other hand is away stays quiet. Returning to
        // the rail establishes a fresh origin without inheriting the shove.
        precondition(pair(left + shove, right + [0, 0, 0.52]).isEmpty)
        precondition(pair(left + shove, right + shove).isEmpty)
        precondition(pair(left + shove, right + shove).isEmpty)

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
        print("Occluded joints passed: estimated fists, 3.2 cm nudge at the authored side rails, off-rail rejection, and tracked index poke")
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
}
