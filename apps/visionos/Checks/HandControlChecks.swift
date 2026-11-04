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
    }
}
