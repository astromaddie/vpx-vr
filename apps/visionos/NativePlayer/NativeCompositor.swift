// license:GPLv3+

import ARKit
import CompositorServices
import Metal
import os
import QuartzCore
import simd
import SwiftUI

struct NativeLayerConfiguration: CompositorLayerConfiguration {
    private static let log = Logger(subsystem: "org.vpinball.vpxvision.player", category: "Compositor")

    /// Launch with `-Foveation NO` to compare against the uniform drawable.
    static var foveationAllowed: Bool { UserDefaults.standard.object(forKey: "Foveation") as? Bool ?? true }

    /// Launch with `-RenderQuality 0.5` to try a lower drawable resolution.
    static var renderQuality: Float {
        let value = UserDefaults.standard.object(forKey: "RenderQuality") as? Double ?? 1
        return Float(min(max(value, 0), 1))
    }

    func makeConfiguration(capabilities: LayerRenderer.Capabilities, configuration: inout LayerRenderer.Configuration) {
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
        Self.log.info("Layer: \(selection, privacy: .public)")
        let quality = foveation ? String(format: "%.2f", configuration.maxRenderQuality.rawValue) : "n/a"
        let defaultQuality = String(format: "%.2f", capabilities.defaultRenderQuality.rawValue)
        let support = "supported \(capabilities.supportsFoveation), allowed \(Self.foveationAllowed)"
        Self.log.info("Layer foveation: \(foveation ? "on" : "off", privacy: .public) (\(support, privacy: .public)), max render quality \(quality, privacy: .public), default \(defaultQuality, privacy: .public)")
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
    #if targetEnvironment(simulator)
    // Only accessed by VPX's render thread.
    private var checkFirstRenderStall = CommandLine.arguments.contains("--check-render-stall")
    #endif

    var isRunning: Bool { layer.state == .running }
    var isClosed: Bool { layer.state == .invalidated }
    var hasPresentedTable: Bool { handoff.withLock { $0.presentedPicture } }

    init(layer: LayerRenderer, world: WorldTrackingProvider, mixedReality: Bool, eyeSize: Int) throws {
        self.layer = layer
        self.world = world
        self.mixedReality = mixedReality
        let device = layer.device
        guard let queue = device.makeCommandQueue() else { throw SetupError.metal }
        self.queue = queue

        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type2DArray
        descriptor.width = eyeSize
        descriptor.height = eyeSize
        Self.log.info("VPX eye targets: \(eyeSize) × \(eyeSize)")
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

        if layer.configuration.isFoveationEnabled {
            layer.renderQuality = .init(rawValue: NativeLayerConfiguration.renderQuality)
            Self.log.info("Render quality: \(String(format: "%.2f", layer.renderQuality.rawValue), privacy: .public)")
        }
    }

    // Called after the player can service a frame request without blocking on table load.
    func place(_ transform: simd_float4x4) {
        handoff.withLock {
            $0.originFromCabinet = transform
            if $0.originFromRoom == nil { $0.originFromRoom = transform }
        }
    }

    func configurePlayer() -> Bool {
        var host = VPINBALL_VISION_HOST()
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
        command.addCompletedHandler { [timing] buffer in
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
            let drewTable = encode(drawables, chosen: chosen, anchor: anchor, completed: completed, command: command)
            if drewTable {
                pictureCount += 1
                if pictureCount == 1, let viewport = drawable.views.first?.textureMap.viewport {
                    Self.log.info("Compositor eye viewport: \(Int(viewport.width)) × \(Int(viewport.height)), \(drawable.views.count) views")
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
                            if count == 1 { handoff.withLock { $0.presentedPicture = true } }
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

    private func reportTiming() {
        let now = CACurrentMediaTime()
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
            let line = String(
                format: "Timing over %.1f s: presented %.1f Hz, %d missed, %d late copies, VPX %.1f fps, copy GPU %.2f ms avg %.2f max, %@",
                span, Double(counters.presented) / span, counters.missed, counters.lateCopies,
                Double(counters.vpxFrames) / span, copyAverage, counters.copyMax * 1000, vpxGPU)
            counters = Timing(windowStart: now, lastPresentation: counters.lastPresentation,
                              frameInterval: counters.frameInterval)
            return line
        }
        guard let line else { return }
        let quality = layer.configuration.isFoveationEnabled ? String(format: ", render quality %.2f", layer.renderQuality.rawValue) : ""
        Self.log.info("\(line, privacy: .public)\(quality, privacy: .public)")
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
            Self.log.info("Compositor path: uniform, no rate map, \(size, privacy: .public)")
        case .viewMaps, .layeredMap:
            let maps = drawable.rasterizationRateMaps
            let map = maps[0]
            let physical = map.physicalSize(layer: 0)
            let kind = path == .layeredMap ? "layered pass with one map of \(map.layerCount) layers" : "a pass per view with \(maps.count) maps"
            Self.log.info("Compositor path: foveated, \(kind, privacy: .public), logical \(map.screenSize.width) × \(map.screenSize.height), physical \(physical.width) × \(physical.height), \(size, privacy: .public)")
        case .unsupportedMaps(let count):
            Self.log.error("Compositor path: \(count) rate maps for \(drawable.views.count) views is not handled, drawing without them, \(size, privacy: .public)")
        }
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
        completed: Submission?, command: MTLCommandBuffer
    ) -> Bool {
        var drewTable = false
        for (index, drawable) in drawables.enumerated() {
            drawable.deviceAnchor = index == chosen ? completed?.anchor ?? anchor : anchor
            let path = index == chosen ? Self.copyPath(for: drawable) : .uniform
            if index == chosen, path == .layeredMap {
                drewTable = encodeLayered(drawable, completed: completed, command: command)
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

    private func encodeLayered(_ drawable: LayerRenderer.Drawable, completed: Submission?, command: MTLCommandBuffer) -> Bool {
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
