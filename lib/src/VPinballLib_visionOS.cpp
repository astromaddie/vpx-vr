// license:GPLv3+

#include "core/stdafx.h"

#include "core/extern.h"
#include "core/player.h"
#include "input/PlungerHandler.h"
#include "parts/ball.h"
#include "parts/pintable.h"
#include "parts/plunger.h"
#include "physics/cabinet/NudgeHandler.h"
#include "renderer/VRDevice.h"
#include "pinmame/libpinmame.h"
#include "VPinballLib.h"
#include "../include/vpinball/VPinballVision.h"

#define SDL_MAIN_HANDLED
#include <SDL3/SDL_main.h>

static VPINBALL_VISION_HOST visionHost{};

const VPINBALL_VISION_HOST& VPinballLib::GetVisionHost() { return visionHost; }

VPINBALLAPI VPINBALL_STATUS VPinballVisionConfigure(const VPINBALL_VISION_HOST* host)
{
   if (!host || !host->metalDevice || !host->metalQueue || !host->color[0] || !host->color[1] || !host->depth[0] || !host->depth[1]
      || !host->beginFrame || !host->endFrame || host->width == 0 || host->height == 0
      || host->width > UINT16_MAX || host->height > UINT16_MAX || g_pplayer)
      return VPINBALL_STATUS_FAILURE;

   visionHost = *host;
   return VPINBALL_STATUS_SUCCESS;
}

VPINBALLAPI VPINBALL_STATUS VPinballVisionInit(VPinballEventCallback eventCallback)
{
   if (eventCallback == nullptr)
      return VPINBALL_STATUS_FAILURE;

   SDL_SetMainReady();
   if (!SDL_IsMainThread())
      return VPINBALL_STATUS_FAILURE;

   static bool initialized = false;
   if (initialized)
      return VPINBALL_STATUS_SUCCESS;

   auto& lib = VPinballLib::VPinballLib::Instance();
   if (!lib.AppInit(0, nullptr))
      return VPINBALL_STATUS_FAILURE;
   initialized = true;
   lib.Init(eventCallback, nullptr);
   return VPINBALL_STATUS_SUCCESS;
}

VPINBALLAPI void VPinballVisionTick(void)
{
   if (!SDL_IsMainThread())
      return;

   auto& lib = VPinballLib::VPinballLib::Instance();
   SDL_Event event;
   while (SDL_PollEvent(&event))
      lib.AppEvent(&event);
   lib.AppIterate();
}

VPINBALLAPI VPINBALL_VISION_LAYOUT VPinballVisionGetLayout(void)
{
   if (!SDL_IsMainThread() || !g_pplayer || !g_pplayer->m_vrDevice)
      return {};
   return g_pplayer->m_vrDevice->GetVisionLayout();
}

VPINBALLAPI void VPinballVisionSetButton(VPINBALL_VISION_INPUT button, int pressed)
{
   if (!SDL_IsMainThread() || button < 0 || button >= VPINBALL_VISION_INPUT_COUNT)
      return;
   if (button == VPINBALL_VISION_NUDGE_BACK)
   {
      // VPX has digital actions for left, right and forward. A backward
      // gesture goes through the same cabinet model and simulated tilt.
      if (pressed && g_pplayer && g_pplayer->IsPlaying(false))
         g_pplayer->m_pininput.m_nudgeHandler->ApplyKeyboardImpulse(180.f, 2.f);
      return;
   }
   VPinballLib::VPinballLib::Instance().SetVisionButton(button, pressed != 0);
}

VPINBALLAPI int VPinballVisionSetPlunger(VPINBALL_VISION_PLUNGER_ACTION action, float pull)
{
   if (!SDL_IsMainThread() || !g_pplayer || !std::isfinite(pull))
      return 0;

   auto& handler = *g_pplayer->m_pininput.m_plungerHandler;
   if (action == VPINBALL_VISION_PLUNGER_HOLD)
   {
      handler.SetExternalPlunger(true, 0.f, clamp(pull, 0.f, 1.f));
      return 0;
   }

   if (action != VPINBALL_VISION_PLUNGER_RELEASE && action != VPINBALL_VISION_PLUNGER_CANCEL)
      return 0;

   if (action == VPINBALL_VISION_PLUNGER_RELEASE)
   {
      PLOGI << "Vision Pro plunger released at " << clamp(pull, 0.f, 1.f) * 100.f << "% pull";
   }
   else if (const float held = handler.GetRawPosition(); held > 0.04f)
   {
      PLOGI << "Vision Pro plunger grip cancelled at " << held * 100.f << "% pull";
   }
   handler.SetExternalPlunger(false, 0.f, 0.f);
   bool mechanical = false;
   for (IEditable* const part : g_pplayer->m_ptable->GetParts())
      if (part && part->GetItemType() == eItemPlunger)
         mechanical |= static_cast<Plunger*>(part)->ReleaseMechanicalPull(action == VPINBALL_VISION_PLUNGER_RELEASE ? pull : 0.f);
   return action == VPINBALL_VISION_PLUNGER_RELEASE && pull > 0.f && !mechanical;
}

