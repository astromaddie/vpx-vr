// license:GPLv3+

import simd

struct CabinetButtonFace {
    let position: SIMD3<Float>
    let halfSize: SIMD2<Float>

    func contains(_ offset: SIMD2<Float>) -> Bool {
        halfSize.x > 0 && abs(offset.x) <= halfSize.x && abs(offset.y) <= halfSize.y
    }
}

/// Metres in cabinet space: x to the player's right, y up, z toward the player.
/// The origin is at the top centre of the front panel.
struct CabinetControlsLayout {
    static let coinFaceSize = SIMD2<Float>(0.080, 0.064)
    // The default preview uses Time Machine's 1,000 by 1,910 VP units.
    var playfieldWidth: Float = 0.53975
    var playfieldLength: Float = 1.0309225
    var plunger: SIMD3<Float>? = nil
    var startFace: CabinetButtonFace? = nil
    var coinFace: CabinetButtonFace? = nil

    // VPX's lockbar calculation leaves 2 1/4 inches around the playfield.
    var width: Float { playfieldWidth + 0.05715 }
    var depth: Float { playfieldLength + 0.09 }
    var start: SIMD3<Float> { startFace?.position ?? SIMD3(-width * 0.30, -0.13, 0.025) }
    var coin: SIMD3<Float> { coinFace?.position ?? SIMD3(width * 0.22, -0.19, 0.025) }

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
    var fingerDirection: SIMD3<Float>?
    var palmNormal: SIMD3<Float>?
    var thumb: SIMD3<Float>?
}

enum CabinetAction: Hashable {
    case leftFlipper, rightFlipper, addCredit, start, launchBall
}

enum CabinetInput: Equatable {
    case flipper(CabinetHandSide, pressed: Bool)
    case insertCoin, pressStart
    case pullPlunger(Float), releasePlunger(Float), cancelPlunger

    var action: CabinetAction {
        switch self {
        case .flipper(.left, _): .leftFlipper
        case .flipper(.right, _): .rightFlipper
        case .insertCoin: .addCredit
        case .pressStart: .start
        case .pullPlunger, .releasePlunger, .cancelPlunger: .launchBall
        }
    }
}

struct CabinetHandControls {
    static let trackingTimeout = 0.12
    let layout: CabinetControlsLayout
    private var left = Hand()
    private var right = Hand()
    private var plunger = PlungerGrip()

    init(layout: CabinetControlsLayout = .init()) {
        self.layout = layout
    }

    mutating func update(_ side: CabinetHandSide, sample: CabinetHandSample?, at time: Double) -> [CabinetInput] {
        let buttons = switch side {
        case .left: left.update(.left, sample: sample, layout: layout, time: time)
        case .right: right.update(.right, sample: sample, layout: layout, time: time)
        }
        guard let handle = layout.plunger else { return buttons }
        return buttons + plunger.update(side, sample: sample, handle: handle, time: time)
    }

    mutating func expire(at time: Double) -> [CabinetInput] {
        left.expire(.left, time: time) + right.expire(.right, time: time) + plunger.expire(at: time)
    }

    mutating func reset() -> [CabinetInput] {
        left.reset(.left) + right.reset(.right) + plunger.reset()
    }

    private struct PlungerGrip {
        private static let stroke: Float = 0.0762
        private var hand: CabinetHandSide?
        private var grabDepth: Float = 0
        private var pull: Float = 0
        private var lastSample: Double = 0

        mutating func reset() -> [CabinetInput] {
            guard hand != nil else { return [] }
            self = PlungerGrip()
            return [.cancelPlunger]
        }

        mutating func expire(at time: Double) -> [CabinetInput] {
            time - lastSample > CabinetHandControls.trackingTimeout ? reset() : []
        }

