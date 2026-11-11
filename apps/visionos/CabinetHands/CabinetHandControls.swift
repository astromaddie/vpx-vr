// license:GPLv3+

import simd

struct CabinetButtonFace: Codable {
    let position: SIMD3<Float>
    let halfSize: SIMD2<Float>

    func contains(_ offset: SIMD2<Float>) -> Bool {
        halfSize.x > 0 && abs(offset.x) <= halfSize.x && abs(offset.y) <= halfSize.y
    }
}

/// Metres in cabinet space: x to the player's right, y up, z toward the player.
/// The origin is at the top centre of the front panel.
struct CabinetControlsLayout: Codable {
    static let coinFaceSize = SIMD2<Float>(0.080, 0.064)
    // The default preview uses Time Machine's 1,000 by 1,910 VP units.
    var playfieldWidth: Float = 0.53975
    var playfieldLength: Float = 1.0309225
    var plunger: SIMD3<Float>? = nil
    var startFace: CabinetButtonFace? = nil
    var coinFace: CabinetButtonFace? = nil
    var leftFlipperCap: SIMD3<Float>? = nil
    var rightFlipperCap: SIMD3<Float>? = nil
    /// A Launch Ball button on the front panel, for cabinets without a plunger knob.
    var launchFace: CabinetButtonFace? = nil
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

    /// Where a resting wrist can shove the cabinet: beside its own side of the
    /// cabinet from the flipper button back along the side rail, or just in
    /// front of the front corner. The wrist sits a few centimetres behind the palm.
    func isInShoveZone(_ side: CabinetHandSide, wrist: SIMD3<Float>) -> Bool {
        let offset = wrist - flipper(side)
        let outward = offset.x * side.sign
        return (-0.12...0.25).contains(outward)
            && abs(offset.y) <= 0.25
            && (-0.45...0.22).contains(offset.z)
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
    /// The wrist joint, tracked or estimated. Shoves follow its translation,
    /// which a wrist bend barely moves.
    var wrist: SIMD3<Float>? = nil

    var gripPosition: SIMD3<Float>? { estimatedGripPosition ?? palm }

    mutating func recognizeGrip(wrist: SIMD3<Float>?, palm: CabinetHandJoint, fingers: [CabinetHandPose.Finger]) {
        // Finger joints are often occluded when making a fist. ARKit still
        // supplies estimates while it tracks the hand as a whole.
        estimatedGripPosition = palm.estimatedPosition
        pose = CabinetHandPose.classify(wrist: wrist, fingers: fingers)
    }
}

extension CabinetHandSample {
    /// Builds the recognizers' sample from cabinet-space joints. The ARKit adapter
    /// and the recording replay both use this, so a replay sees what the headset saw.
    init(_ side: CabinetHandSide, frame: CabinetHandFrame, layout: CabinetControlsLayout) {
        self.init()
        let palm = frame[.middleKnuckle]
        let wrist = frame[.wrist]
        if let palm = palm.trackedPosition, let wrist = wrist.trackedPosition {
            fingerDirection = palm - wrist
        }
        if let fingerDirection, let index = frame[.indexKnuckle].trackedPosition,
           let little = frame[.littleKnuckle].trackedPosition {
            // This order gives both palms the same outward-facing normal relative to their joints.
            palmNormal = side.sign * simd_cross(index - little, fingerDirection)
        }
        self.palm = palm.trackedPosition
        index = frame[.indexTip].trackedPosition
        let wristPosition = wrist.estimatedPosition ?? frame.origin
        self.wrist = wristPosition
        if layout.usesWristGestures {
            if let palmPosition = palm.estimatedPosition {
                fingerDirection = palmPosition - wristPosition
            }
            let forearmWrist = frame[.forearmWrist].estimatedPosition ?? wristPosition
            if let arm = frame[.forearmArm].estimatedPosition {
                forearmDirection = forearmWrist - arm
            }
            let fingers = CabinetJoint.fingers.map { knuckle, bend, next in
                CabinetHandPose.Finger(knuckle: frame[knuckle], bend: frame[bend], next: frame[next])
            }
            recognizeGrip(wrist: wristPosition, palm: palm, fingers: fingers)
        }
        if layout.plunger != nil {
            plungerPose = Self.geometry(side, frame: frame).pose
        }
    }

