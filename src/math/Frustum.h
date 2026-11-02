// license:GPLv3+

#pragma once

// Conservative view frustum culling maths, kept free of renderer dependencies so that it can be unit tested.
//
// Matrices use VPX's row vector convention: a position p is transformed as [p.x p.y p.z 1] * M, so a local
// position reaches clip space through World * View * Proj. Visible clip space is -w <= x <= w, -w <= y <= w,
// and depth between 0 (or -w, depending on the backend) and w. The near plane is tested as z >= -w, which holds
// for both depth conventions (it mostly matters to reject boxes behind the eye, that the side planes, tested one
// at a time, can miss). The far plane is optional (depth clamping, infinite far projections).
//
// Every helper fails open: invalid bounds, non finite matrices or degenerate planes always report 'visible'.

#include <cfloat>
#include <cmath>

namespace VPX::Culling
{

// Axis aligned bounding box. Default constructed boxes are empty, and therefore invalid (never culled).
struct Aabb
{
   float min[3] { FLT_MAX, FLT_MAX, FLT_MAX };
   float max[3] { -FLT_MAX, -FLT_MAX, -FLT_MAX };

   void Extend(const float x, const float y, const float z)
   {
      min[0] = x < min[0] ? x : min[0];
      min[1] = y < min[1] ? y : min[1];
      min[2] = z < min[2] ? z : min[2];
      max[0] = x > max[0] ? x : max[0];
      max[1] = y > max[1] ? y : max[1];
      max[2] = z > max[2] ? z : max[2];
   }

   void Extend(const Aabb& box)
   {
      if (!box.IsValid())
         return;
      Extend(box.min[0], box.min[1], box.min[2]);
      Extend(box.max[0], box.max[1], box.max[2]);
   }

   bool IsValid() const
   {
      for (int i = 0; i < 3; i++)
         if (!std::isfinite(min[i]) || !std::isfinite(max[i]) || min[i] > max[i] || min[i] == FLT_MAX || max[i] == -FLT_MAX)
            return false;
      return true;
   }
};

// Plane with a unit normal, a point p being inside when dot(n, p) + d >= 0
struct Plane
{
   float n[3];
   float d;
};

struct Frustum
{
   Plane planes[6];
   int count = 0;
   bool valid = false; // Invalid frustums never reject anything
};

// Transforms a local box by an affine row vector matrix, giving the world box enclosing the transformed local box.
// Handles rotation, negative and non uniform scale, and shear. Returns an invalid box for invalid input or projective matrices.
inline Aabb TransformAabb(const Aabb& local, const float m[4][4])
{
   if (!local.IsValid() || m[0][3] != 0.f || m[1][3] != 0.f || m[2][3] != 0.f || m[3][3] != 1.f)
      return {};
   float c[3], e[3];
   for (int i = 0; i < 3; i++)
   {
      c[i] = 0.5f * (local.min[i] + local.max[i]);
      e[i] = 0.5f * (local.max[i] - local.min[i]);
   }
   Aabb world;
   for (int j = 0; j < 3; j++)
   {
      const float wc = c[0] * m[0][j] + c[1] * m[1][j] + c[2] * m[2][j] + m[3][j];
      const float we = e[0] * std::fabs(m[0][j]) + e[1] * std::fabs(m[1][j]) + e[2] * std::fabs(m[2][j]);
      world.min[j] = wc - we;
      world.max[j] = wc + we;
   }
   return world.IsValid() ? world : Aabb {};
}

// Extracts the inward facing planes of a camera matrix (View * Proj, row vector convention) mapping world positions to clip space.
inline Frustum FrustumFromClipMatrix(const float m[4][4], const bool testFar = false)
{
   Frustum f;
   for (int i = 0; i < 4; i++)
      for (int j = 0; j < 4; j++)
         if (!std::isfinite(m[i][j]))
            return f;
   // Column j of the matrix gives clip coordinate j as a linear function of (x, y, z, 1)
   const auto addPlane = [&f, m](const int col, const float sign)
   {
      // Plane w + sign * clip[col] >= 0
      const float a = m[0][3] + sign * m[0][col];
      const float b = m[1][3] + sign * m[1][col];
      const float c = m[2][3] + sign * m[2][col];
      const float d = m[3][3] + sign * m[3][col];
      const float len = std::sqrt(a * a + b * b + c * c);
      if (!(len > 1e-12f) || !std::isfinite(len))
         return; // Degenerate plane (for example the far plane of an infinite projection): never rejects
      const float inv = 1.f / len;
      f.planes[f.count++] = Plane { { a * inv, b * inv, c * inv }, d * inv };
   };
   addPlane(0, 1.f); // Left
   addPlane(0, -1.f); // Right
   addPlane(1, 1.f); // Bottom
   addPlane(1, -1.f); // Top
   addPlane(2, 1.f); // Near, loosest convention (z >= -w)
   if (testFar)
      addPlane(2, -1.f); // Far
   f.valid = true;
   return f;
}

// True if the world box may be visible. 'margin' (world units) widens the frustum to absorb floating point differences with the GPU.
inline bool Intersects(const Frustum& frustum, const Aabb& box, const float margin)
{
   if (!frustum.valid || !box.IsValid())
      return true;
   float c[3], e[3];
   for (int i = 0; i < 3; i++)
   {
      c[i] = 0.5f * (box.min[i] + box.max[i]);
      e[i] = 0.5f * (box.max[i] - box.min[i]);
   }
   for (int i = 0; i < frustum.count; i++)
   {
      const Plane& p = frustum.planes[i];
      const float dist = p.n[0] * c[0] + p.n[1] * c[1] + p.n[2] * c[2] + p.d;
      const float radius = std::fabs(p.n[0]) * e[0] + std::fabs(p.n[1]) * e[1] + std::fabs(p.n[2]) * e[2];
      if (dist + radius < -margin)
         return false;
   }
   return true;
}

// Stereo rule: a part is kept if any of the eyes may see it
inline bool IntersectsAny(const Frustum* frustums, const int count, const Aabb& box, const float margin)
{
   for (int i = 0; i < count; i++)
      if (Intersects(frustums[i], box, margin))
         return true;
   return count <= 0;
}

// Effective culling switch: VPX_VR_CULLING=0|1 overrides the setting, anything else falls back to it
inline bool ResolveEnabled(const char* const env, const bool setting)
{
   if (env != nullptr && (env[0] == '0' || env[0] == '1') && env[1] == '\0')
      return env[0] == '1';
   return setting;
}

}
