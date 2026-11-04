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
    private let layout: CabinetControlsLayout
    private let moveCabinet: ((simd_float4x4) -> Void)?
    private var roomPlacement: CabinetRoomPlacement?
    private var floorY: Float?
    private let send: (CabinetInput) -> Void
    let world = WorldTrackingProvider()
    private var cabinetFromOrigin: simd_float4x4?

    init(layout: CabinetControlsLayout, moveCabinet: ((simd_float4x4) -> Void)? = nil,
         send: @escaping (CabinetInput) -> Void) {
        controls = CabinetHandControls(layout: layout)
        self.layout = layout
        self.moveCabinet = moveCabinet
        self.send = send
    }

    func place(originFromCabinet: simd_float4x4) {
        reset()
        cabinetFromOrigin = originFromCabinet.inverse
    }

    func placeOnFloor(_ initial: simd_float4x4, height: Float, simulatedFloor: Float? = nil) -> simd_float4x4 {
        var pose = initial
        // The immersive origin is at floor level until a local floor is detected.
        let floor = simulatedFloor ?? floorY ?? 0
        pose.columns.3.y = floor + height
        let source = simulatedFloor != nil ? "simulated" : (floorY != nil ? "detected" : "immersive origin")
        Self.log.info("Cabinet floor: \(floor) m (\(source, privacy: .public)); cabinet height: \(height) m")
        roomPlacement = CabinetRoomPlacement(width: layout.width, pose: pose)
        place(originFromCabinet: pose)
        return pose
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
        let planes = PlaneDetectionProvider(alignments: [.horizontal])
        var floors: [UUID: simd_float4x4] = [:]
        var planeUpdates: Task<Void, Never>?
        defer {
            planeUpdates?.cancel()
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

        var providers: [any DataProvider] = [world]
        if canTrackHands { providers.append(hands) }
        let canDetectFloor: Bool
        if moveCabinet != nil && PlaneDetectionProvider.isSupported {
            let authorization = await session.requestAuthorization(for: [.worldSensing])
            canDetectFloor = authorization[.worldSensing] == .allowed
        } else {
            canDetectFloor = false
        }
        guard !Task.isCancelled else { return }
        if canDetectFloor { providers.append(planes) }
        do {
            try await session.run(providers)
        } catch {
            guard !Task.isCancelled else { return }
            report("Couldn’t start hand tracking.")
            return
        }
        guard !Task.isCancelled else { return }
        if canDetectFloor {
            planeUpdates = Task { @MainActor in
                for await change in planes.anchorUpdates {
                    guard !Task.isCancelled else { return }
                    let anchor = change.anchor
                    if change.event == .removed || !Self.isFloor(anchor) {
                        floors.removeValue(forKey: anchor.id)
                    } else {
                        let center = anchor.originFromAnchorTransform * anchor.geometry.extent.anchorFromExtentTransform
                        floors[anchor.id] = center
                    }
                }
            }
        }
        report("Look toward where you want the cabinet and hold steady.")
        if WorldTrackingProvider.isSupported {
            var placement = CabinetPlacement()
            var floorWaitStart: Double?
            for _ in 0 ..< 250 {
                guard !Task.isCancelled else { return }
                let now = CACurrentMediaTime()
                let anchor = world.queryDeviceAnchor(atTimestamp: now)
                let head = acceptsInput() ? Self.trackedPose(anchor) : nil
                if let transform = placement.sample(head, at: now), let head {
                    floorWaitStart = floorWaitStart ?? now
                    if canDetectFloor {
                        let eye = head.columns.3.xyz
                        let target = transform.columns.3.xyz
                        floorY = floors.values.map { $0.columns.3.xyz }
                            .filter { (0.45...2.5).contains(eye.y - $0.y) }
                            .min { simd_distance_squared($0, target) < simd_distance_squared($1, target) }?.y
                        if floorY == nil, now - (floorWaitStart ?? now) < 1.5 {
                            try? await Task.sleep(for: .milliseconds(20))
                            continue
                        }
                    }
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
        guard canTrackHands else {
            // The compositor still needs the world provider for its eye poses.
            while !Task.isCancelled { try? await Task.sleep(for: .seconds(1)) }
            return
        }

        let watchdog = Task { @MainActor in
            while !Task.isCancelled {
                let now = CACurrentMediaTime()
                roomPlacement?.expire(at: acceptsInput() ? now : .infinity)
                if acceptsInput() && roomPlacement?.isMoving != true {
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

    @discardableResult
    func updateRoomContact(_ side: CabinetHandSide, index: SIMD3<Float>?, thumb: SIMD3<Float>?, at time: Double) -> Bool {
        let wasMoving = roomPlacement?.isMoving == true
        let oldPose = roomPlacement?.pose
        roomPlacement?.update(side, index: index, thumb: thumb, at: time)
        guard let roomPlacement, roomPlacement.isMoving else { return false }
        if !wasMoving { reset() }
        if roomPlacement.pose != oldPose {
            cabinetFromOrigin = roomPlacement.pose.inverse
            moveCabinet?(roomPlacement.pose)
        }
        return true
    }

    #if targetEnvironment(simulator)
    var simulatorRoomPose: simd_float4x4? { roomPlacement?.pose }
    #endif

    private static func isFloor(_ anchor: PlaneAnchor) -> Bool {
        if #available(visionOS 26.0, *) {
            return anchor.surfaceClassification == .floor
        }
        return false
    }

    private static func trackedPose(_ anchor: DeviceAnchor?) -> simd_float4x4? {
        guard let anchor, anchor.isTracked else { return nil }
        if #available(visionOS 26.0, *), anchor.trackingState != .tracked { return nil }
        return anchor.originFromAnchorTransform
    }

    private func update(_ anchor: HandAnchor, removed: Bool, at time: Double) {
        let side: CabinetHandSide = anchor.chirality == .left ? .left : .right
        let trackedSkeleton = !removed && anchor.isTracked ? anchor.handSkeleton : nil
        if roomPlacement != nil {
            func originJoint(_ name: HandSkeleton.JointName) -> SIMD3<Float>? {
                guard let joint = trackedSkeleton?.joint(name), joint.isTracked else { return nil }
                let point = (anchor.originFromAnchorTransform * joint.anchorFromJointTransform).columns.3.xyz
                return point.x.isFinite && point.y.isFinite && point.z.isFinite ? point : nil
            }
            if updateRoomContact(side, index: originJoint(.indexFingerTip), thumb: originJoint(.thumbTip), at: time) {
                return
            }
        }
        guard let cabinetFromOrigin, let skeleton = trackedSkeleton else {
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
            palm: palm, index: joint(.indexFingerTip), fingerDirection: fingerDirection, palmNormal: palmNormal,
            thumb: layout.plunger != nil ? joint(.thumbTip) : nil
        )
        controls.update(side, sample: sample, at: time).forEach(send)
    }
}

private extension SIMD4<Float> {
    var xyz: SIMD3<Float> { SIMD3(x, y, z) }
}
