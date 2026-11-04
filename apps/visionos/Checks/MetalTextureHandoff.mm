// license:GPLv3+

#import <Metal/Metal.h>
#include <bgfx/bgfx.h>
#include <array>
#include <cstdio>
#include <cstdlib>
#include <cstring>

static void require(bool condition, const char* description)
{
    if (!condition)
    {
        std::fprintf(stderr, "Metal handoff failed: %s\n", description);
        std::exit(1);
    }
}

int main()
{
    @autoreleasepool
    {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        id<MTLCommandQueue> queue = [device newCommandQueue];
        require(queue != nil, "Metal device and command queue");
        bgfx::renderFrame();
        bgfx::Init init;
        init.type = bgfx::RendererType::Metal;
        init.fallback = false;
        init.platformData.context = (__bridge void*)device;
        init.platformData.queue = (__bridge void*)queue;
        init.swapChain.width = 8;
        init.swapChain.height = 8;
        require(bgfx::init(init), "headless BGFX Metal");
        require(bgfx::getCaps()->supported & BGFX_CAPS_TEXTURE_EXTERNAL, "external texture capability");

        MTLTextureDescriptor* desc = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:8 height:8 mipmapped:NO];
        desc.storageMode = MTLStorageModePrivate;
        desc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        id<MTLTexture> eyes[] = { [device newTextureWithDescriptor:desc], [device newTextureWithDescriptor:desc] };
        bgfx::FrameBufferHandle targets[2];
        for (int i = 0; i < 2; ++i)
        {
            require(eyes[i] != nil, "app-owned eye texture");
            const auto texture = bgfx::createTexture2D(
                8, 8, false, 1, bgfx::TextureFormat::RGBA8, BGFX_TEXTURE_RT, nullptr,
                reinterpret_cast<uint64_t>((__bridge void*)eyes[i]));
            require(bgfx::isValid(texture), "import the app's eye texture into BGFX");
            targets[i] = bgfx::createFrameBuffer(1, &texture, true);
            require(bgfx::isValid(targets[i]), "BGFX eye framebuffer");
            bgfx::setViewFrameBuffer(i, targets[i]);
            bgfx::setViewRect(i, 0, 0, 8, 8);
        }

        constexpr std::array<uint32_t, 4> colors = { 0xff0000ff, 0x00ff00ff, 0x0000ffff, 0xffff00ff };
        id<MTLBuffer> result = [device newBufferWithLength:4 * 256 options:MTLResourceStorageModeShared];
        require(result != nil, "test readback buffer");
        id<MTLCommandBuffer> last = nil;
        for (int frame = 0; frame < 2; ++frame)
        {
            for (int eye = 0; eye < 2; ++eye)
            {
                bgfx::setViewClear(eye, BGFX_CLEAR_COLOR, colors[frame * 2 + eye]);
                bgfx::touch(eye);
            }
            bgfx::frame();
            last = [queue commandBuffer];
            id<MTLBlitCommandEncoder> copy = [last blitCommandEncoder];
            for (int eye = 0; eye < 2; ++eye)
            {
                [copy copyFromTexture:eyes[eye] sourceSlice:0 sourceLevel:0
                    sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(1, 1, 1)
                    toBuffer:result destinationOffset:(frame * 2 + eye) * 256
                    destinationBytesPerRow:256 destinationBytesPerImage:256];
            }
            [copy endEncoding];
            [last commit];
        }

        // Wait once at the end to validate the transfer. Rendering never reads back or waits between eyes.
        [last waitUntilCompleted];
        require(last.status == MTLCommandBufferStatusCompleted, "Metal copy finished");
        const auto* bytes = static_cast<const uint8_t*>(result.contents);
        for (int i = 0; i < 4; ++i)
        {
            const uint32_t c = colors[i];
            const uint8_t expected[] = { uint8_t(c >> 24), uint8_t(c >> 16), uint8_t(c >> 8), uint8_t(c) };
            if (std::memcmp(bytes + i * 256, expected, sizeof expected) != 0)
            {
                const auto* actual = bytes + i * 256;
                std::fprintf(stderr, "Frame %d eye %d: expected %08x; got %02x%02x%02x%02x\n",
                             i / 2, i % 2, c, actual[0], actual[1], actual[2], actual[3]);
                return 1;
            }
        }
        for (auto target : targets)
            bgfx::destroy(target);
        bgfx::shutdown();
        std::printf("Metal handoff passed: two distinct eyes over two frames on %s\n", device.name.UTF8String);
    }
}
