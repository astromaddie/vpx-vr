// license:GPLv3+

import CompositorServices
import simd
import SwiftUI

private enum TableEnvironment: String, CaseIterable {
    case physical = "Your Room"
    case virtual = "Virtual Room"

    var style: ImmersionStyle { self == .physical ? .mixed : .full }
}

@main
struct NativePlayerApp: App {
    @State private var player = NativePlayer.shared
    @State private var environment: TableEnvironment =
        CommandLine.arguments.contains("--check-virtual-room") ? .virtual : .physical

    var body: some Scene {
        WindowGroup(id: TableWindow.id) {
            TableWindow(player: player, environment: $environment)
        }
        .defaultSize(width: 440, height: 340)

        ImmersiveSpace(id: "Table") {
            CompositorLayer(configuration: NativeLayerConfiguration()) { layer in
                player.open(layer)
            }
            .upperLimbVisibility(.visible)
        }
        .immersionStyle(selection: Binding(get: { environment.style }, set: { _ in }), in: .mixed, .full)
    }
}

private struct TableWindow: View {
    static let id = "TimeMachineLauncher"
    let player: NativePlayer
    @Binding var environment: TableEnvironment
    @Environment(\.openImmersiveSpace) private var openSpace
    @Environment(\.dismissImmersiveSpace) private var dismissSpace
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var transitioning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Time Machine").font(.largeTitle)
            if !player.isOpen {
                Picker("Environment", selection: $environment) {
                    ForEach(TableEnvironment.allCases, id: \.self) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(transitioning)
            }
            Text(player.status).foregroundStyle(.secondary)
            Button(player.isOpen ? "Close Table" : "Play Time Machine") {
                transitioning = true
                Task {
                    defer { transitioning = false }
                    if player.isOpen {
                        await dismissSpace()
                    } else if player.prepareTable(environment: environment), case .error = await openSpace(id: "Table") {
                        player.status = "Couldn’t open the table."
                    }
                }
            }
            .disabled(transitioning)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(28)
        .onAppear {
            player.setLauncherActions(
                hide: { dismissWindow(id: Self.id) },
                show: { openWindow(id: Self.id) }
            )
        }
        #if targetEnvironment(simulator)
        .task {
            if player.prepareSimulatorLaunch(environment: environment) {
                if case .error = await openSpace(id: "Table") {
                    player.status = "Couldn’t open the table."
                }
            }
        }
        #endif
        .onChange(of: player.needsDismissal, initial: true) { _, dismiss in
            if dismiss {
                Task {
                    await dismissSpace()
                    player.needsDismissal = false
                }
            }
        }
    }
}

// VPX invokes this from the table loader as well as the main thread.
private nonisolated func nativePlayerEvent(_ event: VPINBALL_EVENT, _: UnsafePointer<CChar>?) {
    switch event {
    case VPINBALL_EVENT_PLAYER_READY, VPINBALL_EVENT_PLAYER_CLOSED, VPINBALL_EVENT_PLAYER_FAILED:
        Task { @MainActor in NativePlayer.shared.receive(event) }
    default:
        break
    }
}

@MainActor
@Observable
private final class NativePlayer {
    static let shared = NativePlayer()

    var status = "Look ahead to place the cabinet. In Your Room, pinch both front sides to move or turn it, then release to lock it in place."
    var isOpen = false
    var needsDismissal = false

    private var compositor: NativeCompositor?
    private var hideLauncher: (() -> Void)?
    private var showLauncher: (() -> Void)?
    private var launcherHidden = false
    private var selectedTable: URL?
    private var cabinetTransform: simd_float4x4?
    private var tracker: CabinetHandTracking?
    private var mixedReality = true
    private var pump: Task<Void, Never>?
    #if targetEnvironment(simulator)
    private var inputCheck: Task<Void, Never>?
    private var simulatorLaunchPending = CommandLine.arguments.contains("--play-time-machine")

    func prepareSimulatorLaunch(environment: TableEnvironment) -> Bool {
        guard simulatorLaunchPending else { return false }
        simulatorLaunchPending = false
        return prepareTable(environment: environment)
    }
    #endif
    private var tracking: Task<Void, Never>?
    private var loading = false
    private var ready = false
    private var stopping = false
    private var pulses: [VPINBALL_VISION_INPUT: Task<Void, Never>] = [:]

