// license:GPLv3+

import ARKit
import CompositorServices
import Metal
import os
import QuartzCore
import simd
import SwiftUI

/// Compositor lines go to os_log and to VPX's own `vpinball.log`, which can be
/// pulled from the app container after a session nobody was watching live.
/// VPX starts a new log file when it loads a table, so lines from before a
/// table's first frame wait for that frame.
enum CompositorLog {
    private struct State {
        var pending: [(String, Bool)] = []
        var live = false
    }

    private static let log = Logger(subsystem: "org.vpinball.vpxvision.player", category: "Compositor")
    private static let state = OSAllocatedUnfairLock(initialState: State())

    static func info(_ message: String) { write(message, error: false) }
    static func error(_ message: String) { write(message, error: true) }

    /// A new layer is being set up for a table, so hold lines until it shows.
    static func tableOpening() {
        state.withLock { $0 = State() }
    }

    static func tablePresented() {
        let lines = state.withLock { state -> [(String, Bool)] in
            defer { state = State(pending: [], live: true) }
            return state.pending
        }
        for (message, error) in lines { send(message, error: error) }
    }

    private static func write(_ message: String, error: Bool) {
        if error {
            log.error("\(message, privacy: .public)")
        } else {
            log.info("\(message, privacy: .public)")
        }
        let live = state.withLock { state -> Bool in
            if !state.live { state.pending.append((message, error)) }
            return state.live
        }
        if live { send(message, error: error) }
    }

    private static func send(_ message: String, error: Bool) {
        VPinballLog(error ? VPINBALL_LOG_LEVEL_ERROR : VPINBALL_LOG_LEVEL_INFO, "Compositor: " + message)
    }
}

struct NativeLayerConfiguration: CompositorLayerConfiguration {
    /// Launch with `-Foveation NO` to compare against the uniform drawable.
    static var foveationAllowed: Bool { UserDefaults.standard.object(forKey: "Foveation") as? Bool ?? true }

    /// Launch with `-RenderQuality 0.5` to try a lower drawable resolution.
    static var renderQuality: Float {
        let value = UserDefaults.standard.object(forKey: "RenderQuality") as? Double ?? 1
        return Float(min(max(value, 0), 1))
    }

    func makeConfiguration(capabilities: LayerRenderer.Capabilities, configuration: inout LayerRenderer.Configuration) {
        CompositorLog.tableOpening()
        // Foveation gives the drawable a rate map that spends more physical
        // pixels where the eye looks, and render quality raises its resolution.
        // Both need foveation, so the fallback is today's uniform drawable.
        let foveation = capabilities.supportsFoveation && Self.foveationAllowed
        let layouts = capabilities.supportedLayouts(options: foveation ? [.foveationEnabled] : [])
        configuration.isFoveationEnabled = foveation
        if foveation {
            configuration.maxRenderQuality = .init(rawValue: Self.renderQuality)
        }
        if layouts.contains(.layered) {
            configuration.layout = .layered
        } else if !layouts.contains(configuration.layout), let layout = layouts.first {
            configuration.layout = layout
        }
        if capabilities.supportedColorFormats(options: []).contains(.bgra8Unorm_srgb) {
            configuration.colorFormat = .bgra8Unorm_srgb
        }
        if capabilities.supportedDepthFormats.contains(.depth32Float) {
            configuration.depthFormat = .depth32Float
        }
        let selection = "layout \(configuration.layout), color \(configuration.colorFormat.rawValue), depth \(configuration.depthFormat.rawValue), near \(configuration.defaultDepthRange.y)"
        CompositorLog.info("Layer: \(selection)")
        let quality = foveation ? String(format: "%.2f", configuration.maxRenderQuality.rawValue) : "n/a"
        let defaultQuality = String(format: "%.2f", capabilities.defaultRenderQuality.rawValue)
        let support = "supported \(capabilities.supportsFoveation), allowed \(Self.foveationAllowed)"
        CompositorLog.info("Layer foveation: \(foveation ? "on" : "off") (\(support)), max render quality \(quality), default \(defaultQuality)")
    }
}

/// Compositor Services frames live only on the presentation thread. VPX's
/// render thread receives the latest eye poses and publishes a GPU submission.
final class NativeCompositor: @unchecked Sendable {
    private struct Picture {
        let color: MTLTexture
        let depth: MTLTexture
    }

