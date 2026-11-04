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

/// The player owns the frame loop. Only the cabinet transform crosses from the
/// main actor after initialization. All Metal commands use one command queue.
final class NativeCompositor: @unchecked Sendable {
    private let layer: LayerRenderer
    private let world: WorldTrackingProvider
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private let color: MTLTexture
    private let depth: MTLTexture
    private let placement = OSAllocatedUnfairLock<simd_float4x4?>(initialState: nil)
    private var current: (LayerRenderer.Frame, [LayerRenderer.Drawable], Int)?

    var isRunning: Bool { layer.state == .running }
    var isClosed: Bool { layer.state == .invalidated }

    init(layer: LayerRenderer, world: WorldTrackingProvider) throws {
        self.layer = layer
        self.world = world
        let device = layer.device
        guard let queue = device.makeCommandQueue() else { throw SetupError.metal }
        self.queue = queue

        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type2DArray
        descriptor.width = 1536
        descriptor.height = 1536
        descriptor.arrayLength = 2
        descriptor.storageMode = .private
        descriptor.usage = [.renderTarget, .shaderRead, .pixelFormatView]
        descriptor.pixelFormat = .bgra8Unorm
        guard let color = device.makeTexture(descriptor: descriptor) else { throw SetupError.metal }
        self.color = color
        descriptor.pixelFormat = .depth32Float
        guard let depth = device.makeTexture(descriptor: descriptor) else { throw SetupError.metal }
        self.depth = depth

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
        placement.withLock { $0 = transform }
    }

    func configurePlayer() -> Bool {
        var host = VPINBALL_VISION_HOST()
        host.user = Unmanaged.passUnretained(self).toOpaque()
        host.metalDevice = Unmanaged.passUnretained(layer.device as AnyObject).toOpaque()
        host.metalQueue = Unmanaged.passUnretained(queue as AnyObject).toOpaque()
        host.color = Unmanaged.passUnretained(color as AnyObject).toOpaque()
        host.depth = Unmanaged.passUnretained(depth as AnyObject).toOpaque()
        host.width = UInt32(color.width)
        host.height = UInt32(color.height)
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

    private func begin(_ packet: inout VPINBALL_VISION_FRAME) -> Bool {
        guard isRunning, let frame = layer.queryNextFrame() else { return false }
        frame.startUpdate()
        frame.endUpdate()
        guard let timing = frame.predictTiming() else { return false }
        LayerRenderer.Clock().wait(until: timing.optimalInputTime)
        frame.startSubmission()

        let drawables = frame.queryDrawables()
        guard let chosen = drawables.firstIndex(where: { $0.target == .builtIn }) ?? drawables.indices.first else {
            return false
        }
        let drawable = drawables[chosen]
        let time = Self.seconds(LayerRenderer.Clock.Instant.epoch.duration(to: drawable.frameTiming.presentationTime))
        let anchor = world.queryDeviceAnchor(atTimestamp: time)
        for target in drawables { target.deviceAnchor = anchor }
        current = (frame, drawables, chosen)
        guard let anchor, anchor.isTracked, drawable.views.count == 2,
              let originFromCabinet = placement.withLock({ $0 }) else {
            end(rendered: false)
            return false
        }

        func view(_ eye: Int) -> simd_float4x4 {
            (anchor.originFromAnchorTransform * drawable.views[eye].transform).inverse * originFromCabinet
        }
        func projection(_ eye: Int) -> simd_float4x4 {
            var matrix = drawable.computeProjection(convention: .rightUpBack, viewIndex: eye)
            for column in 0..<4 {
                matrix[column].z = matrix[column].w - matrix[column].z
            }
            return matrix
        }
        Self.copy(view(0), to: &packet.leftView)
        Self.copy(view(1), to: &packet.rightView)
        Self.copy(projection(0), to: &packet.leftProjection)
        Self.copy(projection(1), to: &packet.rightProjection)
        packet.secondsUntilPresentation = Float(max(0, time - CACurrentMediaTime()))
        return true
    }

    private func end(rendered: Bool) {
        guard let (frame, drawables, chosen) = current else { return }
        current = nil
        defer { frame.endSubmission() }

        guard let command = queue.makeCommandBuffer() else { return }
        for (index, drawable) in drawables.enumerated() {
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
                    pass.depthAttachment.texture = drawable.depthTextures[map.textureIndex]
                    pass.depthAttachment.slice = map.sliceIndex
                    pass.depthAttachment.loadAction = alreadyCleared ? .load : .clear
                    pass.depthAttachment.storeAction = .store
                    pass.depthAttachment.clearDepth = 0

                    guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { continue }
                    if rendered {
                        var slice = UInt32(eye)
                        encoder.setViewport(map.viewport)
                        encoder.setRenderPipelineState(pipeline)
                        encoder.setDepthStencilState(depthState)
                        encoder.setFragmentTexture(color, index: 0)
                        encoder.setFragmentTexture(depth, index: 1)
                        encoder.setFragmentBytes(&slice, length: MemoryLayout<UInt32>.size, index: 0)
                        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                    }
                    encoder.endEncoding()
                }
            }
            drawable.encodePresent(commandBuffer: command)
        }
        command.commit()
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
                              constant uint& eye [[buffer(0)]]) {
        constexpr sampler colorSampler(coord::normalized, address::clamp_to_edge, filter::linear);
        constexpr sampler depthSampler(coord::normalized, address::clamp_to_edge, filter::nearest);
        // VPX's RGBA8 tonemap output is encoded for a display. Undo that
        // encoding before writing to the compositor's sRGB attachment.
        half3 srgb = color.sample(colorSampler, v.uv, eye).rgb;
        half3 linear = select(srgb / 12.92h, pow((srgb + 0.055h) / 1.055h, half3(2.4h)), srgb > 0.04045h);
        return { half4(linear, 1), 1.0 - depth.sample(depthSampler, v.uv, eye) };
    }
    """
}
