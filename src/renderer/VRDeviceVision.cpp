// license:GPLv3+

#include "core/stdafx.h"

#include "VRDevice.h"
#include "renderer/RenderTarget.h"
#include "core/FileLocator.h"
#include "core/VPApp.h"
#include "parts/Material.h"
#include "parts/collection.h"
#include "parts/flasher.h"
#include "parts/pintable.h"
#include "parts/primitive.h"

#include <chrono>
#include <fstream>
#include <thread>

namespace
{
constexpr float stockWidth = 0.51435f;
constexpr float stockLength = 1.1684f;
constexpr float stockHeight = 0.9093f;
}

void VRDevice::ConfigureVisionRoom(PinTable* table)
{
   const auto width = VPUTOCM(table->m_right - table->m_left) * 0.01f;
   const auto length = VPUTOCM(table->m_bottom - table->m_top) * 0.01f;
   const auto height = m_lockbarHeight * 0.01f;
   m_visionLayout = { width, length, height, width * 0.44f, -0.095f, 0.040f, 0 };

   // Older VR tables put the room and cabinet in the playfield space.
   const auto getPrimitive = [table](std::string_view name) -> Primitive*
   {
      for (auto* part : table->GetParts())
         if (part->GetItemType() == eItemPrimitive && part->GetName() == name)
            return static_cast<Primitive*>(part);
      return nullptr;
   };
   auto* timeMachineLegs = getPrimitive("PinCab_Metal_L+R+F");
   const bool meteor = getPrimitive("VR_Cab") && getPrimitive("VR_Cab_Leg_Front_Left");
   const bool gorgar = getPrimitive("PinCab_Bottom") && getPrimitive("VRBackleftLeg");
   const bool legacyCabinet = timeMachineLegs || meteor || gorgar;

   bool modernCabinet = false;
   bool modernRoom = false;
   for (const auto* part : table->GetParts())
   {
      if (const auto* group = part->GetPartGroup(); group && part->GetIRenderable())
      {
         const auto space = group->GetReferenceSpace();
         modernCabinet |= space == PartGroupData::SpaceReference::SR_CABINET;
         modernRoom |= space == PartGroupData::SpaceReference::SR_ROOM;
      }
      if (legacyCabinet && (part->GetName() == "VR_Floor" || part->GetName() == "VR_Roof"
         || part->GetName() == "VR_Wall_Left" || part->GetName() == "VR_Wall_Right"
         || (timeMachineLegs && part->GetItemType() == eItemFlasher && part->GetName() == "Logo")
         || (meteor && part->GetName().starts_with("VR_Room_"))))
         m_visionLegacyRoomParts.insert(part);
   }
   for (const auto* collection : table->GetCollections())
      if ((gorgar && (collection->m_name == "VRRoomMin" || collection->m_name == "VRRoomBig"))
         || (meteor && collection->m_name == "VRClock"))
         m_visionLegacyRoomParts.insert(collection->GetParts().begin(), collection->GetParts().end());

   if (meteor)
   {
      // Meteor ships with its own cabinet and the VR option disabled in
      // the script. Set its documented switch on the live copy only.
      constexpr std::string_view switchLine = "const VR_Room = 0 ' 0 is desktop or cab mode, 1 is VR Room";
      if (const auto pos = table->m_script_text.find(switchLine); pos != string::npos)
         table->m_script_text[pos + 16] = '1';
   }

   // This Black Hole table offers several ROM revisions. Its default is
   // the seven-digit conversion, while the original is also supported.
   constexpr std::string_view blackHoleSetting = "\nRomSet = 5";
   if (const auto pos = table->m_script_text.find(blackHoleSetting); pos != string::npos
       && table->m_script_text.find("cGameName=\"blckhole\"") != string::npos)
   {
      const auto roms = table->m_filename.parent_path() / "pinmame" / "roms";
      if (find_case_insensitive_file_path(roms / "blkhole7.zip").empty()
          && !find_case_insensitive_file_path(roms / "blckhole.zip").empty())
      {
         table->m_script_text[pos + blackHoleSetting.size() - 1] = '1';
         PLOGI << "Using the supplied original Black Hole ROM";
      }
   }

   const bool stock = !legacyCabinet && !modernCabinet;
   m_visionLayout.stockCabinet = stock;
   if (stock)
   {
      m_visionLayout.plungerX = width * 0.434f;
      m_visionLayout.plungerY = -0.057f * height / stockHeight;
      m_visionLayout.plungerZ = length * (1.296f / stockLength - 1.f) - 0.05f;
      if (auto* sides = getPrimitive("CABINETSIDES_GIOFF");
          sides && getPrimitive("SIDEWALL_GIOFF") && sides->m_d.m_vSize.y == 42.f)
      {
         // The desktop overlay extends below the stock cabinet.
         // The stock side panels and blades take its place in VR.
         sides->m_d.m_visible = false;
      }
   }
   AddVisionStockGeometry(table, stock, !IsVisionMixedReality() && !modernRoom && m_visionLegacyRoomParts.empty());

   vector<Primitive*> legs;
   if (timeMachineLegs)
      legs.push_back(timeMachineLegs);
   else if (meteor || gorgar)
   {
      for (auto* part : table->GetParts())
      {
         const string& name = part->GetName();
         if (part->GetItemType() == eItemPrimitive && (meteor ? name.starts_with("VR_Cab_Leg_")
            : (name == "VRBackleftLeg" || name == "VRBackRightLeg" || name == "VRFrontRightLeg" || name == "VRLeftFrontLeg")))
            legs.push_back(static_cast<Primitive*>(part));
      }
   }

   if (IsVisionMixedReality() && !legs.empty())
   {
      UpdateWorldTransforms();
      Vertex3Ds front { 0.f, FLT_MAX, 0.f };
      Vertex3Ds back = front;
      const float split = -(table->m_bottom - table->m_top) * 0.5f;
      for (auto* leg : legs)
      {
         const Matrix3D worldFromMesh = leg->RecalculateMatrices() * m_pfWorld.m_toWorld;
         for (const auto& vertex : leg->m_mesh.m_vertices)
         {
            const Vertex3Ds point = worldFromMesh * Vertex3Ds { vertex.x, vertex.y, vertex.z };
            auto& foot = point.z > split ? front : back;
            if (point.y < foot.y)
               foot = point;
         }
      }
      if (front.y != FLT_MAX && back.y != FLT_MAX && front.z - back.z > -split)
      {
         const float lockbar = CMTOVPU(m_lockbarHeight);
         const float pitch = atan2f(front.y - back.y, front.z - back.z);
         m_visionPlayfieldLevel = Matrix3D::MatrixTranslate(0.f, -lockbar, 0.f)
            * Matrix3D::MatrixRotateX(pitch) * Matrix3D::MatrixTranslate(0.f, lockbar, 0.f);
         const Vertex3Ds levelFront = m_visionPlayfieldLevel * front;
         const Vertex3Ds levelBack = m_visionPlayfieldLevel * back;
         m_visionLayout.height = VPUTOCM(lockbar - min(levelFront.y, levelBack.y)) * 0.01f;
      }
   }

   if (timeMachineLegs)
      m_visionLayout.plungerX = 0.24f; // Keep the verified Time Machine hand profile.
   PLOGI << "Vision Pro cabinet: " << (stock ? "stock" : "authored")
      << ", playfield " << width << " x " << length << " m, placement height " << m_visionLayout.height << " m";
}