    func setLauncherActions(hide: @escaping () -> Void, show: @escaping () -> Void) {
        hideLauncher = hide
        showLauncher = show
    }

    func prepareTable(environment: TableEnvironment) -> Bool {
        mixedReality = environment == .physical
        do {
            selectedTable = try timeMachine()
            return true
        } catch {
            selectedTable = nil
            status = error.localizedDescription
            return false
        }
    }

    func open(_ layer: LayerRenderer) {
        guard compositor == nil, let table = selectedTable else { return }
        do {
            // The Time Machine plunger is to the right of the coin door.
            let layout = CabinetControlsLayout(plunger: SIMD3(0.24, -0.095, 0.040))
            let moveCabinet: ((simd_float4x4) -> Void)? = mixedReality ? { [weak self] pose in
                self?.compositor?.place(pose)
            } : nil
            let tracker = CabinetHandTracking(layout: layout, moveCabinet: moveCabinet, send: handle)
            let compositor = try NativeCompositor(layer: layer, world: tracker.world, mixedReality: mixedReality)
            guard compositor.configurePlayer(), VPinballVisionInit(nativePlayerEvent) == VPINBALL_STATUS_SUCCESS else {
                status = "Couldn’t initialize VPX."
                needsDismissal = true
                return
            }
            self.compositor = compositor
            self.tracker = tracker
            isOpen = true
            pump = Task {
                while !Task.isCancelled {
                    VPinballVisionTick()
                    step()
                    try? await Task.sleep(for: .milliseconds(2))
                }
            }
            compositor.start()
            #if targetEnvironment(simulator)
            // Simulator may expose only one view and no device or hand anchor.
            var placement = CabinetPlacement()
            _ = placement.sample(matrix_identity_float4x4, at: 0)
            for sample in 1...6 {
                if var transform = placement.sample(matrix_identity_float4x4, at: Double(sample) * 0.1) {
                    // Keep the default Simulator camera aligned with the
                    // passthrough room while fitting the entire cabinet in view.
                    if mixedReality {
                        transform.columns.3.x = 0.65
                        transform.columns.3.z = -3.35
                    }
                    loadTable(table, at: transform)
                    break
                }
            }
            #else
            tracking = Task {
                await tracker.run(placeCabinet: { transform in
                    loadTable(table, at: transform)
                    return transform
                }, report: { message in
                    if !loading { status = message }
                }, acceptsInput: { compositor.isRunning }, tick: { _ in })
                if !Task.isCancelled && !loading && !ready {
                    needsDismissal = true
                }
            }
            #endif
        } catch {
            status = error.localizedDescription
            needsDismissal = true
        }
    }

    private func loadTable(_ table: URL, at transform: simd_float4x4) {
        cabinetTransform = transform
        status = "Loading Time Machine..."
        loading = VPinballPlay(table.path) == VPINBALL_STATUS_SUCCESS
        if !loading {
            status = "Couldn’t start loading Time Machine."
            needsDismissal = true
        }
    }

    private func step() {
        guard let compositor else { return }
        if !compositor.isClosed {
            if !launcherHidden, compositor.hasPresentedTable {
                launcherHidden = true
                hideLauncher?()
            }
            return
        }
        tracking?.cancel()
        tracking = nil
        if ready, !stopping {
            clearButtons()
            stopping = VPinballStop() == VPINBALL_STATUS_SUCCESS
        } else if !loading && !ready && !stopping {
            close()
        }
    }

