// license:GPLv3+

#include "core/stdafx.h"

#include "core/extern.h"
#include "core/player.h"
#include "input/PlungerHandler.h"
#include "parts/pintable.h"
#include "parts/plunger.h"
#include "VPinballLib.h"
#include "../include/vpinball/VPinballVision.h"

#define SDL_MAIN_HANDLED
#include <SDL3/SDL_main.h>

static VPINBALL_VISION_HOST visionHost{};

const VPINBALL_VISION_HOST& VPinballLib::GetVisionHost() { return visionHost; }

VPINBALLAPI VPINBALL_STATUS VPinballVisionConfigure(const VPINBALL_VISION_HOST* host)
{
   if (!host || !host->metalDevice || !host->metalQueue || !host->color || !host->depth
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
