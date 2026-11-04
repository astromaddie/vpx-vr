// license:GPLv3+

#include "core/stdafx.h"

#include "VRDevice.h"
#include "renderer/RenderTarget.h"
#include "parts/pintable.h"
#include "parts/primitive.h"

#include <chrono>
#include <thread>

void VRDevice::ConfigureVisionRoom(const PinTable* table)
{
   // Time Machine predates VR space references. Recognize its room by the four
   // authored room parts and the cabinet's metal mesh, which contains the legs.
   constexpr std::array<std::string_view, 4> roomNames = { "VR_Floor", "VR_Roof", "VR_Wall_Left", "VR_Wall_Right" };
   std::array<const IEditable*, roomNames.size()> room{};
   Primitive* legs = nullptr;
   for (IEditable* part : table->GetParts())
   {
      const auto* group = part->GetPartGroup();
      if (group && group->GetReferenceSpace() != PartGroupData::SpaceReference::SR_PLAYFIELD)
         continue;
      for (size_t i = 0; i < room.size(); ++i)
         if (part->GetName() == roomNames[i])
            room[i] = part;
      if (part->GetItemType() == eItemPrimitive && part->GetName() == "PinCab_Metal_L+R+F")
         legs = static_cast<Primitive*>(part);
   }
   if (!legs || std::ranges::find(room, nullptr) != room.end())
      return;

   m_visionLegacyRoomParts = room;
   UpdateWorldTransforms();
   const Matrix3D worldFromMesh = legs->RecalculateMatrices() * m_pfWorld.m_toWorld;
   Vertex3Ds front { 0.f, FLT_MAX, 0.f };
   Vertex3Ds back = front;
   const float split = -(table->m_bottom - table->m_top) * 0.5f;
   for (const auto& vertex : legs->m_mesh.m_vertices)
   {
      const Vertex3Ds point = worldFromMesh * Vertex3Ds { vertex.x, vertex.y, vertex.z };
      auto& foot = point.z > split ? front : back;
      if (point.y < foot.y)
         foot = point;
   }
   if (front.y == FLT_MAX || back.y == FLT_MAX || front.z - back.z < -split)
      return;

   // Old VR rooms were modelled in inclined playfield space. Level the floor
   // defined by the front and rear feet around the lockbar, at authored scale.
   const float height = CMTOVPU(m_lockbarHeight);
   const float pitch = atan2f(front.y - back.y, front.z - back.z);
   m_visionPlayfieldLevel = Matrix3D::MatrixTranslate(0.f, -height, 0.f)
      * Matrix3D::MatrixRotateX(pitch) * Matrix3D::MatrixTranslate(0.f, height, 0.f);
   const Vertex3Ds levelFront = m_visionPlayfieldLevel * front;
   const Vertex3Ds levelBack = m_visionPlayfieldLevel * back;
   m_visionCabinetHeight = VPUTOCM(height - min(levelFront.y, levelBack.y)) * 0.01f;
   PLOGI << "Vision Pro legacy mixed reality cabinet height " << m_visionCabinetHeight
      << " m; rear foot rise " << VPUTOCM(back.y - front.y) * 0.01f
      << " m before levelling, " << VPUTOCM(levelBack.y - levelFront.y) * 0.01f << " m after";
}

