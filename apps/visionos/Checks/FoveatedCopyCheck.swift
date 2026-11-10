// license:GPLv3+

// Renders the player's compositor copy into a two-layer rasterization rate
// map on the Mac, maps it back to logical space and compares it with the
// uniform copy. Build it with CompositorShaders.swift. Pass a folder to save
// PNGs of each stage.

import CoreGraphics
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers

@main
enum FoveatedCopyCheck {
    static func main() throws {
        let eyeSize = 512
        let screenSize = 1024
        // Rates per column and row. Layer 1 moves its sharp zone to one side, so a
        // slice drawn with the wrong layer's map lands in the wrong place.
        let layerRates: [[Float]] = [
            [0.25, 0.5, 1, 1, 1, 1, 0.5, 0.25],
            [0.5, 1, 1, 1, 1, 0.5, 0.25, 0.25],
        ]

        func fail(_ message: String) -> Never {
            print("FAIL: \(message)")
            exit(1)
        }

        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { fail("no Metal device") }
        guard device.supportsRasterizationRateMap(layerCount: 2) else { fail("this GPU has no layered rate maps") }
        let outputFolder = CommandLine.arguments.count > 1 ? URL(fileURLWithPath: CommandLine.arguments[1]) : nil

        // VPX's picture: fine checks, a gradient and a different tint per eye.
        func eyePixels(_ eye: Int) -> [UInt8] {
            var pixels = [UInt8](repeating: 255, count: eyeSize * eyeSize * 4)
            for y in 0..<eyeSize {
                for x in 0..<eyeSize {
                    let check: UInt8 = ((x / 3) + (y / 3)) % 2 == 0 ? 230 : 25
                    let ramp = UInt8(x * 255 / (eyeSize - 1))
                    let index = (y * eyeSize + x) * 4
                    // BGRA
                    pixels[index + 0] = eye == 0 ? 40 : check
                    pixels[index + 1] = eye == 0 ? ramp : UInt8(y * 255 / (eyeSize - 1))
                    pixels[index + 2] = eye == 0 ? check : 40
                }
            }
            return pixels
        }

        func arrayTexture(_ format: MTLPixelFormat, _ width: Int, _ height: Int, _ usage: MTLTextureUsage) -> MTLTexture {
            let descriptor = MTLTextureDescriptor()
            descriptor.textureType = .type2DArray
            descriptor.pixelFormat = format
            descriptor.width = width
            descriptor.height = height
            descriptor.arrayLength = 2
            descriptor.usage = usage
            descriptor.storageMode = format == .depth32Float ? .private : .shared
            guard let texture = device.makeTexture(descriptor: descriptor) else { fail("texture") }
            return texture
        }

        let eyeColor = arrayTexture(.bgra8Unorm, eyeSize, eyeSize, [.shaderRead])
        for eye in 0..<2 {
            let pixels = eyePixels(eye)
            eyeColor.replace(region: MTLRegionMake2D(0, 0, eyeSize, eyeSize), mipmapLevel: 0, slice: eye,
                             withBytes: pixels, bytesPerRow: eyeSize * 4, bytesPerImage: pixels.count)
        }
        let eyeDepth = arrayTexture(.depth32Float, eyeSize, eyeSize, [.renderTarget, .shaderRead])

        // The rate map, as the compositor would hand it over.
        let mapDescriptor = MTLRasterizationRateMapDescriptor()
        mapDescriptor.screenSize = MTLSize(width: screenSize, height: screenSize, depth: 0)
        for (layer, rates) in layerRates.enumerated() {
            let layerDescriptor = MTLRasterizationRateLayerDescriptor(sampleCount: MTLSize(width: rates.count, height: rates.count, depth: 0))
            for (index, rate) in rates.enumerated() {
                layerDescriptor.horizontal[index] = rate
                layerDescriptor.vertical[index] = rate
            }
            mapDescriptor.setLayer(layerDescriptor, at: layer)
        }
        guard let map = device.makeRasterizationRateMap(descriptor: mapDescriptor) else { fail("rate map") }
        let physical = (0..<2).map { map.physicalSize(layer: $0) }
        let physicalWidth = physical.map(\.width).max()!
        let physicalHeight = physical.map(\.height).max()!
        let granularity = map.physicalGranularity
        print("Rate map granularity \(granularity.width) × \(granularity.height)")
        print("Rate map: logical \(screenSize) × \(screenSize), physical \(physical[0].width) × \(physical[0].height) and \(physical[1].width) × \(physical[1].height)")

        let library = try device.makeLibrary(source: CompositorShaders.source, options: nil)
        func pipeline(_ vertex: String, _ fragment: String, layered: Bool) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: vertex)
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            descriptor.depthAttachmentPixelFormat = .depth32Float
            if layered { descriptor.inputPrimitiveTopology = .triangle }
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }
        let uniformPipeline = try pipeline(CompositorShaders.fullScreen, CompositorShaders.copyEye, layered: false)
        let layeredPipeline = try pipeline(CompositorShaders.fullScreenLayered, CompositorShaders.copyLayeredEye, layered: true)
        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.isDepthWriteEnabled = true
        let depthState = device.makeDepthStencilState(descriptor: depthDescriptor)!

        let reference = arrayTexture(.bgra8Unorm, screenSize, screenSize, [.renderTarget, .shaderRead])
        let referenceDepth = arrayTexture(.depth32Float, screenSize, screenSize, [.renderTarget])
        let foveated = arrayTexture(.bgra8Unorm, physicalWidth, physicalHeight, [.renderTarget, .shaderRead])
        let foveatedDepth = arrayTexture(.depth32Float, physicalWidth, physicalHeight, [.renderTarget])
        let unwarped = arrayTexture(.bgra8Unorm, screenSize, screenSize, [.shaderWrite, .shaderRead])

        let unwarpLibrary = try device.makeLibrary(source: """
        #include <metal_stdlib>
        using namespace metal;
        kernel void unwarp(texture2d_array<float, access::sample> physical [[texture(0)]],
                           texture2d_array<float, access::write> logical [[texture(1)]],
                           constant rasterization_rate_map_data& data [[buffer(0)]],
                           uint3 id [[thread_position_in_grid]]) {
            rasterization_rate_map_decoder map(data);
            constexpr sampler linear(coord::normalized, address::clamp_to_edge, filter::linear);
            const float2 screen = float2(id.xy) + 0.5;
            const float2 texel = map.map_screen_to_physical_coordinates(screen, id.z);
            const float2 size = float2(physical.get_width(), physical.get_height());
            logical.write(physical.sample(linear, texel / size, id.z), id.xy, id.z);
        }
        """, options: nil)
        let unwarpPipeline = try device.makeComputePipelineState(function: unwarpLibrary.makeFunction(name: "unwarp")!)
        let mapData = device.makeBuffer(length: map.parameterDataSizeAndAlign.size, options: .storageModeShared)!
        map.copyParameterData(buffer: mapData, offset: 0)

        let command = queue.makeCommandBuffer()!
        // VPX's depth: anything nearer than its cleared 1.
        let depthPass = MTLRenderPassDescriptor()
        depthPass.depthAttachment.texture = eyeDepth
        depthPass.depthAttachment.loadAction = .clear
        depthPass.depthAttachment.storeAction = .store
        depthPass.depthAttachment.clearDepth = 0.5
        depthPass.renderTargetArrayLength = 2
        command.makeRenderCommandEncoder(descriptor: depthPass)!.endEncoding()

        var options = SIMD2<UInt32>(0, 0)
        for eye in 0..<2 {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = reference
            pass.colorAttachments[0].slice = eye
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.depthAttachment.texture = referenceDepth
            pass.depthAttachment.slice = eye
            pass.depthAttachment.loadAction = .clear
            pass.depthAttachment.clearDepth = 0
            let encoder = command.makeRenderCommandEncoder(descriptor: pass)!
            options.x = UInt32(eye)
            encoder.setViewport(MTLViewport(originX: 0, originY: 0, width: Double(screenSize), height: Double(screenSize), znear: 0, zfar: 1))
            encoder.setRenderPipelineState(uniformPipeline)
            encoder.setDepthStencilState(depthState)
            encoder.setFragmentTexture(eyeColor, index: 0)
            encoder.setFragmentTexture(eyeDepth, index: 1)
            encoder.setFragmentBytes(&options, length: MemoryLayout<SIMD2<UInt32>>.size, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }

        // The player's layered foveated pass.
        let slices: [UInt32] = [0, 1]
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = foveated
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.depthAttachment.texture = foveatedDepth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 0
        pass.renderTargetArrayLength = 2
        pass.rasterizationRateMap = map
        let encoder = command.makeRenderCommandEncoder(descriptor: pass)!
        let viewport = MTLViewport(originX: 0, originY: 0, width: Double(screenSize), height: Double(screenSize), znear: 0, zfar: 1)
        encoder.setViewports([viewport, viewport])
        encoder.setRenderPipelineState(layeredPipeline)
        encoder.setDepthStencilState(depthState)
        var sliceData = slices
        encoder.setVertexBytes(&sliceData, length: MemoryLayout<UInt32>.stride * 2, index: 0)
        options.x = 0
        encoder.setFragmentTexture(eyeColor, index: 0)
        encoder.setFragmentTexture(eyeDepth, index: 1)
        encoder.setFragmentBytes(&options, length: MemoryLayout<SIMD2<UInt32>>.size, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3, instanceCount: 2)
        encoder.endEncoding()

        let compute = command.makeComputeCommandEncoder()!
        compute.setComputePipelineState(unwarpPipeline)
        compute.setTexture(foveated, index: 0)
        compute.setTexture(unwarped, index: 1)
        compute.setBuffer(mapData, offset: 0, index: 0)
        compute.dispatchThreads(MTLSize(width: screenSize, height: screenSize, depth: 2),
                                threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        compute.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        if let error = command.error { fail("GPU: \(error)") }

        func read(_ texture: MTLTexture, _ slice: Int) -> [UInt8] {
            var pixels = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
            texture.getBytes(&pixels, bytesPerRow: texture.width * 4, bytesPerImage: pixels.count,
                             from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0, slice: slice)
            return pixels
        }

        func save(_ pixels: [UInt8], _ width: Int, _ height: Int, _ name: String) {
            guard let outputFolder else { return }
            let data = Data(pixels) as CFData
            let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            guard let provider = CGDataProvider(data: data),
                  let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info, provider: provider,
                                      decode: nil, shouldInterpolate: false, intent: .defaultIntent),
                  let destination = CGImageDestinationCreateWithURL(outputFolder.appendingPathComponent(name) as CFURL,
                                                                    UTType.png.identifier as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(destination, image, nil)
            CGImageDestinationFinalize(destination)
        }

        // Mean absolute error per rate-map zone, in 8-bit steps. Channel 1 is the
        // smooth ramp, which blurring can't change, so it shows placement alone.
        // The border skips the outermost physical pixel at the lowest rate,
        // which the GPU leaves unrendered when the physical size isn't a
        // multiple of the map's granularity.
        func zoneErrors(_ a: [UInt8], _ b: [UInt8], channels: [Int] = [0, 1, 2], border: Int = 0) -> [[Double]] {
            let zones = layerRates[0].count
            let zone = screenSize / zones
            return (0..<zones).map { zy in
                (0..<zones).map { zx in
                    var sum = 0
                    var count = 0
                    for y in max(zy * zone, border)..<min((zy + 1) * zone, screenSize - border) {
                        for x in max(zx * zone, border)..<min((zx + 1) * zone, screenSize - border) {
                            count += channels.count
                            let index = (y * screenSize + x) * 4
                            for channel in channels { sum += abs(Int(a[index + channel]) - Int(b[index + channel])) }
                        }
                    }
                    return Double(sum) / Double(count)
                }
            }
        }

        var failures = 0
        for eye in 0..<2 {
            let expected = read(reference, eye)
            let actual = read(unwarped, eye)
            save(expected, screenSize, screenSize, "eye\(eye)-uniform.png")
            save(actual, screenSize, screenSize, "eye\(eye)-foveated-unwarped.png")
            save(read(foveated, eye), physicalWidth, physicalHeight, "eye\(eye)-foveated-physical.png")
            let errors = zoneErrors(expected, actual)
            let placement = zoneErrors(expected, actual, channels: [1], border: 8)
            let rates = layerRates[eye]
            var sharpWorst = 0.0
            var softWorst = 0.0
            var placementWorst = 0.0
            for (zy, row) in errors.enumerated() {
                for (zx, error) in row.enumerated() {
                    if rates[zx] == 1 && rates[zy] == 1 { sharpWorst = max(sharpWorst, error) } else { softWorst = max(softWorst, error) }
                    placementWorst = max(placementWorst, placement[zy][zx])
                }
            }
            let crossed = zoneErrors(read(reference, 1 - eye), actual).joined().reduce(0, +) / Double(rates.count * rates.count)
            print(String(format: "Eye %d: full-rate zones worst %.2f, reduced-rate zones worst %.2f (detail lost), ramp worst %.2f, against the other eye %.2f",
                         eye, sharpWorst, softWorst, placementWorst, crossed))
            // Full rate should match the uniform copy. Reduced rate loses detail, but
            // the smooth ramp must stay in place everywhere.
            if sharpWorst > 2 { print("FAIL: eye \(eye) full-rate zones differ from the uniform copy"); failures += 1 }
            if placementWorst > 2 {
                for row in placement { print(row.map { String(format: "%5.2f", $0) }.joined(separator: " ")) }
            }
            if placementWorst > 2 { print("FAIL: eye \(eye) is warped or misplaced"); failures += 1 }
            if crossed < 40 { print("FAIL: eye \(eye) looks like the other eye"); failures += 1 }
        }
        if failures > 0 { exit(1) }
        print("PASS: the layered foveated copy matches the uniform copy in logical space for both eyes")
    }
}
