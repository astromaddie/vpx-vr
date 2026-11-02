// license:GPLv3+

#include "math/Frustum.h"

#include "doctest.h"

#include <cmath>
#include <random>

using namespace VPX::Culling;

namespace
{

// Row vector matrices, as in VPX: p' = [p 1] * M
struct M4
{
   float m[4][4] {};

   static M4 Identity()
   {
      M4 r;
      for (int i = 0; i < 4; i++)
         r.m[i][i] = 1.f;
      return r;
   }

   static M4 Translate(float x, float y, float z)
   {
      M4 r = Identity();
      r.m[3][0] = x;
      r.m[3][1] = y;
      r.m[3][2] = z;
      return r;
   }

   static M4 Scale(float x, float y, float z)
   {
      M4 r = Identity();
      r.m[0][0] = x;
      r.m[1][1] = y;
      r.m[2][2] = z;
      return r;
   }

   static M4 RotateZ(float rad)
   {
      M4 r = Identity();
      r.m[0][0] = cosf(rad);
      r.m[0][1] = sinf(rad);
      r.m[1][0] = -sinf(rad);
      r.m[1][1] = cosf(rad);
      return r;
   }

   static M4 RotateY(float rad)
   {
      M4 r = Identity();
      r.m[0][0] = cosf(rad);
      r.m[0][2] = -sinf(rad);
      r.m[2][0] = sinf(rad);
      r.m[2][2] = cosf(rad);
      return r;
   }

   static M4 RotateX(float rad)
   {
      M4 r = Identity();
      r.m[1][1] = cosf(rad);
      r.m[1][2] = sinf(rad);
      r.m[2][1] = -sinf(rad);
      r.m[2][2] = cosf(rad);
      return r;
   }

   // Same formula as Matrix3D::SetPerspectiveOffCenterRH (depth 0..w, looking down -z)
   static M4 PerspectiveRH(float l, float r, float b, float t, float zn, float zf)
   {
      M4 p;
      p.m[0][0] = 2.f * zn / (r - l);
      p.m[1][1] = 2.f * zn / (t - b);
      p.m[2][0] = (r + l) / (r - l);
      p.m[2][1] = (t + b) / (t - b);
      p.m[2][2] = zf / (zn - zf);
      p.m[2][3] = -1.f;
      p.m[3][2] = zn * p.m[2][2];
      return p;
   }

   // Same formula as the infinite far plane branch of Matrix3D::SetPerspectiveFovRH
   static M4 PerspectiveInfiniteRH(float l, float r, float b, float t, float zn)
   {
      M4 p;
      p.m[0][0] = 2.f * zn / (r - l);
      p.m[1][1] = 2.f * zn / (t - b);
      p.m[2][0] = (r + l) / (r - l);
      p.m[2][1] = (t + b) / (t - b);
      p.m[2][2] = -1.f;
      p.m[2][3] = -1.f;
      p.m[3][2] = -zn;
      return p;
   }

   // Reflection through the plane dot(n, p) = d (n normalized), as Matrix3D::MatrixPlaneReflection
   static M4 PlaneReflection(float nx, float ny, float nz, float d)
   {
      M4 r = Identity();
      const float n[3] = { nx, ny, nz };
      for (int i = 0; i < 3; i++)
      {
         for (int j = 0; j < 3; j++)
            r.m[i][j] = (i == j ? 1.f : 0.f) - 2.f * n[i] * n[j];
         r.m[3][i] = 2.f * d * n[i];
      }
      return r;
   }

   M4 operator*(const M4& o) const
   {
      M4 r;
      for (int i = 0; i < 4; i++)
         for (int j = 0; j < 4; j++)
            for (int k = 0; k < 4; k++)
               r.m[i][j] += m[i][k] * o.m[k][j];
      return r;
   }