    static func geometry(_ side: CabinetHandSide, frame: CabinetHandFrame) -> CabinetPlungerGeometry {
        CabinetPlungerGeometry(side: side, wrist: frame[.wrist], palm: frame[.middleKnuckle],
                               index: frame[.indexKnuckle], little: frame[.littleKnuckle],
                               indexTip: frame[.indexTip], thumb: frame[.thumbTip])
    }
}

/// The hand joints the recognizers read, in a fixed order for recordings.
enum CabinetJoint: Int, CaseIterable {
    case wrist, forearmWrist, forearmArm, thumbTip
    case indexKnuckle, indexBend, indexNext, indexTip
    case middleKnuckle, middleBend, middleNext
    case ringKnuckle, ringBend, ringNext
    case littleKnuckle, littleBend, littleNext

    static let fingers: [(CabinetJoint, CabinetJoint, CabinetJoint)] = [
        (.indexKnuckle, .indexBend, .indexNext), (.middleKnuckle, .middleBend, .middleNext),
        (.ringKnuckle, .ringBend, .ringNext), (.littleKnuckle, .littleBend, .littleNext)
    ]
}

/// One tracked hand in cabinet space: the anchor origin and each joint.
struct CabinetHandFrame {
    var origin: SIMD3<Float>
    var joints: [CabinetHandJoint]

    init(origin: SIMD3<Float>, joints: [CabinetHandJoint]) {
        precondition(joints.count == CabinetJoint.allCases.count)
        self.origin = origin
        self.joints = joints
    }

    subscript(_ joint: CabinetJoint) -> CabinetHandJoint { joints[joint.rawValue] }
}

enum CabinetAction: Hashable {
    case leftFlipper, rightFlipper, addCredit, start, launchBall, nudge
}

enum CabinetInput: Equatable {
    case flipper(CabinetHandSide, pressed: Bool)
    case insertCoin, pressStart, pressLaunchBall
    /// Peak cabinet acceleration of a shove in m/s², x to the player's right and
    /// y toward the player, like VPX's nudge axes. `update` raises the shove
    /// that is still in progress instead of starting another.
    case shove(SIMD2<Float>, update: Bool)
    case pullPlunger(Float), releasePlunger(Float), cancelPlunger

    var action: CabinetAction {
        switch self {
        case .flipper(.left, _): .leftFlipper
        case .flipper(.right, _): .rightFlipper
        case .insertCoin: .addCredit
        case .pressStart: .start
        case .shove: .nudge
        case .pullPlunger, .releasePlunger, .cancelPlunger, .pressLaunchBall: .launchBall
        }
    }
}

struct CabinetHandControls {
    static let trackingTimeout = 0.12
    let layout: CabinetControlsLayout
    private var left = Hand()
    private var right = Hand()
    private var plunger = PlungerGrip()
    private var shove = Shove()
    /// Short diagnostic lines for the session log, such as a flipper hold that
    /// dropped while the hand still looked bent. Collect them with `takeNotes()`.
    private(set) var notes: [String] = []

    init(layout: CabinetControlsLayout = .init()) {
        self.layout = layout
    }

    mutating func update(_ side: CabinetHandSide, sample: CabinetHandSample?, at time: Double) -> [CabinetInput] {
        let heldBefore = plunger.hand
        let flipperDown = side == .left ? left.flipperDown : right.flipperDown
        let plungerEvents = layout.plunger.map {
            plunger.update(side, sample: sample, handle: $0, allowGrab: !flipperDown, time: time)
        } ?? []
        // A plunger hand pulls toward the player. It doesn't shove.
        let holdsPlunger = heldBefore == side || plunger.hand == side
        let shoves = layout.usesWristGestures
            ? shove.update(side, wrist: holdsPlunger ? nil : sample?.wrist, layout: layout, at: time)
            : []
        let blockFlipper = layout.usesWristGestures && holdsPlunger
        // Flips stay free during a shove. A fast-moving wrist needs a larger
        // bend, so the hand lagging or overrunning the arm at the end of a
        // shove doesn't count as a flick.
        let translating = shove.isTranslating(side, at: time)
        let buttons = switch side {
        case .left: left.update(.left, sample: sample, layout: layout, blockFlipper: blockFlipper,
                                translating: translating, time: time, notes: &notes)
        case .right: right.update(.right, sample: sample, layout: layout, blockFlipper: blockFlipper,
                                  translating: translating, time: time, notes: &notes)
        }
        return buttons + plungerEvents + shoves
    }

