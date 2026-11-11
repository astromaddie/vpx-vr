// license:GPLv3+

import ARKit
import OSLog
import QuartzCore
import os
import simd

/// A preview and the eventual player can both use this adapter. Its action sink runs on the main actor.
@MainActor
final class CabinetHandTracking {
    private static let log = Logger(subsystem: "org.vpinball.cabinethands.preview", category: "Placement")
    var calibration: CabinetCalibration? {
        didSet {
            calibration?.layout = layout
            input.setRecorder(calibration?.recorder)
        }
    }
    /// The recognizers run on the hand-tracking thread, so a slow VPX frame on
    /// the main thread doesn't hold them up. `deliver()` hands their inputs over.
    let input: CabinetHandInput
    private(set) var layout: CabinetControlsLayout
    /// Host time of the latest hand anchor update, for the player's input diagnostics.
    var lastHandUpdate: Double { input.lastHandUpdate }
    /// How old the hand data behind the input being sent was, and how long it
    /// waited for the main thread, in seconds. Set during each `send`.
    private(set) var deliveryTiming: (age: Double, queued: Double, lead: Double)?
    /// Diagnostic lines from the recognizers, such as dropped flipper holds.
    var note: ((String) -> Void)?
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
        input = CabinetHandInput(layout: layout)
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
        input.place(cabinetFromOrigin)
    }

    func setWatchSide(_ side: CabinetHandSide) {
        watchSide = side
        wristMenu = CabinetWristMenu()
    }

    func setLayout(_ layout: CabinetControlsLayout) {
        reset()
        self.layout = layout
        calibration?.layout = layout
        input.setLayout(layout)
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
        let events = input.reset()
        if events.contains(.cancelPlunger) {
            Self.log.info("Plunger grip cancelled by cabinet input reset")
        }
        deliver()
        events.forEach(send)
    }

    func serviceControls(at time: Double, playing: Bool) {
        if playing && roomPlacement == nil {
            input.setEnabled(true)
            input.expire(at: time)
            deliver()
        } else {
            input.setEnabled(false)
            reset()
        }
    }

    /// Sends the inputs the recognizers have queued. Call it on every main-loop turn.
    func deliver() {
        let (deliveries, notes) = input.drain()
        notes.forEach { note?($0) }
        guard !deliveries.isEmpty else { return }
        let now = CACurrentMediaTime()
        for delivery in deliveries {
            deliveryTiming = (now - delivery.dataTime, now - delivery.recognizedAt, delivery.lead)
            send(delivery.input)
        }
        deliveryTiming = nil
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
            input.place(nil)
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
                inputAccepted = running
                roomPlacement?.expire(at: running ? now : .infinity)
                reportMovement()
                serviceControls(at: now, playing: running && allowsControls() && hands.state == .running)
                tick(now)
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        defer { watchdog.cancel() }
        // Recognize off the main thread. The main thread only gets the
        // anchors it needs for the wrist menu and placement editing.
        let input = input
        let recognition = Task.detached(priority: .userInitiated) { [weak self] in
            for await change in hands.anchorUpdates {
                guard !Task.isCancelled else { return }
                let side: CabinetHandSide = change.anchor.chirality == .left ? .left : .right
                let removed = change.event == .removed
                input.process(side, update: change.anchor, removed: removed, captured: change.timestamp,
                              predicted: CabinetHandTracking.usesPrediction ? hands : nil)
                let anchor = change.anchor
                Task { @MainActor [weak self] in
                    self?.handleOnMain(anchor, removed: removed)
                }
            }
        }
        await withTaskCancellationHandler {
            await recognition.value
        } onCancel: {
            recognition.cancel()
        }
    }

    /// Predict the hand pose at the moment the recognizers run, from ARKit's
    /// `handAnchors(at:)` (visionOS 2 and later). It makes up for the hand
    /// tracking delay. Each input logs how old its hand data was.
    nonisolated static let usesPrediction = true

    private var inputAccepted = false

    private func handleOnMain(_ anchor: HandAnchor, removed: Bool) {
        guard inputAccepted else { return }
        let now = CACurrentMediaTime()
        if roomPlacement != nil {
            let side: CabinetHandSide = anchor.chirality == .left ? .left : .right
            let joint = anchor.handSkeleton?.joint(.wrist)
            let wrist = !removed && anchor.isTracked && joint?.isTracked == true
                ? joint.map { (anchor.originFromAnchorTransform * $0.anchorFromJointTransform).columns.3.xyz } : nil
            updatePlacement(side, wrist: wrist, at: now)
        } else {
            checkWrist(anchor, removed: removed, at: now)
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
        guard roomPlacement == nil else { return }
        input.setEnabled(true)
        input.process(side, sample: sample, at: time, captured: CACurrentMediaTime())
        deliver()
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

}

/// The hand recognizers and the inputs they have queued for the main thread.
/// Any thread can call it.
final class CabinetHandInput: @unchecked Sendable {
    struct Delivery {
        let input: CabinetInput
        /// When the hand data behind the input was captured or predicted for, in host time.
        let dataTime: Double
        let recognizedAt: Double
        /// How far ahead of the tracked capture the predicted pose was, in seconds.
        let lead: Double
    }

    private struct State {
        var controls: CabinetHandControls
        var cabinetFromOrigin: simd_float4x4?
        var enabled = false
        var pending: [Delivery] = []
        var notes: [String] = []
        var lastTime: [Double] = [-.infinity, -.infinity]
        var lastHandUpdate = 0.0
        var recorder: CabinetHandRecorder?
    }

    private let state: OSAllocatedUnfairLock<State>

    init(layout: CabinetControlsLayout) {
        state = OSAllocatedUnfairLock(initialState: State(controls: CabinetHandControls(layout: layout)))
    }

    var lastHandUpdate: Double { state.withLock { $0.lastHandUpdate } }

    func setLayout(_ layout: CabinetControlsLayout) {
        state.withLock { $0.controls = CabinetHandControls(layout: layout) }
    }

    func place(_ cabinetFromOrigin: simd_float4x4?) {
        state.withLock { $0.cabinetFromOrigin = cabinetFromOrigin }
    }

    func setRecorder(_ recorder: CabinetHandRecorder?) {
        state.withLock { $0.recorder = recorder }
    }

    func setEnabled(_ enabled: Bool) {
        state.withLock { $0.enabled = enabled }
    }

    func reset() -> [CabinetInput] {
        state.withLock { state in
            state.pending.removeAll()
            return state.controls.reset()
        }
    }

    func expire(at time: Double) {
        state.withLock { state in
            guard state.enabled else { return }
            let events = state.controls.expire(at: time)
            state.notes += state.controls.takeNotes()
            state.pending += events.map { Delivery(input: $0, dataTime: time, recognizedAt: time, lead: 0) }
        }
    }

    func drain() -> ([Delivery], [String]) {
        state.withLock { state in
            defer {
                state.pending.removeAll(keepingCapacity: true)
                state.notes.removeAll(keepingCapacity: true)
            }
            return (state.pending, state.notes)
        }
    }

    /// Converts an anchor update to cabinet space and runs the recognizers.
    func process(_ side: CabinetHandSide, update anchor: HandAnchor, removed: Bool, captured: Double,
                 predicted hands: HandTrackingProvider?) {
        let now = CACurrentMediaTime()
        var source = anchor
        var time = captured
        if let hands, !removed {
            let pose = hands.handAnchors(at: now)
            if let latest = side == .left ? pose.leftHand : pose.rightHand, latest.isTracked {
                source = latest
                time = now
            }
        }
        let cabinetFromOrigin = state.withLock { $0.cabinetFromOrigin }
        let frame: CabinetHandFrame?
        if !removed, source.isTracked, let skeleton = source.handSkeleton, let cabinetFromOrigin {
            let cabinetFromHand = cabinetFromOrigin * source.originFromAnchorTransform
            frame = CabinetHandFrame(origin: cabinetFromHand.columns.3.xyz, joints: CabinetJoint.allCases.map { name in
                let joint = skeleton.joint(Self.jointName(name))
                return CabinetHandJoint(point: (cabinetFromHand * joint.anchorFromJointTransform).columns.3.xyz,
                                        isTracked: joint.isTracked)
            })
        } else {
            frame = nil
        }
        process(side, frame: frame, at: time, captured: time, lead: time - captured)
    }

    func process(_ side: CabinetHandSide, frame: CabinetHandFrame?, at time: Double, captured: Double, lead: Double = 0) {
        state.withLock { state in
            state.lastHandUpdate = CACurrentMediaTime()
            let sample = frame.map { CabinetHandSample(side, frame: $0, layout: state.controls.layout) }
            let events = Self.run(&state, side, sample: sample, at: time, captured: captured, lead: lead)
            state.recorder?.record(side, at: time, frame: frame, events: events)
        }
    }

    func process(_ side: CabinetHandSide, sample: CabinetHandSample?, at time: Double, captured: Double) {
        state.withLock { _ = Self.run(&$0, side, sample: sample, at: time, captured: captured) }
    }

    private static func run(_ state: inout State, _ side: CabinetHandSide, sample: CabinetHandSample?,
                            at time: Double, captured: Double, lead: Double = 0) -> [CabinetInput] {
        // Keep each hand's clock moving forward when predicted and captured times mix.
        let index = side == .left ? 0 : 1
        let time = max(time, state.lastTime[index] + 0.0005)
        state.lastTime[index] = time
        guard state.enabled else { return [] }
        let events = state.controls.update(side, sample: sample, at: time)
        state.notes += state.controls.takeNotes()
        let now = CACurrentMediaTime()
        state.pending += events.map { Delivery(input: $0, dataTime: captured, recognizedAt: now, lead: lead) }
        return events
    }

    private static func jointName(_ joint: CabinetJoint) -> HandSkeleton.JointName {
        switch joint {
        case .wrist: .wrist
        case .forearmWrist: .forearmWrist
        case .forearmArm: .forearmArm
        case .thumbTip: .thumbTip
        case .indexKnuckle: .indexFingerKnuckle
        case .indexBend: .indexFingerIntermediateBase
        case .indexNext: .indexFingerIntermediateTip
        case .indexTip: .indexFingerTip
        case .middleKnuckle: .middleFingerKnuckle
        case .middleBend: .middleFingerIntermediateBase
        case .middleNext: .middleFingerIntermediateTip
        case .ringKnuckle: .ringFingerKnuckle
        case .ringBend: .ringFingerIntermediateBase
        case .ringNext: .ringFingerIntermediateTip
        case .littleKnuckle: .littleFingerKnuckle
        case .littleBend: .littleFingerIntermediateBase
        case .littleNext: .littleFingerIntermediateTip
        }
    }
}

private extension SIMD4<Float> {
    var xyz: SIMD3<Float> { SIMD3(x, y, z) }
}
