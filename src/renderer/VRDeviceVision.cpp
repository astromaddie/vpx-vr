// license:GPLv3+

#include "core/stdafx.h"

#include "VRDevice.h"
#include "renderer/RenderTarget.h"
#include "core/FileLocator.h"
#include "core/VPApp.h"
#include "core/player.h"
#include "parts/Material.h"
#include "parts/Collection.h"
#include "parts/bumper.h"
#include "parts/flasher.h"
#include "parts/flipper.h"
#include "parts/gate.h"
#include "parts/kicker.h"
#include "parts/light.h"
#include "parts/pintable.h"
#include "parts/plunger.h"
#include "parts/primitive.h"
#include "parts/ramp.h"
#include "parts/spinner.h"
#include "parts/surface.h"
#include "parts/trigger.h"
#include "renderer/VisionCabinetFit.h"

#include <chrono>
#include <fstream>
#include <thread>
#include <os/proc.h>

namespace
{
constexpr float stockWidth = 0.51435f;
constexpr float stockLength = 1.1684f;
constexpr float stockHeight = 0.9093f;
constexpr float stockGlassBottomHeight = 0.0635f; // glass_bottom_height in blankTable.vpz, in metres
// The centre and outer extents of the three slots in the stock coin door.
const Vertex3Ds stockCoinCenter { MTOVPU(0.25428f), MTOVPU(1.24361f), MTOVPU(0.81072f) };
const Vertex3Ds stockCoinHalfExtent { MTOVPU(0.07313f), 0.f, MTOVPU(0.02169f) };
const Vertex3Ds gorgarCoinScale { 1.f, 1.f, 0.65f };
// Seat the base of the stock door on the visible front of PinCab_Bottom.
const Vertex3Ds gorgarCoinOffset { 476.f - stockCoinCenter.x, 2065.71f - MTOVPU(1.21147f),
   -190.f - stockCoinCenter.z * gorgarCoinScale.z };

PartGroup* AddVisionPartGroup(PinTable* table, std::string_view name, PartGroupData::SpaceReference space, unsigned int visibility)
{
   auto* group = PartGroup::COMCreate();
   group->Init(0.f, 0.f, false);
   group->SetName(table->GetUniqueName(string(name)));
   group->m_d.m_spaceReference = space;
   group->m_d.m_playerModeVisibilityMask = visibility;
   table->AddPart(group);
   group->Release();
   return group;
}
}

