// license:GPLv3+

#include "core/stdafx.h"

#include "core/extern.h"
#include "core/player.h"
#include "input/PlungerHandler.h"
#include "parts/pintable.h"
#include "parts/plunger.h"
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
      return { 0.53975f, 1.0309225f, 0.91f, 0.24f, -0.095f, 0.040f, 0 };
   return g_pplayer->m_vrDevice->GetVisionLayout();
}

VPINBALLAPI void VPinballVisionSetButton(VPINBALL_VISION_INPUT button, int pressed)
{
   if (SDL_IsMainThread() && button >= 0 && button < VPINBALL_VISION_INPUT_COUNT)
      VPinballLib::VPinballLib::Instance().SetVisionButton(button, pressed != 0);
}

VPINBALLAPI void VPinballVisionSetPlunger(VPINBALL_VISION_PLUNGER_ACTION action, float pull)
{
   if (!SDL_IsMainThread() || !g_pplayer || !std::isfinite(pull))
      return;

   auto& handler = *g_pplayer->m_pininput.m_plungerHandler;
   if (action == VPINBALL_VISION_PLUNGER_HOLD)
   {
      handler.SetExternalPlunger(true, 0.f, clamp(pull, 0.f, 1.f));
      return;
   }

   if (action != VPINBALL_VISION_PLUNGER_RELEASE && action != VPINBALL_VISION_PLUNGER_CANCEL)
      return;

   handler.SetExternalPlunger(false, 0.f, 0.f);
   for (IEditable* const part : g_pplayer->m_ptable->GetParts())
      if (part && part->GetItemType() == eItemPlunger)
         static_cast<Plunger*>(part)->ReleaseMechanicalPull(action == VPINBALL_VISION_PLUNGER_RELEASE ? pull : 0.f);
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
      input.GetAddCreditActionId(0), input.GetStartActionId()
   };
   unsigned int pressed = 0;
   for (unsigned int button = 0; button < VPINBALL_VISION_INPUT_COUNT; ++button)
      if (input.IsPressed(actions[button]))
         pressed |= 1u << button;
   return pressed;
}

VPINBALLAPI float VPinballVisionPlungerPosition(void)
{
   return SDL_IsMainThread() && g_pplayer ? g_pplayer->m_pininput.m_plungerHandler->GetRawPosition() : 0.f;
}
#endif
