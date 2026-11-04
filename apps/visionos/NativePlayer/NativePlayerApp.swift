// license:GPLv3+

import CompositorServices
import SwiftUI

@main
struct NativePlayerApp: App {
    @State private var player = NativePlayer.shared
    @State private var immersion: ImmersionStyle = .full

    var body: some Scene {
        WindowGroup {
            TableWindow(player: player)
        }
        .defaultSize(width: 440, height: 340)

        ImmersiveSpace(id: "Table") {
            CompositorLayer(configuration: NativeLayerConfiguration()) { layer in
                player.open(layer)
            }
            .upperLimbVisibility(.visible)
        }
        .immersionStyle(selection: $immersion, in: .full)
    }
}

private struct TableWindow: View {
    let player: NativePlayer
    @Environment(\.openImmersiveSpace) private var openSpace
    @Environment(\.dismissImmersiveSpace) private var dismissSpace
    @State private var transitioning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Time Machine").font(.largeTitle)
            Text(player.status).foregroundStyle(.secondary)
            Button(player.isOpen ? "Close Table" : "Play Time Machine") {
                transitioning = true
                Task {
                    defer { transitioning = false }
                    if player.isOpen {
                        await dismissSpace()
                    } else if player.prepareTable(), case .error = await openSpace(id: "Table") {
                        player.status = "Couldn’t open the table."
                    }
                }
            }
            .disabled(transitioning)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(28)
        .onChange(of: player.needsDismissal) { _, dismiss in
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

    var status = "Look straight ahead and hold steady to place the cabinet."
    var isOpen = false
    var needsDismissal = false

    private var compositor: NativeCompositor?
    private var selectedTable: URL?
    private var pump: Task<Void, Never>?
    private var tracking: Task<Void, Never>?
    private var loading = false
    private var ready = false
    private var stopping = false
    private var pulses: [VPINBALL_VISION_INPUT: Task<Void, Never>] = [:]

    func prepareTable() -> Bool {
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
            let tracker = CabinetHandTracking(layout: layout, send: handle)
            let compositor = try NativeCompositor(layer: layer, world: tracker.world)
            guard compositor.configurePlayer(), VPinballVisionInit(nativePlayerEvent) == VPINBALL_STATUS_SUCCESS else {
                status = "Couldn’t initialize VPX."
                needsDismissal = true
                return
            }
            self.compositor = compositor
            isOpen = true
            pump = Task {
                while !Task.isCancelled {
                    VPinballVisionTick()
                    step()
                    try? await Task.sleep(for: .milliseconds(2))
                }
            }
            tracking = Task {
                await tracker.run(placeCabinet: { transform in
                    let placed = compositor.place(transform)
                    status = "Loading Time Machine..."
                    loading = VPinballPlay(table.path) == VPINBALL_STATUS_SUCCESS
                    if !loading {
                        status = "Couldn’t start loading Time Machine."
                        needsDismissal = true
                    }
                    return placed
                }, report: { message in
                    if !loading { status = message }
                }, acceptsInput: { compositor.isRunning }, tick: { _ in })
                if !Task.isCancelled && !loading && !ready {
                    needsDismissal = true
                }
            }
        } catch {
            status = error.localizedDescription
            needsDismissal = true
        }
    }

    private func step() {
        guard let compositor, compositor.isClosed else { return }
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
            loading = false
            ready = true
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
        clearButtons()
        ready = false
        loading = false
        stopping = false
        isOpen = false
        compositor = nil
    }

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
