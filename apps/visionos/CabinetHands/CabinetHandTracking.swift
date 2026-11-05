// license:GPLv3+

import ARKit
import OSLog
import QuartzCore
import simd

/// A preview and the eventual player can both use this adapter. Its action sink runs on the main actor.
@MainActor
final class CabinetHandTracking {
    private static let log = Logger(subsystem: "org.vpinball.cabinethands.preview", category: "Placement")
    private static let fistJoints: [(HandSkeleton.JointName, HandSkeleton.JointName, HandSkeleton.JointName)] = [
        (.indexFingerKnuckle, .indexFingerIntermediateBase, .indexFingerIntermediateTip),
        (.middleFingerKnuckle, .middleFingerIntermediateBase, .middleFingerIntermediateTip),
        (.ringFingerKnuckle, .ringFingerIntermediateBase, .ringFingerIntermediateTip),
        (.littleFingerKnuckle, .littleFingerIntermediateBase, .littleFingerIntermediateTip)
    ]
    var calibration: CabinetCalibration?
    private var controls: CabinetHandControls
    private(set) var layout: CabinetControlsLayout
    private let moveCabinet: ((simd_float4x4) -> Void)?
    private let placementMoving: (Bool) -> Void
    private var placementIsMoving = false
    private var roomPlacement: CabinetRoomPlacement?
    private var floorY: Float?
    private var watchSide: CabinetHandSide?
    private let showMenu: (() -> Void)?
    private var wristMenu = CabinetWristMenu()
    private let send: (CabinetInput) -> Void
    let world = WorldTrackingProvider()
    private var cabinetFromOrigin: simd_float4x4?

    init(layout: CabinetControlsLayout, moveCabinet: ((simd_float4x4) -> Void)? = nil,
         placementMoving: @escaping (Bool) -> Void = { _ in },
         watchSide: CabinetHandSide? = nil, showMenu: (() -> Void)? = nil,
         send: @escaping (CabinetInput) -> Void) {
        controls = CabinetHandControls(layout: layout)
        self.layout = layout
        self.moveCabinet = moveCabinet
        self.placementMoving = placementMoving
        self.watchSide = watchSide
        self.showMenu = showMenu
        self.send = send
    }

    func place(originFromCabinet: simd_float4x4) {
        reset()
        cabinetFromOrigin = originFromCabinet.inverse
    }

    func setWatchSide(_ side: CabinetHandSide) {
        watchSide = side
        wristMenu = CabinetWristMenu()
    }

    func setLayout(_ layout: CabinetControlsLayout) {
        reset()
        self.layout = layout
        controls = CabinetHandControls(layout: layout)
    }

    func placeForPlay(_ initial: simd_float4x4, height: Float, trackFloor: Bool, simulatedFloor: Float? = nil) -> simd_float4x4 {
        var pose = initial
        // The immersive origin is at floor level until a local floor is detected.
        let floor = simulatedFloor ?? floorY ?? 0
        if trackFloor { pose.columns.3.y = floor + height }
        let source = simulatedFloor != nil ? "simulated" : (floorY != nil ? "detected" : "immersive origin")
        Self.log.info("Cabinet floor: \(floor) m (\(source, privacy: .public)); cabinet height: \(height) m")
        place(originFromCabinet: pose)
        return pose
    }

    func beginEditing() -> Bool {
        guard roomPlacement == nil, let cabinetFromOrigin, moveCabinet != nil else { return false }
        roomPlacement = CabinetRoomPlacement(pose: cabinetFromOrigin.inverse)
        reset()
        return true
    }

    func finishEditing(keepPlacement: Bool) {
        if let edit = roomPlacement, !keepPlacement {
            place(originFromCabinet: edit.original)
            moveCabinet?(edit.original)
        }
        roomPlacement = nil
        reportMovement()
    }

    private func reportMovement() {
        let moving = roomPlacement?.isMoving == true
        if moving != placementIsMoving {
            placementIsMoving = moving
            placementMoving(moving)
        }
    }

