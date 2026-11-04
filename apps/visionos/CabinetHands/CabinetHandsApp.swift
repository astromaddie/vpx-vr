// license:GPLv3+

import Observation
import QuartzCore
import RealityKit
import SwiftUI

@main
struct CabinetHandsApp: App {
    @State private var preview = CabinetPreview()
    @State private var immersion: ImmersionStyle = .mixed

    var body: some SwiftUI.Scene {
        WindowGroup {
            ControlsWindow(preview: preview)
        }
        .defaultSize(width: 440, height: 400)

        ImmersiveSpace(id: "Cabinet") {
            CabinetSpace(preview: preview)
                .upperLimbVisibility(.visible)
        }
        .immersionStyle(selection: $immersion, in: .mixed)
    }
}

@MainActor
@Observable
private final class CabinetPreview {
    let layout: CabinetControlsLayout
    let cabinet: CabinetModel
    var isOpen = false
    var acceptsInput = false
    var status = ""
    var actions: Set<CabinetAction> = []
    var credits = 0
    var starts = 0
    private var flashUntil: [CabinetAction: Double] = [:]

    init(layout: CabinetControlsLayout = .init()) {
        self.layout = layout
        cabinet = CabinetModel(layout: layout)
    }

    func handle(_ input: CabinetInput) {
        let action = input.action
        switch input {
        case let .flipper(_, pressed):
            if pressed { actions.insert(action) } else { actions.remove(action) }
        case .insertCoin, .pressStart:
            if input == .insertCoin { credits += 1 } else { starts += 1 }
            actions.insert(action)
            flashUntil[action] = CACurrentMediaTime() + 0.24
        }
    }

    func tick(_ time: Double) {
        for action in [CabinetAction.addCredit, .start] {
            if let deadline = flashUntil[action], time >= deadline {
                flashUntil.removeValue(forKey: action)
                actions.remove(action)
            }
        }
    }

    func clear() {
        actions.removeAll()
        flashUntil.removeAll()
    }
}

private struct ControlsWindow: View {
    let preview: CabinetPreview
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @State private var transitioning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("VPX Hand Controls").font(.largeTitle)
            Label("Turn your hands inward beside the red flipper buttons.", systemImage: "hand.raised")
            Label("Poke the gold coin box with your index finger.", systemImage: "circle.circle")
            Label("Push the green Start button with your index finger.", systemImage: "play.circle")
            HStack(spacing: 16) {
                Text("Coins: \(preview.credits)")
                Text("Start Presses: \(preview.starts)")
            }
            .monospacedDigit()
            .foregroundStyle(.secondary)

            Button(preview.isOpen ? "Close Cabinet" : "Open Cabinet") {
                transitioning = true
                Task {
                    defer { transitioning = false }
                    if preview.isOpen {
                        await dismissImmersiveSpace()
                    } else {
                        let result = await openImmersiveSpace(id: "Cabinet")
                        if case .error = result { preview.status = "Couldn’t open the cabinet." }
                    }
                }
            }
            .disabled(transitioning)
            if !preview.status.isEmpty {
                Text(preview.status).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(28)
    }
}

private struct CabinetSpace: View {
    let preview: CabinetPreview
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        RealityView { content in
            content.add(preview.cabinet.root)
        } update: { _ in
            preview.cabinet.show(preview.actions)
        }
        .task(id: scenePhase == .background) {
            guard scenePhase != .background else { return }
            let root = preview.cabinet.root
            #if !targetEnvironment(simulator)
            root.isEnabled = false
            #endif
            let tracking = CabinetHandTracking(layout: preview.layout, send: preview.handle)
            await tracking.run(
                placeCabinet: {
                    root.setTransformMatrix($0, relativeTo: nil)
                    root.isEnabled = true
                    return root.transformMatrix(relativeTo: nil)
                },
                report: { preview.status = $0 },
                acceptsInput: { preview.acceptsInput },
                tick: preview.tick
            )
            preview.clear()
        }
        .onAppear { preview.isOpen = true }
        .onChange(of: scenePhase, initial: true) { _, phase in
            preview.acceptsInput = phase == .active
            if !preview.acceptsInput { preview.clear() }
        }
        .onDisappear {
            preview.acceptsInput = false
            preview.isOpen = false
            preview.status = ""
            preview.clear()
        }
    }
}