    private struct Request {
        let packet: VPINBALL_VISION_FRAME
        let anchor: DeviceAnchor?
        let presentationTime: Double
    }

    private struct Submission {
        let buffer: Int
        let anchor: DeviceAnchor?
    }

    private enum CopyPath: Equatable {
        case uniform
        case viewMaps(Int)
        case layeredMap
        case unsupportedMaps(Int)
    }

    /// Counters for the periodic timing line. Times are host seconds, the
    /// same clock as `CACurrentMediaTime` and command buffer GPU times.
    private struct Timing {
        var windowStart = 0.0
        var lastPresentation: Double?
        var frameInterval = Double.infinity
        var presented = 0
        var missed = 0
        var copies = 0
        var lateCopies = 0
        var copySeconds = 0.0
        var copyMax = 0.0
        // GPU timestamps at the start of the copy's vertex stage and the end of its
        // fragment stage, in ticks. The command buffer's own GPU times also count
        // the wait behind VPX's work on the shared queue.
        var copyErrors = 0
        var passes = 0
        var passTicks = 0.0
        var passMaxTicks = 0.0
        var vpxFrames = 0
        var vpxSamples = 0
        var vpxMilliseconds = 0.0
        var vpxMax = 0.0
    }

    private struct Handoff {
        var originFromCabinet: simd_float4x4?
        var originFromRoom: simd_float4x4?
        var request: Request?
        var drawing: Submission?
        var latest: Submission?
        var presentedPicture = false
        var renderedFrames = 0
        // Host times of VPX's last frame request and hand-back, for the stall watch.
        var begins = 0
        var lastBegin = 0.0
        var lastEnd = 0.0
        #if targetEnvironment(simulator)
        var submittedFrames = 0
        #endif
    }

    private static let log = Logger(subsystem: "org.vpinball.vpxvision.player", category: "Compositor")
    private let layer: LayerRenderer
    private let world: WorldTrackingProvider
    private let mixedReality: Bool
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let layeredPipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private let pictures: [Picture]
    private let handoff = OSAllocatedUnfairLock(uncheckedState: Handoff())
    private let timing = OSAllocatedUnfairLock(initialState: Timing())
    private static let timingPeriod = 5.0
    // Only touched by the presentation thread.
    private var pictureCount = 0
    private var copyPath: CopyPath?
    private var viewAspectLogged = false
    // Stall watch, only touched by the presentation thread.
    private let openedAt = CACurrentMediaTime()
    private var watchedFrames = 0
    private var lastNewFrame = 0.0
    private var stalledSince: Double?
    private var firstFrameWarned = false
    // Stage boundary timestamps for the copy pass, two per slot, when the GPU supports them.
    private static let counterSlots = 8
    private let copyCounters: MTLCounterSampleBuffer?
    private var counterSlot = 0
    // GPU ticks against host nanoseconds, to convert the counter timestamps.
    private let clockStart: (gpu: MTLTimestamp, nanoseconds: UInt64)
    #if targetEnvironment(simulator)
    // Only accessed by VPX's render thread.
    private var checkFirstRenderStall = CommandLine.arguments.contains("--check-render-stall")
    #endif

    var isRunning: Bool { layer.state == .running }
    var isClosed: Bool { layer.state == .invalidated }
    var hasPresentedTable: Bool { handoff.withLock { $0.presentedPicture } }

