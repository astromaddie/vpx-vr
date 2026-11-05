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
    var leftFlipperCap: SIMD3<Float>? = nil
    var rightFlipperCap: SIMD3<Float>? = nil
    var usesWristGestures = false

    // VPX's lockbar calculation leaves 2 1/4 inches around the playfield.
    var width: Float { playfieldWidth + 0.05715 }
    var depth: Float { playfieldLength + 0.09 }
    var start: SIMD3<Float> { startFace?.position ?? SIMD3(-width * 0.30, -0.13, 0.025) }
    var coin: SIMD3<Float> { coinFace?.position ?? SIMD3(width * 0.22, -0.19, 0.025) }

    func flipperCap(_ side: CabinetHandSide) -> SIMD3<Float>? {
        side == .left ? leftFlipperCap : rightFlipperCap
    }

    func flipper(_ side: CabinetHandSide) -> SIMD3<Float> {
        flipperCap(side) ?? SIMD3(side.sign * width / 2, -0.065, -0.055)
    }
}

enum CabinetHandSide: CaseIterable {
    case left, right

    var sign: Float { self == .left ? -1 : 1 }
}

struct CabinetHandJoint {
    let point: SIMD3<Float>
    let isTracked: Bool

    var estimatedPosition: SIMD3<Float>? {
        point.x.isFinite && point.y.isFinite && point.z.isFinite ? point : nil
    }

    var trackedPosition: SIMD3<Float>? {
        isTracked ? estimatedPosition : nil
    }
}

enum CabinetHandPose {
    case open, looseFist, fist, unknown

    var canGrip: Bool { self == .fist || self == .looseFist }

    struct Finger {
        let knuckle: CabinetHandJoint?
        let bend: CabinetHandJoint?
        let next: CabinetHandJoint?

        func pose(relativeTo wrist: SIMD3<Float>?) -> CabinetHandPose {
            guard let knuckle = knuckle?.estimatedPosition, let bend = bend?.estimatedPosition else { return .unknown }
            let proximal = bend - knuckle
            guard simd_length_squared(proximal) > 1e-8 else { return .unknown }
            let direction = simd_normalize(proximal)
            func alignment(_ bone: SIMD3<Float>?) -> Float? {
                guard let bone, simd_length_squared(bone) > 1e-8 else { return nil }
                return simd_dot(direction, simd_normalize(bone))
            }
            let atKnuckle = alignment(wrist.map { knuckle - $0 })
            let atBend = alignment((next?.estimatedPosition).map { $0 - bend })
            guard atKnuckle != nil || atBend != nil else { return .unknown }
            // A curled finger can hide the outer joint. Its knuckle bend
            // still distinguishes it from an extended finger.
            let strongestBend = min(atKnuckle ?? 1, atBend ?? 1)
            if strongestBend < 0.64 { return .fist }
            if strongestBend > 0.79 { return .open }
            return .unknown
        }
    }

    static func classify(wrist: SIMD3<Float>?, fingers: [Finger]) -> CabinetHandPose {
        var curled = 0
        var straight = 0
        var isPointing = false
        for (index, finger) in fingers.enumerated() {
            switch finger.pose(relativeTo: wrist) {
            case .fist, .looseFist: curled += 1
            case .open:
                straight += 1
                isPointing = isPointing || (index == 0 && finger.bend?.isTracked == true)
            case .unknown: break
            }
        }
        // A tracked extended index with the other fingers curled can poke a cabinet button.
        if curled >= 2 && curled > straight && !isPointing {
            return curled >= 3 && straight == 0 ? .fist : .looseFist
        }
        if straight >= 3 || (straight >= 2 && curled == 0) { return .open }
        return .unknown
    }
}

struct CabinetHandSample {
    var palm: SIMD3<Float>?
    var index: SIMD3<Float>?
    var fingerDirection: SIMD3<Float>?
    var palmNormal: SIMD3<Float>?
    var forearmDirection: SIMD3<Float>?
    var pose: CabinetHandPose = .unknown
    var estimatedGripPosition: SIMD3<Float>? = nil

    var gripPosition: SIMD3<Float>? { estimatedGripPosition ?? palm }