    var nudgePhase: String { shove.phase }

    mutating func takeNotes() -> [String] {
        defer { notes.removeAll(keepingCapacity: true) }
        return notes
    }

    mutating func expire(at time: Double) -> [CabinetInput] {
        shove.expire(at: time)
        return left.expire(.left, time: time, notes: &notes) + right.expire(.right, time: time, notes: &notes)
            + plunger.expire(at: time)
    }

    mutating func reset() -> [CabinetInput] {
        shove = Shove()
        return left.reset(.left) + right.reset(.right) + plunger.reset()
    }

    /// Shoves the cabinet from the translation of each wrist, like an
    /// accelerometer cabinet. Strength and direction follow the hands.
    ///
    /// A shove starts from a hand that rested in the shove zone beside the
    /// cabinet. It needs a sharp start: the mean acceleration from rest to the
    /// onset speed must reach 5 m/s² with both hands moving together, or 6 m/s²
    /// for one hand alone. Minimum-jerk models of an ordinary 10 cm reach take
    /// about 100 ms to get to that speed (2 to 4.6 m/s²), while a 2 cm bump
    /// in 100 ms gets there in about 30 ms (6.7 m/s²) and a slap faster still.
    /// The strength follows the hand speed for the first 80 ms of the stroke.
    struct Shove {
        static let restSpeed: Float = 0.10
        static let onsetSpeed: Float = 0.22
        static let pairedAcceleration: Float = 5
        static let loneAcceleration: Float = 6
        static let restWindow = 0.15
        static let dwell = 0.10
        static let velocityWindow = 0.030
        static let strokeWindow = 0.08
        static let returnWindow = 0.40
        /// Combined push speed for no nudge and for VPX's strong keyboard nudge.
        static let gentleSpeed: Float = 0.15
        static let firmSpeed: Float = 1.40
        static let maxStrength: Float = 1.5
        /// VPX's NudgeSensor::StrongNudgeAcceleration.
        static let strongNudge: Float = 0.7 * 9.80665
        static let translatingSpeed: Float = 0.25

        private struct Track {
            var history: [(position: SIMD3<Float>, time: Double)] = []
            var zoneSince: Double?
            var restAt: Double?
            var velocity: SIMD3<Float> = .zero
            var velocityAt: Double = -.infinity
            var lastStroke: Double = -.infinity
        }

        private struct Stroke {
            let start: Double
            var push: SIMD2<Float>
            var strength: Float
            let hands: Set<Int>
        }

        private var tracks = [Track(), Track()]
        private var stroke: Stroke?
        private var lastDirection: (direction: SIMD2<Float>, time: Double)?
        private(set) var lastShove: SIMD2<Float>?

        var phase: String { stroke == nil ? "ready" : "stroke" }

        /// A wrist moving fast, or within 150 ms of its last shove, while the hand
        /// can lag and overrun the arm.
        func isTranslating(_ side: CabinetHandSide, at time: Double) -> Bool {
            let track = tracks[side == .left ? 0 : 1]
            return time - track.lastStroke <= 0.15
                || (time - track.velocityAt <= 0.05 && simd_length(track.velocity) >= Self.translatingSpeed)
        }

        mutating func expire(at time: Double) {
            for index in tracks.indices where time - (tracks[index].history.last?.time ?? -.infinity) > CabinetHandControls.trackingTimeout {
                tracks[index] = Track()
            }
            if let stroke, time - stroke.start > Self.strokeWindow { self.stroke = nil }
        }