void VRDevice::RenderVisionFrame(RenderDevice* rd, const std::function<bool(RenderTarget*)>& submit)
{
   VPINBALL_VISION_FRAME frame{};
   if (m_visionHost.beginFrame(m_visionHost.user, &frame) != 1)
   {
      std::this_thread::sleep_for(std::chrono::milliseconds(4));
      return;
   }

   if (frame.eyeBuffer >= m_visionTargets.size())
   {
      m_visionHost.endFrame(m_visionHost.user, 0);
      return;
   }

   auto& target = m_visionTargets[frame.eyeBuffer];
   if (!target)
   {
      const auto width = static_cast<uint16_t>(m_eyeWidth);
      const auto height = static_cast<uint16_t>(m_eyeHeight);
      const auto color = bgfx::createTexture2D(width, height, false, 2, bgfx::TextureFormat::BGRA8,
         BGFX_TEXTURE_RT, nullptr, reinterpret_cast<uint64_t>(m_visionHost.color[frame.eyeBuffer]));
      const auto depth = bgfx::createTexture2D(width, height, false, 2, bgfx::TextureFormat::D32F,
         BGFX_TEXTURE_RT | BGFX_TEXTURE_BLIT_DST, nullptr, reinterpret_cast<uint64_t>(m_visionHost.depth[frame.eyeBuffer]));
      if (!bgfx::isValid(color) || !bgfx::isValid(depth))
      {
         if (bgfx::isValid(color)) bgfx::destroy(color);
         if (bgfx::isValid(depth)) bgfx::destroy(depth);
         PLOGE << "Could not import the visionOS eye textures.";
         m_visionHost.endFrame(m_visionHost.user, 0);
         return;
      }
      bgfx::Attachment attachments[2];
      attachments[0].init(color, bgfx::Access::Write, 0, 2, 0, BGFX_ATTACHMENT_NONE);
      attachments[1].init(depth, bgfx::Access::Write, 0, 2, 0, BGFX_ATTACHMENT_NONE);
      const auto buffer = bgfx::createFrameBuffer(2, attachments);
      if (!bgfx::isValid(buffer))
      {
         bgfx::destroy(color);
         bgfx::destroy(depth);
         PLOGE << "Could not create the visionOS eye framebuffer.";
         m_visionHost.endFrame(m_visionHost.user, 0);
         return;
      }
      target = std::make_unique<RenderTarget>(rd, SurfaceType::RT_STEREO, buffer,
         color, bgfx::TextureFormat::BGRA8, depth, bgfx::TextureFormat::D32F,
         "Vision Pro Eyes", width, height, colorFormat::RGBA8);
      PLOGI << "Vision Pro stereo eye framebuffer ready";
   }

   UpdateWorldTransforms();
   constexpr float vpuToMetres = static_cast<float>(0.0254 * 1.0625 / 50.);
   const Matrix3D vpuScale = Matrix3D::MatrixScale(vpuToMetres);
   const Matrix3D invVpuScale = Matrix3D::MatrixScale(1.f / vpuToMetres);
   const Matrix3D sceneScale = Matrix3D::MatrixScale(m_scale);
   const Matrix3D invSceneScale = Matrix3D::MatrixScale(1.f / m_scale);
   const Matrix3D floorToCabinet = Matrix3D::MatrixTranslate(0.f, -m_lockbarHeight * 0.01f, 0.f);
   const float* views[] = {frame.leftView, frame.rightView};
   const float* projections[] = {frame.leftProjection, frame.rightProjection};
   for (unsigned int eye = 0; eye < 2; ++eye)
   {
      Matrix3D eyeFromCabinet, projection;
      memcpy(eyeFromCabinet.m, views[eye], sizeof eyeFromCabinet.m);
      memcpy(projection.m, projections[eye], sizeof projection.m);
      const Matrix3D view = vpuScale * floorToCabinet * eyeFromCabinet * invVpuScale;
      const Matrix3D viewInvSceneScale = view * invSceneScale;
      m_pfWorld.m_view[eye] = m_pfWorld.m_toWorld * m_visionPlayfieldLevel * viewInvSceneScale;
      m_cabWorld.m_view[eye] = m_cabWorld.m_toWorld * viewInvSceneScale;
      m_feetWorld.m_view[eye] = m_feetWorld.m_toWorld * viewInvSceneScale;
      m_roomWorld.m_view[eye] = m_roomWorld.m_toWorld * view;
      m_roomProj[eye] = vpuScale * projection;
      m_sceneProj[eye] = sceneScale * m_roomProj[eye];
   }
   UpdateSpatialAudio(true);
   m_predictedDisplayTimestamp = static_cast<float>(usec() / 1e6) + frame.secondsUntilPresentation;
   const bool rendered = submit(target.get());
   m_visionHost.endFrame(m_visionHost.user, rendered);
}

void VRDevice::ReleaseVisionTarget()
{
   for (auto& target : m_visionTargets)
      target.reset();
}