   void Transform(const float in[3], float out[4]) const
   {
      for (int j = 0; j < 4; j++)
         out[j] = in[0] * m[0][j] + in[1] * m[1][j] + in[2] * m[2][j] + m[3][j];
   }
};

Aabb Box(float x0, float y0, float z0, float x1, float y1, float z1)
{
   Aabb b;
   b.Extend(x0, y0, z0);
   b.Extend(x1, y1, z1);
   return b;
}

// Camera looking down -z from the origin, 90 degrees symmetric FOV, near 1, far 100
M4 BasicCamera() { return M4::PerspectiveRH(-1.f, 1.f, -1.f, 1.f, 1.f, 100.f); }

// Brute force: does any sampled point of the box land strictly inside the side planes (and optionally the far plane)?
bool AnySampleInside(const M4& clip, const Aabb& box, bool testFar)
{
   constexpr int N = 6;
   for (int i = 0; i <= N; i++)
      for (int j = 0; j <= N; j++)
         for (int k = 0; k <= N; k++)
         {
            const float p[3] = { box.min[0] + (box.max[0] - box.min[0]) * (float)i / N, box.min[1] + (box.max[1] - box.min[1]) * (float)j / N,
               box.min[2] + (box.max[2] - box.min[2]) * (float)k / N };
            float c[4];
            clip.Transform(p, c);
            if (c[3] > 1e-3f && fabsf(c[0]) < c[3] && fabsf(c[1]) < c[3] && (!testFar || c[2] < c[3]))
               return true;
         }
   return false;
}

}

TEST_CASE("Frustum: boxes against each side of a perspective camera")
{
   const Frustum f = FrustumFromClipMatrix(BasicCamera().m);
   REQUIRE(f.valid);
   CHECK(f.count == 5);

   CHECK(Intersects(f, Box(-1, -1, -11, 1, 1, -9), 0.f)); // In front
   CHECK_FALSE(Intersects(f, Box(-1, -1, 9, 1, 1, 11), 0.f)); // Behind the eye
   CHECK_FALSE(Intersects(f, Box(-30, -1, -11, -20, 1, -9), 0.f)); // Left
   CHECK_FALSE(Intersects(f, Box(20, -1, -11, 30, 1, -9), 0.f)); // Right
   CHECK_FALSE(Intersects(f, Box(-1, -30, -11, 1, -20, -9), 0.f)); // Below
   CHECK_FALSE(Intersects(f, Box(-1, 20, -11, 1, 30, -9), 0.f)); // Above

   // Touching the right plane (x = -z) at z = -10 stays visible
   CHECK(Intersects(f, Box(10, -1, -10, 12, 1, -10), 0.f));
   // Slightly outside is culled without margin, kept with a margin
   CHECK_FALSE(Intersects(f, Box(10.5f, -1, -10, 12, 1, -10), 0.f));
   CHECK(Intersects(f, Box(10.5f, -1, -10, 12, 1, -10), 1.f));

   // Crossing the eye plane (part behind, part in front) and the near plane
   CHECK(Intersects(f, Box(-0.5f, -0.5f, -5, 0.5f, 0.5f, 5), 0.f));
   CHECK(Intersects(f, Box(-0.1f, -0.1f, -1.5f, 0.1f, 0.1f, -0.5f), 0.f));

   // A box enclosing the whole frustum and the eye
   CHECK(Intersects(f, Box(-1000, -1000, -1000, 1000, 1000, 1000), 0.f));

   // No corner inside: a long thin bar crossing the view from left to right
   CHECK(Intersects(f, Box(-100, -0.1f, -10.1f, 100, 0.1f, -9.9f), 0.f));

   // Zero thickness quad facing the camera, and an edge on one
   CHECK(Intersects(f, Box(-1, -1, -10, 1, 1, -10), 0.f));
   CHECK(Intersects(f, Box(-1, 0, -20, 1, 0, -10), 0.f));
   CHECK_FALSE(Intersects(f, Box(-1, 0, 10, 1, 0, 20), 0.f));
}