    init(layer: LayerRenderer, world: WorldTrackingProvider, mixedReality: Bool, eyeWidth: Int, eyeHeight: Int) throws {
        self.layer = layer
        self.world = world
        self.mixedReality = mixedReality
        let device = layer.device
        guard let queue = device.makeCommandQueue() else { throw SetupError.metal }
        self.queue = queue

        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type2DArray
        descriptor.width = eyeWidth
        descriptor.height = eyeHeight
        CompositorLog.info("VPX eye targets: \(eyeWidth) × \(eyeHeight)")
        descriptor.arrayLength = 2
        descriptor.storageMode = .private
        descriptor.usage = [.renderTarget, .shaderRead, .pixelFormatView]
        pictures = try (0..<2).map { index in
            descriptor.pixelFormat = .bgra8Unorm
            guard let color = device.makeTexture(descriptor: descriptor) else { throw SetupError.metal }
            descriptor.pixelFormat = .depth32Float
            guard let depth = device.makeTexture(descriptor: descriptor) else { throw SetupError.metal }
            color.label = "VPX Eyes \(index) Color"
            depth.label = "VPX Eyes \(index) Depth"
            return Picture(color: color, depth: depth)
        }

        let library = try device.makeLibrary(source: CompositorShaders.source, options: nil)
        let pass = MTLRenderPipelineDescriptor()
        pass.vertexFunction = library.makeFunction(name: CompositorShaders.fullScreen)
        pass.fragmentFunction = library.makeFunction(name: CompositorShaders.copyEye)
        pass.colorAttachments[0].pixelFormat = layer.configuration.colorFormat
        pass.depthAttachmentPixelFormat = layer.configuration.depthFormat
        pipeline = try device.makeRenderPipelineState(descriptor: pass)
        pass.vertexFunction = library.makeFunction(name: CompositorShaders.fullScreenLayered)
        pass.fragmentFunction = library.makeFunction(name: CompositorShaders.copyLayeredEye)
        pass.inputPrimitiveTopology = .triangle
        layeredPipeline = try device.makeRenderPipelineState(descriptor: pass)
        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.isDepthWriteEnabled = true
        guard let depthState = device.makeDepthStencilState(descriptor: depthDescriptor) else { throw SetupError.metal }
        self.depthState = depthState

        if device.supportsCounterSampling(.atStageBoundary),
           let set = device.counterSets?.first(where: { $0.name == MTLCommonCounterSet.timestamp.rawValue }) {
            let counters = MTLCounterSampleBufferDescriptor()
            counters.counterSet = set
            counters.storageMode = .shared
            counters.sampleCount = Self.counterSlots * 2
            counters.label = "Copy Pass Timestamps"
            copyCounters = try? device.makeCounterSampleBuffer(descriptor: counters)
        } else {
            copyCounters = nil
        }
        CompositorLog.info("Copy pass timestamps: \(copyCounters == nil ? "unavailable" : "stage boundary counters")")
        clockStart = (device.sampleTimestamps().gpu, DispatchTime.now().uptimeNanoseconds)

        if layer.configuration.isFoveationEnabled {
            layer.renderQuality = .init(rawValue: NativeLayerConfiguration.renderQuality)
            CompositorLog.info("Render quality: \(String(format: "%.2f", layer.renderQuality.rawValue))")
        }
    }

    // Called after the player can service a frame request without blocking on table load.
    func place(_ transform: simd_float4x4) {
        handoff.withLock {
            $0.originFromCabinet = transform
            if $0.originFromRoom == nil { $0.originFromRoom = transform }
        }
    }

