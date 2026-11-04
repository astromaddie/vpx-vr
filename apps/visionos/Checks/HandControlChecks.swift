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
        checkPlacement()
        checkRoomGrab()
        checkWristMenu()
        checkPlunger()
    }

    static func checkPlunger() {
        let handle = SIMD3<Float>(0.24, -0.095, 0.040)
        var preview = CabinetHandControls()
        var player = CabinetHandControls(layout: CabinetControlsLayout(plunger: handle))
        func grip(_ depth: Float, gap: Float = 0.02) -> CabinetHandSample {
            .init(index: handle + [gap / 2, 0, depth], thumb: handle + [-gap / 2, 0, depth])
        }
        precondition(preview.update(.right, sample: grip(0), at: 0).isEmpty)
        precondition(player.update(.right, sample: grip(0.10), at: 0).isEmpty)
        precondition(player.update(.right, sample: grip(0), at: 0.016) == [.pullPlunger(0)])
        precondition(player.update(.left, sample: grip(0), at: 0.02).isEmpty)
        let half = player.update(.right, sample: grip(0.0381), at: 0.032)
        guard half.count == 1, case let .pullPlunger(pull) = half[0] else { preconditionFailure("Missing half pull") }
        precondition(abs(pull - 0.5) < 0.01)
        precondition(player.update(.right, sample: grip(0.0381, gap: 0.05), at: 0.048) == [.releasePlunger(pull)])
        precondition(player.update(.right, sample: grip(0.0381, gap: 0.05), at: 0.064).isEmpty)
        precondition(player.update(.right, sample: grip(0), at: 0.08) == [.pullPlunger(0)])
        precondition(player.update(.right, sample: grip(0.1), at: 0.096) == [.pullPlunger(1)])
        precondition(player.expire(at: 0.23) == [.cancelPlunger])
        precondition(player.update(.right, sample: grip(0.1, gap: 0.05), at: 0.24).isEmpty)
        print("Plunger passed: pull distance, one release, single grip, tracking loss cancels")
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