TEST_CASE("Frustum: far plane is optional and degenerate planes never reject")
{
   const Aabb beyondFar = Box(-1, -1, -300, 1, 1, -200);
   CHECK(Intersects(FrustumFromClipMatrix(BasicCamera().m), beyondFar, 0.f));
   CHECK_FALSE(Intersects(FrustumFromClipMatrix(BasicCamera().m, true), beyondFar, 0.f));
   CHECK(Intersects(FrustumFromClipMatrix(BasicCamera().m, true), Box(-1, -1, -99, 1, 1, -50), 0.f));

   // Infinite far plane: w - z is constant, the far plane is dropped instead of rejecting everything
   const Frustum inf = FrustumFromClipMatrix(M4::PerspectiveInfiniteRH(-1.f, 1.f, -1.f, 1.f, 1.f).m, true);
   CHECK(inf.valid);
   CHECK(inf.count == 5);
   CHECK(Intersects(inf, Box(-1, -1, -1e6f, 1, 1, -1e5f), 0.f));
   CHECK_FALSE(Intersects(inf, Box(-1, -1, 10, 1, 1, 20), 0.f));
}

TEST_CASE("Frustum: invalid inputs fail open")
{
   const Frustum f = FrustumFromClipMatrix(BasicCamera().m);
   CHECK(Intersects(f, Aabb {}, 0.f)); // Empty box
   Aabb nanBox = Box(-1, -1, 9, 1, 1, 11);
   nanBox.max[1] = NAN;
   CHECK(Intersects(f, nanBox, 0.f));
   Aabb infBox = Box(-1, -1, 9, 1, 1, 11);
   infBox.max[0] = INFINITY;
   CHECK(Intersects(f, infBox, 0.f));

   M4 bad = BasicCamera();
   bad.m[2][1] = NAN;
   const Frustum badFrustum = FrustumFromClipMatrix(bad.m);
   CHECK_FALSE(badFrustum.valid);
   CHECK(Intersects(badFrustum, Box(-1, -1, 9, 1, 1, 11), 0.f));
   CHECK(Intersects(Frustum {}, Box(-1, -1, 9, 1, 1, 11), 0.f));

   // All zero matrix: every plane is degenerate, nothing is rejected
   const M4 zero;
   CHECK(Intersects(FrustumFromClipMatrix(zero.m, true), Box(-1, -1, 9, 1, 1, 11), 0.f));

   // Projective object matrices are not supported by the affine box transform
   M4 projective = M4::Identity();
   projective.m[2][3] = -1.f;
   CHECK_FALSE(TransformAabb(Box(0, 0, 0, 1, 1, 1), projective.m).IsValid());
   CHECK_FALSE(TransformAabb(Aabb {}, M4::Identity().m).IsValid());
}

TEST_CASE("Frustum: asymmetric stereo eyes, a part seen by one eye only is kept")
{
   // Two eyes 6.4 units apart, canted asymmetric FOV as XR runtimes report it
   const M4 projL = M4::PerspectiveRH(-1.2f, 0.8f, -1.f, 0.9f, 1.f, 1000.f);
   const M4 projR = M4::PerspectiveRH(-0.8f, 1.2f, -1.f, 0.9f, 1.f, 1000.f);
   const M4 viewL = M4::Translate(3.2f, 0.f, 0.f); // Left eye at x = -3.2
   const M4 viewR = M4::Translate(-3.2f, 0.f, 0.f); // Right eye at x = +3.2
   const Frustum eyes[2] = { FrustumFromClipMatrix((viewL * projL).m), FrustumFromClipMatrix((viewR * projR).m) };

   // Left eye sees up to x = -3.2 - 1.2 * 10 = -15.2 at z = -10, right eye only to -3.2 - 0.8 * 10 = 4.8 the other way
   const Aabb leftOnly = Box(-15.f, -0.5f, -10.5f, -14.5f, 0.5f, -9.5f);
   CHECK(Intersects(eyes[0], leftOnly, 0.f));
   CHECK_FALSE(Intersects(eyes[1], leftOnly, 0.f));
   CHECK(IntersectsAny(eyes, 2, leftOnly, 0.f));

   const Aabb rightOnly = Box(14.5f, -0.5f, -10.5f, 15.f, 0.5f, -9.5f);
   CHECK_FALSE(Intersects(eyes[0], rightOnly, 0.f));
   CHECK(Intersects(eyes[1], rightOnly, 0.f));
   CHECK(IntersectsAny(eyes, 2, rightOnly, 0.f));

   const Aabb neither = Box(40.f, -0.5f, -10.5f, 41.f, 0.5f, -9.5f);
   CHECK_FALSE(IntersectsAny(eyes, 2, neither, 0.f));
   CHECK(IntersectsAny(eyes, 0, neither, 0.f)); // No camera: keep
}