#if defined(TARGET_OS_SIMULATOR) && TARGET_OS_SIMULATOR
VPINBALLAPI int VPinballVisionRomRunning(void)
{
   return SDL_IsMainThread() && g_pplayer && PinmameIsRunning() == 1;
}

VPINBALLAPI unsigned int VPinballVisionPressedButtons(void)
{
   if (!SDL_IsMainThread() || !g_pplayer)
      return 0;

   const auto& input = g_pplayer->m_pininput;
   const unsigned int actions[] = {
      input.GetLeftFlipperActionId(), input.GetRightFlipperActionId(),
      input.GetAddCreditActionId(0), input.GetStartActionId(),
      input.GetLeftNudgeActionId(), input.GetRightNudgeActionId(), input.GetCenterNudgeActionId()
   };
   unsigned int pressed = input.IsPressed(input.GetLaunchBallActionId()) ? 1u << VPINBALL_VISION_LAUNCH_BALL : 0;
   for (unsigned int button = 0; button < std::size(actions); ++button)
      if (input.IsPressed(actions[button]))
         pressed |= 1u << button;
   return pressed;
}

VPINBALLAPI int VPinballVisionNudgeCount(void)
{
   return SDL_IsMainThread() && g_pplayer ? g_pplayer->m_pininput.m_nudgeHandler->GetKeyboardNudgeIndex() : 0;
}

VPINBALLAPI float VPinballVisionPlungerPosition(void)
{
   return SDL_IsMainThread() && g_pplayer ? g_pplayer->m_pininput.m_plungerHandler->GetRawPosition() : 0.f;
}

VPINBALLAPI VPINBALL_VISION_BALL_SAMPLE VPinballVisionSampleBall(int ballId, const char* shooterName)
{
   if (!SDL_IsMainThread() || !g_pplayer)
      return { -1, 0.f, 0.f };

   std::optional<Vertex2D> shooter;
   if (ballId < 0 && shooterName)
      for (const auto* part : g_pplayer->m_ptable->GetParts())
         if (StrCompareNoCase(part->GetName(), shooterName))
         {
            shooter = part->GetCenter();
            break;
         }

   for (auto* ball : g_pplayer->m_vball)
   {
      int id;
      ball->get_ID(&id);
      const auto& position = ball->GetPosition();
      if (ballId >= 0)
      {
         if (id == ballId)
            return { id, position.y, ball->GetVelocity().y };
         continue;
      }
      if (shooterName)
      {
         if (shooter && abs(position.x - shooter->x) <= 45.f && abs(position.y - shooter->y) <= 140.f)
            return { id, position.y, ball->GetVelocity().y };
         continue;
      }
      for (const auto* part : g_pplayer->m_ptable->GetParts())
         if (part->GetItemType() == eItemPlunger)
         {
            const auto& plunger = static_cast<const Plunger*>(part)->m_d;
            if (plunger.m_mechPlunger && !plunger.m_autoPlunger
                && abs(position.x - plunger.m_v.x) <= plunger.m_width
                && position.y <= plunger.m_v.y && position.y >= plunger.m_v.y - 200.f)
               return { id, position.y, ball->GetVelocity().y };
         }
   }
   if (ballId < 0 && shooterName)
   {
      PLOGI << "Simulator found no ball at " << shooterName << ", shooter found=" << shooter.has_value()
         << ", switch 18=" << PinmameGetSwitch(18) << ", active balls=" << g_pplayer->m_vball.size();
      for (auto* ball : g_pplayer->m_vball)
      {
         const auto& pos = ball->GetPosition();
         PLOGI << "Simulator ball position: " << pos.x << ", " << pos.y << ", " << pos.z;
      }
   }
   return { -1, 0.f, 0.f };
}
#endif
