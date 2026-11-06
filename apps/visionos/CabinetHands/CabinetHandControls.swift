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

    func isByNudgeRail(_ side: CabinetHandSide, palm: SIMD3<Float>, margin: Float) -> Bool {
        let offset = palm - flipper(side)
        let outward = offset.x * side.sign
        // Allow a shallow reach in front of the cabinet while keeping
        // each fist near its own side.
        return (-0.06 - margin...0.22 + margin).contains(outward)
            && abs(offset.y) <= 0.22 + margin
            && (-0.32 - margin...0.13 + margin).contains(offset.z)
            && palm.z <= 0.06 + margin
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

    var isClosed: Bool { self == .fist || self == .looseFist }

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

struct CabinetPlungerPose {
    enum Signal { case uncertain, grab, hold, release }
    enum Grip { case tuck, pinch }

    var tuck: Signal = .uncertain
    var pinch: Signal = .uncertain
    static let uncertain = Self()

    var grab: Grip? {
        if tuck == .grab { return .tuck }
        if pinch == .grab { return .pinch }
        return nil
    }

    func signal(for grip: Grip) -> Signal {
        grip == .tuck ? tuck : pinch
    }

    static func classify(angle: Float?, across: Float?, gapMM: Float?, trackedPalmJoints: Int) -> Self {
        guard trackedPalmJoints >= 2 else { return .uncertain }
        var pose = Self()
        if let angle, let across {
            if angle >= 60 || across <= 25 {
                pose.tuck = .release
            } else if angle <= 55 {
                pose.tuck = across >= 30 ? .grab : .hold
            }
        }
        if let gapMM {
            if gapMM <= 15 { pose.pinch = .grab }
            else if gapMM >= 25 { pose.pinch = .release }
            else { pose.pinch = .hold }
        }
        return pose
    }
}

struct CabinetPlungerGeometry {
    let trackedPalmJoints: Int
    let thumbIndexGapMM: Float?
    let palmDownDegrees: Float?
    let thumbBelowPalmMM: Float?
    let thumbAcrossPalmPercent: Float?

    init(side: CabinetHandSide, wrist: CabinetHandJoint, palm: CabinetHandJoint,
         index: CabinetHandJoint, little: CabinetHandJoint, indexTip: CabinetHandJoint, thumb: CabinetHandJoint) {
        trackedPalmJoints = [wrist, palm, index, little].filter { $0.trackedPosition != nil }.count
        thumbIndexGapMM = thumb.estimatedPosition.flatMap { tip in
            indexTip.estimatedPosition.map { simd_distance(tip, $0) * 1000 }
        }
        var angle: Float?
        var below: Float?
        var across: Float?
        if let wrist = wrist.estimatedPosition, let palm = palm.estimatedPosition,
           let index = index.estimatedPosition, let little = little.estimatedPosition {
            let span = little - index
            let normal = side.sign * simd_cross(-span, palm - wrist)
            if simd_length_squared(normal) > 1e-8 {
                let unitNormal = simd_normalize(normal)
                angle = acos(min(max(-unitNormal.y, -1), 1)) * 180 / .pi
                if let tip = thumb.estimatedPosition {
                    below = simd_dot(tip - palm, unitNormal) * 1000
                    across = simd_dot(tip - index, span) / simd_length_squared(span) * 100
                }
            }
        }
        palmDownDegrees = angle
        thumbBelowPalmMM = below
        thumbAcrossPalmPercent = across
    }

    var pose: CabinetPlungerPose {
        .classify(angle: palmDownDegrees, across: thumbAcrossPalmPercent,
                  gapMM: thumbIndexGapMM, trackedPalmJoints: trackedPalmJoints)
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
    var plungerPose: CabinetPlungerPose = .uncertain

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
        let flipperDown = side == .left ? left.flipperDown : right.flipperDown
        let plungerEvents = layout.plunger.map {
            plunger.update(side, sample: sample, handle: $0, allowGrab: !nudge.isArmed && !flipperDown, time: time)
        } ?? []
        let direction: CabinetNudgeDirection?
        if layout.usesWristGestures, heldBefore == nil, plunger.hand == nil {
            direction = nudge.update(side, sample: sample, layout: layout, at: time)
        } else {
            nudge = FistNudge()
            direction = nil
        }
        let blockFlipper = layout.usesWristGestures && (nudge.blocksFlippers || heldBefore == side || plunger.hand == side)
        let buttons = switch side {
        case .left: left.update(.left, sample: sample, layout: layout, blockFlipper: blockFlipper, time: time)
        case .right: right.update(.right, sample: sample, layout: layout, blockFlipper: blockFlipper, time: time)
        }
        return buttons + plungerEvents + (direction.map { [.nudge($0)] } ?? [])
    }

    var nudgePhase: String { nudge.phase }
    var nudgeMotion: String? { nudge.lastMotion }

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
            let position: SIMD3<Float>
            let confirmedAt: Double
            let sampledAt: Double
        }

        private struct Pair {
            let left: SIMD3<Float>
            let right: SIMD3<Float>
            let time: Double
            var center: SIMD3<Float> { (left + right) * 0.5 }
        }

        private struct Stroke {
            let axis: Int
            let sign: Float
            let start: Float

            func hasReturned(_ pair: Pair) -> Bool {
                sign * (pair.center[axis] - start) <= 0.022
            }
        }

        private var left: Fist?
        private var right: Fist?
        private var leftNearRailAt: Double?
        private var rightNearRailAt: Double?
        private var lastPair = -Double.infinity
        private var history: [Pair] = []
        private var spent = false
        private var stroke: Stroke?
        private(set) var lastMotion: String?
        var isArmed: Bool { !history.isEmpty }
        var blocksFlippers: Bool { isArmed || stroke != nil || (leftNearRailAt != nil && rightNearRailAt != nil) }
        var phase: String { isArmed ? (spent ? "latched" : "armed") : "waitingForFists" }

        mutating func expire(at time: Double) {
            if let left, time - left.confirmedAt > CabinetHandControls.trackingTimeout { self.left = nil }
            if let right, time - right.confirmedAt > CabinetHandControls.trackingTimeout { self.right = nil }
            if let leftNearRailAt, time - leftNearRailAt > CabinetHandControls.trackingTimeout { self.leftNearRailAt = nil }
            if let rightNearRailAt, time - rightNearRailAt > CabinetHandControls.trackingTimeout { self.rightNearRailAt = nil }
            if left == nil || right == nil {
                history.removeAll(keepingCapacity: true)
                spent = false
                stroke = nil
            }
        }

        mutating func update(
            _ side: CabinetHandSide, sample: CabinetHandSample?, layout: CabinetControlsLayout, at time: Double
        ) -> CabinetNudgeDirection? {
            expire(at: time)
            // A paired fist stance can suppress wrist presses just outside
            // the rail. The tighter placement gate still controls nudging.
            let nearRailAt = side == .left ? leftNearRailAt : rightNearRailAt
            var updatedNearRailAt = nearRailAt
            if sample?.pose == .open {
                updatedNearRailAt = nil
            } else if let palm = sample?.gripPosition {
                if !layout.isByNudgeRail(side, palm: palm, margin: 0.07) {
                    updatedNearRailAt = nil
                } else if sample?.pose == .fist {
                    updatedNearRailAt = time
                }
            }
            if side == .left { leftNearRailAt = updatedNearRailAt } else { rightNearRailAt = updatedNearRailAt }

            let previous = side == .left ? left : right
            var current = previous
            if sample?.pose == .open {
                current = nil
            } else if let palm = sample?.gripPosition {
                // Keep the stroke through a rail exit while both fists are
                // tracked. Otherwise re-entry can count the return as a shove.
                if !layout.isByNudgeRail(side, palm: palm, margin: isArmed ? 0.04 : 0) {
                    history.removeAll(keepingCapacity: true)
                }
                if sample?.pose == .fist {
                    current = Fist(position: palm, confirmedAt: time, sampledAt: time)
                } else if let previous {
                    current = Fist(position: palm, confirmedAt: previous.confirmedAt, sampledAt: time)
                }
            }
            if side == .left { left = current } else { right = current }
            expire(at: time)
            guard let left, let right, min(left.sampledAt, right.sampledAt) > lastPair else { return nil }
            lastPair = max(left.sampledAt, right.sampledAt)
            let margin: Float = isArmed ? 0.04 : 0
            guard layout.isByNudgeRail(.left, palm: left.position, margin: margin),
                  layout.isByNudgeRail(.right, palm: right.position, margin: margin) else {
                history.removeAll(keepingCapacity: true)
                return nil
            }
            let leftConfirmed = left.confirmedAt == left.sampledAt
            let rightConfirmed = right.confirmedAt == right.sampledAt
            let pair = Pair(left: left.position, right: right.position, time: lastPair)
            guard isArmed else {
                if leftConfirmed && rightConfirmed { history.append(pair) }
                return nil
            }

            history.removeAll { pair.time - $0.time > 0.18 }
            let recent = history.drop(while: { pair.time - $0.time > 0.10 })
            let settled = recent.first.map { pair.time - $0.time >= 0.06 } == true
                && recent.allSatisfy {
                    simd_distance($0.left, pair.left) < 0.012 && simd_distance($0.right, pair.right) < 0.012
                }
            let returned = stroke?.hasReturned(pair) == true
            if returned && settled {
                stroke = nil
                spent = false
                history = [pair]
                return nil
            }
            if spent {
                if settled || returned {
                    spent = false
                    history.removeAll(keepingCapacity: true)
                }
                history.append(pair)
                return nil
            }

            defer { history.append(pair) }
            guard leftConfirmed || rightConfirmed, let reference = recent.first else { return nil }
            let leftMove = pair.left - reference.left
            let rightMove = pair.right - reference.right
            let move = (leftMove + rightMove) * 0.5
            if let stroke, stroke.sign * move[stroke.axis] <= -0.022 { return nil }
            let acceleration = sharedAcceleration(to: pair)
            let leftMinimum = max(0.022, 0.55 * simd_length(leftMove))
            let rightMinimum = max(0.022, 0.55 * simd_length(rightMove))
            var strongestAxis: Int?
            var strongestMove: Float = 0
            for axis in 0..<3 {
                let sign: Float = move[axis] < 0 ? -1 : 1
                let distance = abs(move[axis])
                guard distance >= 0.030, distance > strongestMove,
                      sign * leftMove[axis] >= leftMinimum, sign * rightMove[axis] >= rightMinimum,
                      sign * acceleration[axis] >= 4 else { continue }
                strongestAxis = axis
                strongestMove = distance
            }
            guard let axis = strongestAxis else { return nil }
            let sign: Float = move[axis] < 0 ? -1 : 1
            stroke = Stroke(axis: axis, sign: sign, start: reference.center[axis])
            spent = true
            history.removeAll(keepingCapacity: true)
            switch axis {
            case 0:
                lastMotion = sign < 0 ? "left" : "right"
                return sign < 0 ? .left : .right
            case 1:
                lastMotion = sign < 0 ? "down" : "up"
                return sign < 0 ? .down : .up
            default:
                lastMotion = sign < 0 ? "forward" : "back"
                return sign < 0 ? .up : .down
            }
        }

        private func sharedAcceleration(to pair: Pair) -> SIMD3<Float> {
            guard let split = history.min(by: {
                abs(pair.time - $0.time - 0.05) < abs(pair.time - $1.time - 0.05)
            }) else { return .zero }
            let recentDuration = Float(pair.time - split.time)
            let velocity = (pair.center - split.center) / recentDuration
            guard let earlier = history.prefix(while: { $0.time < split.time }).min(by: {
                abs(split.time - $0.time - 0.065) < abs(split.time - $1.time - 0.065)
            }) else {
                // The first measurable shove can fire on the next pair.
                return velocity / recentDuration
            }
            let previous = (split.center - earlier.center) / Float(split.time - earlier.time)
            return (velocity - previous) / Float((pair.time - earlier.time) * 0.5)
        }
    }

    // About the length of the visible Time Machine handle travel.
    static let plungerStroke: Float = 0.060

    private struct PlungerGrip {
        private(set) var hand: CabinetHandSide?
        private var grabDepth: Float = 0
        private var pull: Float = 0
        private var lastSample: Double = 0
        private var grip: CabinetPlungerPose.Grip?
        private var needsRelease: (side: CabinetHandSide, grip: CabinetPlungerPose.Grip)?

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
            guard let hand, let grip, time - lastSample > CabinetHandControls.trackingTimeout else { return [] }
            let events = reset()
            needsRelease = (hand, grip)
            return events
        }

        mutating func update(
            _ side: CabinetHandSide, sample: CabinetHandSample?, handle: SIMD3<Float>, allowGrab: Bool, time: Double
        ) -> [CabinetInput] {
            let expired = expire(at: time)
            guard expired.isEmpty, hand == nil || hand == side else { return expired }
            guard let sample else { return [] }
            if let needsRelease, needsRelease.side == side,
               sample.plungerPose.signal(for: needsRelease.grip) == .release {
                self.needsRelease = nil
            }
            if hand == side, let grip, sample.plungerPose.signal(for: grip) == .release {
                let events = release()
                // Rolling out of a tuck can leave the fingertips touching.
                // Require a fresh gesture before accepting the other grip.
                if let otherGrip = sample.plungerPose.grab { needsRelease = (side, otherGrip) }
                return events
            }
            guard let palm = sample.gripPosition else { return [] }
            if hand == nil {
                let offset = palm - handle
                guard allowGrab, let grip = sample.plungerPose.grab, needsRelease?.side != side,
                      simd_length_squared(SIMD2(offset.x, offset.y)) <= 0.13 * 0.13,
                      (-0.10...0.20).contains(offset.z) else { return [] }
                hand = side
                self.grip = grip
                grabDepth = palm.z
                lastSample = time
                return [.pullPlunger(0)]
            }

            lastSample = time
            // Ambiguous tracking can preserve a pull without weakening the shot.
            guard let grip else { return [] }
            let signal = sample.plungerPose.signal(for: grip)
            guard signal == .grab || signal == .hold else { return [] }
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
        private var wristFlick = WristFlick()
        private var usingForearm: Bool?
        private var lastForearm: (direction: SIMD3<Float>, time: Double)?
        var flipperDown: Bool { translationDown || fingerTurn.isDown || palmTurn.isDown || wristFlick.isDown }
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

            let fingertip = layout.usesWristGestures && sample.pose.isClosed ? nil : sample.index
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
                wristFlick = WristFlick()
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
                wristFlick = WristFlick()
            }
            let angle = bend ?? atan2(inward.x * direction.x, simd_length(SIMD2(direction.y, direction.z)))
            wristFlick.update(angle: angle, at: time)
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

        private struct WristFlick {
            private static let historyDuration = 0.10
            private static let pressAngle: Float = 8 * .pi / 180
            private static let pressSpeed: Float = 140 * .pi / 180
            private static let releaseRollback: Float = 5 * .pi / 180

            private var history: [(angle: Float, time: Double)] = []
            private var releaseAt: Float?
            var isDown: Bool { releaseAt != nil }

            mutating func update(angle: Float, at time: Double) {
                if let releaseAt {
                    if angle <= releaseAt {
                        self.releaseAt = nil
                        history.append((angle, time))
                    } else {
                        self.releaseAt = max(releaseAt, angle - Self.releaseRollback)
                    }
                    return
                }

                history.removeAll { time - $0.time > Self.historyDuration }
                if history.contains(where: { previous in
                    let elapsed = Float(time - previous.time)
                    let bend = angle - previous.angle
                    return elapsed > 0 && bend >= Self.pressAngle && bend >= Self.pressSpeed * elapsed
                }) {
                    // Release on relaxation from the held bend, including
                    // when the press fired early in a large flick.
                    releaseAt = angle - Self.releaseRollback
                    history.removeAll(keepingCapacity: true)
                    return
                }
                history.append((angle, time))
            }
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
