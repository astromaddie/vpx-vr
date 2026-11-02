// license:GPLv3+

#include "renderer/FoveaLayout.h"

#include "doctest.h"

using namespace VPX::Fovea;

namespace
{
// Steam Frame like asymmetric eye frustum (radians)
const TanBounds leftEye = EyeTanBounds(-1.028f, 0.885f, -1.048f, 0.864f);
}

TEST_CASE("Foveation view indices keep the coarse eyes first and map back to eye and tier")
{
   CHECK(ViewCount == 6);
   CHECK(ViewIndex(0, Coarse) == 0);
   CHECK(ViewIndex(1, Coarse) == 1);
   CHECK(ViewIndex(0, Middle) == 2);
   CHECK(ViewIndex(1, Middle) == 3);
   CHECK(ViewIndex(0, Sharp) == 4);
   CHECK(ViewIndex(1, Sharp) == 5);
   for (int view = 0; view < ViewCount; view++)
   {
      CHECK(ViewIndex(EyeOfView(view), TierOfView(view)) == view);
      // Mirroring swaps the physical eye within the same tier
      CHECK(TierOfView(view ^ 1) == TierOfView(view));
      CHECK(EyeOfView(view ^ 1) == 1 - EyeOfView(view));
   }
}

TEST_CASE("Feather weight is opaque in the core, smooth across the band and zero at the support edge")
{
   constexpr float feather = 0.43f;
   CHECK(FeatherWeight(0.f, feather) == 1.f);
   CHECK(FeatherWeight(SupportRadius - feather, feather) == 1.f);
   CHECK(FeatherWeight(SupportRadius - 0.5f * feather, feather) == doctest::Approx(0.5f));
   CHECK(FeatherWeight(SupportRadius, feather) == 0.f);
   CHECK(FeatherWeight(1.2f, feather) == 0.f);
   // Monotonic, with flat ends (no visible edge at either side of the band)
   float previous = 1.f;
   for (int i = 0; i <= 100; i++)
   {
      const float r = (SupportRadius - feather) + feather * static_cast<float>(i) / 100.f;
      const float w = FeatherWeight(r, feather);
      CHECK(w <= previous + 1e-6f);
      previous = w;
   }
   CHECK(1.f - FeatherWeight(SupportRadius - feather + 0.01f * feather, feather) < 1e-4f);
   CHECK(FeatherWeight(SupportRadius - 0.01f * feather, feather) < 1e-4f);
}

TEST_CASE("Window size puts the feather middle at the requested angle")
{
   constexpr float feather = 0.43f;
   const float h = WindowHalfTangent(16.f, feather);
   const float mid = SupportRadius - 0.5f * feather;
   CHECK(atanf(h * mid) * 57.2957795f == doctest::Approx(16.f).epsilon(1e-4));
   // Defaults land close to Stargate's densities: about 1 for sharp (512 px of a 2160 px eye at 1.0) and 0.4 for middle
   const Window sharp = ComputeWindow(leftEye, 0.f, 0.f, h, PictureSize);
   const float sharpDensity = PictureSize / (2160.f * WindowSpanFraction(leftEye, sharp));
   CHECK(sharpDensity > 0.9f);
   CHECK(sharpDensity < 1.15f);
   const Window middle = ComputeWindow(leftEye, 0.f, 0.f, WindowHalfTangent(35.f, feather), PictureSize);
   const float middleDensity = PictureSize / (2160.f * WindowSpanFraction(leftEye, middle));
   CHECK(middleDensity > 0.35f);
   CHECK(middleDensity < 0.5f);
}

TEST_CASE("Optical axis window is centred on the axis, inside the eye, and its rect matches its frustum")
{
   const float h = WindowHalfTangent(16.f, 0.43f);
   const Window w = ComputeWindow(leftEye, 0.f, 0.f, h, PictureSize);
   // Snapping moves the centre by at most half a window texel
   const float texel = 2.f * h / PictureSize;
   CHECK(fabsf(0.5f * (w.tan.left + w.tan.right)) <= 0.5f * texel + 1e-6f);
   CHECK(fabsf(0.5f * (w.tan.down + w.tan.up)) <= 0.5f * texel + 1e-6f);
   CHECK(w.tan.right - w.tan.left == doctest::Approx(2.f * h));
   CHECK(w.tan.left >= leftEye.left);
   CHECK(w.tan.right <= leftEye.right);
   CHECK(w.rect[0] > 0.f);
   CHECK(w.rect[2] < 1.f);
   // Optical axis is not the image centre for an asymmetric eye frustum
   CHECK(0.5f * (w.rect[0] + w.rect[2]) == doctest::Approx(-leftEye.left / (leftEye.right - leftEye.left)).epsilon(0.01));
}

TEST_CASE("A direction maps to the same place through the eye frustum and through the window crop")
{
   const Window w = ComputeWindow(leftEye, 0.1f, -0.05f, WindowHalfTangent(16.f, 0.43f), PictureSize);
   for (const float tx : { -0.2f, -0.05f, 0.f, 0.13f, 0.31f })
      for (const float ty : { -0.25f, 0.f, 0.07f, 0.2f })
      {
         // Projected through the full eye frustum, as composed
         const float u = (tx - leftEye.left) / (leftEye.right - leftEye.left);
         const float v = (ty - leftEye.down) / (leftEye.up - leftEye.down);
         float wu, wv;
         EyeToWindow(w, u, v, wu, wv);
         // Projected through the window frustum, as rendered
         const float ru = (tx - w.tan.left) / (w.tan.right - w.tan.left);
         const float rv = (ty - w.tan.down) / (w.tan.up - w.tan.down);
         CHECK(wu == doctest::Approx(ru).epsilon(1e-4));
         CHECK(wv == doctest::Approx(rv).epsilon(1e-4));
      }
}

TEST_CASE("Windows are clamped inside the eye and never larger than it")
{
   const Window corner = ComputeWindow(leftEye, -5.f, 5.f, WindowHalfTangent(16.f, 0.43f), PictureSize);
   CHECK(corner.tan.left >= leftEye.left - 1e-6f);
   CHECK(corner.tan.up <= leftEye.up + 1e-6f);
   CHECK(corner.rect[0] >= -1e-6f);
   CHECK(corner.rect[3] <= 1.f + 1e-6f);
   const Window huge = ComputeWindow(leftEye, 0.f, 0.f, 100.f, PictureSize);
   CHECK(huge.tan.left == doctest::Approx(leftEye.left));
   CHECK(huge.tan.right == doctest::Approx(leftEye.right));
   CHECK(huge.tan.down == doctest::Approx(leftEye.down));
   CHECK(huge.tan.up == doctest::Approx(leftEye.up));
}

TEST_CASE("Kernel step scale keeps the same footprint in the eye")
{
   // A picture covering the full eye at a quarter of its width needs quarter steps, a crop of a quarter of the eye at the same raster needs full steps
   CHECK(KernelStepScale(540, 2160, 1.f) == doctest::Approx(0.25f));
   CHECK(KernelStepScale(540, 2160, 0.25f) == doctest::Approx(1.f));
   CHECK(KernelStepScale(2160, 2160, 1.f) == doctest::Approx(1.f));
}