    func configurePlayer(session: String) -> Bool {
        var host = VPINBALL_VISION_HOST()
        withUnsafeMutableBytes(of: &host.session) { buffer in
            let bytes = Array(session.utf8.prefix(buffer.count - 1))
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        host.user = Unmanaged.passUnretained(self).toOpaque()
        host.metalDevice = Unmanaged.passUnretained(layer.device as AnyObject).toOpaque()
        host.metalQueue = Unmanaged.passUnretained(queue as AnyObject).toOpaque()
        host.color = (Unmanaged.passUnretained(pictures[0].color as AnyObject).toOpaque(),
                      Unmanaged.passUnretained(pictures[1].color as AnyObject).toOpaque())
        host.depth = (Unmanaged.passUnretained(pictures[0].depth as AnyObject).toOpaque(),
                      Unmanaged.passUnretained(pictures[1].depth as AnyObject).toOpaque())
        host.width = UInt32(pictures[0].color.width)
        host.height = UInt32(pictures[0].color.height)
        host.mixedReality = mixedReality ? 1 : 0
        host.beginFrame = { user, frame in
            guard let user, let frame else { return 0 }
            let renderer = Unmanaged<NativeCompositor>.fromOpaque(user).takeUnretainedValue()
            return autoreleasepool { renderer.begin(&frame.pointee) ? 1 : 0 }
        }
        host.endFrame = { user, rendered in
            guard let user else { return }
            let renderer = Unmanaged<NativeCompositor>.fromOpaque(user).takeUnretainedValue()
            autoreleasepool { renderer.end(rendered: rendered != 0) }
        }
        return VPinballVisionConfigure(&host) == VPINBALL_STATUS_SUCCESS
    }

    func start() {
        let thread = Thread { [self] in
            while !isClosed {
                if isRunning {
                    autoreleasepool { present() }
                } else {
                    handoff.withLock { $0.request = nil }
                    layer.waitUntilRunning()
                }
            }
        }
        thread.name = "VPX Compositor"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    private func begin(_ packet: inout VPINBALL_VISION_FRAME) -> Bool {
        guard isRunning else { return false }
        let acquired: VPINBALL_VISION_FRAME? = handoff.withLock { state in
            guard let request = state.request else { return nil }
            state.request = nil
            let buffer = state.latest?.buffer == 0 ? 1 : 0
            var result = request.packet
            result.eyeBuffer = UInt32(buffer)
            result.secondsUntilPresentation = Float(max(0, request.presentationTime - CACurrentMediaTime()))
            state.drawing = Submission(buffer: buffer, anchor: request.anchor)
            state.begins += 1
            state.lastBegin = CACurrentMediaTime()
            return result
        }
        guard let acquired else { return false }
        packet = acquired
        #if targetEnvironment(simulator)
        if checkFirstRenderStall {
            checkFirstRenderStall = false
            let before = handoff.withLock { $0.submittedFrames }
            Thread.sleep(forTimeInterval: 3)
            let submitted = handoff.withLock { $0.submittedFrames - before }
            if submitted > 0 {
                Self.log.info("Simulator submitted \(submitted) frames during a three-second VPX render stall")
            } else {
                Self.log.error("Simulator compositor stalled with VPX")
            }
        }
        #endif
        return true
    }

    private func end(rendered: Bool) {
        if rendered {
            // BGFX's GPU time for its newest finished frame, read on its API thread.
            let milliseconds = Double(VPinballVisionLastGpuMilliseconds())
            timing.withLock { counters in
                counters.vpxFrames += 1
                if milliseconds >= 0 {
                    counters.vpxSamples += 1
                    counters.vpxMilliseconds += milliseconds
                    counters.vpxMax = max(counters.vpxMax, milliseconds)
                }
            }
        }
        handoff.withLock { state in
            state.lastEnd = CACurrentMediaTime()
            if rendered, let drawing = state.drawing {
                state.latest = drawing
                state.renderedFrames += 1
            }
            state.drawing = nil
        }
    }

    private func present() {
        guard let frame = layer.queryNextFrame() else {
            Thread.sleep(forTimeInterval: 0.001)
            return
        }
        frame.startUpdate()
        frame.endUpdate()
        guard let predicted = frame.predictTiming() else { return }
        LayerRenderer.Clock().wait(until: predicted.optimalInputTime)
        guard let command = queue.makeCommandBuffer() else { return }
        frame.startSubmission()

        let drawables = frame.queryDrawables()
        guard let chosen = drawables.firstIndex(where: { $0.target == .builtIn }) ?? drawables.indices.first else { return }
        defer { frame.endSubmission() }

        let drawable = drawables[chosen]
        let time = Self.seconds(LayerRenderer.Clock.Instant.epoch.duration(to: drawable.frameTiming.presentationTime))
        let deadline = Self.seconds(LayerRenderer.Clock.Instant.epoch.duration(to: drawable.frameTiming.renderingDeadline))
        recordPresentation(at: time)
        let slot = counterSlot
        counterSlot = (counterSlot + 1) % Self.counterSlots
        command.addCompletedHandler { [timing] buffer in
            if buffer.status == .error {
                // A failing copy usually means the GPU is out of memory or VPX's work faulted first.
                let report = timing.withLock { counters -> Bool in
                    counters.copyErrors += 1
                    return counters.copyErrors == 1 || counters.copyErrors.isMultiple(of: 90)
                }
                if report {
                    CompositorLog.error("Copy command buffer failed: \(buffer.error.map { String(describing: $0) } ?? "no error"), \(Double(os_proc_available_memory()) / 1_048_576) MB available")
                }
            }
            guard buffer.status == .completed, buffer.gpuEndTime > 0 else { return }
            let seconds = buffer.gpuEndTime - buffer.gpuStartTime
            let late = buffer.gpuEndTime > deadline
            timing.withLock { counters in
                counters.copies += 1
                counters.copySeconds += seconds
                counters.copyMax = max(counters.copyMax, seconds)
                if late { counters.lateCopies += 1 }
            }
        }
        let anchor = world.state == .running ? world.queryDeviceAnchor(atTimestamp: time) : nil
        let request = makeRequest(drawable, anchor: anchor, presentationTime: time)
        // Hold the slot until the copy is queued. VPX can then reuse it on
        // the same queue even if this copy has not finished on the GPU.
        handoff.withLockUnchecked { state in
            state.request = request
            let completed = state.latest
            let drewTable = encode(drawables, chosen: chosen, anchor: anchor, completed: completed, command: command, slot: slot)
            if drewTable, let copyCounters {
                command.addCompletedHandler { [timing] buffer in
                    guard buffer.status == .completed else { return }
                    if let data = try? copyCounters.resolveCounterRange(slot * 2..<slot * 2 + 2),
                       data.count >= 2 * MemoryLayout<MTLCounterResultTimestamp>.stride {
                        let stamps = data.withUnsafeBytes { Array($0.bindMemory(to: MTLCounterResultTimestamp.self).prefix(2)) }
                        if stamps[0].timestamp != MTLCounterErrorValue, stamps[1].timestamp != MTLCounterErrorValue,
                           stamps[1].timestamp > stamps[0].timestamp {
                            let ticks = Double(stamps[1].timestamp - stamps[0].timestamp)
                            timing.withLock { counters in
                                counters.passes += 1
                                counters.passTicks += ticks
                                counters.passMaxTicks = max(counters.passMaxTicks, ticks)
                            }
                        }
                    }
                }
            }
            if drewTable {
                pictureCount += 1
                if pictureCount == 1, let viewport = drawable.views.first?.textureMap.viewport {
                    CompositorLog.info("Compositor eye viewport: \(Int(viewport.width)) × \(Int(viewport.height)), \(drawable.views.count) views")
                }
                logCopyPath(drawable)
                #if targetEnvironment(simulator)
                let report = pictureCount == 1 || pictureCount.isMultiple(of: 120)
                #else
                let report = pictureCount == 1
                #endif
                if report {
                    let count = pictureCount
                    let rendered = state.renderedFrames
                    command.addCompletedHandler { [self] buffer in
                        if let error = buffer.error {
                            Self.log.error("Table frame \(count) failed: \(error.localizedDescription, privacy: .public)")
                        } else {
                            if count == 1 {
                                handoff.withLock { $0.presentedPicture = true }
                                CompositorLog.tablePresented()
                            }
                            Self.log.info("Table frame \(count) completed, \(rendered) VPX frames submitted")
                        }
                    }
                }
            }
            command.commit()
            #if targetEnvironment(simulator)
            state.submittedFrames += 1
            #endif
        }
        reportTiming()
        watchForStalls()
    }

    private func recordPresentation(at time: Double) {
        timing.withLock { counters in
            counters.presented += 1
            if let last = counters.lastPresentation {
                let interval = time - last
                // The shortest step seen is the display's frame interval.
                if interval > 0.004 { counters.frameInterval = min(counters.frameInterval, interval) }
                if counters.frameInterval.isFinite {
                    counters.missed += max(0, Int((interval / counters.frameInterval).rounded()) - 1)
                }
            }
            counters.lastPresentation = time
        }
    }

    /// Logs when VPX stops handing over new pictures for more than a second while the compositor
    /// keeps presenting (the table freezes but the head still tracks), and when they come back.
    private func watchForStalls() {
        let now = CACurrentMediaTime()
        let state = handoff.withLock { ($0.renderedFrames, $0.begins, $0.lastBegin, $0.lastEnd, $0.drawing != nil, $0.presentedPicture) }
        let (rendered, begins, lastBegin, lastEnd, drawing, presented) = state
        func detail() -> String {
            let memory = Double(os_proc_available_memory()) / 1_048_576
            func ago(_ time: Double) -> String { time > 0 ? String(format: "%.1f s ago", now - time) : "never" }
            return String(format: "%d VPX frames, %d requests, last request %@, last hand-back %@, VPX %@, %.0f MB available",
                          rendered, begins, ago(lastBegin), ago(lastEnd), drawing ? "holding a frame" : "not drawing", memory)
        }
        if !presented {
            if !firstFrameWarned, now - openedAt > 20 {
                firstFrameWarned = true
                // Sent straight to VPX's log: held lines only go out once a table frame shows.
                VPinballLog(VPINBALL_LOG_LEVEL_ERROR, "Compositor: no table frame 20 s after opening: " + detail())
            }
            return
        }
        if rendered != watchedFrames {
            if let since = stalledSince {
                CompositorLog.info(String(format: "VPX frames resumed after %.1f s", now - since))
                stalledSince = nil
            }
            watchedFrames = rendered
            lastNewFrame = now
        } else if stalledSince == nil, lastNewFrame > 0, now - lastNewFrame > 1 {
            stalledSince = lastNewFrame
            CompositorLog.error("VPX frames stopped for 1 s while the compositor keeps presenting: " + detail())
        }
    }

    private func reportTiming() {
        let now = CACurrentMediaTime()
        let gpu = layer.device.sampleTimestamps().gpu
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - clockStart.nanoseconds)
        let millisecondsPerTick = gpu > clockStart.gpu ? elapsed / Double(gpu - clockStart.gpu) / 1e6 : 0
        let line: String? = timing.withLock { counters in
            if counters.windowStart == 0 {
                counters.windowStart = now
                return nil
            }
            let span = now - counters.windowStart
            guard span >= Self.timingPeriod else { return nil }
            let copyAverage = counters.copies > 0 ? counters.copySeconds * 1000 / Double(counters.copies) : 0
            let vpxAverage = counters.vpxSamples > 0 ? counters.vpxMilliseconds / Double(counters.vpxSamples) : 0
            let vpxGPU = counters.vpxSamples > 0
                ? String(format: "VPX GPU %.2f ms avg %.2f max", vpxAverage, counters.vpxMax) : "VPX GPU unavailable"
            let pass = counters.passes > 0 && millisecondsPerTick > 0
                ? String(format: "copy pass %.2f ms avg %.2f max", counters.passTicks / Double(counters.passes) * millisecondsPerTick,
                         counters.passMaxTicks * millisecondsPerTick)
                : "copy pass unavailable"
            let line = String(
                format: "Timing over %.1f s: presented %.1f Hz, %d missed, %d late copies, VPX %.1f fps, %@, copy buffer %.2f ms avg %.2f max, %@",
                span, Double(counters.presented) / span, counters.missed, counters.lateCopies,
                Double(counters.vpxFrames) / span, pass, copyAverage, counters.copyMax * 1000, vpxGPU)
            counters = Timing(windowStart: now, lastPresentation: counters.lastPresentation,
                              frameInterval: counters.frameInterval)
            return line
        }
        guard let line else { return }
        let quality = layer.configuration.isFoveationEnabled ? String(format: ", render quality %.2f", layer.renderQuality.rawValue) : ""
        CompositorLog.info(line + quality)
    }

    private static func copyPath(for drawable: LayerRenderer.Drawable) -> CopyPath {
        let maps = drawable.rasterizationRateMaps
        let views = drawable.views
        guard !maps.isEmpty else { return .uniform }
        // Layered foveation has one map with a layer per slice. Each layer
        // applies to the slice the vertex stage routes the view to, so both
        // views are drawn in one layered pass.
        let textures = Set(views.map(\.textureMap.textureIndex))
        let slices = Set(views.map(\.textureMap.sliceIndex))
        if maps.count == 1, views.count > 1, textures.count == 1, slices.count == views.count,
           maps[0].layerCount > slices.max() ?? 0 {
            return .layeredMap
        }
        // Dedicated textures, or a single view, get one map per view.
        if maps.count == views.count { return .viewMaps(maps.count) }
        return .unsupportedMaps(maps.count)
    }

    private func logCopyPath(_ drawable: LayerRenderer.Drawable) {
        let path = Self.copyPath(for: drawable)
        guard path != copyPath else { return }
        copyPath = path
        let texture = drawable.colorTextures[drawable.views.first?.textureMap.textureIndex ?? 0]
        let size = "drawable texture \(texture.width) × \(texture.height) × \(texture.arrayLength)"
        switch path {
        case .uniform:
            CompositorLog.info("Compositor path: uniform, no rate map, \(size)")
            if let viewport = drawable.views.first?.textureMap.viewport { logAspect(viewport.width / max(viewport.height, 1)) }
        case .viewMaps, .layeredMap:
            let maps = drawable.rasterizationRateMaps
            let map = maps[0]
            let physical = map.physicalSize(layer: 0)
            let kind = path == .layeredMap ? "layered pass with one map of \(map.layerCount) layers" : "a pass per view with \(maps.count) maps"
            CompositorLog.info("Compositor path: foveated, \(kind), logical \(map.screenSize.width) × \(map.screenSize.height), physical \(physical.width) × \(physical.height), \(size)")
            logAspect(Double(map.screenSize.width) / Double(max(map.screenSize.height, 1)))
        case .unsupportedMaps(let count):
            CompositorLog.error("Compositor path: \(count) rate maps for \(drawable.views.count) views is not handled, drawing without them, \(size)")
        }
    }

    private func logAspect(_ view: Double) {
        guard !viewAspectLogged else { return }
        viewAspectLogged = true
        let eyes = pictures[0].color
        CompositorLog.info(String(format: "View aspect %.3f, VPX eye targets %d × %d (aspect %.3f)",
                                  view, eyes.width, eyes.height, Double(eyes.width) / Double(eyes.height)))
    }

    private func makeRequest(
        _ drawable: LayerRenderer.Drawable, anchor: DeviceAnchor?, presentationTime: Double
    ) -> Request? {
        let origins = handoff.withLock { ($0.originFromCabinet, $0.originFromRoom) }
        guard let originFromCabinet = origins.0, let originFromRoom = origins.1, !drawable.views.isEmpty else {
            return nil
        }
        #if targetEnvironment(simulator)
        let originFromHead = anchor?.originFromAnchorTransform ?? matrix_identity_float4x4
        #else
        guard let anchor, anchor.isTracked, drawable.views.count == 2 else { return nil }
        let originFromHead = anchor.originFromAnchorTransform
        #endif

        func eyeFromOrigin(_ eye: Int) -> simd_float4x4 {
            (originFromHead * drawable.views[eye].transform).inverse
        }
        func projection(_ eye: Int) -> simd_float4x4 {
            var matrix = drawable.computeProjection(convention: .rightUpBack, viewIndex: eye)
            for column in 0..<4 {
                matrix[column].z = matrix[column].w - matrix[column].z
            }
            return matrix
        }
        var packet = VPINBALL_VISION_FRAME()
        let right = drawable.views.count == 2 ? 1 : 0
        let leftView = eyeFromOrigin(0)
        let rightView = right == 0 ? leftView : eyeFromOrigin(right)
        Self.copy(leftView * originFromCabinet, to: &packet.leftView)
        Self.copy(rightView * originFromCabinet, to: &packet.rightView)
        Self.copy(leftView * originFromRoom, to: &packet.leftRoomView)
        Self.copy(rightView * originFromRoom, to: &packet.rightRoomView)
        Self.copy(projection(0), to: &packet.leftProjection)
        Self.copy(projection(right), to: &packet.rightProjection)
        return Request(packet: packet, anchor: anchor, presentationTime: presentationTime)
    }

    private func encode(
        _ drawables: [LayerRenderer.Drawable], chosen: Int, anchor: DeviceAnchor?,
        completed: Submission?, command: MTLCommandBuffer, slot: Int
    ) -> Bool {
        var drewTable = false
        for (index, drawable) in drawables.enumerated() {
            drawable.deviceAnchor = index == chosen ? completed?.anchor ?? anchor : anchor
            let path = index == chosen ? Self.copyPath(for: drawable) : .uniform
            if index == chosen, path == .layeredMap {
                drewTable = encodeLayered(drawable, completed: completed, command: command, slot: slot)
            } else if index == chosen {
                for (eye, view) in drawable.views.enumerated() {
                    let map = view.textureMap
                    let pass = MTLRenderPassDescriptor()
                    pass.colorAttachments[0].texture = drawable.colorTextures[map.textureIndex]
                    pass.colorAttachments[0].slice = map.sliceIndex
                    // Shared layout places both views in the same texture and slice.
                    let alreadyCleared = drawable.views.prefix(eye).contains {
                        $0.textureMap.textureIndex == map.textureIndex && $0.textureMap.sliceIndex == map.sliceIndex
                    }
                    pass.colorAttachments[0].loadAction = alreadyCleared ? .load : .clear
                    pass.colorAttachments[0].storeAction = .store
                    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, mixedReality ? 0 : 1)
                    pass.depthAttachment.texture = drawable.depthTextures[map.textureIndex]
                    pass.depthAttachment.slice = map.sliceIndex
                    pass.depthAttachment.loadAction = alreadyCleared ? .load : .clear
                    pass.depthAttachment.storeAction = .store
                    pass.depthAttachment.clearDepth = 0
                    if case .viewMaps = path { pass.rasterizationRateMap = drawable.rasterizationRateMaps[eye] }
                    if completed != nil {
                        attachCounters(pass, slot: slot, start: eye == 0, end: eye == drawable.views.count - 1)
                    }

                    guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { continue }
                    if let completed {
                        let picture = pictures[completed.buffer]
                        var copyOptions = SIMD2(UInt32(eye), mixedReality ? 1 : 0)
                        encoder.setViewport(map.viewport)
                        encoder.setRenderPipelineState(pipeline)
                        encoder.setDepthStencilState(depthState)
                        encoder.setFragmentTexture(picture.color, index: 0)
                        encoder.setFragmentTexture(picture.depth, index: 1)
                        encoder.setFragmentBytes(&copyOptions, length: MemoryLayout<SIMD2<UInt32>>.size, index: 0)
                        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                        drewTable = true
                    }
                    encoder.endEncoding()
                }
            }
            drawable.encodePresent(commandBuffer: command)
        }
        return drewTable
    }