        mutating func update(_ side: CabinetHandSide, wrist: SIMD3<Float>?, layout: CabinetControlsLayout,
                             at time: Double) -> [CabinetInput] {
            expire(at: time)
            let index = side == .left ? 0 : 1
            guard let wrist else {
                tracks[index] = Track()
                return []
            }
            var track = tracks[index]
            if layout.isInShoveZone(side, wrist: wrist) {
                if track.zoneSince == nil { track.zoneSince = time }
            } else {
                track.zoneSince = nil
            }
            track.history.removeAll { time - $0.time > 0.2 }
            track.history.append((wrist, time))
            // Speed over the newest 30 ms or more, which averages out about
            // a millimetre of joint jitter per sample.
            if let reference = track.history.last(where: { time - $0.time >= Self.velocityWindow }) {
                track.velocity = (wrist - reference.position) / Float(time - reference.time)
                track.velocityAt = time
                if simd_length(track.velocity) < Self.restSpeed { track.restAt = time }
            }
            tracks[index] = track
            return recognize(side, at: time)
        }

        private func recent(_ index: Int, at time: Double) -> SIMD3<Float>? {
            time - tracks[index].velocityAt <= 0.035 ? tracks[index].velocity : nil
        }

        private mutating func recognize(_ side: CabinetHandSide, at time: Double) -> [CabinetInput] {
            let index = side == .left ? 0 : 1
            let other = 1 - index
            guard let velocity = recent(index, at: time) else { return [] }
            let flat = SIMD2(velocity.x, velocity.z)

            if var stroke {
                // Grow the shove in progress while the hands keep speeding up.
                guard stroke.hands.contains(index) else { return [] }
                var push = SIMD2<Float>.zero
                for hand in stroke.hands {
                    if let v = recent(hand, at: time) { push += Self.contribution(SIMD2(v.x, v.z), side: hand == 0 ? .left : .right, lone: stroke.hands.count == 1) }
                }
                let strength = Self.strength(push)
                guard strength > stroke.strength * 1.1, simd_dot(push, stroke.push) > 0 else { return [] }
                stroke.push = push
                stroke.strength = strength
                self.stroke = stroke
                lastShove = Self.acceleration(push, strength: strength)
                return [.shove(lastShove!, update: true)]
            }

            let track = tracks[index]
            guard let zoneSince = track.zoneSince, time - zoneSince >= Self.dwell,
                  let restAt = track.restAt, time - restAt <= Self.restWindow, restAt > track.lastStroke,
                  simd_length(flat) >= Self.onsetSpeed,
                  simd_length(flat) >= 1.2 * abs(velocity.y) else { return [] }
            // Mean acceleration from the last moment at rest.
            let elapsed = Float(max(time - restAt, 0.011))

            var hands: Set<Int> = [index]
            var push = Self.contribution(flat, side: side, lone: false)
            let otherTrack = tracks[other]
            if let otherVelocity = recent(other, at: time), otherTrack.zoneSince != nil {
                let otherFlat = SIMD2(otherVelocity.x, otherVelocity.z)
                if simd_length(otherFlat) >= 0.15, simd_dot(otherFlat, flat) >= 0.4 * simd_length_squared(flat) {
                    hands.insert(other)
                    push += otherFlat
                }
            }
            let lone = hands.count == 1
            if lone { push = Self.contribution(flat, side: side, lone: true) }
            let threshold = lone ? Self.loneAcceleration : Self.pairedAcceleration
            guard simd_length(push) / Float(hands.count) >= Self.onsetSpeed,
                  (simd_length(flat) - Self.restSpeed) / elapsed >= threshold else { return [] }
            let direction = simd_normalize(push)
            // The way back after a shove isn't another shove.
            if let last = lastDirection, time - last.time <= Self.returnWindow,
               simd_dot(direction, last.direction) < -0.3 { return [] }
            let strength = Self.strength(push)
            guard strength > 0 else { return [] }
            stroke = Stroke(start: time, push: push, strength: strength, hands: hands)
            lastDirection = (direction, time)
            for hand in hands { tracks[hand].lastStroke = time }
            lastShove = Self.acceleration(push, strength: strength)
            return [.shove(lastShove!, update: false)]
        }