    func reset() {
        let events = controls.reset()
        if events.contains(.cancelPlunger) {
            Self.log.info("Plunger grip cancelled by cabinet input reset")
        }
        events.forEach(send)
    }

    func serviceControls(at time: Double, playing: Bool) {
        if playing && roomPlacement == nil {
            let events = controls.expire(at: time)
            calibration?.observeSystemEvents(at: time, events: events)
            events.forEach(send)
        } else {
            reset()
        }
    }

    func run(
        placeCabinet: (simd_float4x4) -> simd_float4x4,
        report: (String) -> Void,
        acceptsInput: @escaping () -> Bool,
        tick: @escaping (Double) -> Void,
        trackFloor: Bool = false,
        allowsControls: @escaping () -> Bool = { true }
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
        if trackFloor && PlaneDetectionProvider.isSupported {
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
                let running = acceptsInput()
                roomPlacement?.expire(at: running ? now : .infinity)
                reportMovement()
                serviceControls(at: now, playing: running && allowsControls() && hands.state == .running)
                tick(now)
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        defer { watchdog.cancel() }
        for await change in hands.anchorUpdates {
            guard !Task.isCancelled else { return }
            if acceptsInput() && hands.state == .running {
                let now = CACurrentMediaTime()
                if roomPlacement != nil {
                    let anchor = change.anchor
                    let side: CabinetHandSide = anchor.chirality == .left ? .left : .right
                    let joint = anchor.handSkeleton?.joint(.wrist)
                    let wrist = change.event != .removed && anchor.isTracked && joint?.isTracked == true
                        ? joint.map { (anchor.originFromAnchorTransform * $0.anchorFromJointTransform).columns.3.xyz } : nil
                    updatePlacement(side, wrist: wrist, at: now)
                } else {
                    checkWrist(change.anchor, removed: change.event == .removed, at: now)
                    if allowsControls() {
                        update(change.anchor, removed: change.event == .removed, at: now)
                    }
                }
            }
        }
    }

    func updatePlacement(_ side: CabinetHandSide, wrist: SIMD3<Float>?, at time: Double) {
        let previous = roomPlacement?.pose
        roomPlacement?.update(side, wrist: wrist, at: time)
        reportMovement()
        if let pose = roomPlacement?.pose, pose != previous {
            cabinetFromOrigin = pose.inverse
            moveCabinet?(pose)
        }
    }

    #if targetEnvironment(simulator)
    var simulatorRoomPose: simd_float4x4? { cabinetFromOrigin?.inverse }

    func simulateControl(_ side: CabinetHandSide, sample: CabinetHandSample?, at time: Double) {
        if roomPlacement == nil { sendControlSample(side, sample: sample, at: time) }
    }
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

    private func checkWrist(_ anchor: HandAnchor, removed: Bool, at time: Double) {
        let side: CabinetHandSide = anchor.chirality == .left ? .left : .right
        guard side == watchSide, let showMenu else { return }
        func joint(_ name: HandSkeleton.JointName) -> SIMD3<Float>? {
            guard !removed, anchor.isTracked, let joint = anchor.handSkeleton?.joint(name), joint.isTracked else { return nil }
            return (anchor.originFromAnchorTransform * joint.anchorFromJointTransform).columns.3.xyz
        }
        let head = Self.trackedPose(world.queryDeviceAnchor(atTimestamp: time))
        if let wrist = joint(.wrist), let middle = joint(.middleFingerKnuckle),
           let index = joint(.indexFingerKnuckle), let little = joint(.littleFingerKnuckle) {
            let direction = middle - wrist
            let normal = side.sign * simd_cross(index - little, direction)
            if wristMenu.update(head: head, wrist: wrist, fingers: direction, palmNormal: normal, at: time) {
                showMenu()
            }
        } else {
            _ = wristMenu.update(head: nil, wrist: nil, fingers: nil, palmNormal: nil, at: time)
        }
    }

    private func update(_ anchor: HandAnchor, removed: Bool, at time: Double) {
        let side: CabinetHandSide = anchor.chirality == .left ? .left : .right
        let trackedSkeleton = !removed && anchor.isTracked ? anchor.handSkeleton : nil
        guard let cabinetFromOrigin, let skeleton = trackedSkeleton else {
            sendControlSample(side, sample: nil, at: time)
            return
        }
        let cabinetFromHand = cabinetFromOrigin * anchor.originFromAnchorTransform
        func joint(_ name: HandSkeleton.JointName) -> CabinetHandJoint {
            let joint = skeleton.joint(name)
            let point = (cabinetFromHand * joint.anchorFromJointTransform).columns.3.xyz
            return CabinetHandJoint(point: point, isTracked: joint.isTracked)
        }
        let palm = joint(.middleFingerKnuckle)
        let wrist = joint(.wrist)
        let indexKnuckle = joint(.indexFingerKnuckle)
        let littleKnuckle = joint(.littleFingerKnuckle)
        let fingerDirection: SIMD3<Float>?
        if let palm = palm.trackedPosition, let wrist = wrist.trackedPosition {
            fingerDirection = palm - wrist
        } else {
            fingerDirection = nil
        }
        let palmNormal: SIMD3<Float>?
        if let fingerDirection, let index = indexKnuckle.trackedPosition,
           let little = littleKnuckle.trackedPosition {
            // This order gives both palms the same outward-facing normal relative to their joints.
            palmNormal = side.sign * simd_cross(index - little, fingerDirection)
        } else {
            palmNormal = nil
        }
        let indexTip = joint(.indexFingerTip)
        var sample = CabinetHandSample(
            palm: palm.trackedPosition, index: indexTip.trackedPosition,
            fingerDirection: fingerDirection, palmNormal: palmNormal
        )
        if layout.usesWristGestures {
            let wristPosition = wrist.estimatedPosition ?? cabinetFromHand.columns.3.xyz
            if let palmPosition = palm.estimatedPosition {
                sample.fingerDirection = palmPosition - wristPosition
            }
            let forearmWrist = joint(.forearmWrist).estimatedPosition ?? wristPosition
            if let arm = joint(.forearmArm).estimatedPosition {
                sample.forearmDirection = forearmWrist - arm
            }
            let fingers = Self.fistJoints.map { knuckle, bend, next in
                CabinetHandPose.Finger(knuckle: joint(knuckle), bend: joint(bend), next: joint(next))
            }
            sample.recognizeGrip(wrist: wristPosition,
                                 palm: palm, fingers: fingers)
        }
        let metrics: CalibrationMetrics?
        if layout.plunger != nil || calibration?.isRecording == true {
            let thumb = joint(.thumbTip)
            let geometry = CabinetPlungerGeometry(side: side, wrist: wrist, palm: palm, index: indexKnuckle,
                                                  little: littleKnuckle, indexTip: indexTip, thumb: thumb)
            if layout.plunger != nil { sample.plungerPose = geometry.pose }
            metrics = calibration?.isRecording == true
                ? CalibrationMetrics(side: side, sample: sample, layout: layout, geometry: geometry,
                                     thumbTipTracked: thumb.isTracked)
                : nil
        } else {
            metrics = nil
        }
        sendControlSample(side, sample: sample, at: time, metrics: metrics)
    }

    private func sendControlSample(
        _ side: CabinetHandSide, sample: CabinetHandSample?, at time: Double, metrics: CalibrationMetrics? = nil
    ) {
        let events = controls.update(side, sample: sample, at: time)
        calibration?.observe(side: side, at: time, sample: sample, metrics: metrics, events: events, nudgePhase: controls.nudgePhase)
        events.forEach(send)
    }
}

private extension SIMD4<Float> {
    var xyz: SIMD3<Float> { SIMD3(x, y, z) }
}
