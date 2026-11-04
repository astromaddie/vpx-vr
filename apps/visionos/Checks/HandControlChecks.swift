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
        checkFistNudges()
        checkPlacement()
        checkRoomGrab()
        checkWristMenu()
        checkPlunger()
    }

    static func checkPlunger() {
        let handle = SIMD3<Float>(0.24, -0.095, 0.040)
        var preview = CabinetHandControls()
        var player = CabinetHandControls(layout: CabinetControlsLayout(plunger: handle))
        func grip(_ depth: Float, gap: Float = 0.02, tipDrift: Float = 0) -> CabinetHandSample {
            .init(palm: handle + [0, 0, depth + 0.05],
                  index: handle + [gap / 2, 0, depth + tipDrift],
                  thumb: handle + [-gap / 2, 0, depth + tipDrift])
        }
        precondition(preview.update(.right, sample: grip(0), at: 0).isEmpty)
        precondition(player.update(.right, sample: grip(0.10), at: 0).isEmpty)
        precondition(player.update(.right, sample: grip(0), at: 0.016) == [.pullPlunger(0)])
        precondition(player.update(.left, sample: grip(0), at: 0.02).isEmpty)
        let halfDepth = CabinetHandControls.plungerStroke / 2
        let half = player.update(.right, sample: grip(halfDepth), at: 0.032)
        guard half.count == 1, case let .pullPlunger(pull) = half[0] else { preconditionFailure("Missing half pull") }
        precondition(abs(pull - 0.5) < 0.01)
        precondition(player.update(.right, sample: grip(halfDepth, tipDrift: -0.024), at: 0.048).isEmpty)
        precondition(player.update(.right, sample: grip(0, gap: 0.041), at: 0.064).isEmpty)
        var occluded = grip(0, gap: 0.041)
        occluded.thumb = nil
        precondition(player.update(.right, sample: occluded, at: 0.080).isEmpty)
        precondition(player.update(.right, sample: grip(0, gap: 0.055), at: 0.096) == [.releasePlunger(pull)])
        precondition(player.update(.right, sample: grip(0, gap: 0.055), at: 0.112).isEmpty)
        precondition(player.update(.right, sample: grip(0), at: 0.128) == [.pullPlunger(0)])
        precondition(player.update(.right, sample: grip(0.10), at: 0.144) == [.pullPlunger(1)])
        let eased = player.update(.right, sample: grip(halfDepth), at: 0.160)
        precondition(eased == half)
        precondition(player.expire(at: 0.30) == [.releasePlunger(pull)])
        precondition(player.expire(at: 0.32).isEmpty)

        // The M2 stopped reporting a usable grip before an open pinch was seen.
        precondition(player.update(.right, sample: grip(0), at: 0.34) == [.pullPlunger(0)])
        precondition(player.update(.right, sample: grip(0.10), at: 0.36) == [.pullPlunger(1)])
        precondition(player.update(.right, sample: nil, at: 0.38).isEmpty)
        precondition(player.expire(at: 0.46).isEmpty)
        precondition(player.expire(at: 0.49) == [.releasePlunger(1)])
        precondition(player.update(.right, sample: nil, at: 0.51).isEmpty)

        // An occluded tip can come back before the grace period expires.
        precondition(player.update(.right, sample: grip(0), at: 0.54) == [.pullPlunger(0)])
        precondition(player.update(.right, sample: grip(0.10), at: 0.56) == [.pullPlunger(1)])
        precondition(player.update(.right, sample: occluded, at: 0.59).isEmpty)
        precondition(player.update(.right, sample: grip(0.10), at: 0.64).isEmpty)
        precondition(player.expire(at: 0.70).isEmpty)
        precondition(player.reset() == [.cancelPlunger])
        precondition(player.expire(at: 0.85).isEmpty)

        // A small accidental movement followed by loss does not launch.
        precondition(player.update(.right, sample: grip(0), at: 0.90) == [.pullPlunger(0)])
        precondition(player.update(.right, sample: grip(0.003), at: 0.92).count == 1)
        precondition(player.expire(at: 1.05) == [.cancelPlunger])

        // Leaving the grip corridor after pulling also lets the spring go.
        precondition(player.update(.right, sample: grip(0), at: 1.10) == [.pullPlunger(0)])
        precondition(player.update(.right, sample: grip(0.10), at: 1.12) == [.pullPlunger(1)])
        var away = grip(0.10)
        away.thumb = away.thumb.map { $0 + [0.15, 0, 0] }
        away.index = away.index.map { $0 + [0.15, 0, 0] }
        precondition(player.update(.right, sample: away, at: 1.14).isEmpty)
        precondition(player.update(.right, sample: away, at: 1.26) == [.releasePlunger(1)])
        precondition(player.expire(at: 1.40).isEmpty)
        print("Plunger passed: visible release, lost hand, recovered fingertip, off-axis release, and lifecycle cancellation")
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
                                           forearmDirection: arm, fist: fist)
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
        precondition(feed(.right, [-0.18, 0, -1], fist: true) == [.flipper(.right, pressed: false)])
        precondition(controls.reset().isEmpty)
        precondition(feed(.left, straight, arm: nil).isEmpty)
        precondition(feed(.left, [0.18, 0, -1], arm: nil) == [.flipper(.left, pressed: true)])
        precondition(controls.expire(at: time + 0.13) == [.flipper(.left, pressed: false)])

        let knob: SIMD3<Float> = [0.24, -0.15, 0.109]
        controls = CabinetHandControls(layout: CabinetControlsLayout(plunger: knob, usesWristGestures: true))
        func grip(_ pull: Float, direction: SIMD3<Float>) -> [CabinetInput] {
            time += 0.016
            return controls.update(.right, sample: .init(palm: knob + [0, 0, 0.05 + pull],
                                                         index: knob + [0.01, 0, pull],
                                                         fingerDirection: direction, thumb: knob + [-0.01, 0, pull],
                                                         forearmDirection: straight), at: time)
        }
        precondition(grip(0, direction: straight) == [.pullPlunger(0)])
        precondition(grip(0.07, direction: [-0.20, 0, -1]) == [.pullPlunger(1)])
        precondition(controls.reset() == [.cancelPlunger])
        print("Gesture flippers passed: distance-independent bends, palm roll, arm motion rejection, independent holds and forearm fallback")
    }

    static func checkFistNudges() {
        let knuckle: SIMD3<Float> = [0, 0, 0]
        let bend: SIMD3<Float> = [0, 0, -0.03]
        precondition(CabinetHandSample.fingerIsCurled(knuckle: knuckle, bend: bend, next: [0, -0.024, -0.028]))
        precondition(!CabinetHandSample.fingerIsCurled(knuckle: knuckle, bend: bend, next: [0, 0, -0.054]))
        precondition(!CabinetHandSample.fingerIsCurled(knuckle: knuckle, bend: bend, next: nil))

        let directions: [(CabinetNudgeDirection, SIMD3<Float>)] = [
            (.left, [-0.085, 0, 0]), (.right, [0.085, 0, 0]), (.up, [0, 0.085, 0]), (.down, [0, -0.085, 0])
        ]
        for (direction, offset) in directions {
            var controls = CabinetHandControls(layout: CabinetControlsLayout(usesWristGestures: true))
            var time = 0.0
            func pair(_ left: SIMD3<Float> = .zero, _ right: SIMD3<Float> = .zero, rightClosed: Bool = true) -> [CabinetInput] {
                time += 0.016
                let first = controls.update(.left, sample: .init(palm: [-0.4, 0, 0.3] + left, fist: true), at: time)
                time += 0.016
                return first + controls.update(.right, sample: .init(palm: [0.4, 0, 0.3] + right, fist: rightClosed), at: time)
            }
            for _ in 0..<9 { precondition(pair(offset, offset, rightClosed: false).isEmpty) }
            for _ in 0..<9 { precondition(pair().isEmpty) }
            precondition(pair(offset, -offset).isEmpty)
            precondition(pair(offset * 2, .zero).isEmpty)
            precondition(pair(offset, offset) == [.nudge(direction)])
            for _ in 0..<16 { precondition(pair(offset, offset).isEmpty) }
            precondition(pair().isEmpty)
            precondition(pair(offset, offset) == [.nudge(direction)])
            precondition(controls.expire(at: time + 0.15).isEmpty)
            time += 0.15
            precondition(pair().isEmpty)
            precondition(pair(offset, offset).isEmpty)
        }
        print("Nudges passed: closed-finger evidence, two-fist dwell, shared movement, four directions, re-arm and tracking loss")
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