        /// What one hand adds to the shove. A lone hand only pushes: inward
        /// against its side or forward. Moving out or back alone is letting go.
        private static func contribution(_ flat: SIMD2<Float>, side: CabinetHandSide, lone: Bool) -> SIMD2<Float> {
            guard lone else { return flat }
            let inward = -side.sign
            return SIMD2(flat.x * inward > 0 ? flat.x : 0, min(flat.y, 0))
        }

        static func strength(_ push: SIMD2<Float>) -> Float {
            min(max((simd_length(push) - gentleSpeed) / (firmSpeed - gentleSpeed), 0), maxStrength)
        }

        private static func acceleration(_ push: SIMD2<Float>, strength: Float) -> SIMD2<Float> {
            simd_normalize(push) * strength * strongNudge
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
        private var lastBend: Double?
        var flipperDown: Bool { translationDown || fingerTurn.isDown || palmTurn.isDown || wristFlick.isDown }
        private var startArmed = false
        private var coinArmed = false
        private var launchArmed = false

        mutating func reset(_ side: CabinetHandSide) -> [CabinetInput] {
            let events: [CabinetInput] = flipperDown ? [.flipper(side, pressed: false)] : []
            self = Hand()
            return events
        }

        /// A held wrist flipper rides out a short tracking gap. Losing a held
        /// flipper costs a ball, while a late release rarely matters.
        static let holdGrace = 0.25

        mutating func expire(_ side: CabinetHandSide, time: Double, notes: inout [String]) -> [CabinetInput] {
            if wristFlick.isDown, let lastBend {
                guard time - lastBend > Self.holdGrace else { return [] }
                notes.append(String(format: "%@ flipper hold dropped: no hand bend for %.0f ms while held %.0f degrees",
                                    side == .left ? "Left" : "Right", (time - lastBend) * 1000,
                                    wristFlick.heldBendDegrees))
                return reset(side)
            }
            guard let lastSample, time - lastSample > CabinetHandControls.trackingTimeout else { return [] }
            return reset(side)
        }

        mutating func update(
            _ side: CabinetHandSide,
            sample: CabinetHandSample?,
            layout: CabinetControlsLayout,
            blockFlipper: Bool,
            translating: Bool = false,
            time: Double,
            notes: inout [String]
        ) -> [CabinetInput] {
            guard let sample else {
                return wristFlick.isDown && !blockFlipper ? expire(side, time: time, notes: &notes) : reset(side)
            }
            var events = expire(side, time: time, notes: &notes)
            lastSample = time
            let wasDown = flipperDown
            if layout.usesWristGestures {
                if blockFlipper {
                    lastBend = nil
                    usingForearm = nil
                    wristFlick = WristFlick()
                } else {
                    updateWristGesture(sample, side: side, translating: translating, at: time, notes: &notes)
                }
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
            if let launch = layout.launchFace,
               Self.poke(fingertip, at: launch.position, contactDepth: 0.012, armed: &launchArmed, contains: launch.contains) {
                events.append(.pressLaunchBall)
            }
            return events
        }

        private mutating func updateWristGesture(_ sample: CabinetHandSample?, side: CabinetHandSide, translating: Bool,
                                                 at time: Double, notes: inout [String]) {
            guard let direction = sample?.fingerDirection, simd_length_squared(direction) > 1e-8 else {
                // Keep a held flipper through the grace period.
                guard !wristFlick.isDown else { return }
                usingForearm = nil
                lastForearm = nil
                lastBend = nil
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
            let angle = bend ?? atan2(inward.x * direction.x, simd_length(SIMD2(direction.y, direction.z)))
            if usingForearm != hasForearm {
                // A held flipper keeps its hold in the new reference frame.
                if usingForearm != nil && wristFlick.isDown { wristFlick.rebase(angle) } else { wristFlick = WristFlick() }
                usingForearm = hasForearm
            }
            lastBend = time
            // Without the arm direction, a moving arm turns the hand as a whole.
            if let drop = wristFlick.update(angle: angle, at: time, translating: translating,
                                            allowPress: hasForearm || !translating) {
                notes.append(String(format: "%@ flipper hold dropped while bent: the hand stayed at %.0f degrees or more of its %.0f degree bend, after %.0f ms held",
                                    side == .left ? "Left" : "Right", drop.bend, drop.peak, drop.held * 1000))
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

        /// The wrist flipper. A press needs an 8-degree inward bend at 140 degrees per
        /// second or faster, or 14 degrees while the wrist is moving fast. A held press
        /// follows the peak of the median of its last three samples, so one noisy
        /// sample can't move it. It releases once that median relaxes 5 degrees from
        /// the peak, or when a single sample relaxes 10 degrees.
        private struct WristFlick {
            private static let historyDuration = 0.10
            private static let pressAngle: Float = 8 * .pi / 180
            private static let movingPressAngle: Float = 14 * .pi / 180
            private static let pressSpeed: Float = 140 * .pi / 180
            private static let releaseRollback: Float = 5 * .pi / 180
            private static let quickRollback: Float = 10 * .pi / 180

            private struct Hold {
                var base: Float
                var peak: Float
                var recent: [Float]
                let since: Double
                var median: Float {
                    let sorted = recent.sorted()
                    return sorted[sorted.count / 2]
                }
            }
            private var history: [(angle: Float, time: Double)] = []
            private var hold: Hold?
            /// A release being watched: if the hand stays bent for the next 150 ms,
            /// the hold dropped rather than the player letting go.
            private var released: (bent: Float, peak: Float, held: Double, at: Double, lowest: Float)?
            var isDown: Bool { hold != nil }
            var heldBendDegrees: Float { hold.map { ($0.median - $0.base) * 180 / .pi } ?? 0 }

            mutating func rebase(_ angle: Float) {
                guard var hold else { return }
                let bend = hold.median - hold.base
                hold.base = angle - bend
                hold.peak = angle
                hold.recent = [angle]
                self.hold = hold
            }

            /// Returns the peak bend and hold time when a hold dropped while the hand stayed bent.
            mutating func update(angle: Float, at time: Double, translating: Bool = false,
                                 allowPress: Bool = true) -> (bend: Float, peak: Float, held: Double)? {
                var dropped: (bend: Float, peak: Float, held: Double)?
                if var watch = released {
                    watch.lowest = min(watch.lowest, angle)
                    released = watch
                    if watch.lowest < watch.bent {
                        released = nil
                    } else if time - watch.at >= 0.15 || hold != nil {
                        released = nil
                        dropped = ((watch.lowest - watch.bent + 0.7 * watch.peak) * 180 / .pi, watch.peak * 180 / .pi, watch.held)
                    }
                }
                if var hold {
                    hold.recent = Array((hold.recent + [angle]).suffix(3))
                    let median = hold.median
                    if hold.peak - median >= Self.releaseRollback || hold.peak - angle >= Self.quickRollback {
                        self.hold = nil
                        history = [(angle, time)]
                        let peak = hold.peak - hold.base
                        // Still bent means at least 70% of the peak bend.
                        // Judge by the samples after the release, so one glitch reads as a drop.
                        released = (hold.base + 0.7 * peak, peak, time - hold.since, time, .infinity)
                        return dropped
                    }
                    hold.peak = max(hold.peak, median)
                    self.hold = hold
                    return dropped
                }

                history.removeAll { time - $0.time > Self.historyDuration }
                let minimum = translating ? Self.movingPressAngle : Self.pressAngle
                if allowPress, let start = history.first(where: { previous in
                    let elapsed = Float(time - previous.time)
                    let bend = angle - previous.angle
                    return elapsed > 0 && bend >= minimum && bend >= Self.pressSpeed * elapsed
                }) {
                    let base = history.filter { $0.time >= start.time }.map(\.angle).min() ?? start.angle
                    hold = Hold(base: base, peak: angle, recent: [angle], since: time)
                    history.removeAll(keepingCapacity: true)
                    return dropped
                }
                history.append((angle, time))
                return dropped
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
