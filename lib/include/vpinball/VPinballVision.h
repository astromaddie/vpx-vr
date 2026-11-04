// license:GPLv3+

#pragma once

#include "VPinballLib_C.h"

typedef enum {
   VPINBALL_VISION_LEFT_FLIPPER,
   VPINBALL_VISION_RIGHT_FLIPPER,
   VPINBALL_VISION_ADD_CREDIT,
   VPINBALL_VISION_START,
   VPINBALL_VISION_INPUT_COUNT
} VPINBALL_VISION_INPUT;

typedef enum {
   VPINBALL_VISION_PLUNGER_HOLD,
   VPINBALL_VISION_PLUNGER_RELEASE,
   VPINBALL_VISION_PLUNGER_CANCEL
} VPINBALL_VISION_PLUNGER_ACTION;

typedef struct {
   // Cabinet-to-eye and projection matrices, column-major on the Apple side.
   // VPX uses the same 16 floats as a row-vector transform. Projection uses
   // conventional Metal depth, where near = 0 and far = 1.
   float leftView[16], rightView[16];
   float leftProjection[16], rightProjection[16];
   float secondsUntilPresentation;
} VPINBALL_VISION_FRAME;

typedef struct {
   void* user;
   void* metalDevice;
   void* metalQueue;
   // Two-slice app-owned textures. Keep these alive until the player closes.
   void* color;
   void* depth;
   unsigned int width, height;
   // Called on VPX's render thread. Return 1 for a frame or 0 if paused.
   int (*beginFrame)(void* user, VPINBALL_VISION_FRAME* frame);
   void (*endFrame)(void* user, int rendered);
} VPINBALL_VISION_HOST;

// Configure before initializing the native player.
VPINBALLAPI VPINBALL_STATUS VPinballVisionConfigure(const VPINBALL_VISION_HOST* host);

// Call from the visionOS app's main thread. The host owns the event loop.
VPINBALLAPI VPINBALL_STATUS VPinballVisionInit(VPinballEventCallback eventCallback);
VPINBALLAPI void VPinballVisionTick(void);
VPINBALLAPI void VPinballVisionSetButton(VPINBALL_VISION_INPUT button, int pressed);
// Pull is measured from the resting position (0) to fully pulled back (1).
VPINBALLAPI void VPinballVisionSetPlunger(VPINBALL_VISION_PLUNGER_ACTION action, float pull);