void VRDevice::ConfigureVisionRoom(PinTable* table)
{
   const auto width = VPUTOCM(table->m_right - table->m_left) * 0.01f;
   const auto length = VPUTOCM(table->m_bottom - table->m_top) * 0.01f;
   const auto height = m_lockbarHeight * 0.01f;
   m_visionLayout = { width, length, height };

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
   bool neutral = false;
   if (stock)
   {
      auto* sides = getPrimitive("CABINETSIDES_GIOFF");
      auto* litWall = getPrimitive("SIDEWALL");
      auto* darkWall = getPrimitive("SIDEWALL_GIOFF");
      if (sides && litWall && darkWall && sides->m_d.m_vSize.y == 42.f)
      {
         // This desktop cabinet and its GI-controlled sidewalls overlap the stock blades.
         // A group keeps the overlays out of the headset even when the script toggles them.
         using enum PartGroupData::PlayerModeVisibilityMask;
         auto* overlays = AddVisionPartGroup(table, "VisionDesktopOverlays", PartGroupData::SpaceReference::SR_PLAYFIELD,
            PMVM_DESKTOP | PMVM_FSS | PMVM_CABINET);
         for (auto* part : { sides, litWall, darkWall })
            part->SetPartGroup(overlays);
      }
      neutral = AddVisionNeutralCabinet(table);
      if (!neutral)
      {
         // Legacy desktop tables use the rear glass height at both ends.
         // Fit the playfield to the depth the stock cabinet was built for.
         m_visionStockGlassDepth = MTOVPU(stockGlassBottomHeight * height / stockHeight);
      }
   }
   AddVisionStockGeometry(table, stock && !neutral, !IsVisionMixedReality() && !modernRoom && m_visionLegacyRoomParts.empty(), gorgar);

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

   UpdateWorldTransforms();
   const float lockbar = CMTOVPU(m_lockbarHeight);
   const auto cabinetPoint = [lockbar](const Matrix3D& worldFromMesh, const Vertex3Ds& local)
   {
      auto point = worldFromMesh * local;
      point.y -= lockbar;
      return point * (VPUTOCM(1.f) * 0.01f);
   };
   const auto face = [&cabinetPoint](const Matrix3D& transform, const Vertex3Ds& center,
                                    const Vertex3Ds& halfExtent)
   {
      const auto point = cabinetPoint(transform, center);
      const auto edgeX = cabinetPoint(transform, center + Vertex3Ds{halfExtent.x, 0.f, 0.f}) - point;
      const auto edgeY = cabinetPoint(transform, center + Vertex3Ds{0.f, halfExtent.y, 0.f}) - point;
      const auto edgeZ = cabinetPoint(transform, center + Vertex3Ds{0.f, 0.f, halfExtent.z}) - point;
      constexpr float fingertipTolerance = 0.017f;
      return VPINBALL_VISION_BUTTON_FACE { point.x, point.y, point.z,
         abs(edgeX.x) + abs(edgeY.x) + abs(edgeZ.x) + fingertipTolerance,
         abs(edgeX.y) + abs(edgeY.y) + abs(edgeZ.y) + fingertipTolerance };
   };
   const auto flipper = [&cabinetPoint](const Matrix3D& transform, const Vertex3Ds& center)
   {
      const auto point = cabinetPoint(transform, center);
      return VPINBALL_VISION_POINT { point.x, point.y, point.z };
   };
   const auto plunger = [this, &cabinetPoint](const Matrix3D& transform, const Vertex3Ds& center)
   {
      const auto point = cabinetPoint(transform, center);
      m_visionLayout.plungerX = point.x;
      m_visionLayout.plungerY = point.y;
      m_visionLayout.plungerZ = point.z;
      m_visionLayout.hasPlunger = 1;
   };

   if (neutral)
   {
      // The fitted anchors are already in the cabinet space of the meshes.
      const auto& n = m_visionNeutral;
      const Matrix3D& worldFromCabinet = m_cabWorld.m_toWorld;
      m_visionLayout.start = face(worldFromCabinet, n.start, n.startHalf);
      m_visionLayout.coin = face(worldFromCabinet, n.coin, n.coinHalf);
      m_visionLayout.leftFlipper = flipper(worldFromCabinet, n.leftFlipper);
      m_visionLayout.rightFlipper = flipper(worldFromCabinet, n.rightFlipper);
      if (n.launchButton)
      {
         m_visionLayout.launch = face(worldFromCabinet, n.launch, n.launchHalf);
         m_visionLayout.hasLaunchButton = 1;
      }
      else
         plunger(worldFromCabinet, n.plunger);
   }
   else if (stock)
   {
      const auto scale = Matrix3D::MatrixScale(width / stockWidth, length / stockLength, height / stockHeight);
      const auto worldFromStock = scale * m_cabWorld.m_toWorld;
      // Centre and extents of the button, three coin slots and plunger cap
      // in blankTable.vpz. GLB (right, up, front) becomes VPX (x, y, height).
      m_visionLayout.start = face(worldFromStock,
         { MTOVPU(0.03287f), MTOVPU(1.22739f), MTOVPU(0.80861f) },
         { MTOVPU(0.01267f), 0.f, MTOVPU(0.01268f) });
      m_visionLayout.coin = face(worldFromStock, stockCoinCenter, stockCoinHalfExtent);
      m_visionLayout.leftFlipper = flipper(worldFromStock, { MTOVPU(-0.03161f), MTOVPU(1.14771f), MTOVPU(0.86215f) });
      m_visionLayout.rightFlipper = flipper(worldFromStock, { MTOVPU(0.54406f), MTOVPU(1.14771f), MTOVPU(0.86215f) });
      plunger(worldFromStock, { MTOVPU(0.48053f), MTOVPU(1.28027f), MTOVPU(0.85304f) });
   }
   // Legacy cabinet controls use the same playfield space as their meshes.
   const Matrix3D worldFromLegacyCabinet = m_pfWorld.m_toWorld * m_visionPlayfieldLevel;
   const auto legacyBounds = [midX = (table->m_left + table->m_right) * 0.5f](Primitive* part, int side = 0)
      -> std::optional<std::pair<Vertex3Ds, Vertex3Ds>>
   {
      if (!part)
         return std::nullopt;
      const auto& playfieldFromMesh = part->RecalculateMatrices();
      Vertex3Ds low { FLT_MAX, FLT_MAX, FLT_MAX };
      Vertex3Ds high { -FLT_MAX, -FLT_MAX, -FLT_MAX };
      for (const auto& vertex : part->m_mesh.m_vertices)
      {
         const auto point = playfieldFromMesh * Vertex3Ds { vertex.x, vertex.y, vertex.z };
         if (side != 0 && (point.x - midX) * side <= 0.f)
            continue;
         low.Set(min(low.x, point.x), min(low.y, point.y), min(low.z, point.z));
         high.Set(max(high.x, point.x), max(high.y, point.y), max(high.z, point.z));
      }
      if (low.x == FLT_MAX)
         return std::nullopt;
      return std::pair { low, high };
   };
   const auto legacyButton = [&](Primitive* part)
   {
      const auto bounds = legacyBounds(part);
      if (!bounds)
         return VPINBALL_VISION_BUTTON_FACE{};
      const auto& [low, high] = *bounds;
      const auto center = (low + high) * 0.5f;
      return face(worldFromLegacyCabinet, { center.x, high.y, center.z },
         { (high.x - low.x) * 0.5f, 0.f, (high.z - low.z) * 0.5f });
   };
   const auto legacyFlipper = [&](Primitive* part, int side)
   {
      const auto bounds = legacyBounds(part, side);
      if (!bounds)
         return VPINBALL_VISION_POINT{};
      const auto& [low, high] = *bounds;
      const auto center = (low + high) * 0.5f;
      return flipper(worldFromLegacyCabinet, { side < 0 ? low.x : high.x, center.y, center.z });
   };
   if (timeMachineLegs)
   {
      // The separate cap in PinCab_Cabinet and the three slot faces in
      // PinCab_Metal_Coindoor, measured in the table's playfield units.
      m_visionLayout.start = face(worldFromLegacyCabinet, { 69.93f, 2093.54f, -119.37f }, { 25.13f, 0.f, 25.19f });
      m_visionLayout.coin = face(worldFromLegacyCabinet, { 491.4f, 2119.57f, -113.62f }, { 129.3f, 0.f, 29.54f });
      auto* buttons = getPrimitive("PinCab_Buttons");
      m_visionLayout.leftFlipper = legacyFlipper(buttons, -1);
      m_visionLayout.rightFlipper = legacyFlipper(buttons, 1);
      plunger(worldFromLegacyCabinet, { 946.8f, 2200.f, -14.6f });
   }
   else if (meteor)
   {
      m_visionLayout.start = legacyButton(getPrimitive("VR_Cab_StartButton"));
      m_visionLayout.leftFlipper = legacyFlipper(getPrimitive("VR_CabFlipperLeft"), -1);
      m_visionLayout.rightFlipper = legacyFlipper(getPrimitive("VR_CabFlipperRight"), 1);
      // Slot artwork mapped through the three UV panels of VR_Cab_Coindoor_Graphics.
      m_visionLayout.coin = face(worldFromLegacyCabinet, { 467.f, 2115.2f, -51.5f }, { 125.f, 0.f, 12.f });
      plunger(worldFromLegacyCabinet, { 893.f, 2164.f, 19.f });
   }
   else if (gorgar)
   {
      m_visionLayout.start = legacyButton(getPrimitive("PinCab_Button1i"));
      m_visionLayout.leftFlipper = legacyFlipper(getPrimitive("Primary_flipper_button_left"), -1);
      m_visionLayout.rightFlipper = legacyFlipper(getPrimitive("Primary_flipper_button_right"), 1);
      const auto worldFromDoor = Matrix3D::MatrixScale(gorgarCoinScale.x, gorgarCoinScale.y, gorgarCoinScale.z)
         * Matrix3D::MatrixTranslate(gorgarCoinOffset) * worldFromLegacyCabinet;
      m_visionLayout.coin = face(worldFromDoor, stockCoinCenter, stockCoinHalfExtent);
      plunger(worldFromLegacyCabinet, { 896.8f, 2199.f, -1.f });
   }
   PLOGI << "Vision Pro cabinet: " << (neutral ? "neutral" : stock ? "stock" : "authored")
      << ", playfield " << width << " x " << length << " m, placement height " << m_visionLayout.height << " m";
   if (stock && !neutral)
   {
      PLOGI << "Vision Pro stock playfield depth at lockbar: " << VPUTOCM(m_visionStockGlassDepth)
         << " cm (table glass depth " << VPUTOCM(table->m_glassBottomHeight) << " cm)";
   }
   const auto logFace = [](const char* name, const VPINBALL_VISION_BUTTON_FACE& button)
   {
      PLOGI << "Vision Pro " << name << " face: " << button.x << ", " << button.y << ", " << button.z
         << " m; half extents " << button.halfWidth << ", " << button.halfHeight << " m";
   };
   logFace("Start", m_visionLayout.start);
   logFace("coin", m_visionLayout.coin);
   const auto logFlipper = [](const char* side, const VPINBALL_VISION_POINT& cap)
   {
      PLOGI << "Vision Pro " << side << " flipper cap: " << cap.x << ", " << cap.y << ", " << cap.z << " m";
   };
   logFlipper("left", m_visionLayout.leftFlipper);
   logFlipper("right", m_visionLayout.rightFlipper);
   if (m_visionLayout.hasPlunger)
   {
      PLOGI << "Vision Pro plunger grip: " << m_visionLayout.plungerX << ", "
         << m_visionLayout.plungerY << ", " << m_visionLayout.plungerZ << " m";
   }
   if (m_visionLayout.hasLaunchButton)
      logFace("Launch Ball", m_visionLayout.launch);
}

