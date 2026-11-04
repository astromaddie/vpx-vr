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
}
