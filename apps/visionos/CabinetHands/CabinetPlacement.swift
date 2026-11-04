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