void VRDevice::AddVisionStockGeometry(PinTable* table, bool cabinet, bool room, bool gorgarCoinDoor)
{
   if (!cabinet && !room && !gorgarCoinDoor)
      return;

   using enum PartGroupData::SpaceReference;
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
   const auto addMesh = [table, &assets](PartGroup* group, const char* name, const Material* mat, const Vertex3Ds& scale, const Vertex3Ds& position = { 0.f, 0.f, 0.f })
   {
      std::ifstream file(assets / (string(name) + ".glb"), std::ios::binary);
      vector<uint8_t> bytes((std::istreambuf_iterator<char>(file)), std::istreambuf_iterator<char>());
      auto* part = Primitive::COMCreate();
      part->Init(0.f, 0.f, false);
      if (!bytes.empty() && part->m_mesh.LoadGLB(bytes.data(), bytes.size()))
      {
         part->SetName(table->GetUniqueName("Vision" + string(name)));
         part->SetPartGroup(group);
         part->m_d.m_vPosition = position;
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
      auto* group = AddVisionPartGroup(table, "VisionRoom", SR_ROOM, PartGroupData::PMVM_VIRTUAL_REALITY);
      auto* floor = material("VisionRoomFloor", RGB(83, 91, 103), 0.9f);
      addMesh(group, "VRGround", floor, { 2.f, 2.f, 1.f });
   }
   constexpr unsigned int modes = PartGroupData::PMVM_MIXED_REALITY | PartGroupData::PMVM_VIRTUAL_REALITY;
   if (gorgarCoinDoor)
   {
      auto* group = AddVisionPartGroup(table, "VisionCoinDoor", SR_PLAYFIELD, modes);
      auto* metal = material("VisionCoinDoorMetal", RGB(93, 96, 104), 0.44f);
      addMesh(group, "VRCoinDoor", metal, gorgarCoinScale, gorgarCoinOffset);
   }
   if (!cabinet)
      return;

   auto* body = AddVisionPartGroup(table, "VisionCabinet", SR_CABINET, modes);
   auto* feet = AddVisionPartGroup(table, "VisionCabinetFeet", SR_CABINET_FEET, modes);
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

// The size of a directB2S's score view, its 'DMD' image, when that carries score digits as on
// alphanumeric machines like Bride of Pinbot. Zero when the file has no such section.
static std::pair<int, int> VisionB2SScoreView(const std::filesystem::path& path)
{
   std::ifstream file(path, std::ios::binary);
   const string text((std::istreambuf_iterator<char>(file)), std::istreambuf_iterator<char>());
   constexpr std::string_view imageTag = "<DMDImage Value=\"";
   const auto image = text.find(imageTag);
   if (image == string::npos || text.find("Parent=\"DMD\"") == string::npos)
      return { 0, 0 };
   // The PNG's IHDR width and height are bytes 16 to 23, the first 32 base64 characters.
   const std::string_view b64 = std::string_view(text).substr(image + imageTag.size(), 32);
   const auto value = [](char c) -> int
   {
      if (c >= 'A' && c <= 'Z') return c - 'A';
      if (c >= 'a' && c <= 'z') return c - 'a' + 26;
      if (c >= '0' && c <= '9') return c - '0' + 52;
      return c == '+' ? 62 : c == '/' ? 63 : -1;
   };
   if (b64.size() < 32)
      return { 0, 0 };
   uint8_t bytes[24];
   for (size_t i = 0; i < 8; ++i)
   {
      int quad[4];
      for (int k = 0; k < 4; ++k)
         if ((quad[k] = value(b64[i * 4 + k])) < 0)
            return { 0, 0 };
      bytes[i * 3] = static_cast<uint8_t>((quad[0] << 2) | (quad[1] >> 4));
      bytes[i * 3 + 1] = static_cast<uint8_t>(((quad[1] & 15) << 4) | (quad[2] >> 2));
      bytes[i * 3 + 2] = static_cast<uint8_t>(((quad[2] & 3) << 6) | quad[3]);
   }
   if (memcmp(bytes + 12, "IHDR", 4) != 0)
      return { 0, 0 };
   const auto be32 = [&bytes](int at) { return (bytes[at] << 24) | (bytes[at + 1] << 16) | (bytes[at + 2] << 8) | bytes[at + 3]; };
   return { be32(16), be32(20) };
}

bool VRDevice::AddVisionNeutralCabinet(PinTable* table)
{
   namespace VC = VisionCabinet;
   const auto fail = [](const string& reason)
   {
      PLOGW << "Vision Pro neutral cabinet not used, falling back to the stock cabinet: " << reason;
      return false;
   };
   const auto root = g_app->m_fileLocator.GetAppPath(FileLocator::AppSubFolder::Assets, "neutralCabinet");
   const auto readJson = [&root](const char* name)
   {
      std::ifstream file(root / name);
      return file ? nlohmann::json::parse(file, nullptr, false) : nlohmann::json(nlohmann::json::value_t::discarded);
   };
   VC::Spec spec;
   VC::Reference ref;
   VC::Controls controls;
   string error;
   if (!VC::LoadSpec(readJson("cabinet.json"), spec, error) || !VC::LoadReference(readJson("reference.json"), ref, error)
      || !VC::LoadControls(readJson("controls.json"), controls, error))
      return fail(error + " in " + PathToUTF8(root));

   // The add-cabinet tool's rules (fit.py choose_variant and glass.py choose) on the loaded table.
   vector<VC::PlungerInfo> plungers;
   std::unordered_set<string> usedSurfaces;
   for (auto* part : table->GetParts())
   {
      const string* surface = nullptr;
      switch (part->GetItemType())
      {
      case eItemPlunger:
      {
         const auto& d = static_cast<Plunger*>(part)->m_d;
         plungers.push_back({ part->GetName(), d.m_autoPlunger, d.m_visible, d.m_v.x });
         surface = &d.m_szSurface;
         break;
      }
      case eItemKicker: surface = &static_cast<Kicker*>(part)->m_d.m_szSurface; break;
      case eItemTrigger: surface = &static_cast<Trigger*>(part)->m_d.m_szSurface; break;
      case eItemFlipper: surface = &static_cast<Flipper*>(part)->m_d.m_szSurface; break;
      case eItemBumper: surface = &static_cast<Bumper*>(part)->m_d.m_szSurface; break;
      case eItemGate: surface = &static_cast<Gate*>(part)->m_d.m_szSurface; break;
      case eItemSpinner: surface = &static_cast<Spinner*>(part)->m_d.m_szSurface; break;
      case eItemLight: surface = &static_cast<Light*>(part)->m_d.m_szSurface; break;
      default: break;
      }
      if (surface && !surface->empty())
         usedSurfaces.insert(lowerCase(*surface));
   }
   string variantReason;
   const VC::Variant variant = VC::ChooseVariant(plungers, variantReason);
   Plunger* manualPlunger = nullptr;
   for (auto* part : table->GetParts())
      if (part->GetItemType() == eItemPlunger)
         if (auto* plunger = static_cast<Plunger*>(part); !manualPlunger && !plunger->m_d.m_autoPlunger && plunger->m_d.m_visible)
            manualPlunger = plunger;

   VC::GlassInput glassInput;
   glassInput.tableArea = (table->m_right - table->m_left) * (table->m_bottom - table->m_top);
   glassInput.legacy = table->m_loadedFileVersion < 1080;
   glassInput.glassTop = table->m_glassTopHeight;
   glassInput.glassBottom = table->m_glassBottomHeight;
   for (auto* part : table->GetParts())
   {
      const bool referenced = usedSurfaces.contains(lowerCase(part->GetName()));
      if (part->GetItemType() == eItemSurface && referenced)
      {
         const auto* wall = static_cast<Surface*>(part);
         vector<std::array<double, 2>> points;
         for (const auto& point : wall->m_curve.GetPoints())
            points.push_back({ point->GetX(), point->GetY() });
         glassInput.referencedWalls.push_back({ part->GetName(), wall->m_d.m_heighttop, VC::PolygonArea(points) });
      }
      else if (part->GetItemType() == eItemRamp)
      {
         const auto& d = static_cast<Ramp*>(part)->m_d;
         const double top = max(d.m_heighttop, d.m_heightbottom);
         if (referenced)
            glassInput.reach.emplace_back(top, part->GetName());
         if (d.m_collidable)
            glassInput.reach.emplace_back(top, part->GetName());
      }
      else if (part->GetItemType() == eItemPrimitive)
      {
         auto* prim = static_cast<Primitive*>(part);
         if (prim->m_d.m_collidable && !prim->m_d.m_toy && prim->m_d.m_use3DMesh && !prim->m_mesh.m_vertices.empty()
            && lowerCase(part->GetName() + ' ' + prim->m_d.m_szImage).find("ramp") != string::npos)
         {
            const Matrix3D& playfieldFromMesh = prim->RecalculateMatrices();
            float top = -FLT_MAX;
            for (const auto& vertex : prim->m_mesh.m_vertices)
               top = max(top, (playfieldFromMesh * Vertex3Ds { vertex.x, vertex.y, vertex.z }).z);
            glassInput.reach.emplace_back(top, part->GetName());
         }
      }
   }
   const VC::GlassChoice glass = VC::ChooseGlass(glassInput, 8.0);

   VC::Table fitTable;
   fitTable.left = table->m_left;
   fitTable.top = table->m_top;
   fitTable.right = table->m_right;
   fitTable.bottom = table->m_bottom;
   fitTable.glassTop = glass.newTop;
   fitTable.glassBottom = glass.newBottom;
   // The playfield is drawn at the live slope, so fit to it rather than the authored one.
   fitTable.slope = table->GetPlayfieldSlope();
   fitTable.groundToLockbar = table->m_groundToLockbarHeight;
   fitTable.plungerX = VC::PlungerX(plungers);
   const VC::Fit fit(ref, spec, fitTable, false);
   if (!fit.Error().empty())
      return fail(fit.Error());

   // Load and fit every mesh before anything is added to the table.
   struct LoadedPart
   {
      const VC::PartSpec* spec;
      Primitive* primitive;
      VC::Point rigidOffset;
   };
   vector<LoadedPart> parts;
   const auto releaseParts = [&parts]
   {
      for (auto& part : parts)
         part.primitive->Release();
      parts.clear();
   };
   size_t triangles = 0;
   for (const auto& partSpec : spec.parts)
   {
      if (!partSpec.InVariant(variant))
         continue;
      std::ifstream file(root / "meshes" / (partSpec.mesh + ".glb"), std::ios::binary);
      const vector<uint8_t> bytes((std::istreambuf_iterator<char>(file)), std::istreambuf_iterator<char>());
      auto* part = Primitive::COMCreate();
      part->Init(0.f, 0.f, false);
      if (bytes.empty() || !part->m_mesh.LoadGLB(bytes.data(), bytes.size()) || part->m_mesh.m_vertices.empty())
      {
         part->Release();
         releaseParts();
         return fail("could not load the mesh " + partSpec.mesh);
      }
      vector<VC::Point> vertices;
      vertices.reserve(part->m_mesh.m_vertices.size());
      for (const auto& v : part->m_mesh.m_vertices)
         vertices.push_back({ v.x, v.y, v.z });
      // The tool keeps the stored normals: the field shear is a few degrees at most.
      const VC::Point offset = VC::FitVertices(fit, partSpec, vertices);
      for (size_t i = 0; i < vertices.size(); ++i)
      {
         auto& v = part->m_mesh.m_vertices[i];
         v.x = static_cast<float>(vertices[i][0]);
         v.y = static_cast<float>(vertices[i][1]);
         v.z = static_cast<float>(vertices[i][2]);
      }
      part->m_mesh.UpdateBounds();
      triangles += part->m_mesh.NumIndices() / 3;
      parts.push_back({ &partSpec, part, offset });
   }

   // Both flipper buttons are one mesh. Split it at the playfield centre so
   // each button can be pushed in on its own.
   VC::PartSpec leftButtonSpec, rightButtonSpec;
   if (const auto buttons = std::ranges::find_if(parts, [](const LoadedPart& p) { return p.spec->name == "FlipperButtons"; });
       buttons != parts.end())
   {
      leftButtonSpec = *buttons->spec;
      leftButtonSpec.name = "FlipperButtonLeft";
      rightButtonSpec = *buttons->spec;
      rightButtonSpec.name = "FlipperButtonRight";
      const float midX = (table->m_left + table->m_right) * 0.5f;
      const Mesh& both = buttons->primitive->m_mesh;
      auto* right = Primitive::COMCreate();
      right->Init(0.f, 0.f, false);
      Mesh left;
      right->m_mesh.m_vertices.clear();
      right->m_mesh.m_indices.clear();
      vector<int> remap[2] { vector<int>(both.m_vertices.size(), -1), vector<int>(both.m_vertices.size(), -1) };
      for (size_t i = 0; i + 2 < both.m_indices.size(); i += 3)
      {
         const unsigned int* tri = &both.m_indices[i];
         const bool isRight = both.m_vertices[tri[0]].x + both.m_vertices[tri[1]].x + both.m_vertices[tri[2]].x > midX * 3.f;
         Mesh& mesh = isRight ? right->m_mesh : left;
         for (int k = 0; k < 3; ++k)
         {
            int& index = remap[isRight][tri[k]];
            if (index < 0)
            {
               index = static_cast<int>(mesh.m_vertices.size());
               mesh.m_vertices.push_back(both.m_vertices[tri[k]]);
            }
            mesh.m_indices.push_back(static_cast<unsigned int>(index));
         }
      }
      if (!left.m_indices.empty() && !right->m_mesh.m_indices.empty())
      {
         buttons->primitive->m_mesh.m_vertices = std::move(left.m_vertices);
         buttons->primitive->m_mesh.m_indices = std::move(left.m_indices);
         buttons->primitive->m_mesh.UpdateBounds();
         right->m_mesh.UpdateBounds();
         buttons->spec = &leftButtonSpec;
         parts.push_back({ &rightButtonSpec, right, {} });
      }
      else
         right->Release();
   }

   // Inner walls under the rails and lockbar, two triangles per quad facing inward.
   auto* walls = Primitive::COMCreate();
   walls->Init(0.f, 0.f, false);
   walls->m_mesh.m_vertices.clear(); // Init builds the default prism
   walls->m_mesh.m_indices.clear();
   for (const auto& quad : fit.InnerWalls())
   {
      const auto& [a, b, c, d] = quad.corners;
      const VC::Point u { b[0] - a[0], b[1] - a[1], b[2] - a[2] };
      const VC::Point w { c[0] - a[0], c[1] - a[1], c[2] - a[2] };
      const double facing = (u[1] * w[2] - u[2] * w[1]) * quad.normal[0] + (u[2] * w[0] - u[0] * w[2]) * quad.normal[1]
         + (u[0] * w[1] - u[1] * w[0]) * quad.normal[2];
      const auto base = static_cast<unsigned int>(walls->m_mesh.m_vertices.size());
      constexpr float uv[4][2] { { 0.f, 0.f }, { 1.f, 0.f }, { 1.f, 1.f }, { 0.f, 1.f } };
      for (int k = 0; k < 4; ++k)
      {
         Vertex3D_NoTex2 v;
         v.x = static_cast<float>(quad.corners[k][0]);
         v.y = static_cast<float>(quad.corners[k][1]);
         v.z = static_cast<float>(quad.corners[k][2]);
         v.nx = static_cast<float>(quad.normal[0]);
         v.ny = static_cast<float>(quad.normal[1]);
         v.nz = static_cast<float>(quad.normal[2]);
         v.tu = uv[k][0];
         v.tv = uv[k][1];
         walls->m_mesh.m_vertices.push_back(v);
      }
      const unsigned int order[2][6] { { 0, 1, 2, 0, 2, 3 }, { 0, 2, 1, 0, 3, 2 } };
      for (const unsigned int i : order[facing < 0 ? 1 : 0])
         walls->m_mesh.m_indices.push_back(base + i);
   }
   walls->m_mesh.UpdateBounds();
   triangles += walls->m_mesh.NumIndices() / 3;
   const VC::PartSpec wallSpec { "InnerWalls", "", "VRCab_Interior", "" };
   parts.push_back({ &wallSpec, walls, {} });
   if (std::ranges::none_of(spec.materials, [](const VC::MaterialSpec& m) { return m.name == "VRCab_Interior"; }))
   {
      releaseParts();
      return fail("cabinet.json has no VRCab_Interior material");
   }

   // Images, then everything else: none of these can fail once the images are in.
   std::unordered_map<string, string> imageNames;
   vector<Texture*> addedImages;
   for (const auto& [name, file] : spec.images)
   {
      if (std::ranges::none_of(parts, [&name](const LoadedPart& p) { return p.spec->image == name; }))
         continue;
      string unique = name;
      for (int suffix = 1; table->GetImage(unique); ++suffix)
         unique = name + std::to_string(suffix);
      Texture* image = table->ImportImage(root / "textures" / file, unique);
      if (!image)
      {
         for (auto* added : addedImages)
            table->RemoveImage(added);
         releaseParts();
         return fail("could not load the texture " + file);
      }
      addedImages.push_back(image);
      imageNames[name] = image->m_name;
   }

   table->m_glassTopHeight = static_cast<float>(glass.newTop);
   table->m_glassBottomHeight = static_cast<float>(glass.newBottom);

   std::unordered_map<string, string> materialNames;
   for (const auto& m : spec.materials)
   {
      if (std::ranges::none_of(parts, [&m](const LoadedPart& p) { return p.spec->material == m.name; }))
         continue;
      const auto color = [](unsigned int c) { return static_cast<COLORREF>(RGB((c >> 16) & 0xFF, (c >> 8) & 0xFF, c & 0xFF)); };
      auto* mat = new Material(m.metal ? Material::METAL : Material::BASIC, m.wrapLighting, m.roughness, m.glossyImageLerp, m.thickness,
         m.edge, m.edgeAlpha, m.opacity, color(m.baseColor), color(m.glossyColor), color(m.clearcoatColor), m.opacityActive,
         0.f, 0.f, 0.f, 0.f, RGB(255, 255, 255));
      mat->m_name = m.name;
      table->AddMaterial(mat); // adds a suffix if the table already has the name
      materialNames[m.name] = mat->m_name;
   }

   using enum PartGroupData::SpaceReference;
   constexpr unsigned int modes = PartGroupData::PMVM_MIXED_REALITY | PartGroupData::PMVM_VIRTUAL_REALITY;
   auto* body = AddVisionPartGroup(table, "VRCab_Cabinet", SR_CABINET, modes);
   auto* feet = AddVisionPartGroup(table, "VRCab_Feet", SR_CABINET_FEET, modes);
   std::unordered_map<string, VC::Point> rigidOffsets;
   auto& n = m_visionNeutral;
   n = {};
   // A few millimetres of button travel, as on the real switches.
   const float buttonTravel = MTOVPU(0.004f);
   const float flipperButtonTravel = MTOVPU(0.005f);
   const std::unordered_map<std::string_view, std::pair<VisionNeutralCabinet::Moving*, Vertex3Ds>> moving {
      { "FlipperButtonLeft", { &n.leftFlipperButton, { flipperButtonTravel, 0.f, 0.f } } },
      { "FlipperButtonRight", { &n.rightFlipperButton, { -flipperButtonTravel, 0.f, 0.f } } },
      { "StartButton", { &n.startButton, { 0.f, -buttonTravel, 0.f } } },
      { "CoinInserts", { &n.coinInserts, { 0.f, -buttonTravel, 0.f } } },
      { "LaunchButton", { &n.launchCap, { 0.f, -buttonTravel, 0.f } } },
      // The knob comes toward the player. UpdateVisionNeutralControls sets the length.
      { "Plunger", { &n.knob, { 0.f, 1.f, 0.f } } },
   };
   for (auto& [partSpec, part, offset] : parts)
   {
      part->SetName(table->GetUniqueName("VRCab_" + partSpec->name));
      part->SetPartGroup(partSpec->feet ? feet : body);
      part->m_d.m_vPosition = { 0.f, 0.f, 0.f };
      part->m_d.m_vSize = { 1.f, 1.f, 1.f };
      std::fill(std::begin(part->m_d.m_aRotAndTra), std::end(part->m_d.m_aRotAndTra), 0.f);
      part->m_d.m_szMaterial = materialNames[partSpec->material];
      part->m_d.m_szImage = partSpec->image.empty() ? string() : imageNames[partSpec->image];
      part->m_d.m_use3DMesh = true;
      part->m_d.m_visible = true;
      part->m_d.m_collidable = false;
      part->m_d.m_toy = true;
      part->m_d.m_staticRendering = true;
      part->m_d.m_reflectionEnabled = false;
      part->m_d.m_backfacesEnabled = false;
      part->m_d.m_disableLightingTop = 0.f;
      part->m_d.m_disableLightingBelow = 1.f;
      if (const auto it = moving.find(partSpec->name); it != moving.end())
      {
         // Moving parts are drawn every frame rather than baked into the static pass.
         part->m_d.m_staticRendering = false;
         *it->second.first = { part, it->second.second };
      }
      if (partSpec->name == "CoinInserts")
      {
         // Lit coin inserts, like the glowing reject buttons on Meteor's coin door art.
         part->m_d.m_disableLightingTop = 1.f;
      }
      table->AddPart(part);
      part->Release();
      rigidOffsets[partSpec->name] = offset;
   }

   // Fit the control anchors with their meshes.
   const auto anchor = [&](const VC::ButtonAnchor& a)
   {
      const auto it = std::ranges::find_if(spec.parts, [&a](const VC::PartSpec& p) { return p.name == a.part; });
      const VC::Point p = it == spec.parts.end() ? a.point : VC::FitPoint(fit, *it, rigidOffsets[a.part], a.point);
      return Vertex3Ds { static_cast<float>(p[0]), static_cast<float>(p[1]), static_cast<float>(p[2]) };
   };
   const auto half = [](const VC::ButtonAnchor& a) { return Vertex3Ds { static_cast<float>(a.half[0]), 0.f, static_cast<float>(a.half[1]) }; };
   n.active = true;
   n.launchButton = variant == VC::Variant::LaunchButton;
   n.tablePlunger = n.launchButton ? nullptr : manualPlunger;
   n.fitSlope = table->GetPlayfieldSlope();
   n.start = anchor(controls.start);
   n.startHalf = half(controls.start);
   n.coin = anchor(controls.coin);
   n.coinHalf = half(controls.coin);
   n.leftFlipper = anchor(controls.leftFlipper);
   n.rightFlipper = anchor(controls.rightFlipper);
   n.plunger = anchor(controls.plunger);
   n.launch = anchor(controls.launch);
   n.launchHalf = half(controls.launch);

   // Backglass in the smoked glass and DMD in the speaker panel's window, both following the head fit.
   auto companion = table->m_filename;
   companion.replace_extension(".directb2s");
   const bool backglass = !find_case_insensitive_file_path(companion).empty();
   // The translite leans back slightly. Each display stands just in front of it at its own height.
   const auto frontY = [&controls](double z)
   {
      const double t = (z - controls.transliteZ[0]) / max(controls.transliteZ[1] - controls.transliteZ[0], 1.0);
      return controls.transliteFrontYBottom + (controls.transliteFrontYTop - controls.transliteFrontYBottom) * t + 3.0;
   };
   // An alphanumeric machine's directB2S puts its score digits in a score view. That goes in the
   // panel's window in place of the DMD.
   const auto [scoreViewWidth, scoreViewHeight] = backglass ? VisionB2SScoreView(find_case_insensitive_file_path(companion)) : std::pair { 0, 0 };
   const bool scoreView = scoreViewWidth > 0 && scoreViewHeight > 0;
   enum class Display { Backglass, Dmd, ScoreView };
   const auto addDisplay = [&](const std::array<double, 2>& xs, const std::array<double, 2>& zs, Display kind, double& width, double& height)
   {
      const bool dmd = kind == Display::Dmd;
      const double y = frontY((zs[0] + zs[1]) * 0.5);
      const VC::Point low = fit.MapHead({ xs[0], y, zs[0] });
      const VC::Point high = fit.MapHead({ xs[1], y, zs[1] });
      const double regionWidth = high[0] - low[0], regionHeight = high[2] - low[2];
      if (dmd)
      {
         // A 128 x 32 DMD is about 35 x 9 cm. The window is painted 37.5 x 10 cm around it.
         width = std::min(regionWidth * (35.0 / 37.5), regionHeight * 0.875 * 4.0);
         height = width / 4.0;
      }
      else if (kind == Display::ScoreView)
      {
         const double aspect = static_cast<double>(scoreViewWidth) / scoreViewHeight;
         width = std::min(regionWidth * 0.95, regionHeight * 0.92 * aspect);
         height = width / aspect;
      }
      else
      {
         width = regionWidth * 0.95;
         height = regionHeight * 0.95;
      }
      auto* display = Flasher::COMCreate();
      display->Init(static_cast<float>((low[0] + high[0]) * 0.5), static_cast<float>((low[1] + high[1]) * 0.5), false);
      display->SetName(table->GetUniqueName(dmd ? "VisionCabinetDMD" : kind == Display::ScoreView ? "VisionCabinetScoreView" : "VisionCabinetBackglass"));
      display->SetPartGroup(body);
      display->m_d.m_renderMode = dmd ? FlasherData::DMD : FlasherData::EXT_RENDER;
      display->m_d.m_renderStyle = dmd ? 0 : kind == Display::ScoreView ? VPXWINDOW_ScoreView : VPXWINDOW_Backglass;
      // The default DMD profile uses the legacy renderer, which tints the dots with the flasher color.
      // Neon plasma orange-red instead of the editor's green flasher default, a little over full
      // intensity since the legacy shader's dot falloff darkens it.
      display->m_d.m_color = RGB(255, 36, 6);
      display->m_d.m_intensity_scale = dmd ? 1.25f : 1.f;
      display->m_d.m_height = static_cast<float>((low[2] + high[2]) * 0.5);
      display->m_d.m_rotX = -90.f;
      display->Scale(static_cast<float>(width / 100.0), static_cast<float>(height / 100.0), {}, true);
      table->AddPart(display);
      display->Release();
   };
   double backglassWidth = 0, backglassHeight = 0, dmdWidth = 0, dmdHeight = 0;
   if (backglass)
      addDisplay(controls.glassX, controls.glassZ, Display::Backglass, backglassWidth, backglassHeight);
   // Segment and EM tables without a score view have no DMD source, so the window stays dark and
   // their scores show on the backglass.
   addDisplay(controls.windowX, controls.windowZ, scoreView ? Display::ScoreView : Display::Dmd, dmdWidth, dmdHeight);
   PLOGI << "Vision Pro neutral cabinet displays: " << (backglass ? "backglass " : "no backglass") << (backglass ? std::to_string(VPUTOCM(static_cast<float>(backglassWidth))) + " x " + std::to_string(VPUTOCM(static_cast<float>(backglassHeight))) + " cm" : string())
         << (scoreView ? ", directB2S score view (" + std::to_string(scoreViewWidth) + " x " + std::to_string(scoreViewHeight) + ") " : string(", DMD ")) << VPUTOCM(static_cast<float>(dmdWidth)) << " x " << VPUTOCM(static_cast<float>(dmdHeight)) << " cm in the speaker panel";
   n.dmdLogged = scoreView; // the score view is drawn by the backglass plugin, not from a DMD source

   PLOGI << "Vision Pro neutral cabinet: " << (n.launchButton ? "launch button" : "plunger") << " (" << variantReason << "), "
         << parts.size() << " parts, " << triangles << " triangles, " << addedImages.size() << " textures";
   PLOGI << "Vision Pro neutral cabinet glass at the lockbar: " << glassInput.glassBottom << " -> " << glass.height << " VPU ("
         << VPUTOCM(static_cast<float>(glass.height)) << " cm" << (glass.limitedBy.empty() ? "" : ", kept above " + glass.limitedBy)
         << (glass.mainSurfaceName.empty() ? "" : ", from the raised playfield " + glass.mainSurfaceName) << "), file version "
         << table->m_loadedFileVersion << ", top " << glass.newTop << ", bottom " << glass.newBottom;
   PLOGI << "Vision Pro neutral cabinet fit: playfield " << fitTable.Width() << " x " << fitTable.Length() << " VPU, slope " << fitTable.slope
         << " deg (authored " << lerp(table->m_angletiltMin, table->m_angletiltMax, table->m_difficulty) << "), rail slope "
         << RADTOANG(static_cast<float>(atan(fit.railSlope))) << " deg, plunger x " << fit.plungerX << ", lockbar " << fit.lockbarZ << " VPU, rail above playfield "
         << fit.RailTopZ(fit.yFront) - fit.PlayfieldZ(fit.yFront) << " / " << fit.RailTopZ(fit.yBack) - fit.PlayfieldZ(fit.yBack) << " VPU";
   return true;
}

void VRDevice::UpdateVisionNeutralControls()
{
   auto& n = m_visionNeutral;
   if (!n.active || !g_pplayer)
      return;
   const auto& input = g_pplayer->m_pininput;
   const auto push = [](const VisionNeutralCabinet::Moving& control, float amount)
   {
      if (control.part)
         control.part->m_d.m_vPosition = control.travel * amount;
   };
   const auto pressed = [&input](unsigned int action) { return input.IsPressed(action) ? 1.f : 0.f; };
   push(n.leftFlipperButton, pressed(input.GetLeftFlipperActionId()));
   push(n.rightFlipperButton, pressed(input.GetRightFlipperActionId()));
   push(n.startButton, pressed(input.GetStartActionId()));
   push(n.coinInserts, max(pressed(input.GetAddCreditActionId(0)), pressed(input.GetAddCreditActionId(1))));
   push(n.launchCap, pressed(input.GetLaunchBallActionId()));
   if (n.knob.part && n.tablePlunger)
   {
      // Follow the table's rod, so the knob comes out with the hand and springs
      // back with the plunger's own physics. A full pull matches the 6 cm the
      // hand controls take for a full pull, in real-world size.
      push(n.knob, n.tablePlunger->GetPullFromRest() * MTOVPU(0.06f) / max(m_scale, 0.1f));
   }
   if (!n.dmdLogged && (++n.dmdProbe % 60) == 0)
   {
      const auto dmd = g_pplayer->m_resURIResolver.GetDisplayState(PinballPlugin::ResURIResolver::DefaultDmdUri);
      if (dmd.state.frame != nullptr)
      {
         n.dmdLogged = true;
         PLOGI << "Vision Pro cabinet DMD source: " << dmd.source->width << " x " << dmd.source->height << ", format " << dmd.source->frameFormat
               << ", first seen after " << n.dmdProbe << " frames";
      }
      else if (n.dmdProbe == 60 * 5)
      {
         const auto any = g_pplayer->m_resURIResolver.GetDisplayState("ctrl://default/display");
         PLOGI << "Vision Pro cabinet DMD source: none yet. Any display: " << (any.state.frame ? std::to_string(any.source->width) + " x " + std::to_string(any.source->height) + ", hardware " + std::to_string(any.source->hardware) : string("none"))
               << ". Sources:\n" << g_pplayer->m_resURIResolver.DumpDisplaySources();
      }
      else if (n.dmdProbe >= 60 * 30)
      {
         n.dmdLogged = true;
         PLOGI << "Vision Pro cabinet DMD source: none after " << n.dmdProbe << " frames, so the panel DMD stays dark";
      }
   }
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
   UpdateVisionNeutralControls();
   m_predictedDisplayTimestamp = static_cast<float>(usec() / 1e6) + frame.secondsUntilPresentation;
   const bool rendered = submit(target.get());
   m_visionHost.endFrame(m_visionHost.user, rendered);
   if (rendered && ++m_visionFrameCount == 300)
   {
      // BGFX's own totals once the table's passes have all run, with the eye pictures included.
      const bgfx::Stats* stats = bgfx::getStats();
      PLOGI << "Vision Pro GPU memory after 300 frames: render targets " << stats->rtMemoryUsed / (1024 * 1024) << " MB, textures "
            << stats->textureMemoryUsed / (1024 * 1024) << " MB, " << stats->numTextures << " textures, " << stats->numFrameBuffers << " framebuffers, "
            << os_proc_available_memory() / (1024 * 1024) << " MB available to the app";
   }
}

void VRDevice::ReleaseVisionTarget()
{
   for (auto& target : m_visionTargets)
      target.reset();
}
