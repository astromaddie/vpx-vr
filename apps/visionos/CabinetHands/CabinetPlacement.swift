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

/// Both pinches must start at the cabinet sides. Only their horizontal
/// midpoint and heading can move the cabinet, so it stays on the floor.
struct CabinetRoomPlacement {
    private struct Contact {
        let point: SIMD3<Float>
        let gap: Float
        let time: Double
    }

    private struct Grab {
        let pose: simd_float4x4
        let center: SIMD3<Float>
        let heading: SIMD2<Float>
    }

    private static let pinchDistance: Float = 0.024
    private static let releaseDistance: Float = 0.041
    private static let sampleLifetime = 0.12

    let width: Float
    var pose: simd_float4x4
    private var contacts: [CabinetHandSide: Contact] = [:]
    private var grab: Grab?
    private var needsRelease = false
    private var armed: Set<CabinetHandSide> = []
    private var lastMove: Double = -.infinity
    var isMoving: Bool { grab != nil }

    init(width: Float, pose: simd_float4x4) {
        self.width = width
        self.pose = pose
    }

    mutating func update(_ side: CabinetHandSide, index: SIMD3<Float>?, thumb: SIMD3<Float>?, at time: Double) {
        if let index, let thumb {
            contacts[side] = Contact(point: (index + thumb) * 0.5, gap: simd_distance(index, thumb), time: time)
        } else {
            contacts.removeValue(forKey: side)
        }

        expire(at: time)
        if !isMoving {
            if let contact = contacts[side], nearEdge(contact, side) {
                if contact.gap >= Self.releaseDistance { armed.insert(side) }
            } else {
                armed.remove(side)
            }
        }
        guard let left = contacts[.left], let right = contacts[.right],
              time - min(left.time, right.time) <= Self.sampleLifetime else { return }
        if needsRelease {
            if left.gap >= Self.releaseDistance && right.gap >= Self.releaseDistance {
                needsRelease = false
            }
            return
        }

        let center = (left.point + right.point) * 0.5
        let axis = SIMD2(right.point.x - left.point.x, right.point.z - left.point.z)
        let span = simd_length(axis)
        guard span >= 0.22 else { return }
        let heading = axis / span
        if let grab {
            // Apply one pose per pair of new samples to avoid alternating hand jitter.
            guard min(left.time, right.time) > lastMove else { return }
            lastMove = max(left.time, right.time)
            let cosine = simd_dot(grab.heading, heading)
            let sine = grab.heading.y * heading.x - grab.heading.x * heading.y
            let rotation = simd_float4x4(
                SIMD4(cosine, 0, -sine, 0), SIMD4(0, 1, 0, 0),
                SIMD4(sine, 0, cosine, 0), SIMD4(0, 0, 0, 1))
            var moved = rotation * grab.pose
            let pivot = rotation * (grab.pose.columns.3 - SIMD4(grab.center, 1)) + SIMD4(center, 1)
            moved.columns.3 = SIMD4(pivot.x, grab.pose.columns.3.y, pivot.z, 1)
            pose = moved
        } else if armed.count == 2 && left.gap <= Self.pinchDistance && right.gap <= Self.pinchDistance {
            grab = Grab(pose: pose, center: center, heading: heading)
            lastMove = max(left.time, right.time)
        }
    }

    private func nearEdge(_ contact: Contact, _ side: CabinetHandSide) -> Bool {
        let local = pose.inverse * SIMD4(contact.point, 1)
        let edge = SIMD3(side.sign * width * 0.5, -0.05, -0.12)
        return simd_distance(SIMD3(local.x, local.y, local.z), edge) <= 0.13
    }

    mutating func expire(at time: Double) {
        guard isMoving else { return }
        if CabinetHandSide.allCases.contains(where: { side in
            guard let contact = contacts[side] else { return true }
            return time - contact.time > Self.sampleLifetime || contact.gap >= Self.releaseDistance
        }) {
            grab = nil
            needsRelease = true
            armed.removeAll()
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
