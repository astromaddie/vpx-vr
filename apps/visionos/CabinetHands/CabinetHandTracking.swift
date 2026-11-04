// license:GPLv3+

import ARKit
import OSLog
import QuartzCore
import simd

/// A preview and the eventual player can both use this adapter. Its action sink runs on the main actor.
@MainActor
final class CabinetHandTracking {
    private static let log = Logger(subsystem: "org.vpinball.cabinethands.preview", category: "Placement")
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
        placeCabinet: (simd_float4x4) -> simd_float4x4,
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
        report("Look toward where you want the cabinet and hold steady.")
        if WorldTrackingProvider.isSupported {
            var placement = CabinetPlacement()
            for _ in 0 ..< 250 {
                guard !Task.isCancelled else { return }
                let now = CACurrentMediaTime()
                let anchor = world.queryDeviceAnchor(atTimestamp: now)
                let head = acceptsInput() ? Self.trackedPose(anchor) : nil
                if let transform = placement.sample(head, at: now), let head {
                    let rendered = placeCabinet(transform)
                    place(originFromCabinet: rendered)
                    let eyeDrop = head.columns.3.y - rendered.columns.3.y
                    let edgeRise = rendered.columns.0.y
                    let gaze = atan2(head.columns.2.x, head.columns.2.z)
                    let heading = atan2(rendered.columns.2.x, rendered.columns.2.z)
                    let headingError = atan2(sin(heading - gaze), cos(heading - gaze)) * 180 / .pi
                    Self.log.info("Cabinet placement: \(eyeDrop) m below head; heading error \(headingError) degrees; front edge rise \(edgeRise) m per metre")
                    break
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        guard !Task.isCancelled else { return }
        guard cabinetFromOrigin != nil else {
            #if targetEnvironment(simulator)
            report("Hand tracking is unavailable in this preview.")
            #else
            report("Couldn’t place the cabinet. Close it and try again while looking ahead.")
            #endif
            return
        }
        report(canTrackHands ? "Place your hands by the cabinet." : "Hand tracking is unavailable.")
        guard canTrackHands else { return }

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

    private static func trackedPose(_ anchor: DeviceAnchor?) -> simd_float4x4? {
        guard let anchor, anchor.isTracked else { return nil }
        if #available(visionOS 26.0, *), anchor.trackingState != .tracked { return nil }
        return anchor.originFromAnchorTransform
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
        let palm = joint(.middleFingerKnuckle)
        let fingerDirection: SIMD3<Float>?
        if let palm, let wrist = joint(.wrist) {
            fingerDirection = palm - wrist
        } else {
            fingerDirection = nil
        }
        let palmNormal: SIMD3<Float>?
        if let fingerDirection, let index = joint(.indexFingerKnuckle), let little = joint(.littleFingerKnuckle) {
            // This order gives both palms the same outward-facing normal relative to their joints.
            palmNormal = side.sign * simd_cross(index - little, fingerDirection)
        } else {
            palmNormal = nil
        }
        let sample = CabinetHandSample(
            palm: palm, index: joint(.indexFingerTip), fingerDirection: fingerDirection, palmNormal: palmNormal
        )
        controls.update(side, sample: sample, at: time).forEach(send)
    }
}

private extension SIMD4<Float> {
    var xyz: SIMD3<Float> { SIMD3(x, y, z) }
}
