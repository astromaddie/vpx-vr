// license:GPLv3+

import CompositorServices
import simd
import SwiftUI
import UniformTypeIdentifiers

private enum TableEnvironment: String, CaseIterable {
    case physical = "Your Room"
    case virtual = "Virtual Room"

    var style: ImmersionStyle { self == .physical ? .mixed : .full }
}

private enum EyeResolution: Int, CaseIterable {
    case standard = 1536
    case high = 1792
    case veryHigh = 2304
    case highest = 2816

    var title: String {
        switch self {
        case .standard: "Standard · 1536 px"
        case .high: "High · 1792 px"
        case .veryHigh: "Very High · 2304 px"
        case .highest: "Highest · 2816 px"
        }
    }
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
        .defaultSize(width: 460, height: 680)

        WindowGroup(id: PlacementWindow.id) {
            PlacementWindow(player: player)
        }
        .defaultSize(width: 400, height: 230)
        .windowResizability(.contentSize)

        ImmersiveSpace(id: "Table") {
            CompositorLayer(configuration: NativeLayerConfiguration()) { layer in
                player.open(layer)
            }
            .upperLimbVisibility(.visible)
        }
        .immersionStyle(selection: Binding(get: { (player.isOpen ? player.activeEnvironment : environment).style }, set: { _ in }), in: .mixed, .full)
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
    @AppStorage("LeftHandDominant") private var leftHandDominant = false
    @AppStorage("EyeResolution") private var resolution = EyeResolution.high
    @State private var selection: LibraryTable?
    @State private var transitioning = false
    @State private var importing = false
    @State private var choosingFolder = false

    var body: some View {
        Group {
            if player.isCalibrating {
                ControlCalibrationView(calibration: player.calibration, done: player.finishCalibration)
            } else {
                tablePicker
            }
        }
        .onDisappear { player.menuDidClose() }
    }

