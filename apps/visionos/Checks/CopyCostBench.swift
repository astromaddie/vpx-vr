// license:GPLv3+

import Foundation
import Metal

/// Times the compositor's layered copy pass on the Mac's GPU at the M2's sizes: a 6261 × 5023
/// logical view per eye through a two-layer rate map of about 2432 × 2368 physical pixels,
/// from VPX eye pictures of a given size. The copy runs alone on its queue and each pass is
/// timed with stage boundary counters. The Mac's GPU isn't the Vision Pro's, so treat the
/// numbers as relative: one tap against four, and one eye size against another.
@main
struct CopyCostBench {
    static func main() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { fatalError("Metal") }
        let screen = MTLSize(width: 6261, height: 5023, depth: 0)
        // Zone rates chosen so the physical size lands near the M2's 2432 × 2368.
        let horizontal: [Float] = [0.2, 0.3, 1, 0.3, 0.2]
        let vertical: [Float] = [0.25, 0.4, 1, 0.4, 0.25]
        let mapDescriptor = MTLRasterizationRateMapDescriptor()
        mapDescriptor.screenSize = screen
        for layer in 0..<2 {
            let rates = MTLRasterizationRateLayerDescriptor(sampleCount: MTLSize(width: horizontal.count, height: vertical.count, depth: 0))
            for (i, r) in horizontal.enumerated() { rates.horizontal[i] = r }
            for (i, r) in vertical.enumerated() { rates.vertical[i] = r }
            mapDescriptor.setLayer(rates, at: layer)
        }
        guard let map = device.makeRasterizationRateMap(descriptor: mapDescriptor) else { fatalError("rate map") }
        let physical = map.physicalSize(layer: 0)
        print("\(device.name): logical \(screen.width) × \(screen.height), physical \(physical.width) × \(physical.height) per eye")

        func texture(_ format: MTLPixelFormat, _ width: Int, _ height: Int, _ usage: MTLTextureUsage) -> MTLTexture {
            let descriptor = MTLTextureDescriptor()
            descriptor.textureType = .type2DArray
            descriptor.pixelFormat = format
            descriptor.width = width
            descriptor.height = height
            descriptor.arrayLength = 2
            descriptor.usage = usage
            descriptor.storageMode = .private
            return device.makeTexture(descriptor: descriptor)!
        }
        let target = texture(.rgba16Float, physical.width, physical.height, [.renderTarget])
        let targetDepth = texture(.depth32Float, physical.width, physical.height, [.renderTarget])

        guard device.supportsCounterSampling(.atStageBoundary),
              let set = device.counterSets?.first(where: { $0.name == MTLCommonCounterSet.timestamp.rawValue }) else {
            fatalError("no stage boundary timestamps on this GPU")
        }
        let runs = 120
        let counterDescriptor = MTLCounterSampleBufferDescriptor()
        counterDescriptor.counterSet = set
        counterDescriptor.storageMode = .shared
        counterDescriptor.sampleCount = runs * 2
        let counters = try device.makeCounterSampleBuffer(descriptor: counterDescriptor)