    fileprivate func receive(_ event: VPINBALL_EVENT) {
        switch event {
        case VPINBALL_EVENT_PLAYER_READY:
            if let cabinetTransform {
                let pose: simd_float4x4
                if mixedReality, let tracker {
                    let height = VPinballVisionCabinetHeight()
                    #if targetEnvironment(simulator)
                    pose = tracker.placeOnFloor(cabinetTransform, height: height, simulatedFloor: -1.60)
                    #else
                    pose = tracker.placeOnFloor(cabinetTransform, height: height)
                    #endif
                } else {
                    pose = cabinetTransform
                }
                compositor?.place(pose)
            }
            loading = false
            ready = true
            #if targetEnvironment(simulator)
            if CommandLine.arguments.contains("--check-controls"), inputCheck == nil {
                inputCheck = Task { await checkControls() }
            }
            #endif
            status = "Poke the coin box and Start. Grab, pull, and release the plunger. Turn your wrists to flip."
        case VPINBALL_EVENT_PLAYER_FAILED:
            loading = false
            status = "VPX couldn’t load Time Machine."
            needsDismissal = true
        case VPINBALL_EVENT_PLAYER_CLOSED:
            if compositor?.isClosed == false { needsDismissal = true }
            close()
        default:
            break
        }
    }

    private func close() {
        tracking?.cancel()
        tracking = nil
        pump?.cancel()
        pump = nil
        #if targetEnvironment(simulator)
        inputCheck?.cancel()
        inputCheck = nil
        #endif
        clearButtons()
        ready = false
        loading = false
        stopping = false
        isOpen = false
        compositor = nil
        tracker = nil
        cabinetTransform = nil
        if launcherHidden {
            launcherHidden = false
            showLauncher?()
        }
    }