        mutating func update(
            _ side: CabinetHandSide, sample: CabinetHandSample?, handle: SIMD3<Float>, time: Double
        ) -> [CabinetInput] {
            let expired = expire(at: time)
            guard hand == nil || hand == side else { return expired }
            guard let thumb = sample?.thumb, let index = sample?.index else { return expired + reset() }
            let gap = simd_distance(thumb, index)
            let center = (thumb + index) * 0.5
            let offset = center - handle
            if hand == nil {
                guard gap <= 0.032, simd_length_squared(offset) <= 0.060 * 0.060 else { return expired }
                hand = side
                grabDepth = center.z
                lastSample = time
                return expired + [.pullPlunger(0)]
            }

            lastSample = time
            if gap >= 0.048 {
                let released = pull
                self = PlungerGrip()
                return released >= 0.04 ? [.releasePlunger(released)] : [.cancelPlunger]
            }
            guard simd_length_squared(SIMD2(offset.x, offset.y)) <= 0.10 * 0.10 else { return reset() }
            let newPull = min(max((center.z - grabDepth) / Self.stroke, 0), 1)
            guard abs(newPull - pull) >= 0.005 else { return [] }
            pull = newPull
            return [.pullPlunger(pull)]
        }
    }

    private struct Hand {
        private var lastSample: Double?
        private var flipperArmed = false
        private var translationDown = false
        private var fingerTurn = WristTurn()
        private var palmTurn = WristTurn()
        private var flipperDown: Bool { translationDown || fingerTurn.isDown || palmTurn.isDown }
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
            updateFlipper(sample, side: side, button: layout.flipper(side))
            if flipperDown != wasDown {
                events.append(.flipper(side, pressed: flipperDown))
            }

            if Self.poke(sample.index, at: layout.start, contactDepth: layout.startFace == nil ? 0.003 : 0.012, armed: &startArmed, contains: {
                layout.startFace?.contains($0) ?? (simd_length_squared($0) <= 0.034 * 0.034)
            }) {
                events.append(.pressStart)
            }
            if Self.poke(sample.index, at: layout.coin, contactDepth: layout.coinFace == nil ? 0.003 : 0.012, armed: &coinArmed, contains: {
                let face = layout.coinFace ?? CabinetButtonFace(position: layout.coin, halfSize: CabinetControlsLayout.coinFaceSize / 2)
                return face.contains($0)
            }) {
                events.append(.insertCoin)
            }
            return events
        }

        private mutating func updateFlipper(_ sample: CabinetHandSample, side: CabinetHandSide, button: SIMD3<Float>) {
            if let offset = sample.palm.map({ $0 - button }) {
                let outside = offset.x * side.sign
                // Give a held gesture extra room so small tracking changes do not release a trap.
                let margin: Float = flipperDown ? 0.020 : 0
                if abs(offset.y) <= 0.065 + margin, abs(offset.z) <= 0.10 + margin,
                   (-0.085 ... 0.13).contains(outside) {
                    if outside >= 0.018 {
                        flipperArmed = true
                        translationDown = false
                    } else if flipperArmed && outside <= -0.012 {
                        translationDown = true
                    }

                    let canArm = outside >= -0.008
                    fingerTurn.update(sample.fingerDirection, inward: -side.sign, canArm: canArm)
                    palmTurn.update(sample.palmNormal, inward: -side.sign, canArm: canArm)
                    return
                }
            }
            flipperArmed = false
            translationDown = false
            fingerTurn = WristTurn()
            palmTurn = WristTurn()
        }

        private struct WristTurn {
            private var neutral: Float?
            private(set) var isDown = false
            private static let pressAngle: Float = 8 * .pi / 180
            private static let releaseAngle: Float = 3 * .pi / 180

            mutating func update(_ direction: SIMD3<Float>?, inward: Float, canArm: Bool) {
                guard let direction, simd_length_squared(direction) > 1e-10 else {
                    self = WristTurn()
                    return
                }

                let angle = atan2(inward * direction.x, simd_length(SIMD2(direction.y, direction.z)))
                guard let neutral else {
                    if canArm { self.neutral = angle }
                    return
                }
                let turn = angle - neutral
                if isDown {
                    if turn <= Self.releaseAngle { isDown = false }
                } else if turn >= Self.pressAngle {
                    isDown = true
                }
            }
        }

        private static func poke(
            _ tip: SIMD3<Float>?,
            at button: SIMD3<Float>,
            contactDepth: Float,
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
            } else if offset.z <= contactDepth && armed {
                armed = false
                return true
            }
            return false
        }
    }
}
