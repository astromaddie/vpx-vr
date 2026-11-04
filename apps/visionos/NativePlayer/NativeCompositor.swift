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

    func makeConfiguration(capabilities: LayerRenderer.Capabilities, configuration: inout LayerRenderer.Configuration) {
        let layouts = capabilities.supportedLayouts(options: [])
        configuration.isFoveationEnabled = false
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
    private let depthState: MTLDepthStencilState
    private let pictures: [Picture]
    private let handoff = OSAllocatedUnfairLock(uncheckedState: Handoff())
    // Only touched by the presentation thread.
    private var pictureCount = 0
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

        let library = try device.makeLibrary(source: Self.blitSource, options: nil)
        let pass = MTLRenderPipelineDescriptor()
        pass.vertexFunction = library.makeFunction(name: "fullScreen")
        pass.fragmentFunction = library.makeFunction(name: "copyEye")
        pass.colorAttachments[0].pixelFormat = layer.configuration.colorFormat
        pass.depthAttachmentPixelFormat = layer.configuration.depthFormat
        pipeline = try device.makeRenderPipelineState(descriptor: pass)
        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.isDepthWriteEnabled = true
        guard let depthState = device.makeDepthStencilState(descriptor: depthDescriptor) else { throw SetupError.metal }
        self.depthState = depthState
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
        guard let timing = frame.predictTiming() else { return }
        LayerRenderer.Clock().wait(until: timing.optimalInputTime)
        guard let command = queue.makeCommandBuffer() else { return }
        frame.startSubmission()

        let drawables = frame.queryDrawables()
        guard let chosen = drawables.firstIndex(where: { $0.target == .builtIn }) ?? drawables.indices.first else { return }
        defer { frame.endSubmission() }

        let drawable = drawables[chosen]
        let time = Self.seconds(LayerRenderer.Clock.Instant.epoch.duration(to: drawable.frameTiming.presentationTime))
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
            if index == chosen {
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

    private static let blitSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct EyeVertex { float4 position [[position]]; float2 uv; };
    struct EyePixel { half4 color [[color(0)]]; float depth [[depth(any)]]; };

    vertex EyeVertex fullScreen(uint id [[vertex_id]]) {
        float2 uv = float2((id << 1) & 2, id & 2);
        return { float4(uv.x * 2 - 1, 1 - uv.y * 2, 0, 1), uv };
    }

    fragment EyePixel copyEye(EyeVertex v [[stage_in]],
                              texture2d_array<half> color [[texture(0)]],
                              depth2d_array<float> depth [[texture(1)]],
                              constant uint2& options [[buffer(0)]]) {
        constexpr sampler colorSampler(coord::normalized, address::clamp_to_edge, filter::linear);
        constexpr sampler depthSampler(coord::normalized, address::clamp_to_edge, filter::nearest);
        const uint eye = options.x;
        const float reverseDepth = 1.0 - depth.sample(depthSampler, v.uv, eye);
        // VPX clears its conventional depth to 1. Keep the passthrough visible
        // there and submit opaque premultiplied color wherever VPX drew geometry.
        if (options.y && reverseDepth <= 0.0)
            return { half4(0), 0.0 };
        half3 linear = color.sample(colorSampler, v.uv, eye).rgb;
        return { half4(linear, 1), reverseDepth };
    }
    """
}
