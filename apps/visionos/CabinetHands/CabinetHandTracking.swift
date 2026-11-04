// license:GPLv3+

import ARKit
import QuartzCore
import simd

/// A preview and the eventual player can both use this adapter. Its action sink runs on the main actor.
@MainActor
final class CabinetHandTracking {
    private var controls: CabinetHandControls
    private let send: (CabinetInput) -> Void
    private var cabinetFromOrigin: simd_float4x4?

    init(layout: CabinetControlsLayout, send: @escaping (CabinetInput) -> Void) {
        controls = CabinetHandControls(layout: layout)
        self.send = send
    }

    func place(originFromCabinet: simd_float4x4) {
        reset()
        cabinetFromOrigin = originFromCabinet.inverse
    }

    func reset() {
        controls.reset().forEach(send)
    }

    func run(
        placeCabinet: @escaping (simd_float4x4) -> Void,
        report: (String) -> Void,
        acceptsInput: @escaping () -> Bool,
        tick: @escaping (Double) -> Void
    ) async {
        let session = ARKitSession()
        let hands = HandTrackingProvider()
        let world = WorldTrackingProvider()
        defer {
            session.stop()
            reset()
            cabinetFromOrigin = nil
        }

        var canTrackHands = false
        if HandTrackingProvider.isSupported {
            let authorization = await session.requestAuthorization(for: [.handTracking])
            canTrackHands = authorization[.handTracking] == .allowed
        }
        guard !Task.isCancelled else { return }

        do {
            if canTrackHands {
                try await session.run([world, hands])
            } else if WorldTrackingProvider.isSupported {
                try await session.run([world])
            }
        } catch {
            guard !Task.isCancelled else { return }
            report("Couldn’t start hand tracking.")
            return
        }
        guard !Task.isCancelled else { return }
        report(canTrackHands ? "Place your hands by the cabinet." : "Hand tracking is unavailable.")

        // Start in front of the wearer, then keep the cabinet fixed in world space.
        // When the simulator has no device pose, the preview scene supplies its own placement.
        if WorldTrackingProvider.isSupported {
            for _ in 0 ..< 90 {
                guard !Task.isCancelled else { return }
                if let anchor = world.queryDeviceAnchor(atTimestamp: CACurrentMediaTime()), anchor.isTracked {
                    let head = anchor.originFromAnchorTransform
                    let forward = SIMD3(-head.columns.2.x, 0, -head.columns.2.z)
                    if simd_length_squared(forward) > 0.05 {
                        let towardPlayer = -simd_normalize(forward)
                        let up = SIMD3<Float>(0, 1, 0)
                        let right = simd_cross(up, towardPlayer)
                        let position = head.columns.3.xyz - towardPlayer * 0.53 - up * 0.35
                        let transform = simd_float4x4(
                            SIMD4(right, 0), SIMD4(up, 0), SIMD4(towardPlayer, 0), SIMD4(position, 1)
                        )
                        place(originFromCabinet: transform)
                        placeCabinet(transform)
                        break
                    }
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        guard !Task.isCancelled else { return }
        guard canTrackHands else { return }
        guard cabinetFromOrigin != nil else {
            report("Couldn’t place the cabinet.")
            return
        }

        let watchdog = Task { @MainActor in
            while !Task.isCancelled {
                let now = CACurrentMediaTime()
                if acceptsInput() {
                    controls.expire(at: now).forEach(send)
                } else {
                    reset()
                }
                tick(now)
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        defer { watchdog.cancel() }
        for await change in hands.anchorUpdates {
            guard !Task.isCancelled else { return }
            if acceptsInput() {
                update(change.anchor, removed: change.event == .removed, at: CACurrentMediaTime())
            }
        }
    }

    private func update(_ anchor: HandAnchor, removed: Bool, at time: Double) {
        let side: CabinetHandSide = anchor.chirality == .left ? .left : .right
        guard !removed, let cabinetFromOrigin, anchor.isTracked, let skeleton = anchor.handSkeleton else {
            controls.update(side, sample: nil, at: time).forEach(send)
            return
        }
        let cabinetFromHand = cabinetFromOrigin * anchor.originFromAnchorTransform
        func joint(_ name: HandSkeleton.JointName) -> SIMD3<Float>? {
            let joint = skeleton.joint(name)
            guard joint.isTracked else { return nil }
            let point = (cabinetFromHand * joint.anchorFromJointTransform).columns.3.xyz
            return point.x.isFinite && point.y.isFinite && point.z.isFinite ? point : nil
        }
        let sample = CabinetHandSample(
            palm: joint(.middleFingerKnuckle), index: joint(.indexFingerTip)
        )
        controls.update(side, sample: sample, at: time).forEach(send)
    }
}

private extension SIMD4<Float> {
    var xyz: SIMD3<Float> { SIMD3(x, y, z) }
}
