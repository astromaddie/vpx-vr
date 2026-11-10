// license:GPLv3+

/// Copies VPX's square eye pictures into the compositor drawable. The Mac check
/// in `Checks/FoveatedCopyCheck.swift` compiles the same source.
enum CompositorShaders {
    static let copyEye = "copyEye"
    static let copyLayeredEye = "copyLayeredEye"
    static let fullScreen = "fullScreen"
    static let fullScreenLayered = "fullScreenLayered"

    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct EyeVertex { float4 position [[position]]; float2 uv; };
    struct LayeredEyeVertex {
        float4 position [[position]];
        float2 uv;
        uint eye [[flat]];
        uint slice [[render_target_array_index]];
        uint viewport [[viewport_array_index]];
    };
    struct EyePixel { half4 color [[color(0)]]; float depth [[depth(any)]]; };

    // The UVs come from clip space, so they stay in the logical view even when
    // a rasterization rate map packs the periphery into fewer physical pixels.
    static float2 screenUV(uint id, thread float4& position) {
        float2 uv = float2((id << 1) & 2, id & 2);
        position = float4(uv.x * 2 - 1, 1 - uv.y * 2, 0, 1);
        return uv;
    }

    vertex EyeVertex fullScreen(uint id [[vertex_id]]) {
        EyeVertex out;
        out.uv = screenUV(id, out.position);
        return out;
    }

    // One instance per view. The drawable's views can sit in any slice.
    vertex LayeredEyeVertex fullScreenLayered(uint id [[vertex_id]], uint view [[instance_id]],
                                              constant uint* slices [[buffer(0)]]) {
        LayeredEyeVertex out;
        out.uv = screenUV(id, out.position);
        out.eye = view;
        out.slice = slices[view];
        out.viewport = view;
        return out;
    }

    static EyePixel shade(float2 uv, uint eye, bool mixedReality,
                          texture2d_array<half> color, depth2d_array<float> depth) {
        constexpr sampler colorSampler(coord::normalized, address::clamp_to_edge, filter::linear);
        constexpr sampler depthSampler(coord::normalized, address::clamp_to_edge, filter::nearest);
        // Derivatives are per physical pixel. Where one pixel covers more than
        // a VPX texel (the foveated periphery, or a picture larger than the
        // drawable) average four taps across its footprint so the extra
        // detail doesn't shimmer. Elsewhere this is the old single tap.
        const float2 dx = dfdx(uv);
        const float2 dy = dfdy(uv);
        const float2 size = float2(color.get_width(), color.get_height());
        const float footprint = max(length(dx * size), length(dy * size));
        const float reverseDepth = 1.0 - depth.sample(depthSampler, uv, eye);
        // VPX clears its conventional depth to 1. Keep the passthrough visible
        // there and submit opaque premultiplied color wherever VPX drew geometry.
        if (mixedReality && reverseDepth <= 0.0)
            return { half4(0), 0.0 };
        half3 linear;
        if (footprint <= 1.0) {
            linear = color.sample(colorSampler, uv, eye).rgb;
        } else {
            linear = (color.sample(colorSampler, uv + 0.125 * dx + 0.375 * dy, eye).rgb
                    + color.sample(colorSampler, uv - 0.125 * dx - 0.375 * dy, eye).rgb
                    + color.sample(colorSampler, uv + 0.375 * dx - 0.125 * dy, eye).rgb
                    + color.sample(colorSampler, uv - 0.375 * dx + 0.125 * dy, eye).rgb) * 0.25h;
        }
        return { half4(linear, 1), reverseDepth };
    }

    fragment EyePixel copyEye(EyeVertex v [[stage_in]],
                              texture2d_array<half> color [[texture(0)]],
                              depth2d_array<float> depth [[texture(1)]],
                              constant uint2& options [[buffer(0)]]) {
        return shade(v.uv, options.x, options.y != 0, color, depth);
    }

    fragment EyePixel copyLayeredEye(LayeredEyeVertex v [[stage_in]],
                                     texture2d_array<half> color [[texture(0)]],
                                     depth2d_array<float> depth [[texture(1)]],
                                     constant uint2& options [[buffer(0)]]) {
        return shade(v.uv, v.eye, options.y != 0, color, depth);
    }
    """
}
