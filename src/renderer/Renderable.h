// license:GPLv3+

#pragma once

#include "math/Frustum.h"
#include "math/matrix.h"

class Renderer;

// Conservative bounds of everything a part's Render() may draw for a render mask, used for frustum culling.
// The box is in the part's local space; toWorld (affine) maps it to the part's reference space (playfield, cabinet, room...),
// that is the object matrix the part renders with. It must enclose every vertex of every draw (all animation frames,
// grouped meshes, backfaces, reflection only overlays...): a part whose bounds are not reliable must not provide any.
struct RenderBounds
{
   VPX::Culling::Aabb local;
   Matrix3D toWorld;
   unsigned int triangles = 0; // Triangles of the main draw, for statistics only
};

// Interface used by the renderer to render each part.
//
// All functions may only be called after RenderSetup and before RenderRelease.
// RenderRelease is guaranteed to be called before the object is disposed.
class IRenderable
{
public:
   virtual void RenderSetup(Renderer *renderer) = 0;
   virtual void UpdateAnimation(const float diff_time_msec) = 0;
   virtual void Render(const unsigned int renderMask) = 0;
   virtual float GetDepth(const Vertex3Ds& viewDir) const { return 0.0f; }
   // Fill bounds and return true if they are known for this render mask. Unknown (the default) means never culled.
   // Called by the renderer before Render() with the same mask, only when frustum culling is active.
   virtual bool GetRenderBounds(const unsigned int renderMask, RenderBounds& bounds) { return false; }
   virtual void RenderRelease() = 0;
};
