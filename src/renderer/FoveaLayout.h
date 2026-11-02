// license:GPLv3+

#pragma once

#include <algorithm>
#include <cmath>

// Application side foveation layout (pure math, no renderer dependency so that it can be unit tested).
//
// Each physical eye is rendered as 3 pictures of the same raster size: 'coarse' covers the whole eye frustum, 'middle'
// and 'sharp' are asymmetric sub-frusta (crops) of the eye frustum, sharing its view matrix, near and far planes. The 6
// pictures are the layers of the scene render targets, rendered with one instanced submission per pass. They are composed
// back into the 2 full resolution eye images, in linear HDR, before bloom and tonemapping.
namespace VPX::Fovea
{

inline constexpr int EyeCount = 2;
inline constexpr int TierCount = 3;
inline constexpr int ViewCount = EyeCount * TierCount;

// Common raster size of the 6 internal pictures
inline constexpr int PictureSize = 576;

// Outer edge of a window's round support, in window NDC (1 is the half side of the square window). Nothing of a window
// contributes at or beyond this radius, which leaves a few texels of margin to the window's square edge for filtering.
inline constexpr float SupportRadius = 0.98f;

// Filter reach used by the composer around the support edge, in texels (bilinear footprint along the diagonal)
inline constexpr float SupportGuardTexels = 1.4143f;

enum Tier : int
{
   Coarse = 0,
   Middle = 1,
   Sharp = 2,
};

// Internal view (layer) index. Views 0/1 are the coarse left/right eyes: they use the eye frustum as is, so everything
// that refers to 'view 0' (picking, anti-stretch,...) still gets the full eye view.
constexpr int ViewIndex(const int eye, const int tier) { return tier * EyeCount + eye; }
constexpr int EyeOfView(const int view) { return view % EyeCount; }
constexpr int TierOfView(const int view) { return view / EyeCount; }

// Frustum bounds, as tangents of the half angles (x pointing right, y pointing up)
struct TanBounds
{
   float left, right, down, up;
};

inline TanBounds EyeTanBounds(const float angleLeft, const float angleRight, const float angleDown, const float angleUp)
{
   return { tanf(angleLeft), tanf(angleRight), tanf(angleDown), tanf(angleUp) };
}

struct Window
{
   TanBounds tan; // Window frustum
   float rect[4]; // Window placement in the full eye image: (u0, v0, u1, v1) with u pointing right and v pointing up
};

// Feather band width is expressed as a fraction of the window radius (window NDC), ending at the support radius
inline constexpr float MinFeather = 0.05f;
inline constexpr float MaxFeather = 0.9f;

inline float ClampFeather(const float feather) { return std::clamp(feather, MinFeather, MaxFeather); }

// Window contribution at window NDC radius r: 1 inside the core, quintic (smootherstep) falloff across the feather band,
// 0 at and beyond the support radius
inline float FeatherWeight(const float r, const float feather)
{
   if (r >= SupportRadius)
      return 0.f;
   const float width = ClampFeather(feather);
   const float t = std::clamp((r - (SupportRadius - width)) / width, 0.f, 1.f);
   return 1.f - t * t * t * (t * (t * 6.f - 15.f) + 10.f);
}

// Half size, in tangent units, of a window whose feather middle (where it contributes half) is 'sizeDeg' away from its
// centre when it is centred on the optical axis. The size is kept constant in tangent units when the window moves.
inline float WindowHalfTangent(const float sizeDeg, const float feather)
{
   const float mid = SupportRadius - 0.5f * ClampFeather(feather);
   const float size = std::clamp(sizeDeg, 1.f, 80.f) * 0.01745329252f;
   return tanf(size) / mid;
}

// Builds a window of half size 'halfTan' (tangent units) around the requested centre (tangents, (0,0) is the optical
// axis), kept inside the eye frustum and snapped to its own raster grid so that a still scene stays still when the
// requested centre moves by less than a window texel.
inline Window ComputeWindow(const TanBounds& eye, float cx, float cy, const float halfTan, const int raster)
{
   const float spanX = eye.right - eye.left, spanY = eye.up - eye.down;
   const float hx = std::min(halfTan, 0.5f * spanX), hy = std::min(halfTan, 0.5f * spanY);
   const float minX = eye.left + hx, maxX = eye.right - hx, minY = eye.down + hy, maxY = eye.up - hy;
   cx = std::clamp(cx, minX, maxX);
   cy = std::clamp(cy, minY, maxY);
   const float px = 2.f * hx / static_cast<float>(raster), py = 2.f * hy / static_cast<float>(raster);
   cx = std::clamp(minX + std::round((cx - minX) / px) * px, minX, maxX);
   cy = std::clamp(minY + std::round((cy - minY) / py) * py, minY, maxY);
   Window w;
   w.tan = { cx - hx, cx + hx, cy - hy, cy + hy };
   w.rect[0] = (w.tan.left - eye.left) / spanX;
   w.rect[1] = (w.tan.down - eye.down) / spanY;
   w.rect[2] = (w.tan.right - eye.left) / spanX;
   w.rect[3] = (w.tan.up - eye.down) / spanY;
   return w;
}

// Maps a position in the full eye image (u right, v up, 0..1) to the window image (0..1 inside the window)
inline void EyeToWindow(const Window& w, const float u, const float v, float& wu, float& wv)
{
   wu = (u - w.rect[0]) / (w.rect[2] - w.rect[0]);
   wv = (v - w.rect[1]) / (w.rect[3] - w.rect[1]);
}

// Fraction of the eye frustum width covered by a window
inline float WindowSpanFraction(const TanBounds& eye, const Window& w) { return (w.tan.right - w.tan.left) / (eye.right - eye.left); }

// Step scale to apply to a screen space kernel defined in texels of a buffer covering the full eye at 'eyePixels' wide,
// so that it covers the same part of the eye when applied to a picture of 'raster' texels covering 'spanFraction' of the
// eye width (1 for the coarse picture).
inline float KernelStepScale(const int raster, const int eyePixels, const float spanFraction)
{
   return static_cast<float>(raster) / (static_cast<float>(eyePixels) * spanFraction);
}

} // namespace VPX::Fovea