    private func encodeLayered(_ drawable: LayerRenderer.Drawable, completed: Submission?, command: MTLCommandBuffer, slot: Int) -> Bool {
        let views = drawable.views
        let first = views[0].textureMap
        let color = drawable.colorTextures[first.textureIndex]
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = color
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, mixedReality ? 0 : 1)
        pass.depthAttachment.texture = drawable.depthTextures[first.textureIndex]
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .store
        pass.depthAttachment.clearDepth = 0
        pass.renderTargetArrayLength = color.arrayLength
        pass.rasterizationRateMap = drawable.rasterizationRateMaps[0]
        if completed != nil { attachCounters(pass, slot: slot, start: true, end: true) }

        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return false }
        defer { encoder.endEncoding() }
        guard let completed else { return false }
        let picture = pictures[completed.buffer]
        // Viewports stay in the logical (screen) space of the rate map.
        encoder.setViewports(views.map(\.textureMap.viewport))
        encoder.setRenderPipelineState(layeredPipeline)
        encoder.setDepthStencilState(depthState)
        var slices = views.map { UInt32($0.textureMap.sliceIndex) }
        encoder.setVertexBytes(&slices, length: MemoryLayout<UInt32>.stride * slices.count, index: 0)
        var copyOptions = SIMD2<UInt32>(0, mixedReality ? 1 : 0)
        encoder.setFragmentTexture(picture.color, index: 0)
        encoder.setFragmentTexture(picture.depth, index: 1)
        encoder.setFragmentBytes(&copyOptions, length: MemoryLayout<SIMD2<UInt32>>.size, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3, instanceCount: views.count)
        return true
    }

    /// Samples the start of the first pass's vertex stage and the end of the last pass's fragment stage.
    private func attachCounters(_ pass: MTLRenderPassDescriptor, slot: Int, start: Bool, end: Bool) {
        guard let copyCounters, start || end, let attachment = pass.sampleBufferAttachments[0] else { return }
        attachment.sampleBuffer = copyCounters
        attachment.startOfVertexSampleIndex = start ? slot * 2 : MTLCounterDontSample
        attachment.endOfVertexSampleIndex = MTLCounterDontSample
        attachment.startOfFragmentSampleIndex = MTLCounterDontSample
        attachment.endOfFragmentSampleIndex = end ? slot * 2 + 1 : MTLCounterDontSample
    }

    private static func seconds(_ duration: Duration) -> Double {
        let value = duration.components
        return Double(value.seconds) + Double(value.attoseconds) / 1e18
    }

    private static func copy<T>(_ matrix: simd_float4x4, to storage: inout T) {
        withUnsafeBytes(of: matrix) { source in
            withUnsafeMutableBytes(of: &storage) { $0.copyBytes(from: source) }
        }
    }

    private enum SetupError: Error { case metal }
}