void VRDevice::AddVisionStockGeometry(PinTable* table, bool cabinet, bool room)
{
   if (!cabinet && !room)
      return;

   using enum PartGroupData::SpaceReference;
   const auto makeGroup = [table](std::string_view name, PartGroupData::SpaceReference space, unsigned int visibility)
   {
      auto* group = PartGroup::COMCreate();
      group->Init(0.f, 0.f, false);
      group->SetName(table->GetUniqueName(string(name)));
      group->m_d.m_spaceReference = space;
      group->m_d.m_playerModeVisibilityMask = visibility;
      table->AddPart(group);
      group->Release();
      return group;
   };

   const auto material = [table](std::string_view name, COLORREF color, float roughness)
   {
      auto* value = new Material();
      value->m_name = table->GetUniqueName(string(name));
      value->m_cBase = color;
      value->m_fRoughness = roughness;
      value->m_fWrapLighting = 0.55f;
      table->AddMaterial(value);
      return value;
   };

   const auto assets = g_app->m_fileLocator.GetAppPath(FileLocator::AppSubFolder::Assets, "blankTable.vpz/meshes");
   const auto addMesh = [table, &assets](PartGroup* group, const char* name, const Material* mat, const Vertex3Ds& scale)
   {
      std::ifstream file(assets / (string(name) + ".glb"), std::ios::binary);
      vector<uint8_t> bytes((std::istreambuf_iterator<char>(file)), std::istreambuf_iterator<char>());
      auto* part = Primitive::COMCreate();
      part->Init(0.f, 0.f, false);
      if (!bytes.empty() && part->m_mesh.LoadGLB(bytes.data(), bytes.size()))
      {
         part->SetName(table->GetUniqueName("Vision" + string(name)));
         part->SetPartGroup(group);
         part->m_d.m_vPosition = { 0.f, 0.f, 0.f };
         part->m_d.m_vSize = scale;
         part->m_d.m_szMaterial = mat->m_name;
         part->m_d.m_use3DMesh = true;
         part->m_d.m_visible = true;
         part->m_d.m_collidable = false;
         part->m_d.m_toy = true;
         part->m_d.m_staticRendering = true;
         part->m_d.m_reflectionEnabled = false;
         table->AddPart(part);
      }
      else
         PLOGE << "Unable to load the stock Vision Pro cabinet mesh " << name;
      part->Release();
   };

   if (room)
   {
      auto* group = makeGroup("VisionRoom", SR_ROOM, PartGroupData::PMVM_VIRTUAL_REALITY);
      auto* floor = material("VisionRoomFloor", RGB(83, 91, 103), 0.9f);
      addMesh(group, "VRGround", floor, { 2.f, 2.f, 1.f });
   }
   if (!cabinet)
      return;

   constexpr unsigned int modes = PartGroupData::PMVM_MIXED_REALITY | PartGroupData::PMVM_VIRTUAL_REALITY;
   auto* body = makeGroup("VisionCabinet", SR_CABINET, modes);
   auto* feet = makeGroup("VisionCabinetFeet", SR_CABINET_FEET, modes);
   auto* wood = material("VisionCabinetBody", RGB(39, 46, 61), 0.67f);
   auto* metal = material("VisionCabinetMetal", RGB(126, 134, 149), 0.34f);
   auto* black = material("VisionCabinetBlack", RGB(25, 27, 31), 0.52f);
   auto* red = material("VisionCabinetButton", RGB(208, 43, 35), 0.42f);
   const Vertex3Ds scale { m_visionLayout.width / stockWidth, m_visionLayout.length / stockLength, m_visionLayout.height / stockHeight };
   for (const char* name : { "VRCab", "VRBackbox", "VRCrossBar" })
      addMesh(body, name, wood, scale);
   for (const char* name : { "VRRail", "VRHinges", "VRPlunger", "VRPlungerHousing" })
      addMesh(body, name, metal, scale);
   for (const char* name : { "VRBackglass", "VRBlades", "VRCoinDoor", "VRStartButtonHousing" })
      addMesh(body, name, black, scale);
   for (const char* name : { "VRStartButton", "VRLeftFlip", "VRRightFlip" })
      addMesh(body, name, red, scale);
   for (const char* name : { "VRLegs", "VRCaster" })
      addMesh(feet, name, metal, scale);

   auto* display = Flasher::COMCreate();
   auto companion = table->m_filename;
   companion.replace_extension(".directb2s");
   const bool backglass = !find_case_insensitive_file_path(companion).empty();
   display->Init(MTOVPU(m_visionLayout.width * 0.5f), MTOVPU(0.085f * scale.y), false);
   display->SetName(table->GetUniqueName("VisionCabinetDisplay"));
   display->SetPartGroup(body);
   display->m_d.m_renderMode = backglass ? FlasherData::EXT_RENDER : FlasherData::DMD;
   display->m_d.m_renderStyle = backglass ? VPXWINDOW_Backglass : 0;
   display->m_d.m_height = MTOVPU((backglass ? 1.57f : 1.41f) * scale.z);
   display->m_d.m_rotX = -90.f;
   display->Scale(MTOVPU(0.65f * scale.x) / 100.f, MTOVPU((backglass ? 0.46f : 0.15f) * scale.z) / 100.f, {}, true);
   table->AddPart(display);
   display->Release();
}