    mutating func recognizeGrip(wrist: SIMD3<Float>?, palm: CabinetHandJoint, fingers: [CabinetHandPose.Finger]) {
        // Finger joints are often occluded when making a fist. ARKit still
        // supplies estimates while it tracks the hand as a whole.
        estimatedGripPosition = palm.estimatedPosition
        pose = CabinetHandPose.classify(wrist: wrist, fingers: fingers)
    }
}

enum CabinetNudgeDirection: CaseIterable {
    case left, right, up, down
}

enum CabinetAction: Hashable {
    case leftFlipper, rightFlipper, addCredit, start, launchBall, nudge
}

enum CabinetInput: Equatable {
    case flipper(CabinetHandSide, pressed: Bool)
    case insertCoin, pressStart
    case nudge(CabinetNudgeDirection)
    case pullPlunger(Float), releasePlunger(Float), cancelPlunger

    var action: CabinetAction {
        switch self {
        case .flipper(.left, _): .leftFlipper
        case .flipper(.right, _): .rightFlipper
        case .insertCoin: .addCredit
        case .pressStart: .start
        case .nudge: .nudge
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
    private var nudge = FistNudge()

    init(layout: CabinetControlsLayout = .init()) {
        self.layout = layout
    }

    mutating func update(_ side: CabinetHandSide, sample: CabinetHandSample?, at time: Double) -> [CabinetInput] {
        let heldBefore = plunger.hand
        let plungerEvents = layout.plunger.map {
            plunger.update(side, sample: sample, handle: $0, allowGrab: !nudge.isArmed, time: time)
        } ?? []
        let closedHand = sample?.pose == .fist || (sample?.pose == .unknown && nudge.isClosed(side, at: time))
        let blockFlipper = layout.usesWristGestures && (closedHand || heldBefore == side || plunger.hand == side)
        let buttons = switch side {
        case .left: left.update(.left, sample: sample, layout: layout, blockFlipper: blockFlipper, time: time)
        case .right: right.update(.right, sample: sample, layout: layout, blockFlipper: blockFlipper, time: time)
        }
        guard layout.usesWristGestures else { return buttons + plungerEvents }
        guard heldBefore == nil, plunger.hand == nil else {
            nudge = FistNudge()
            return buttons + plungerEvents
        }
        if let direction = nudge.update(side, sample: sample, at: time) {
            return buttons + plungerEvents + [.nudge(direction)]
        }
        return buttons + plungerEvents
    }

    mutating func expire(at time: Double) -> [CabinetInput] {
        nudge.expire(at: time)
        return left.expire(.left, time: time) + right.expire(.right, time: time) + plunger.expire(at: time)
    }

    mutating func reset() -> [CabinetInput] {
        nudge = FistNudge()
        return left.reset(.left) + right.reset(.right) + plunger.reset()
    }

    private struct FistNudge {
        private struct Fist {
            let position: SIMD2<Float>
            let confirmedAt: Double
            let sampledAt: Double
        }

        private var left: Fist?
        private var right: Fist?
        private var settling: (left: SIMD2<Float>, right: SIMD2<Float>, since: Double)?
        private var lastPair = -Double.infinity
        private var origin: (left: SIMD2<Float>, right: SIMD2<Float>)?
        private var lastNudge = -Double.infinity
        private var spent = false
        var isArmed: Bool { origin != nil }

        func isClosed(_ side: CabinetHandSide, at time: Double) -> Bool {
            guard let fist = side == .left ? left : right else { return false }
            return time - fist.confirmedAt <= CabinetHandControls.trackingTimeout
        }

        mutating func expire(at time: Double) {
            if let left, time - left.confirmedAt > CabinetHandControls.trackingTimeout { self.left = nil }
            if let right, time - right.confirmedAt > CabinetHandControls.trackingTimeout { self.right = nil }
            if left == nil || right == nil {
                origin = nil
                settling = nil
                spent = false
            }
        }

        mutating func update(_ side: CabinetHandSide, sample: CabinetHandSample?, at time: Double) -> CabinetNudgeDirection? {
            expire(at: time)
            let previous = side == .left ? left : right
            var current = previous
            if sample?.pose == .open {
                current = nil
            } else if let palm = sample?.gripPosition {
                let position = SIMD2(palm.x, palm.y)
                if sample?.pose == .fist {
                    current = Fist(position: position, confirmedAt: time, sampledAt: time)
                } else if let previous {
                    // Preserve a closed fist briefly when some finger joints
                    // disappear, using the palm for movement in the meantime.
                    current = Fist(position: position, confirmedAt: previous.confirmedAt, sampledAt: time)
                }
            }
            if side == .left { left = current } else { right = current }
            expire(at: time)
            guard let left, let right, min(left.sampledAt, right.sampledAt) > lastPair else { return nil }
            lastPair = max(left.sampledAt, right.sampledAt)

            guard let origin else {
                // Take the reference after both fists settle. Closing them
                // or moving into position should never count as the shove.
                guard left.confirmedAt == left.sampledAt, right.confirmedAt == right.sampledAt else {
                    settling = nil
                    return nil
                }
                if let settling, simd_distance(left.position, settling.left) < 0.012,
                   simd_distance(right.position, settling.right) < 0.012 {
                    if time - settling.since >= 0.14 {
                        self.origin = (left.position, right.position)
                        self.settling = nil
                    }
                } else {
                    settling = (left.position, right.position, time)
                }
                return nil
            }

            let leftMove = left.position - origin.left
            let rightMove = right.position - origin.right
            if spent {
                if time - lastNudge >= 0.30, simd_length(leftMove) < 0.012, simd_length(rightMove) < 0.012 {
                    spent = false
                }
                return nil
            }
            let move = (leftMove + rightMove) * 0.5
            let axis = abs(move.x) >= abs(move.y) ? 0 : 1
            let sign: Float = move[axis] < 0 ? -1 : 1
            guard left.confirmedAt == left.sampledAt || right.confirmedAt == right.sampledAt,
                  time - lastNudge >= 0.30, abs(move[axis]) >= 0.030,
                  sign * leftMove[axis] >= 0.022, sign * rightMove[axis] >= 0.022 else { return nil }
            spent = true
            lastNudge = time
            if axis == 0 { return sign < 0 ? .left : .right }
            return sign < 0 ? .down : .up
        }
    }

    // About the length of the visible Time Machine handle travel.
    static let plungerStroke: Float = 0.060

    private struct PlungerGrip {
        private(set) var hand: CabinetHandSide?
        private var grabDepth: Float = 0
        private var pull: Float = 0
        private var lastSample: Double = 0
        private var needsOpen: CabinetHandSide?

        mutating func reset() -> [CabinetInput] {
            let wasHeld = hand != nil
            self = PlungerGrip()
            return wasHeld ? [.cancelPlunger] : []
        }

        private mutating func release() -> [CabinetInput] {
            let released = pull
            self = PlungerGrip()
            return released >= 0.04 ? [.releasePlunger(released)] : [.cancelPlunger]
        }

        mutating func expire(at time: Double) -> [CabinetInput] {
            guard let hand, time - lastSample > CabinetHandControls.trackingTimeout else { return [] }
            let events = reset()
            needsOpen = hand
            return events
        }

        mutating func update(
            _ side: CabinetHandSide, sample: CabinetHandSample?, handle: SIMD3<Float>, allowGrab: Bool, time: Double
        ) -> [CabinetInput] {
            let expired = expire(at: time)
            guard expired.isEmpty, hand == nil || hand == side else { return expired }
            if sample?.pose == .open {
                if needsOpen == side { needsOpen = nil }
                return hand == side ? release() : []
            }
            guard let sample, let palm = sample.gripPosition else { return [] }
            if hand == nil {
                let offset = palm - handle
                guard allowGrab, sample.pose.canGrip, needsOpen != side,
                      simd_length_squared(SIMD2(offset.x, offset.y)) <= 0.13 * 0.13,
                      (-0.10...0.20).contains(offset.z) else { return [] }
                hand = side
                grabDepth = palm.z
                lastSample = time
                return [.pullPlunger(0)]
            }

            lastSample = time
            // An obscured finger can leave the palm tracked. Hold the saved
            // pull until the hand clearly closes or opens again.
            guard sample.pose.canGrip else { return [] }
            let newPull = min(max((palm.z - grabDepth) / CabinetHandControls.plungerStroke, 0), 1)
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
        private var usingForearm: Bool?
        private var lastForearm: (direction: SIMD3<Float>, time: Double)?
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
            blockFlipper: Bool,
            time: Double
        ) -> [CabinetInput] {
            guard let sample else { return reset(side) }
            var events = expire(side, time: time)
            lastSample = time
            let wasDown = flipperDown
            if layout.usesWristGestures {
                updateWristGesture(blockFlipper ? nil : sample, side: side, at: time)
            } else {
                updateFlipper(sample, side: side, button: layout.flipper(side), mapped: layout.flipperCap(side) != nil)
            }
            if flipperDown != wasDown {
                events.append(.flipper(side, pressed: flipperDown))
            }

            let fingertip = layout.usesWristGestures && sample.pose.canGrip ? nil : sample.index
            if Self.poke(fingertip, at: layout.start, contactDepth: layout.startFace == nil ? 0.003 : 0.012, armed: &startArmed, contains: {
                layout.startFace?.contains($0) ?? (simd_length_squared($0) <= 0.034 * 0.034)
            }) {
                events.append(.pressStart)
            }
            if Self.poke(fingertip, at: layout.coin, contactDepth: layout.coinFace == nil ? 0.003 : 0.012, armed: &coinArmed, contains: {
                let face = layout.coinFace ?? CabinetButtonFace(position: layout.coin, halfSize: CabinetControlsLayout.coinFaceSize / 2)
                return face.contains($0)
            }) {
                events.append(.insertCoin)
            }
            return events
        }

        private mutating func updateWristGesture(_ sample: CabinetHandSample?, side: CabinetHandSide, at time: Double) {
            guard let direction = sample?.fingerDirection, simd_length_squared(direction) > 1e-8 else {
                usingForearm = nil
                lastForearm = nil
                fingerTurn = WristTurn()
                return
            }
            if let forearm = sample?.forearmDirection, simd_length_squared(forearm) > 1e-8 {
                lastForearm = (simd_normalize(forearm), time)
            }
            let inward = SIMD3<Float>(-side.sign, 0, 0)
            var bend: Float?
            // A short loss of the arm joint during a flick should not change
            // the reference frame halfway through the gesture.
            if let lastForearm, time - lastForearm.time <= 0.08 {
                let arm = lastForearm.direction
                let lateral = inward - arm * simd_dot(inward, arm)
                if simd_length_squared(lateral) > 0.1, simd_dot(direction, arm) > 0 {
                    bend = atan2(simd_dot(direction, simd_normalize(lateral)), simd_dot(direction, arm))
                }
            }
            let hasForearm = bend != nil
            if usingForearm != hasForearm {
                usingForearm = hasForearm
                fingerTurn = WristTurn()
            }
            if let bend {
                fingerTurn.update(angle: bend, canArm: true)
            } else {
                fingerTurn.update(direction, inward: inward.x, canArm: true)
            }
        }

        private mutating func updateFlipper(_ sample: CabinetHandSample, side: CabinetHandSide, button: SIMD3<Float>, mapped: Bool) {
            if let offset = sample.palm.map({ $0 - button }) {
                let outside = offset.x * side.sign
                // Give a held gesture extra room so small tracking changes do not release a trap.
                let margin: Float = flipperDown ? 0.020 : 0
                let verticalReach: Float = mapped ? 0.090 : 0.065
                let depthReach: Float = mapped ? 0.135 : 0.100
                if abs(offset.y) <= verticalReach + margin, abs(offset.z) <= depthReach + margin,
                   (-0.085 ... (0.13 + (mapped ? margin : 0))).contains(outside) {
                    if outside >= (mapped ? 0.012 : 0.018) {
                        flipperArmed = true
                        translationDown = false
                    } else if flipperArmed && outside <= (mapped ? -0.006 : -0.012) {
                        translationDown = true
                    }

                    let canArm = outside >= (mapped ? -0.025 : -0.008)
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
                update(angle: angle, canArm: canArm)
            }

            mutating func update(angle: Float, canArm: Bool) {
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
