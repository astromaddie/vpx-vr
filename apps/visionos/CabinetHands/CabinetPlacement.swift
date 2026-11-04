// license:GPLv3+

import simd

/// Place the cabinet from a settled headset pose. The cabinet's Y axis stays
/// aligned with world up and its front edge stays level even when the head rolls.
struct CabinetPlacement {
    static let eyeDrop: Float = 0.25
    private static let distance: Float = 0.53
    private static let settleSeconds = 0.5
    private static let maxPositionDrift: Float = 0.025
    private static let minimumHeadingDot: Float = cos(3 * .pi / 180)

    private var reference: (time: Double, position: SIMD3<Float>, towardPlayer: SIMD3<Float>)?
    private var lastSample: Double?

    mutating func sample(_ originFromHead: simd_float4x4?, at time: Double) -> simd_float4x4? {
        guard let head = originFromHead else {
            reference = nil
            lastSample = nil
            return nil
        }
        let position = SIMD3(head.columns.3.x, head.columns.3.y, head.columns.3.z)
        let horizontal = SIMD3(head.columns.2.x, 0, head.columns.2.z)
        guard position.x.isFinite, position.y.isFinite, position.z.isFinite,
              horizontal.x.isFinite, horizontal.z.isFinite,
              simd_length_squared(horizontal) > 0.05 else {
            reference = nil
            lastSample = nil
            return nil
        }
        let towardPlayer = simd_normalize(horizontal)
        let continuous = lastSample.map { time >= $0 && time - $0 <= 0.12 } ?? false
        lastSample = time
        guard continuous, let reference,
              simd_distance(reference.position, position) <= Self.maxPositionDrift,
              simd_dot(reference.towardPlayer, towardPlayer) >= Self.minimumHeadingDot else {
            reference = (time, position, towardPlayer)
            return nil
        }
        guard time - reference.time >= Self.settleSeconds else { return nil }

        let up = SIMD3<Float>(0, 1, 0)
        let right = simd_cross(up, towardPlayer)
        let front = position - towardPlayer * Self.distance - up * Self.eyeDrop
        return simd_float4x4(SIMD4(right, 0), SIMD4(up, 0), SIMD4(towardPlayer, 0), SIMD4(front, 1))
    }
}

/// Placement uses a paired wrist sample only while the editing panel is open.
struct CabinetRoomPlacement {
    private struct Contact {
        let point: SIMD3<Float>
        let time: Double
    }

    private struct Hold {
        let pose: simd_float4x4
        let center: SIMD3<Float>
        let heading: SIMD2<Float>
    }

    let original: simd_float4x4
    private(set) var pose: simd_float4x4
    private var contacts: [CabinetHandSide: Contact] = [:]
    private var hold: Hold?
    private var readySince: Double?
    private var lastPair: Double = -.infinity
    var isMoving: Bool { hold != nil }

    init(pose: simd_float4x4) {
        original = pose
        self.pose = pose
    }

    mutating func update(_ side: CabinetHandSide, wrist: SIMD3<Float>?, at time: Double) {
        let minimumY = pose.columns.3.y + (isMoving ? 0.015 : 0.075)
        if let wrist, wrist.y >= minimumY {
            contacts[side] = Contact(point: wrist, time: time)
        } else {
            contacts.removeValue(forKey: side)
        }
        expire(at: time)
        guard let left = contacts[.left], let right = contacts[.right],
              min(left.time, right.time) > lastPair else { return }
        // Apply one pose per pair of new samples to avoid alternating hand jitter.
        lastPair = max(left.time, right.time)

        let center = (left.point + right.point) * 0.5
        let axis = SIMD2(right.point.x - left.point.x, right.point.z - left.point.z)
        let span = simd_length(axis)
        guard (0.23...1.15).contains(span) else {
            hold = nil
            readySince = nil
            return
        }
        let heading = axis / span
        if let hold {
            let cosine = simd_dot(hold.heading, heading)
            let sine = hold.heading.y * heading.x - hold.heading.x * heading.y
            let rotation = simd_float4x4(
                SIMD4(cosine, 0, -sine, 0), SIMD4(0, 1, 0, 0),
                SIMD4(sine, 0, cosine, 0), SIMD4(0, 0, 0, 1))
            var moved = rotation * hold.pose
            let pivot = rotation * (hold.pose.columns.3 - SIMD4(hold.center, 1)) + SIMD4(center, 1)
            moved.columns.3 = SIMD4(pivot.x, hold.pose.columns.3.y, pivot.z, 1)
            pose = moved
        } else {
            readySince = readySince ?? time
            if time - (readySince ?? time) >= 0.28 {
                hold = Hold(pose: pose, center: center, heading: heading)
            }
        }
    }

    mutating func expire(at time: Double) {
        for side in CabinetHandSide.allCases {
            if let contact = contacts[side], time - contact.time > 0.18 {
                contacts.removeValue(forKey: side)
            }
        }
        if contacts.count != 2 {
            hold = nil
            readySince = nil
        }
    }
}

/// Use head direction and the tracked back of the hand for a watch glance.
/// Require a dwell, and then a sustained release before showing another menu.
struct CabinetWristMenu {
    private var enteredAt: Double?
    private var releasedAt: Double?
    private var lastSample: Double?
    private var latched = false

    mutating func update(
        head: simd_float4x4?, wrist: SIMD3<Float>?, fingers: SIMD3<Float>?,
        palmNormal: SIMD3<Float>?, at time: Double
    ) -> Bool {
        let gap = lastSample.map { time - $0 } ?? .infinity
        let continuous = (0...0.16).contains(gap)
        if gap >= 0.25 { latched = false }
        lastSample = time
        if !continuous { enteredAt = nil }
        let looking: Bool
        if let head, let wrist, let fingers, let palmNormal {
            let eye = SIMD3(head.columns.3.x, head.columns.3.y, head.columns.3.z)
            let forward = -SIMD3(head.columns.2.x, head.columns.2.y, head.columns.2.z)
            let toWrist = wrist - eye
            let distance = simd_length(toWrist)
            let handDirection = simd_normalize(fingers)
            looking = (0.24...0.80).contains(distance) && toWrist.y < -0.12
                && simd_dot(toWrist / distance, forward) > 0.957
                && simd_dot(toWrist / distance, simd_normalize(palmNormal)) > 0.55
                && abs(handDirection.y) < 0.65
                && abs(simd_dot(handDirection, forward)) < 0.65
        } else {
            looking = false
        }

        if !looking {
            enteredAt = nil
            releasedAt = releasedAt ?? time
            if time - (releasedAt ?? time) >= 0.25 { latched = false }
            return false
        }
        releasedAt = nil
        guard !latched else { return false }
        enteredAt = enteredAt ?? time
        guard time - (enteredAt ?? time) >= 0.45 else { return false }
        latched = true
        return true
    }
}