TEST_CASE("Frustum: mirrored camera of a plane reflection probe")
{
   // Eye at z = 10 above the plane z = 0, looking straight down. The reflected camera is the eye mirrored below the plane looking up.
   const M4 lookDown = M4::Translate(0.f, 0.f, -10.f); // Camera looks down -z in view space, so view = translate(-eye)
   const M4 proj = M4::PerspectiveRH(-0.5f, 0.5f, -0.5f, 0.5f, 1.f, 1000.f);
   const M4 reflect = M4::PlaneReflection(0.f, 0.f, 1.f, 0.f);
   const Frustum direct = FrustumFromClipMatrix((lookDown * proj).m);
   const Frustum mirrored = FrustumFromClipMatrix((reflect * lookDown * proj).m);

   // A part just above the plane under the eye is seen directly and in the mirror
   const Aabb onPlane = Box(-1, -1, 0.f, 1, 1, 1.f);
   CHECK(Intersects(direct, onPlane, 0.f));
   CHECK(Intersects(mirrored, onPlane, 0.f));

   // A part behind the eye (above it) is invisible directly, but a mirror shows what is behind the viewer
   const Aabb aboveEye = Box(-1, -1, 12.f, 1, 1, 13.f);
   CHECK_FALSE(Intersects(direct, aboveEye, 0.f));
   CHECK(Intersects(mirrored, aboveEye, 0.f));

   // A low part just outside the direct view is still inside the (farther away, so wider) mirrored view
   const Aabb besideView = Box(5.f, -0.5f, 0.5f, 6.f, 0.5f, 1.f);
   CHECK_FALSE(Intersects(direct, besideView, 0.f));
   CHECK(Intersects(mirrored, besideView, 0.f));

   // Far to the side, neither sees it
   CHECK_FALSE(Intersects(direct, Box(20.f, -0.5f, 0.5f, 21.f, 0.5f, 1.f), 0.f));
   CHECK_FALSE(Intersects(mirrored, Box(20.f, -0.5f, 0.5f, 21.f, 0.5f, 1.f), 0.f));

   // Brute force agreement with the reflected clip matrix
   const M4 clip = reflect * lookDown * proj;
   std::mt19937 rng(7);
   std::uniform_real_distribution<float> pos(-20.f, 20.f), size(0.f, 4.f);
   for (int i = 0; i < 500; i++)
   {
      const float x = pos(rng), y = pos(rng), z = pos(rng);
      const Aabb box = Box(x, y, z, x + size(rng), y + size(rng), z + size(rng));
      if (AnySampleInside(clip, box, false))
         CHECK(Intersects(mirrored, box, 0.f));
   }
}

TEST_CASE("Frustum: affine box transform matches the eight transformed corners")
{
   const Aabb local = Box(-1.f, -2.f, -0.5f, 3.f, 1.f, 2.f);
   M4 shear = M4::Identity();
   shear.m[1][0] = 0.7f; // x += 0.7 y
   shear.m[2][1] = -0.3f; // y -= 0.3 z
   const M4 transforms[] = {
      M4::Identity(),
      M4::Translate(10.f, -5.f, 3.f),
      M4::Scale(-2.f, 0.5f, 3.f) * M4::Translate(1.f, 2.f, 3.f),
      M4::RotateZ(0.785398f) * M4::RotateX(0.3f) * M4::RotateY(-1.1f) * M4::Translate(100.f, 50.f, 25.f),
      M4::Scale(1.f, -1.f, 1.f) * shear * M4::RotateZ(2.f),
   };
   for (const M4& w : transforms)
   {
      Aabb corners;
      for (int i = 0; i < 8; i++)
      {
         const float p[3] = { (i & 1) ? local.max[0] : local.min[0], (i & 2) ? local.max[1] : local.min[1], (i & 4) ? local.max[2] : local.min[2] };
         float o[4];
         w.Transform(p, o);
         corners.Extend(o[0], o[1], o[2]);
      }
      const Aabb world = TransformAabb(local, w.m);
      REQUIRE(world.IsValid());
      for (int j = 0; j < 3; j++)
      {
         CHECK(world.min[j] == doctest::Approx(corners.min[j]).epsilon(1e-4));
         CHECK(world.max[j] == doctest::Approx(corners.max[j]).epsilon(1e-4));
      }
   }
}