    #if targetEnvironment(simulator)
    private func checkControls() async {
        while !Task.isCancelled && compositor?.hasPresentedTable == false {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard !Task.isCancelled, ready else { return }

        // The ROM can still be starting when the first frame reaches the GPU.
        try? await Task.sleep(for: .seconds(4))
        // The Data East script delays the ROM's coin-switch pulse by 750 ms.
        let inputs: [(CabinetInput, VPINBALL_VISION_INPUT, Duration)] = [
            (.insertCoin, VPINBALL_VISION_ADD_CREDIT, .milliseconds(1100)),
            (.insertCoin, VPINBALL_VISION_ADD_CREDIT, .milliseconds(1100)),
            (.pressStart, VPINBALL_VISION_START, .seconds(2)),
            (.flipper(.left, pressed: true), VPINBALL_VISION_LEFT_FLIPPER, .milliseconds(150)),
            (.flipper(.right, pressed: true), VPINBALL_VISION_RIGHT_FLIPPER, .milliseconds(150))
        ]
        for (event, button, delay) in inputs {
            guard !Task.isCancelled, ready else { return }
            handle(event)
            try? await Task.sleep(for: .milliseconds(30))
            let mask = UInt32(1) << button.rawValue
            guard VPinballVisionPressedButtons() & mask != 0 else {
                VPinballLog(VPINBALL_LOG_LEVEL_ERROR, "Simulator button \(button.rawValue) never reached the input manager")
                return
            }
            if case let .flipper(side, _) = event { handle(.flipper(side, pressed: false)) }
            try? await Task.sleep(for: delay)
            guard VPinballVisionPressedButtons() & mask == 0 else {
                VPinballLog(VPINBALL_LOG_LEVEL_ERROR, "Simulator button \(button.rawValue) stayed pressed")
                return
            }
        }

        handle(.pullPlunger(0.5))
        try? await Task.sleep(for: .milliseconds(350))
        guard abs(VPinballVisionPlungerPosition() - 0.5) < 0.02 else {
            VPinballLog(VPINBALL_LOG_LEVEL_ERROR, "Simulator half pull never reached the plunger handler")
            return
        }
        handle(.releasePlunger(0.5))
        try? await Task.sleep(for: .milliseconds(500))
        guard abs(VPinballVisionPlungerPosition()) < 0.02 else {
            VPinballLog(VPINBALL_LOG_LEVEL_ERROR, "Simulator plunger failed to return to rest")
            return
        }
        VPinballLog(VPINBALL_LOG_LEVEL_INFO, "Simulator verified coin, start, both flippers and half pull in the native input manager")
        if CommandLine.arguments.contains("--check-room-placement") {
            VPinballLog(VPINBALL_LOG_LEVEL_INFO, "Simulator ready for cabinet grab")
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, ready else { return }
            checkRoomPlacement()
        }
    }

    private func checkRoomPlacement() {
        guard let tracker, let initial = tracker.simulatorRoomPose else { return }
        let layout = CabinetControlsLayout()
        let center = initial * SIMD4<Float>(0, -0.05, -0.12, 1)
        var time = 0.0
        func feed(_ side: CabinetHandSide, at point: SIMD4<Float>, gap: Float) {
            time += 0.015
            let p = SIMD3(point.x, point.y, point.z)
            let offset = SIMD3(0, gap * 0.5, 0)
            tracker.updateRoomContact(side, index: p + offset, thumb: p - offset, at: time)
        }
        for gap: Float in [0.06, 0.016] {
            for side in CabinetHandSide.allCases {
                feed(side, at: center + initial.columns.0 * (side.sign * layout.width * 0.5), gap: gap)
            }
        }

        let turn = simd_float4x4(simd_quatf(angle: .pi / 9, axis: [0, 1, 0]))
        let target = center + SIMD4<Float>(0.25, 0.15, -0.25, 0)
        for side in CabinetHandSide.allCases {
            feed(side, at: target + turn * initial.columns.0 * (side.sign * layout.width * 0.5), gap: 0.016)
        }
        let moved = tracker.simulatorRoomPose
        feed(.left, at: target, gap: 0.065)
        feed(.right, at: target, gap: 0.065)
        guard let moved, moved == tracker.simulatorRoomPose, moved.columns.3.y == initial.columns.3.y,
              abs(moved.columns.0.z + sin(.pi / 9)) < 0.001,
              moved.columns.3.x - initial.columns.3.x > 0.25 else {
            VPinballLog(VPINBALL_LOG_LEVEL_ERROR, "Simulator cabinet movement or release failed")
            return
        }
        VPinballLog(VPINBALL_LOG_LEVEL_INFO, "Simulator verified mixed reality translation, yaw and release at fixed floor height")
    }
    #endif

    private func handle(_ input: CabinetInput) {
        guard ready, !stopping else { return }
        switch input {
        case let .flipper(side, pressed):
            VPinballVisionSetButton(side == .left ? VPINBALL_VISION_LEFT_FLIPPER : VPINBALL_VISION_RIGHT_FLIPPER,
                                   pressed ? 1 : 0)
        case .insertCoin:
            pulse(VPINBALL_VISION_ADD_CREDIT)
        case .pressStart:
            pulse(VPINBALL_VISION_START)
        case let .pullPlunger(amount):
            VPinballVisionSetPlunger(VPINBALL_VISION_PLUNGER_HOLD, amount)
        case let .releasePlunger(amount):
            VPinballVisionSetPlunger(VPINBALL_VISION_PLUNGER_RELEASE, amount)
        case .cancelPlunger:
            VPinballVisionSetPlunger(VPINBALL_VISION_PLUNGER_CANCEL, 0)
        }
    }

    private func pulse(_ button: VPINBALL_VISION_INPUT) {
        guard pulses[button] == nil else { return }
        VPinballVisionSetButton(button, 1)
        pulses[button] = Task {
            try? await Task.sleep(for: .milliseconds(75))
            guard !Task.isCancelled else { return }
            VPinballVisionSetButton(button, 0)
            pulses.removeValue(forKey: button)
        }
    }

    private func clearButtons() {
        for (button, release) in pulses {
            release.cancel()
            VPinballVisionSetButton(button, 0)
        }
        pulses.removeAll()
        VPinballVisionSetButton(VPINBALL_VISION_LEFT_FLIPPER, 0)
        VPinballVisionSetButton(VPINBALL_VISION_RIGHT_FLIPPER, 0)
    }

    private func timeMachine() throws -> URL {
        let directory = URL.documentsDirectory.appending(path: "Time Machine", directoryHint: .isDirectory)
        let files = (try? FileManager.default.contentsOfDirectory(at: directory,
                                                                  includingPropertiesForKeys: nil)) ?? []
        guard let table = files.first(where: { $0.pathExtension.lowercased() == "vpx" }) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [
                NSLocalizedDescriptionKey: "Import the Time Machine table and ROM into the app’s Documents folder."
            ])
        }
        return table
    }
}