    private var tablePicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Pinball Tables").font(.title)
                Spacer()
                Menu {
                    Picker("Dominant Hand", selection: $leftHandDominant) {
                        Text("Right").tag(false)
                        Text("Left").tag(true)
                    }
                    Picker("Eye Resolution", selection: $resolution) {
                        ForEach(EyeResolution.allCases, id: \.self) { option in
                            Text(option.title).tag(option)
                        }
                    }
                } label: {
                    Label("Table Settings", systemImage: "gearshape")
                        .labelStyle(.iconOnly)
                }
                .accessibilityLabel("Table Settings")
            }
            Picker("Environment", selection: $environment) {
                ForEach(TableEnvironment.allCases, id: \.self) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .pickerStyle(.segmented)

            if player.tables.isEmpty {
                ContentUnavailableView("No Tables", systemImage: "arcade.stick",
                                       description: Text("Import a folder with your tables, ROMs, and backglasses."))
                    .frame(maxHeight: .infinity)
            } else {
                List(player.tables, selection: $selection) { table in
                    Text(table.title).tag(table)
                }
                .listStyle(.plain)
            }

            if let message = player.status {
                Text(message).font(.footnote).foregroundStyle(.secondary)
            } else if player.isOpen {
                HStack {
                    Button("Edit Placement", systemImage: "move.3d") { player.beginEditing() }
                    Button("Calibrate Controls", systemImage: "hand.raised") { player.beginCalibration() }
                }
            } else {
                Text("Look toward your non-dominant wrist during play to switch tables or edit placement.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            HStack {
                Button("Import Folder…") { choosingFolder = true }
                Spacer()
                if player.isOpen {
                    Button("Resume") { player.hideMenu() }
                }
                Button("Play Table") {
                    guard let selection else { return }
                    Task { await play(selection) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selection == nil)
            }
        }
        .padding(24)
        .disabled(transitioning || importing)
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            guard case .success(let folder) = result else { return }
            importing = true
            Task {
                defer { importing = false }
                do {
                    let tables = try await Task.detached {
                        let accessed = folder.startAccessingSecurityScopedResource()
                        defer { if accessed { folder.stopAccessingSecurityScopedResource() } }
                        return try TableLibrary.importFolder(folder, to: .documentsDirectory)
                    }.value
                    player.tables = tables
                    selection = selection ?? tables.first
                    player.status = nil
                } catch {
                    player.status = error.localizedDescription
                }
            }
        }
        .onAppear {
            player.refreshLibrary()
            selection = player.currentTable ?? selection ?? player.tables.first
            player.setLauncherActions(
                hide: { dismissWindow(id: Self.id) },
                show: { openWindow(id: Self.id) },
                showPlacement: { openWindow(id: PlacementWindow.id) },
                hidePlacement: { dismissWindow(id: PlacementWindow.id) }
            )
        }
        .onChange(of: player.tables) { _, tables in
            if selection == nil { selection = tables.first }
        }
        .onChange(of: leftHandDominant) { _, leftHand in
            player.setDominantHand(leftHand)
        }
        #if targetEnvironment(simulator)
        .task {
            if let table = player.takeSimulatorTable() {
                await play(table)
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

    private func play(_ table: LibraryTable) async {
        guard !transitioning else { return }
        transitioning = true
        defer { transitioning = false }
        if player.isOpen {
            // Keep the picker open until the replacement has a rendered frame.
            await dismissSpace()
            guard await player.waitUntilClosed() else { return }
        }
        let renderResolution: EyeResolution
        #if targetEnvironment(simulator)
        let arguments = CommandLine.arguments
        if arguments.contains("--check-standard-resolution") {
            renderResolution = .standard
        } else if let flag = arguments.firstIndex(of: "--check-eye-size"), flag + 1 < arguments.count,
                  let size = Int(arguments[flag + 1]), let option = EyeResolution(rawValue: size) {
            renderResolution = option
        } else {
            renderResolution = resolution
        }
        #else
        renderResolution = resolution
        #endif
        player.prepareTable(table, environment: environment, leftHandDominant: leftHandDominant, resolution: renderResolution)
        if case .opened = await openSpace(id: "Table") { return }
        player.status = "Couldn’t open the table."
    }
}

private struct PlacementWindow: View {
    static let id = "CabinetPlacement"
    let player: NativePlayer

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit Placement").font(.title2)
            Label(player.isMovingCabinet ? "Moving Cabinet" : "Ready to Move",
                  systemImage: player.isMovingCabinet ? "move.3d" : "hand.raised")
                .foregroundStyle(.secondary)
            Text("Raise both hands above the lockbar and hold them apart. Move or turn your hands, then lower either hand to stop.")
                .font(.callout)
            HStack {
                Button("Cancel") { player.finishEditing(keepPlacement: false) }
                Spacer()
                Button("Done") { player.finishEditing(keepPlacement: true) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 400)
        .onDisappear { player.finishEditing(keepPlacement: false, closeWindow: false) }
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

    var status: String?
    var tables: [LibraryTable] = []
    var activeEnvironment: TableEnvironment = .physical
    var currentTable: LibraryTable? { selectedTable }
    private var menuVisible = false
    private(set) var isCalibrating = false
    let calibration: CabinetCalibration = {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        return CabinetCalibration(url: URL.documentsDirectory.appending(path: CabinetCalibration.filename(build: build)),
                                  build: build)
    }()
    var isEditingPlacement = false
    var isMovingCabinet = false
    private var resolution = EyeResolution.high
    private var watchSide: CabinetHandSide = .left
    var isOpen = false
    var needsDismissal = false

    private var compositor: NativeCompositor?
    private var hideLauncher: (() -> Void)?
    private var showLauncher: (() -> Void)?
    private var showPlacement: (() -> Void)?
    private var hidePlacement: (() -> Void)?
    private var launcherHidden = false
    private var selectedTable: LibraryTable?
    private var cabinetTransform: simd_float4x4?
    private var tracker: CabinetHandTracking?
    private var mixedReality: Bool { activeEnvironment == .physical }
    private var pump: Task<Void, Never>?
    #if targetEnvironment(simulator)
    private var inputCheck: Task<Void, Never>?
    private var simulatorLaunchPending = true
    private var simulatorTables: [LibraryTable] = []
    private var simulatorSequence = false

    func takeSimulatorTable() -> LibraryTable? {
        if simulatorLaunchPending {
            simulatorLaunchPending = false
            let arguments = CommandLine.arguments
            if let index = arguments.firstIndex(of: "--import-tables"), arguments.indices.contains(index + 1) {
                do {
                    tables = try TableLibrary.importFolder(URL(filePath: arguments[index + 1]), to: .documentsDirectory)
                } catch {
                    status = error.localizedDescription
                    print("Simulator library import failed: \(error)")
                    return nil
                }
            }
            refreshLibrary()
            simulatorSequence = arguments.contains("--check-library")
            if simulatorSequence {
                simulatorTables = tables
                // Run the library checks on one table, for example to capture it.
                if let index = arguments.firstIndex(of: "--only-table"), arguments.indices.contains(index + 1) {
                    simulatorTables = tables.filter { $0.title == arguments[index + 1] }
                }
            } else if arguments.contains("--play-time-machine") {
                simulatorTables = Array(tables.filter { $0.title == "Time Machine" }.prefix(1))
            }
        }
        return simulatorTables.isEmpty ? nil : simulatorTables.removeFirst()
    }
    #endif
    private var tracking: Task<Void, Never>?
    private var loading = false
    private var ready = false
    private var stopping = false
    private var pulses: [VPINBALL_VISION_INPUT: Task<Void, Never>] = [:]

    func setLauncherActions(hide: @escaping () -> Void, show: @escaping () -> Void,
                            showPlacement: @escaping () -> Void, hidePlacement: @escaping () -> Void) {
        hideLauncher = hide
        showLauncher = show
        self.showPlacement = showPlacement
        self.hidePlacement = hidePlacement
    }

    func refreshLibrary() {
        tables = TableLibrary.tables(in: .documentsDirectory)
    }

    func prepareTable(_ table: LibraryTable, environment: TableEnvironment, leftHandDominant: Bool, resolution: EyeResolution) {
        selectedTable = table
        self.resolution = resolution
        activeEnvironment = environment
        setDominantHand(leftHandDominant)
        status = "Look ahead and hold steady to place the cabinet."
    }

    func setDominantHand(_ left: Bool) {
        watchSide = left ? .right : .left
        tracker?.setWatchSide(watchSide)
    }

    func waitUntilClosed() async -> Bool {
        let deadline = ContinuousClock.now + .seconds(15)
        while isOpen && !Task.isCancelled && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(40))
        }
        if isOpen { status = "The current table is still closing." }
        return !isOpen
    }

    private func showMenu() {
        guard ready, !stopping, launcherHidden, !menuVisible, !isEditingPlacement else { return }
        menuVisible = true
        tracker?.reset()
        clearButtons()
        launcherHidden = false
        status = nil
        showLauncher?()
    }

    func hideMenu() {
        guard menuVisible else { return }
        menuVisible = false
        launcherHidden = true
        hideLauncher?()
    }

    func beginCalibration() {
        guard ready, !stopping, menuVisible, !isEditingPlacement, let tracker else { return }
        tracker.reset()
        clearButtons()
        tracker.calibration = calibration
        isCalibrating = true
    }

    func finishCalibration() {
        guard isCalibrating else { return }
        calibration.cancel()
        tracker?.calibration = nil
        tracker?.reset()
        isCalibrating = false
    }

    func beginEditing() {
        guard ready, !stopping, !isEditingPlacement, tracker?.beginEditing() == true else { return }
        isEditingPlacement = true
        clearButtons()
        showPlacement?()
        hideMenu()
    }

    func finishEditing(keepPlacement: Bool, closeWindow: Bool = true) {
        guard isEditingPlacement else { return }
        isEditingPlacement = false
        tracker?.finishEditing(keepPlacement: keepPlacement)
        if closeWindow { hidePlacement?() }
    }

    func menuDidClose() {
        finishCalibration()
        if menuVisible {
            menuVisible = false
            launcherHidden = isOpen
        }
    }

    func open(_ layer: LayerRenderer) {
        guard compositor == nil, let table = selectedTable else { return }
        do {
            let tracker = CabinetHandTracking(layout: .init(), moveCabinet: { [weak self] pose in
                self?.compositor?.place(pose)
            }, placementMoving: { [weak self] moving in
                self?.isMovingCabinet = moving
            }, watchSide: watchSide, showMenu: { [weak self] in self?.showMenu() }, send: handle)
            let compositor = try NativeCompositor(layer: layer, world: tracker.world, mixedReality: mixedReality,
                                                  eyeSize: resolution.rawValue)
            guard compositor.configurePlayer(), VPinballVisionInit(nativePlayerEvent) == VPINBALL_STATUS_SUCCESS else {
                status = "Couldn’t initialize VPX."
                needsDismissal = true
                return
            }
            CompositorLog.vpxLogStarted()
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
                    Self.applySimulatorView(&transform)
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
                }, acceptsInput: { compositor.isRunning }, tick: { time in
                    if self.isCalibrating { self.calibration.advance(at: time) }
                }, trackFloor: mixedReality, allowsControls: {
                    if self.isCalibrating { return self.calibration.isRecording }
                    return !self.menuVisible && !self.isEditingPlacement
                })
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

    private func loadTable(_ table: LibraryTable, at transform: simd_float4x4) {
        cabinetTransform = transform
        status = "Loading \(table.title)…"
        loading = VPinballPlay(table.url.path) == VPINBALL_STATUS_SUCCESS
        if !loading {
            status = "Couldn’t start loading \(table.title)."
            needsDismissal = true
        }
    }

    private func step() {
        guard let compositor else { return }
        if !compositor.isClosed {
            if !launcherHidden, !menuVisible, compositor.hasPresentedTable {
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
                if let tracker {
                    let dimensions = VPinballVisionGetLayout()
                    func face(_ button: VPINBALL_VISION_BUTTON_FACE) -> CabinetButtonFace {
                        CabinetButtonFace(position: SIMD3(button.x, button.y, button.z),
                                          halfSize: SIMD2(button.halfWidth, button.halfHeight))
                    }
                    tracker.setLayout(CabinetControlsLayout(
                        playfieldWidth: dimensions.width, playfieldLength: dimensions.length,
                        plunger: dimensions.hasPlunger == 0 ? nil : SIMD3(dimensions.plungerX, dimensions.plungerY, dimensions.plungerZ),
                        startFace: face(dimensions.start), coinFace: face(dimensions.coin),
                        leftFlipperCap: dimensions.leftFlipper.x < 0 ? SIMD3(dimensions.leftFlipper.x, dimensions.leftFlipper.y, dimensions.leftFlipper.z) : nil,
                        rightFlipperCap: dimensions.rightFlipper.x > 0 ? SIMD3(dimensions.rightFlipper.x, dimensions.rightFlipper.y, dimensions.rightFlipper.z) : nil,
                        launchFace: dimensions.hasLaunchButton == 0 ? nil : face(dimensions.launch),
                        usesWristGestures: true))
                    let height = dimensions.height
                    #if targetEnvironment(simulator)
                    pose = tracker.placeForPlay(cabinetTransform, height: height, trackFloor: mixedReality, simulatedFloor: -1.60)
                    #else
                    pose = tracker.placeForPlay(cabinetTransform, height: height, trackFloor: mixedReality)
                    #endif
                } else {
                    pose = cabinetTransform
                }
                compositor?.place(pose)
            }
            loading = false
            ready = true
            #if targetEnvironment(simulator)
            if simulatorSequence || CommandLine.arguments.contains("--check-controls"), inputCheck == nil {
                inputCheck = Task { await checkControls() }
            }
            #endif
            status = nil
        case VPINBALL_EVENT_PLAYER_FAILED:
            loading = false
            status = "VPX couldn’t load \(selectedTable?.title ?? "the table")."
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
        finishEditing(keepPlacement: true)
        finishCalibration()
        menuVisible = false
        compositor = nil
        tracker = nil
        cabinetTransform = nil
        if launcherHidden {
            launcherHidden = false
            showLauncher?()
        }
    }

    #if targetEnvironment(simulator)
    /// `--check-view side` turns the cabinet so its left side faces the camera,
    /// `--check-view front` brings its front panel close, `--check-view corner` shows the
    /// front left corner, and `--check-view top` tips it back to look down at the front
    /// of the playfield, all for screenshots.
    private static func applySimulatorView(_ transform: inout simd_float4x4) {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--check-view"), arguments.indices.contains(index + 1) else { return }
        switch arguments[index + 1] {
        case "side":
            let yaw = simd_float4x4(simd_quatf(angle: -.pi / 2, axis: [0, 1, 0]))
            transform = simd_mul(transform, yaw)
            transform.columns.3 = [-0.55, 0, -2.3, 1]
        case "front":
            transform.columns.3 = [0, 0, -1.9, 1]
        case "corner":
            // Front left corner, to see the left flipper button on the side.
            transform = simd_mul(transform, simd_float4x4(simd_quatf(angle: -0.9, axis: [0, 1, 0])))
            transform.columns.3 = [0.1, 0, -2.1, 1]
        case "top":
            // Tip the cabinet back so the level Simulator camera looks down into the front of the playfield.
            transform = simd_mul(transform, simd_float4x4(simd_quatf(angle: 0.9, axis: [1, 0, 0])))
            transform.columns.3 = [0, 0, -1.25, 1]
        default:
            break
        }
    }

    /// `--check-hold <left-flipper|start|coin|launch|plunger>` holds that input
    /// after the checks so a screenshot can show the pressed button or pulled knob.
    private func holdForScreenshot() async {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--check-hold"), arguments.indices.contains(index + 1) else { return }
        let name = arguments[index + 1]
        let buttons: [String: VPINBALL_VISION_INPUT] = [
            "left-flipper": VPINBALL_VISION_LEFT_FLIPPER, "right-flipper": VPINBALL_VISION_RIGHT_FLIPPER,
            "start": VPINBALL_VISION_START, "coin": VPINBALL_VISION_ADD_CREDIT, "launch": VPINBALL_VISION_LAUNCH_BALL
        ]
        VPinballLog(VPINBALL_LOG_LEVEL_INFO, "Simulator holding \(name) for a screenshot")
        let deadline = ContinuousClock.now + .seconds(40)
        var reported = false
        while ContinuousClock.now < deadline, !Task.isCancelled, ready {
            if name == "plunger" {
                _ = VPinballVisionSetPlunger(VPINBALL_VISION_PLUNGER_HOLD, 0.6)
            } else if let button = buttons[name] {
                VPinballVisionSetButton(button, 1)
            }
            try? await Task.sleep(for: .milliseconds(100))
            if !reported {
                reported = true
                VPinballLog(VPINBALL_LOG_LEVEL_INFO, "Simulator held \(name): pressed buttons \(VPinballVisionPressedButtons()), plunger \(VPinballVisionPlungerPosition())")
            }
        }
        if name == "plunger" {
            _ = VPinballVisionSetPlunger(VPINBALL_VISION_PLUNGER_CANCEL, 0)
        } else if let button = buttons[name] {
            VPinballVisionSetButton(button, 0)
        }
        VPinballLog(VPINBALL_LOG_LEVEL_INFO, "Simulator released \(name)")
    }

    private func checkControls() async {
        while !Task.isCancelled && compositor?.hasPresentedTable == false {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard !Task.isCancelled, ready else { return }

        let arguments = CommandLine.arguments
        let checkLaunchButton = arguments.contains("--check-attack-from-mars-launch") && selectedTable?.title == "Attack from Mars"
        // The ROM can still be starting when the first frame reaches the GPU.
        try? await Task.sleep(for: .seconds(checkLaunchButton ? 8 : 4))
        guard let tracker, let start = tracker.layout.startFace, let coin = tracker.layout.coinFace,
              start.halfSize.x > 0, coin.halfSize.x > 0, tracker.layout.usesWristGestures else {
            VPinballLog(VPINBALL_LOG_LEVEL_ERROR, "Simulator found missing cabinet button geometry")
            return
        }
        var time = 0.0
        func send(_ side: CabinetHandSide, _ sample: CabinetHandSample?) {
            time += 0.016
            tracker.simulateControl(side, sample: sample, at: time)
        }
        func poke(_ position: SIMD3<Float>) {
            send(.right, .init(index: position + [0, 0, 0.045]))
            send(.right, .init(index: position + [0, 0, 0.006]))
            send(.right, nil)
        }
        func pressed(_ button: VPINBALL_VISION_INPUT) -> Bool {
            VPinballVisionPressedButtons() & (UInt32(1) << button.rawValue) != 0
        }
        // Move down from the visible coin slots to the door's blank panel.
        poke(coin.position - [0, coin.halfSize.y + 0.04, 0])
        try? await Task.sleep(for: .milliseconds(30))
        guard !pressed(VPINBALL_VISION_ADD_CREDIT), !pressed(VPINBALL_VISION_START) else {
            VPinballLog(VPINBALL_LOG_LEVEL_ERROR, "Simulator registered a poke outside the button faces")
            return
        }

        // The table scripts can delay the ROM's coin-switch pulse by 750 ms.
        let credit: (VPINBALL_VISION_INPUT, Duration, () -> Void) =
            (VPINBALL_VISION_ADD_CREDIT, .milliseconds(1100), { poke(coin.position) })
        let inputs = Array(repeating: credit, count: checkLaunchButton ? 5 : 2) + [
            (VPINBALL_VISION_START, .seconds(checkLaunchButton ? 4 : 2), { poke(start.position) }),
            (VPINBALL_VISION_LEFT_FLIPPER, .milliseconds(150), {
                let palm: SIMD3<Float> = [-0.65, 0.30, 0.35]
                send(.left, .init(palm: palm, fingerDirection: [0, 0, -1], forearmDirection: [0, 0, -1]))
                send(.left, .init(palm: palm, fingerDirection: [0.18, 0, -1], palmNormal: [-1, 0, 0],
                                  forearmDirection: [0, 0, -1]))
            }),
            (VPINBALL_VISION_RIGHT_FLIPPER, .milliseconds(150), {
                let palm: SIMD3<Float> = [0.65, 0.30, 0.35]
                send(.right, .init(palm: palm, fingerDirection: [0, 0, -1], forearmDirection: [0, 0, -1]))
                send(.right, .init(palm: palm, fingerDirection: [-0.18, 0, -1], palmNormal: [1, 0, 0],
                                   forearmDirection: [0, 0, -1]))
            })
        ]
        for (button, delay, gesture) in inputs {
            guard !Task.isCancelled, ready else { return }
            gesture()
            try? await Task.sleep(for: .milliseconds(30))
            guard pressed(button) else {
                VPinballLog(VPINBALL_LOG_LEVEL_ERROR, "Simulator gesture for button \(button.rawValue) never reached the input manager")
                return
            }
            if button == VPINBALL_VISION_LEFT_FLIPPER { send(.left, nil) }
            if button == VPINBALL_VISION_RIGHT_FLIPPER { send(.right, nil) }
            try? await Task.sleep(for: delay)
            guard !pressed(button) else {
                VPinballLog(VPINBALL_LOG_LEVEL_ERROR, "Simulator button \(button.rawValue) stayed pressed")
                return
            }
        }

        if let launch = tracker.layout.launchFace {
            // A launch button cabinet: the poke pulses Launch Ball and the table's
            // script fires the ball. Follow the ball at the shooter on Attack from Mars.
            var ball = checkLaunchButton ? VPinballVisionSampleBall(-1, "swplunger") : nil
            // A fresh NVRAM makes Attack from Mars clear its totals before it serves
            // a ball. Credit and start again until the ball reaches the shooter.
            var attempts = 0
            while let waiting = ball, waiting.id < 0, attempts < 4, !Task.isCancelled {
                attempts += 1
                VPinballLog(VPINBALL_LOG_LEVEL_INFO, "Simulator waiting for a ball at the shooter, attempt \(attempts)")
                poke(coin.position)
                try? await Task.sleep(for: .milliseconds(1100))
                poke(start.position)
                try? await Task.sleep(for: .seconds(6))
                ball = VPinballVisionSampleBall(-1, "swplunger")
            }
            poke(launch.position - [launch.halfSize.x + 0.03, 0, 0])
            try? await Task.sleep(for: .milliseconds(30))
            guard !pressed(VPINBALL_VISION_LAUNCH_BALL) else {
                VPinballLog(VPINBALL_LOG_LEVEL_ERROR, "Simulator registered a poke beside the launch button")
                return
            }
            poke(launch.position)
            try? await Task.sleep(for: .milliseconds(30))
            guard pressed(VPINBALL_VISION_LAUNCH_BALL) else {
                VPinballLog(VPINBALL_LOG_LEVEL_ERROR, "Simulator launch button poke never reached Launch Ball")
                return
            }
            if let ball {
                var frontmostY = ball.y
                var peakSpeed: Float = 0
                let deadline = ContinuousClock.now + .seconds(2)
                while ContinuousClock.now < deadline && !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(8))
                    let current = VPinballVisionSampleBall(ball.id, nil)
                    if current.id == ball.id && ball.id >= 0 {
                        frontmostY = min(frontmostY, current.y)
                        peakSpeed = max(peakSpeed, -current.velocityY)
                    }
                }
                let travel = ball.y - frontmostY
                VPinballLog(VPINBALL_LOG_LEVEL_INFO, "Simulator launch button shot: ball \(ball.id), Y \(ball.y) to \(frontmostY), travel \(travel) VP units, peak up-lane velocity \(peakSpeed)")
                guard ball.id >= 0, travel > 350, peakSpeed > 0 else {
                    VPinballLog(VPINBALL_LOG_LEVEL_ERROR, "Simulator launch button shot did not reach the required point in the shooter lane")
                    return
                }
            } else {
                try? await Task.sleep(for: .milliseconds(500))
            }
            guard !pressed(VPINBALL_VISION_LAUNCH_BALL) else {
                VPinballLog(VPINBALL_LOG_LEVEL_ERROR, "Simulator Launch Ball stayed pressed")
                return
            }
            VPinballLog(VPINBALL_LOG_LEVEL_INFO, "Simulator verified the launch button poke and Launch Ball release")
        }

        if let handle = tracker.layout.plunger {
            func grip(depth: Float, pose: CabinetPlungerPose = .init(tuck: .grab)) {
                send(.right, .init(palm: handle + [0, 0, depth + 0.05], plungerPose: pose))
            }
            let shot: Float? = checkLaunchButton || arguments.contains("--check-ball-launch") ? 1
                : arguments.contains("--check-half-launch") ? 0.5 : nil
            let pulls: [Float] = shot.map { [$0] } ?? [0.5, 1]
            for expected in pulls {
                let distance = CabinetHandControls.plungerStroke * expected
                grip(depth: 0)
                grip(depth: distance)
                try? await Task.sleep(for: .milliseconds(350))
                guard abs(VPinballVisionPlungerPosition() - expected) < 0.02 else {
                    VPinballLog(VPINBALL_LOG_LEVEL_ERROR, "Simulator pull \(expected) never reached the plunger handler")
                    return
                }

                // Keep the last pull if the wrist moves forward while
                // rolling from the grab angle to the release angle.
                grip(depth: 0, pose: .uncertain)
                try? await Task.sleep(for: .milliseconds(45))
                time += 0.045
                tracker.serviceControls(at: time, playing: true)
                guard abs(VPinballVisionPlungerPosition() - expected) < 0.02 else {
                    VPinballLog(VPINBALL_LOG_LEVEL_ERROR, "Simulator lost the held plunger before release")
                    return
                }
                let ball = shot.map { _ in
                    checkLaunchButton ? VPinballVisionSampleBall(-1, "swplunger") : VPinballVisionSampleBall(-1, nil)
                }
                grip(depth: 0, pose: .init(tuck: .release))
                if checkLaunchButton && !pressed(VPINBALL_VISION_LAUNCH_BALL) {
                    VPinballLog(VPINBALL_LOG_LEVEL_ERROR, "Simulator plunger release never reached Launch Ball")
                    return
                }
                if let ball {
                    var frontmostY = ball.y
                    var peakSpeed: Float = 0
                    let deadline = ContinuousClock.now + .seconds(2)
                    while ContinuousClock.now < deadline && !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(8))
                        let current = VPinballVisionSampleBall(ball.id, nil)
                        if current.id == ball.id && ball.id >= 0 {
                            frontmostY = min(frontmostY, current.y)
                            peakSpeed = max(peakSpeed, -current.velocityY)
                        }
                    }
                    let travel = ball.y - frontmostY
                    // The supplied Time Machine script uses Gate1_Hit to mark the
                    // ball as out of the shooter. The authored gate sits at Y 725.16.
                    let passed = checkLaunchButton ? travel > 350 && peakSpeed > 0
                        : expected == 1 ? frontmostY < 725.16 : travel > 80
                    VPinballLog(VPINBALL_LOG_LEVEL_INFO, "Simulator shot \(expected): ball \(ball.id), Y \(ball.y) to \(frontmostY), travel \(travel) VP units, peak up-lane velocity \(peakSpeed)")
                    guard ball.id >= 0, passed else {
                        VPinballLog(VPINBALL_LOG_LEVEL_ERROR, "Simulator shot \(expected) did not reach the required point in the shooter lane")
                        return
                    }
                } else {
                    try? await Task.sleep(for: .milliseconds(500))
                }
                guard abs(VPinballVisionPlungerPosition()) < 0.02 else {
                    VPinballLog(VPINBALL_LOG_LEVEL_ERROR, "Simulator plunger failed to return to rest")
                    return
                }
            }

            VPinballLog(VPINBALL_LOG_LEVEL_INFO, "Simulator verified native palm-down plunger travel and release")
        }
        VPinballLog(VPINBALL_LOG_LEVEL_INFO, "Simulator verified coin, Start and both wrist flippers from cabinet-space hand samples")
        if CommandLine.arguments.contains("--check-nudges") {
            let offsets: [(SIMD3<Float>, VPINBALL_VISION_INPUT)] = [
                ([-0.032, 0, 0], VPINBALL_VISION_NUDGE_LEFT), ([0.032, 0, 0], VPINBALL_VISION_NUDGE_RIGHT),
                ([0, 0.032, 0], VPINBALL_VISION_NUDGE_FORWARD), ([0, -0.032, 0], VPINBALL_VISION_NUDGE_BACK)
            ]
            let leftRail = tracker.layout.flipper(.left) + [-0.07, 0.06, -0.08]
            let rightRail = tracker.layout.flipper(.right) + [0.07, 0.06, -0.08]
            func fists(_ offset: SIMD3<Float>, rightPose: CabinetHandPose = .fist) {
                send(.left, .init(palm: leftRail + offset, pose: .fist))
                send(.right, .init(palm: rightRail + offset, pose: rightPose))
            }
            for (offset, button) in offsets {
                time += 0.42
                let before = VPinballVisionNudgeCount()
                fists(.zero)
                fists(offset * 0.8)
                guard VPinballVisionNudgeCount() == before else {
                    VPinballLog(VPINBALL_LOG_LEVEL_ERROR, "Simulator nudge dead zone failed for button \(button.rawValue)")
                    return
                }
                fists(offset, rightPose: .unknown)
                try? await Task.sleep(for: .milliseconds(30))
                guard VPinballVisionNudgeCount() == before + 1,
                      button == VPINBALL_VISION_NUDGE_BACK || pressed(button),
                      !pressed(VPINBALL_VISION_LEFT_FLIPPER), !pressed(VPINBALL_VISION_RIGHT_FLIPPER) else {
                    VPinballLog(VPINBALL_LOG_LEVEL_ERROR, "Simulator two-fist nudge failed for button \(button.rawValue)")
                    return
                }
                send(.left, nil)
                send(.right, nil)
                try? await Task.sleep(for: .milliseconds(410))
            }
            VPinballLog(VPINBALL_LOG_LEVEL_INFO, "Simulator verified four two-fist nudges in the native cabinet model")
        }
        if CommandLine.arguments.contains("--check-room-placement") {
            VPinballLog(VPINBALL_LOG_LEVEL_INFO, "Simulator ready for cabinet grab")
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, ready else { return }
            await checkRoomPlacement()
        }
        if simulatorSequence, let selectedTable {
            guard VPinballVisionRomRunning() != 0 else {
                print("Simulator ROM was not running for \(selectedTable.title)")
                return
            }
            let width = VPinballVisionGetLayout().width
            VPinballLog(VPINBALL_LOG_LEVEL_INFO, "Simulator library passed \(selectedTable.title) at \(width) m")
            print("Simulator library passed \(selectedTable.title) at \(width) m")
            if !simulatorTables.isEmpty {
                try? await Task.sleep(for: .seconds(2))
                if !Task.isCancelled { showMenu() }
            }
        }
        await holdForScreenshot()
    }

    private func checkRoomPlacement() async {
        guard let tracker, let initial = tracker.simulatorRoomPose else { return }
        let center = initial * SIMD4<Float>(0, 0.22, 0.12, 1)
        var time = 0.0
        func feed(_ midpoint: SIMD4<Float>, right: SIMD4<Float>) {
            for side in CabinetHandSide.allCases {
                time += 0.015
                let point = midpoint + right * (side.sign * 0.25)
                tracker.updatePlacement(side, wrist: SIMD3(point.x, point.y, point.z), at: time)
            }
        }
        let turn = simd_float4x4(simd_quatf(angle: .pi / 9, axis: [0, 1, 0]))
        let target = center + SIMD4<Float>(0.25, 0.15, -0.25, 0)
        for _ in 0..<12 { feed(center, right: initial.columns.0) }
        feed(target, right: turn * initial.columns.0)
        guard tracker.simulatorRoomPose == initial else {
            VPinballLog(VPINBALL_LOG_LEVEL_ERROR, "Simulator moved the cabinet while playing")
            return
        }
        beginEditing()
        guard isEditingPlacement else { return }
        VPinballLog(VPINBALL_LOG_LEVEL_INFO, "Simulator placement panel open")
        try? await Task.sleep(for: .seconds(3))
        guard !Task.isCancelled, isEditingPlacement else { return }
        for _ in 0..<12 { feed(center, right: initial.columns.0) }
        feed(target, right: turn * initial.columns.0)
        let moved = tracker.simulatorRoomPose
        finishEditing(keepPlacement: false)
        guard let moved, let restored = tracker.simulatorRoomPose,
              abs(moved.columns.3.y - initial.columns.3.y) < 0.001,
              abs(moved.columns.0.z + sin(.pi / 9)) < 0.001,
              moved.columns.3.x - initial.columns.3.x > 0.20,
              simd_distance(restored.columns.3, initial.columns.3) < 0.001 else {
            VPinballLog(VPINBALL_LOG_LEVEL_ERROR, "Simulator cabinet movement or cancel failed")
            return
        }
        try? await Task.sleep(for: .milliseconds(750))
        guard !Task.isCancelled, ready else { return }
        beginEditing()
        for _ in 0..<12 { feed(center, right: initial.columns.0) }
        feed(target, right: turn * initial.columns.0)
        let preview = tracker.simulatorRoomPose
        finishEditing(keepPlacement: true)
        guard preview == tracker.simulatorRoomPose, preview != initial else { return }
        VPinballLog(VPINBALL_LOG_LEVEL_INFO, "Simulator verified edit-only translation, yaw, cancel and lock at fixed height")
    }
    #endif

    private func handle(_ input: CabinetInput) {
        guard ready, !stopping, !isCalibrating else { return }
        switch input {
        case let .flipper(side, pressed):
            VPinballVisionSetButton(side == .left ? VPINBALL_VISION_LEFT_FLIPPER : VPINBALL_VISION_RIGHT_FLIPPER,
                                   pressed ? 1 : 0)
        case .insertCoin:
            pulse(VPINBALL_VISION_ADD_CREDIT)
        case .pressStart:
            pulse(VPINBALL_VISION_START)
        case .pressLaunchBall:
            pulse(VPINBALL_VISION_LAUNCH_BALL)
        case let .nudge(direction):
            VPinballLog(VPINBALL_LOG_LEVEL_INFO, "Vision Pro two-fist nudge \(direction)")
            let button = switch direction {
            case .left: VPINBALL_VISION_NUDGE_LEFT
            case .right: VPINBALL_VISION_NUDGE_RIGHT
            case .up: VPINBALL_VISION_NUDGE_FORWARD
            case .down: VPINBALL_VISION_NUDGE_BACK
            }
            pulse(button)
        case let .pullPlunger(amount):
            _ = VPinballVisionSetPlunger(VPINBALL_VISION_PLUNGER_HOLD, amount)
        case let .releasePlunger(amount):
            if VPinballVisionSetPlunger(VPINBALL_VISION_PLUNGER_RELEASE, amount) != 0 {
                pulse(VPINBALL_VISION_LAUNCH_BALL)
            }
        case .cancelPlunger:
            _ = VPinballVisionSetPlunger(VPINBALL_VISION_PLUNGER_CANCEL, 0)
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

}
