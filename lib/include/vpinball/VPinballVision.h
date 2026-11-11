// license:GPLv3+

#pragma once

#include "VPinballLib_C.h"
#ifdef __APPLE__
#include <TargetConditionals.h>
#endif

typedef enum {
   VPINBALL_VISION_LEFT_FLIPPER,
   VPINBALL_VISION_RIGHT_FLIPPER,
   VPINBALL_VISION_ADD_CREDIT,
   VPINBALL_VISION_START,
   VPINBALL_VISION_NUDGE_LEFT,
   VPINBALL_VISION_NUDGE_RIGHT,
   VPINBALL_VISION_NUDGE_FORWARD,
   VPINBALL_VISION_NUDGE_BACK,
   VPINBALL_VISION_LAUNCH_BALL,
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
   float leftRoomView[16], rightRoomView[16];
   float leftProjection[16], rightProjection[16];
   float secondsUntilPresentation;
   unsigned int eyeBuffer;
} VPINBALL_VISION_FRAME;

typedef struct {
   void* user;
   void* metalDevice;
   void* metalQueue;
   // Two sets of stereo textures. Keep them alive until the player closes.
   void* color[2];
   void* depth[2];
   unsigned int width, height;
   int mixedReality;
   // One line on the app build, table, eye size and room, logged at the top of each table's log.
   char session[256];
   // Called on VPX's render thread. Return 1 for an eye pose and a writable buffer.
   int (*beginFrame)(void* user, VPINBALL_VISION_FRAME* frame);
   void (*endFrame)(void* user, int rendered);
} VPINBALL_VISION_HOST;

// Configure before initializing the native player.
VPINBALLAPI VPINBALL_STATUS VPinballVisionConfigure(const VPINBALL_VISION_HOST* host);

// Call from the visionOS app's main thread. The host owns the event loop.
VPINBALLAPI VPINBALL_STATUS VPinballVisionInit(VPinballEventCallback eventCallback);
VPINBALLAPI void VPinballVisionTick(void);
typedef struct {
   float x, y, z;
   float halfWidth, halfHeight;
} VPINBALL_VISION_BUTTON_FACE;

typedef struct {
   float x, y, z;
} VPINBALL_VISION_POINT;

typedef struct {
   float width, length, height;
   VPINBALL_VISION_BUTTON_FACE start, coin;
   VPINBALL_VISION_POINT leftFlipper, rightFlipper;
   float plungerX, plungerY, plungerZ;
   int hasPlunger;
   // A launch button pokes Launch Ball. Cabinets have a plunger knob or this button.
   VPINBALL_VISION_BUTTON_FACE launch;
   int hasLaunchButton;
} VPINBALL_VISION_LAYOUT;

// Dimensions and control placement in metres. Read after PLAYER_READY.
VPINBALLAPI VPINBALL_VISION_LAYOUT VPinballVisionGetLayout(void);
VPINBALLAPI void VPinballVisionSetButton(VPINBALL_VISION_INPUT button, int pressed);
// GPU time of the newest frame BGFX has finished, in milliseconds, or -1 when
// none has finished yet. Call it from endFrame, which runs on BGFX's API thread.
VPINBALLAPI float VPinballVisionLastGpuMilliseconds(void);
// Pull is measured from the resting position (0) to fully pulled back (1).
// Returns 1 if the release needs a Launch Ball button pulse.
VPINBALLAPI int VPinballVisionSetPlunger(VPINBALL_VISION_PLUNGER_ACTION action, float pull);

#if defined(TARGET_OS_SIMULATOR) && TARGET_OS_SIMULATOR
// Read resolved native input, on the player thread, for the Simulator check.
VPINBALLAPI int VPinballVisionRomRunning(void);
VPINBALLAPI unsigned int VPinballVisionPressedButtons(void);
VPINBALLAPI int VPinballVisionNudgeCount(void);
VPINBALLAPI float VPinballVisionPlungerPosition(void);
typedef struct {
   int id;
   float y, velocityY;
} VPINBALL_VISION_BALL_SAMPLE;
// Use -1 to find the ball at the plunger or a named shooter, then pass its ID to follow it.
VPINBALLAPI VPINBALL_VISION_BALL_SAMPLE VPinballVisionSampleBall(int ballId, const char* shooterName);
#endif