void VRDevice::UpdateVisionLegacyRoomPosition(ModelViewProj& mvp) const
{
   for (unsigned int eye = 0; eye < mvp.m_nEyes; ++eye)
   {
      mvp.SetView(eye, m_visionLegacyRoomView[eye]);
      mvp.SetProj(eye, m_sceneProj[eye]);
   }
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
   const float* roomViews[] = {frame.leftRoomView, frame.rightRoomView};
   const float* projections[] = {frame.leftProjection, frame.rightProjection};
   for (unsigned int eye = 0; eye < 2; ++eye)
   {
      Matrix3D eyeFromCabinet, eyeFromRoom, projection;
      memcpy(eyeFromCabinet.m, views[eye], sizeof eyeFromCabinet.m);
      memcpy(eyeFromRoom.m, roomViews[eye], sizeof eyeFromRoom.m);
      memcpy(projection.m, projections[eye], sizeof projection.m);
      const Matrix3D view = vpuScale * floorToCabinet * eyeFromCabinet * invVpuScale;
      const Matrix3D viewInvSceneScale = view * invSceneScale;
      m_pfWorld.m_view[eye] = m_pfWorld.m_toWorld * m_visionPlayfieldLevel * viewInvSceneScale;
      m_cabWorld.m_view[eye] = m_cabWorld.m_toWorld * viewInvSceneScale;
      m_feetWorld.m_view[eye] = m_feetWorld.m_toWorld * viewInvSceneScale;
      const Matrix3D roomView = vpuScale * floorToCabinet * eyeFromRoom * invVpuScale;
      m_roomWorld.m_view[eye] = m_roomWorld.m_toWorld * roomView;
      m_visionLegacyRoomView[eye] = m_pfWorld.m_toWorld * roomView * invSceneScale;
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