TEST_CASE("Frustum: 45 degree rotated box is not underbounded")
{
   // Transforming only the min and max corners of a rotated box (as the legacy camera fitting bounds do) collapses it.
   const Aabb local = Box(-1.f, -1.f, -1.f, 1.f, 1.f, 1.f);
   const M4 w = M4::RotateZ(0.785398f);
   const Aabb world = TransformAabb(local, w.m);
   CHECK(world.max[0] == doctest::Approx(sqrtf(2.f)).epsilon(1e-4));
   CHECK(world.max[1] == doctest::Approx(sqrtf(2.f)).epsilon(1e-4));
   CHECK(world.min[0] == doctest::Approx(-sqrtf(2.f)).epsilon(1e-4));

   // A view only covering x >= 1.3 (w = x - 1.3, clip x = 0, tiny clip y) sees the rotated box's corner: the true bounds keep it
   M4 sliver;
   sliver.m[0][3] = 1.f;
   sliver.m[3][3] = -1.3f;
   sliver.m[1][1] = 0.0001f;
   const Frustum f = FrustumFromClipMatrix(sliver.m);
   CHECK(Intersects(f, world, 0.f));
   CHECK_FALSE(Intersects(f, local, 0.f));
}

TEST_CASE("Frustum: randomized boxes and cameras never cull a box with a visible point")
{
   std::mt19937 rng(1234);
   std::uniform_real_distribution<float> angle(-3.14f, 3.14f), fov(0.3f, 1.4f), pos(-50.f, 50.f), size(0.f, 20.f), unit(0.f, 1.f);
   int culled = 0, kept = 0;
   for (int cam = 0; cam < 40; cam++)
   {
      const M4 view = M4::Translate(pos(rng), pos(rng), pos(rng)) * M4::RotateZ(angle(rng)) * M4::RotateX(angle(rng)) * M4::RotateY(angle(rng));
      const M4 proj = M4::PerspectiveRH(-fov(rng), fov(rng), -fov(rng), fov(rng), 0.5f + unit(rng), 200.f + 100.f * unit(rng));
      const M4 clip = view * proj;
      const bool testFar = (cam & 1) != 0;
      const Frustum f = FrustumFromClipMatrix(clip.m, testFar);
      for (int i = 0; i < 100; i++)
      {
         // Random local box under a random object transform, as primitives are
         const Aabb local = Box(-size(rng), -size(rng), -size(rng), size(rng), size(rng), size(rng));
         const M4 world = M4::Scale(0.2f + 2.f * unit(rng), -(0.2f + 2.f * unit(rng)), 0.2f + 2.f * unit(rng)) * M4::RotateX(angle(rng)) * M4::RotateZ(angle(rng))
            * M4::Translate(pos(rng), pos(rng), pos(rng));
         const Aabb box = TransformAabb(local, world.m);
         const bool visible = Intersects(f, box, 0.f);
         if (AnySampleInside(clip, box, testFar))
            CHECK(visible);
         // The object's own mesh lies inside its local box, so sampling the local box through the object transform must agree too
         if (AnySampleInside(world * clip, local, testFar))
            CHECK(visible);
         (visible ? kept : culled)++;
      }
   }
   // The scenario must exercise both outcomes
   CHECK(culled > 100);
   CHECK(kept > 100);
}

TEST_CASE("Frustum culling switch: environment overrides the setting")
{
   CHECK(ResolveEnabled(nullptr, true));
   CHECK_FALSE(ResolveEnabled(nullptr, false));
   CHECK(ResolveEnabled("1", false));
   CHECK_FALSE(ResolveEnabled("0", true));
   CHECK(ResolveEnabled("", true)); // Malformed values fall back to the setting
   CHECK_FALSE(ResolveEnabled("10", false));
   CHECK(ResolveEnabled("yes", true));
   CHECK_FALSE(ResolveEnabled("01", false));
}
