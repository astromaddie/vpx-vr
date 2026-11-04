// license:GPLv3+

import simd

/// Metres in cabinet space: x to the player's right, y up, z toward the player.
/// The origin is at the top centre of the front panel.
struct CabinetControlsLayout {
    static let coinFaceSize = SIMD2<Float>(0.080, 0.064)
    // The default preview uses Time Machine's 1,000 by 1,910 VP units.
    var playfieldWidth: Float = 0.53975
    var playfieldLength: Float = 1.0309225

    // VPX's lockbar calculation leaves 2 1/4 inches around the playfield.
    var width: Float { playfieldWidth + 0.05715 }
    var depth: Float { playfieldLength + 0.09 }
    var start: SIMD3<Float> { SIMD3(-width * 0.30, -0.13, 0.025) }
    var coin: SIMD3<Float> { SIMD3(width * 0.22, -0.19, 0.025) }

    func flipper(_ side: CabinetHandSide) -> SIMD3<Float> {
        SIMD3(side.sign * width / 2, -0.065, -0.055)
    }
}

enum CabinetHandSide: CaseIterable {
    case left, right

    var sign: Float { self == .left ? -1 : 1 }
}

struct CabinetHandSample {
    var palm: SIMD3<Float>?
    var index: SIMD3<Float>?
}

enum CabinetAction: Hashable {
    case leftFlipper, rightFlipper, addCredit, start
}

enum CabinetInput: Equatable {
    case flipper(CabinetHandSide, pressed: Bool)
    case insertCoin, pressStart

    var action: CabinetAction {
        switch self {
        case .flipper(.left, _): .leftFlipper
        case .flipper(.right, _): .rightFlipper
        case .insertCoin: .addCredit
        case .pressStart: .start
        }
    }
}

struct CabinetHandControls {
    static let trackingTimeout = 0.12
    let layout: CabinetControlsLayout
    private var left = Hand()
    private var right = Hand()

    init(layout: CabinetControlsLayout = .init()) {
        self.layout = layout
    }

    mutating func update(_ side: CabinetHandSide, sample: CabinetHandSample?, at time: Double) -> [CabinetInput] {
        switch side {
        case .left: left.update(.left, sample: sample, layout: layout, time: time)
        case .right: right.update(.right, sample: sample, layout: layout, time: time)
        }
    }

    mutating func expire(at time: Double) -> [CabinetInput] {
        left.expire(.left, time: time) + right.expire(.right, time: time)
    }

    mutating func reset() -> [CabinetInput] {
        left.reset(.left) + right.reset(.right)
    }

    private struct Hand {
        private var lastSample: Double?
        private var flipperArmed = false
        private var flipperDown = false
        private var startArmed = false
        private var coinArmed = false

        mutating func reset(_ side: CabinetHandSide) -> [CabinetInput] {
            let events: [CabinetInput] = flipperDown ? [.flipper(side, pressed: false)] : []
            self = Hand()
            return events
        }

        mutating func expire(_ side: CabinetHandSide, time: Double) -> [CabinetInput] {
            guard let lastSample, time - lastSample > CabinetHandControls.trackingTimeout else { return [] }
            return reset(side)
        }

        mutating func update(
            _ side: CabinetHandSide,
            sample: CabinetHandSample?,
            layout: CabinetControlsLayout,
            time: Double
        ) -> [CabinetInput] {
            guard let sample else { return reset(side) }
            var events = expire(side, time: time)
            lastSample = time
            let wasDown = flipperDown
            updateFlipper(sample.palm, side: side, button: layout.flipper(side))
            if flipperDown != wasDown {
                events.append(.flipper(side, pressed: flipperDown))
            }

            if Self.poke(sample.index, at: layout.start, armed: &startArmed, contains: {
                simd_length_squared($0) <= 0.034 * 0.034
            }) {
                events.append(.pressStart)
            }
            if Self.poke(sample.index, at: layout.coin, armed: &coinArmed, contains: {
                let halfSize = CabinetControlsLayout.coinFaceSize / 2
                return abs($0.x) <= halfSize.x && abs($0.y) <= halfSize.y
            }) {
                events.append(.insertCoin)
            }
            return events
        }

        private mutating func updateFlipper(_ palm: SIMD3<Float>?, side: CabinetHandSide, button: SIMD3<Float>) {
            if let offset = palm.map({ $0 - button }) {
                let outside = offset.x * side.sign
                // Give a held gesture extra room so small tracking changes do not release a trap.
                let margin: Float = flipperDown ? 0.020 : 0
                if abs(offset.y) <= 0.065 + margin, abs(offset.z) <= 0.10 + margin,
                   (-0.085 ... 0.13).contains(outside) {
                    if outside >= 0.018 {
                        flipperArmed = true
                        flipperDown = false
                    } else if flipperArmed && outside <= -0.012 {
                        flipperDown = true
                    }
                    return
                }
            }
            flipperArmed = false
            flipperDown = false
        }

        private static func poke(
            _ tip: SIMD3<Float>?,
            at button: SIMD3<Float>,
            armed: inout Bool,
            contains: (SIMD2<Float>) -> Bool
        ) -> Bool {
            guard let offset = tip.map({ $0 - button }),
                  contains(SIMD2(offset.x, offset.y)),
                  (-0.05 ... 0.085).contains(offset.z) else {
                armed = false
                return false
            }
            if offset.z >= 0.025 {
                armed = true
            } else if offset.z <= 0.003 && armed {
                armed = false
                return true
            }
            return false
        }
    }
}