        let oneTap = CompositorShaders.source.replacingOccurrences(of: "if (footprint <= 1.0) {", with: "if (true) {")
        for (label, source) in [("4-tap periphery", CompositorShaders.source), ("1 tap", oneTap)] {
            let library = try device.makeLibrary(source: source, options: nil)
            let pass = MTLRenderPipelineDescriptor()
            pass.vertexFunction = library.makeFunction(name: CompositorShaders.fullScreenLayered)
            pass.fragmentFunction = library.makeFunction(name: CompositorShaders.copyLayeredEye)
            pass.inputPrimitiveTopology = .triangle
            pass.colorAttachments[0].pixelFormat = .rgba16Float
            pass.depthAttachmentPixelFormat = .depth32Float
            let pipeline = try device.makeRenderPipelineState(descriptor: pass)
            let depthDescriptor = MTLDepthStencilDescriptor()
            depthDescriptor.isDepthWriteEnabled = true
            let depthState = device.makeDepthStencilState(descriptor: depthDescriptor)!

            for (eyeWidth, eyeHeight) in [(2816, 2816), (3152, 2520), (3432, 2744)] {
                let color = texture(.bgra8Unorm, eyeWidth, eyeHeight, [.shaderRead, .renderTarget])
                let depth = texture(.depth32Float, eyeWidth, eyeHeight, [.shaderRead, .renderTarget])
                // Fill the pictures so the copy reads real memory.
                let fill = queue.makeCommandBuffer()!
                let clear = MTLRenderPassDescriptor()
                clear.colorAttachments[0].texture = color
                clear.colorAttachments[0].loadAction = .clear
                clear.colorAttachments[0].clearColor = MTLClearColorMake(0.3, 0.5, 0.7, 1)
                clear.colorAttachments[0].storeAction = .store
                clear.depthAttachment.texture = depth
                clear.depthAttachment.loadAction = .clear
                clear.depthAttachment.clearDepth = 0.5
                clear.depthAttachment.storeAction = .store
                clear.renderTargetArrayLength = 2
                fill.makeRenderCommandEncoder(descriptor: clear)!.endEncoding()
                fill.commit()

                var ticks: [Double] = []
                var bufferSeconds: [Double] = []
                let (_, gpuStart) = device.sampleTimestamps()
                let clockStart = DispatchTime.now().uptimeNanoseconds
                for run in 0..<runs {
                    let command = queue.makeCommandBuffer()!
                    let pass = MTLRenderPassDescriptor()
                    pass.colorAttachments[0].texture = target
                    pass.colorAttachments[0].loadAction = .clear
                    pass.colorAttachments[0].storeAction = .store
                    pass.depthAttachment.texture = targetDepth
                    pass.depthAttachment.loadAction = .clear
                    pass.depthAttachment.storeAction = .store
                    pass.depthAttachment.clearDepth = 0
                    pass.renderTargetArrayLength = 2
                    pass.rasterizationRateMap = map
                    let attachment = pass.sampleBufferAttachments[0]!
                    attachment.sampleBuffer = counters
                    attachment.startOfVertexSampleIndex = run * 2
                    attachment.endOfVertexSampleIndex = MTLCounterDontSample
                    attachment.startOfFragmentSampleIndex = MTLCounterDontSample
                    attachment.endOfFragmentSampleIndex = run * 2 + 1
                    let encoder = command.makeRenderCommandEncoder(descriptor: pass)!
                    let viewport = MTLViewport(originX: 0, originY: 0, width: Double(screen.width), height: Double(screen.height), znear: 0, zfar: 1)
                    encoder.setViewports([viewport, viewport])
                    encoder.setRenderPipelineState(pipeline)
                    encoder.setDepthStencilState(depthState)
                    var slices: [UInt32] = [0, 1]
                    encoder.setVertexBytes(&slices, length: 8, index: 0)
                    var options = SIMD2<UInt32>(0, 1)
                    encoder.setFragmentTexture(color, index: 0)
                    encoder.setFragmentTexture(depth, index: 1)
                    encoder.setFragmentBytes(&options, length: 8, index: 0)
                    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3, instanceCount: 2)
                    encoder.endEncoding()
                    command.commit()
                    command.waitUntilCompleted()
                    bufferSeconds.append(command.gpuEndTime - command.gpuStartTime)
                }
                let (_, gpuEnd) = device.sampleTimestamps()
                let msPerTick = Double(DispatchTime.now().uptimeNanoseconds - clockStart) / Double(gpuEnd - gpuStart) / 1e6
                let data = try counters.resolveCounterRange(0..<runs * 2)!
                data.withUnsafeBytes { raw in
                    let stamps = raw.bindMemory(to: MTLCounterResultTimestamp.self)
                    for run in 10..<runs where stamps[run * 2 + 1].timestamp > stamps[run * 2].timestamp {
                        ticks.append(Double(stamps[run * 2 + 1].timestamp - stamps[run * 2].timestamp))
                    }
                }
                ticks.sort()
                bufferSeconds = Array(bufferSeconds.dropFirst(10)).sorted()
                let median = ticks.isEmpty ? 0 : ticks[ticks.count / 2] * msPerTick
                print(String(format: "%@, eyes %d × %d: pass %.2f ms median, command buffer %.2f ms median",
                             label, eyeWidth, eyeHeight, median, bufferSeconds[bufferSeconds.count / 2] * 1000))
            }
        }
    }
}
