// license:GPLv3+

#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <string_view>

namespace VPX::XRInput
{

enum class ActionType
{
   Boolean,
   Float,
   Vector2,
   Pose,
   Haptic
};

struct ActionPath
{
   std::string_view path;
   ActionType type;
   std::string_view vector2XAxisPath = {};
   std::string_view vector2YAxisPath = {};
};

// Keep the original entries in their existing order: InputManager persists device element IDs.
inline constexpr std::array ActionPaths {
   ActionPath { "/user/hand/left/input/select/click", ActionType::Boolean },
   ActionPath { "/user/hand/right/input/select/click", ActionType::Boolean },
   ActionPath { "/user/hand/left/input/menu/click", ActionType::Boolean },
   ActionPath { "/user/hand/right/input/menu/click", ActionType::Boolean },
   ActionPath { "/user/hand/left/input/squeeze/click", ActionType::Boolean },
   ActionPath { "/user/hand/right/input/squeeze/click", ActionType::Boolean },
   ActionPath { "/user/hand/left/input/trigger/click", ActionType::Boolean },
   ActionPath { "/user/hand/right/input/trigger/click", ActionType::Boolean },
   ActionPath { "/user/hand/left/input/x/click", ActionType::Boolean },
   ActionPath { "/user/hand/left/input/y/click", ActionType::Boolean },
   ActionPath { "/user/hand/right/input/a/click", ActionType::Boolean },
   ActionPath { "/user/hand/right/input/b/click", ActionType::Boolean },
   ActionPath { "/user/hand/left/input/thumbstick/click", ActionType::Boolean },
   ActionPath { "/user/hand/right/input/thumbstick/click", ActionType::Boolean },
   ActionPath { "/user/hand/left/input/trackpad/click", ActionType::Boolean },
   ActionPath { "/user/hand/right/input/trackpad/click", ActionType::Boolean },
   ActionPath { "/user/hand/left/input/trigger/value", ActionType::Float },
   ActionPath { "/user/hand/right/input/trigger/value", ActionType::Float },
   ActionPath { "/user/hand/left/input/squeeze/value", ActionType::Float },
   ActionPath { "/user/hand/right/input/squeeze/value", ActionType::Float },
   ActionPath { "/user/hand/left/input/thumbstick/x", ActionType::Float },
   ActionPath { "/user/hand/left/input/thumbstick/y", ActionType::Float },
   ActionPath { "/user/hand/right/input/thumbstick/x", ActionType::Float },
   ActionPath { "/user/hand/right/input/thumbstick/y", ActionType::Float },
   ActionPath { "/user/hand/left/input/trackpad/x", ActionType::Float },
   ActionPath { "/user/hand/left/input/trackpad/y", ActionType::Float },
   ActionPath { "/user/hand/right/input/trackpad/x", ActionType::Float },
   ActionPath { "/user/hand/right/input/trackpad/y", ActionType::Float },
   ActionPath { "/user/hand/left/input/grip/pose", ActionType::Pose },
   ActionPath { "/user/hand/right/input/grip/pose", ActionType::Pose },
   ActionPath { "/user/hand/left/output/haptic", ActionType::Haptic },
   ActionPath { "/user/hand/right/output/haptic", ActionType::Haptic },
   // Frame-only face buttons and left-side controls are appended to preserve persisted IDs above.
   ActionPath { "/user/hand/right/input/x/click", ActionType::Boolean },
   ActionPath { "/user/hand/right/input/y/click", ActionType::Boolean },
   ActionPath { "/user/hand/left/input/dpad_up/click", ActionType::Boolean },
   ActionPath { "/user/hand/left/input/dpad_left/click", ActionType::Boolean },
   ActionPath { "/user/hand/left/input/dpad_down/click", ActionType::Boolean },
   ActionPath { "/user/hand/left/input/dpad_right/click", ActionType::Boolean },
   ActionPath { "/user/hand/left/input/view/click", ActionType::Boolean },
   // The Frame profile exposes each stick as one vector2 component. Map those components
   // back to the existing scalar input IDs so saved mappings and sensors keep their IDs.
   ActionPath { "/user/hand/left/input/thumbstick", ActionType::Vector2,
      "/user/hand/left/input/thumbstick/x", "/user/hand/left/input/thumbstick/y" },
   ActionPath { "/user/hand/right/input/thumbstick", ActionType::Vector2,
      "/user/hand/right/input/thumbstick/x", "/user/hand/right/input/thumbstick/y" },
};

inline constexpr std::array FrameProfilePaths {
   std::string_view { "/user/hand/right/input/a/click" },
   std::string_view { "/user/hand/right/input/b/click" },
   std::string_view { "/user/hand/right/input/x/click" },
   std::string_view { "/user/hand/right/input/y/click" },
   std::string_view { "/user/hand/right/input/menu/click" },
   std::string_view { "/user/hand/right/input/squeeze/value" },
   std::string_view { "/user/hand/right/input/trigger/value" },
   std::string_view { "/user/hand/right/input/thumbstick" },
   std::string_view { "/user/hand/right/input/grip/pose" },
   std::string_view { "/user/hand/right/output/haptic" },
   std::string_view { "/user/hand/left/input/dpad_up/click" },
   std::string_view { "/user/hand/left/input/dpad_left/click" },
   std::string_view { "/user/hand/left/input/dpad_down/click" },
   std::string_view { "/user/hand/left/input/dpad_right/click" },
   std::string_view { "/user/hand/left/input/view/click" },
   std::string_view { "/user/hand/left/input/squeeze/value" },
   std::string_view { "/user/hand/left/input/trigger/value" },
   std::string_view { "/user/hand/left/input/thumbstick" },
   std::string_view { "/user/hand/left/input/grip/pose" },
   std::string_view { "/user/hand/left/output/haptic" },
};

inline constexpr std::size_t MissingActionPath = std::numeric_limits<std::size_t>::max();

constexpr std::size_t FindActionPath(std::string_view path)
{
   for (std::size_t i = 0; i < ActionPaths.size(); ++i)
      if (ActionPaths[i].path == path)
         return i;
   return MissingActionPath;
}

inline constexpr auto FrameProfileActionIndices = []
{
   std::array<std::size_t, FrameProfilePaths.size()> indices {};
   for (std::size_t i = 0; i < FrameProfilePaths.size(); ++i)
      indices[i] = FindActionPath(FrameProfilePaths[i]);
   return indices;
}();

constexpr bool HasOnlyDeclaredFramePaths()
{
   for (std::size_t i = 0; i < FrameProfilePaths.size(); ++i)
   {
      const std::size_t index = FrameProfileActionIndices[i];
      if (index == MissingActionPath || ActionPaths[index].path != FrameProfilePaths[i])
         return false;
   }
   return true;
}

static_assert(HasOnlyDeclaredFramePaths());
static_assert(FindActionPath("/user/hand/left/input/trigger/value") == 16);
static_assert(FindActionPath("/user/hand/right/input/trigger/value") == 17);
static_assert(FindActionPath("/user/hand/left/input/thumbstick/x") == 20);
static_assert(FindActionPath("/user/hand/right/input/thumbstick/y") == 23);

enum class StickSource
{
   None,
   LegacyScalar,
   FrameVector,
};

constexpr StickSource GetStickSource(const ActionPath& path)
{
   if (path.type == ActionType::Vector2)
      return StickSource::FrameVector;
   if (path.type == ActionType::Float && path.path.find("/input/thumbstick/") != std::string_view::npos)
      return StickSource::LegacyScalar;
   return StickSource::None;
}

constexpr bool IsLeftHandPath(std::string_view path)
{
   return path.find("/user/hand/left/") == 0;
}

constexpr std::array<StickSource, 2> StickSamplingOrder(const bool frameProfileActive)
{
   // Release the inactive source before sampling the selected source so source changes cannot
   // leave a zero from the previous interaction profile as the final value for the frame.
   return frameProfileActive ? std::array { StickSource::LegacyScalar, StickSource::FrameVector }
                             : std::array { StickSource::FrameVector, StickSource::LegacyScalar };
}

class StickAxisRoute final
{
public:
   bool ShouldEmit(const bool selected, const bool active, const bool changedSinceLastSync)
   {
      if (!selected || !active)
      {
         const bool release = m_isRouted;
         m_isRouted = false;
         return release;
      }

      const bool emit = !m_isRouted || changedSinceLastSync;
      m_isRouted = true;
      return emit;
   }

private:
   bool m_isRouted = false;
};

enum class PinballAction
{
   LeftFlipper,
   RightFlipper,
   StagedLeftFlipper,
   StagedRightFlipper,
   LeftMagna,
   RightMagna,
   LeftStickClick,
   RightStickClick,
   Start,
   Back,
   Credit,
   Pause,
   UIUp,
   UIDown,
   UILeft,
   UIRight,
   OpenInGameUI,
   ExitGame,
};

struct ButtonBinding
{
   std::string_view path;
   PinballAction action;
   float threshold = 0.f;
   bool reversed = false;
   bool frameOnly = false;
};

// These defaults are proposed through InputManager's normal layout flow. Saved user mappings
// remain in force unless the player explicitly applies a new default layout.
inline constexpr std::array DefaultButtonBindings {
   ButtonBinding { "/user/hand/left/input/trigger/value", PinballAction::LeftFlipper, 0.3f },
   ButtonBinding { "/user/hand/right/input/trigger/value", PinballAction::RightFlipper, 0.3f },
   ButtonBinding { "/user/hand/left/input/trigger/value", PinballAction::StagedLeftFlipper, 0.6f },
   ButtonBinding { "/user/hand/right/input/trigger/value", PinballAction::StagedRightFlipper, 0.6f },
   ButtonBinding { "/user/hand/left/input/squeeze/click", PinballAction::LeftMagna },
   ButtonBinding { "/user/hand/right/input/squeeze/click", PinballAction::RightMagna },
   ButtonBinding { "/user/hand/left/input/squeeze/value", PinballAction::LeftMagna, 0.3f, false, true },
   ButtonBinding { "/user/hand/right/input/squeeze/value", PinballAction::RightMagna, 0.3f, false, true },
   ButtonBinding { "/user/hand/left/input/thumbstick/click", PinballAction::LeftStickClick },
   ButtonBinding { "/user/hand/right/input/thumbstick/click", PinballAction::RightStickClick },
   ButtonBinding { "/user/hand/right/input/a/click", PinballAction::Start },
   ButtonBinding { "/user/hand/right/input/b/click", PinballAction::Back },
   ButtonBinding { "/user/hand/right/input/x/click", PinballAction::Credit, 0.f, false, true },
   ButtonBinding { "/user/hand/right/input/menu/click", PinballAction::Pause, 0.f, false, true },
   ButtonBinding { "/user/hand/left/input/dpad_up/click", PinballAction::UIUp, 0.f, false, true },
   ButtonBinding { "/user/hand/left/input/dpad_down/click", PinballAction::UIDown, 0.f, false, true },
   ButtonBinding { "/user/hand/left/input/dpad_left/click", PinballAction::UILeft, 0.f, false, true },
   ButtonBinding { "/user/hand/left/input/dpad_right/click", PinballAction::UIRight, 0.f, false, true },
   ButtonBinding { "/user/hand/left/input/thumbstick/y", PinballAction::UIDown, -0.9f, true },
   ButtonBinding { "/user/hand/left/input/thumbstick/y", PinballAction::UIUp, 0.9f },
   ButtonBinding { "/user/hand/right/input/thumbstick/x", PinballAction::UILeft, -0.9f, true },
   ButtonBinding { "/user/hand/right/input/thumbstick/x", PinballAction::UIRight, 0.9f },
   // Legacy fallbacks for Index/Touch profiles; these are not suggested to the Frame profile.
   ButtonBinding { "/user/hand/left/input/x/click", PinballAction::OpenInGameUI },
   ButtonBinding { "/user/hand/left/input/y/click", PinballAction::ExitGame },
};

struct AxisBinding
{
   std::string_view path;
   enum class Target { Plunger, NudgeX, NudgeY } target;
};

inline constexpr std::array DefaultAxisBindings {
   AxisBinding { "/user/hand/right/input/thumbstick/y", AxisBinding::Target::Plunger },
   AxisBinding { "/user/hand/left/input/thumbstick/x", AxisBinding::Target::NudgeX },
   AxisBinding { "/user/hand/left/input/thumbstick/y", AxisBinding::Target::NudgeY },
};

struct ViewHoldEvents
{
   bool back = false;
   bool recenter = false;
};

// View is back on release for a short press and recentres after one second. There is no standing
// height to infer from a seated pinball pose. An inactive OpenXR action cancels the gesture.
class ViewHoldGesture final
{
public:
   ViewHoldEvents Update(bool pressed, std::uint64_t nowMs, bool active = true)
   {
      ViewHoldEvents events;
      if (!active)
      {
         Reset();
         return events;
      }

      if (pressed && !m_isHeld)
      {
         m_isHeld = true;
         m_startedAtMs = nowMs;
      }
      if (!m_isHeld)
         return events;

      const std::uint64_t elapsedMs = nowMs >= m_startedAtMs ? nowMs - m_startedAtMs : 0;
      if (pressed && !m_didRecenter && elapsedMs >= 1000)
      {
         events.recenter = true;
         m_didRecenter = true;
      }
      if (!pressed)
      {
         if (!m_didRecenter && elapsedMs < 1000)
            events.back = true;
         Reset();
      }
      return events;
   }

   void Reset()
   {
      m_isHeld = false;
      m_didRecenter = false;
      m_startedAtMs = 0;
   }

private:
   bool m_isHeld = false;
   bool m_didRecenter = false;
   std::uint64_t m_startedAtMs = 0;
};

} // namespace VPX::XRInput
