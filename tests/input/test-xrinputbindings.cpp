// license:GPLv3+

#include "input/XRInputBindings.h"

#include "doctest.h"

#include <algorithm>
#include <vector>

using namespace VPX::XRInput;

TEST_CASE("Steam Frame profile only suggests its declared physical controls")
{
   CHECK(FrameProfilePaths.size() == 20);
   CHECK(HasOnlyDeclaredFramePaths());

   for (const std::string_view path : FrameProfilePaths)
      CHECK(FindActionPath(path) != MissingActionPath);

   CHECK(FindActionPath("/user/hand/right/input/thumbstick") == 40);
   CHECK(ActionPaths[FrameProfileActionIndices[7]].type == ActionType::Vector2);
   CHECK(ActionPaths[FrameProfileActionIndices[17]].type == ActionType::Vector2);

   for (const std::string_view path : FrameProfilePaths)
   {
      CHECK(path.find("/squeeze/click") == std::string_view::npos);
      CHECK(path.find("/trackpad/") == std::string_view::npos);
      CHECK(path.find("/thumbstick/x") == std::string_view::npos);
      CHECK(path.find("/thumbstick/y") == std::string_view::npos);
      CHECK(path.find("/input/select/") == std::string_view::npos);
      CHECK(path != "/user/hand/left/input/x/click");
      CHECK(path != "/user/hand/left/input/y/click");
   }

   CHECK(FindActionPath("/user/hand/right/input/squeeze/click") != MissingActionPath); // retained for legacy profiles
   CHECK(std::find(FrameProfilePaths.begin(), FrameProfilePaths.end(), "/user/hand/right/input/squeeze/click") == FrameProfilePaths.end());
}

TEST_CASE("Frame defaults use the requested pinball controls and preserve legacy element IDs")
{
   CHECK(FindActionPath("/user/hand/left/input/trigger/value") == 16);
   CHECK(FindActionPath("/user/hand/right/input/trigger/value") == 17);
   CHECK(FindActionPath("/user/hand/left/input/thumbstick/x") == 20);
   CHECK(FindActionPath("/user/hand/left/input/thumbstick/y") == 21);
   CHECK(FindActionPath("/user/hand/right/input/thumbstick/x") == 22);
   CHECK(FindActionPath("/user/hand/right/input/thumbstick/y") == 23);

   const auto hasBinding = [](std::string_view path, PinballAction action, float threshold = 0.f)
   {
      return std::find_if(DefaultButtonBindings.begin(), DefaultButtonBindings.end(), [&](const ButtonBinding& binding)
      {
         return binding.path == path && binding.action == action && binding.threshold == threshold;
      }) != DefaultButtonBindings.end();
   };
   const auto isFrameOnly = [](std::string_view path)
   {
      const auto binding = std::find_if(DefaultButtonBindings.begin(), DefaultButtonBindings.end(), [&](const ButtonBinding& item)
      {
         return item.path == path;
      });
      return binding != DefaultButtonBindings.end() && binding->frameOnly;
   };

   CHECK(hasBinding("/user/hand/left/input/trigger/value", PinballAction::LeftFlipper, 0.3f));
   CHECK(hasBinding("/user/hand/right/input/trigger/value", PinballAction::RightFlipper, 0.3f));
   CHECK(hasBinding("/user/hand/left/input/trigger/value", PinballAction::StagedLeftFlipper, 0.6f));
   CHECK(hasBinding("/user/hand/right/input/trigger/value", PinballAction::StagedRightFlipper, 0.6f));
   CHECK(hasBinding("/user/hand/right/input/a/click", PinballAction::Start));
   CHECK(hasBinding("/user/hand/right/input/b/click", PinballAction::Back));
   CHECK(hasBinding("/user/hand/right/input/x/click", PinballAction::Credit));
   CHECK(hasBinding("/user/hand/right/input/menu/click", PinballAction::Pause));
   CHECK(hasBinding("/user/hand/left/input/dpad_up/click", PinballAction::UIUp));
   CHECK(hasBinding("/user/hand/left/input/dpad_left/click", PinballAction::UILeft));
   CHECK(hasBinding("/user/hand/left/input/dpad_down/click", PinballAction::UIDown));
   CHECK(hasBinding("/user/hand/left/input/dpad_right/click", PinballAction::UIRight));
   CHECK(hasBinding("/user/hand/left/input/squeeze/value", PinballAction::LeftMagna, 0.3f));
   CHECK(hasBinding("/user/hand/right/input/squeeze/value", PinballAction::RightMagna, 0.3f));
   CHECK(isFrameOnly("/user/hand/left/input/squeeze/value"));
   CHECK(isFrameOnly("/user/hand/right/input/squeeze/value"));
   CHECK(isFrameOnly("/user/hand/right/input/x/click"));
   CHECK(isFrameOnly("/user/hand/right/input/menu/click"));
   CHECK(isFrameOnly("/user/hand/left/input/dpad_up/click"));
   CHECK(hasBinding("/user/hand/left/input/x/click", PinballAction::OpenInGameUI)); // legacy defaults remain available
   CHECK_FALSE(isFrameOnly("/user/hand/left/input/x/click"));

   CHECK(DefaultAxisBindings[0].path == "/user/hand/right/input/thumbstick/y");
   CHECK(DefaultAxisBindings[0].target == AxisBinding::Target::Plunger);
   CHECK(DefaultAxisBindings[1].path == "/user/hand/left/input/thumbstick/x");
   CHECK(DefaultAxisBindings[1].target == AxisBinding::Target::NudgeX);
   CHECK(DefaultAxisBindings[2].path == "/user/hand/left/input/thumbstick/y");
   CHECK(DefaultAxisBindings[2].target == AxisBinding::Target::NudgeY);

   CHECK(ActionPaths[39].vector2XAxisPath == "/user/hand/left/input/thumbstick/x");
   CHECK(ActionPaths[39].vector2YAxisPath == "/user/hand/left/input/thumbstick/y");
   CHECK(ActionPaths[40].vector2XAxisPath == "/user/hand/right/input/thumbstick/x");
   CHECK(ActionPaths[40].vector2YAxisPath == "/user/hand/right/input/thumbstick/y");
}

TEST_CASE("thumbstick profile transitions release the old source before sampling the selected source")
{
   const auto simulateSample = [](StickAxisRoute& route, const StickSource source, const bool frameActive, const bool active,
                                  const bool changed, const float value, std::vector<float>& output)
   {
      const bool selected = source == (frameActive ? StickSource::FrameVector : StickSource::LegacyScalar);
      if (route.ShouldEmit(selected, active, changed))
         output.push_back(selected && active ? value : 0.f);
   };

   SUBCASE("Frame vector to unchanged legacy scalar re-emits the selected scalar after vector release")
   {
      StickAxisRoute legacy;
      StickAxisRoute frame;
      std::vector<float> samples;

      for (const StickSource source : StickSamplingOrder(true))
         simulateSample(source == StickSource::FrameVector ? frame : legacy, source, true, true, true, 0.7f, samples);
      REQUIRE(samples == std::vector<float> { 0.7f });

      samples.clear();
      for (const StickSource source : StickSamplingOrder(false))
         simulateSample(source == StickSource::FrameVector ? frame : legacy, source, false,
            source == StickSource::LegacyScalar, false, 0.7f, samples);

      REQUIRE(samples == std::vector<float> { 0.f, 0.7f });
      CHECK(samples.back() == 0.7f);
   }

   SUBCASE("legacy scalar to Frame vector leaves the vector sample last")
   {
      StickAxisRoute legacy;
      StickAxisRoute frame;
      std::vector<float> samples;
      simulateSample(legacy, StickSource::LegacyScalar, false, true, true, -0.4f, samples);
      samples.clear();

      for (const StickSource source : StickSamplingOrder(true))
         simulateSample(source == StickSource::FrameVector ? frame : legacy, source, true,
            source == StickSource::FrameVector, true, -0.4f, samples);

      REQUIRE(samples == std::vector<float> { 0.f, -0.4f });
   }
}

TEST_CASE("Steam Frame View press selects back or recenter by hold duration")
{
   SUBCASE("short release backs out")
   {
      ViewHoldGesture gesture;
      CHECK_FALSE(gesture.Update(true, 100).back);
      const ViewHoldEvents released = gesture.Update(false, 600);
      CHECK(released.back);
      CHECK_FALSE(released.recenter);
   }

   SUBCASE("one second recenters once; a longer hold does not infer seated height")
   {
      ViewHoldGesture gesture;
      gesture.Update(true, 100);
      CHECK_FALSE(gesture.Update(true, 1099).recenter);
      const ViewHoldEvents recentered = gesture.Update(true, 1100);
      CHECK(recentered.recenter);
      CHECK_FALSE(gesture.Update(true, 2100).recenter);

      const ViewHoldEvents heldLonger = gesture.Update(true, 3100);
      CHECK_FALSE(heldLonger.back);
      CHECK_FALSE(heldLonger.recenter);

      const ViewHoldEvents released = gesture.Update(false, 4200);
      CHECK_FALSE(released.back);
      CHECK_FALSE(released.recenter);
   }

   SUBCASE("focus loss cancels the hold without synthesizing an action")
   {
      ViewHoldGesture gesture;
      gesture.Update(true, 0);
      const ViewHoldEvents lostFocus = gesture.Update(true, 500, false);
      CHECK_FALSE(lostFocus.back);
      CHECK_FALSE(lostFocus.recenter);

      gesture.Update(true, 600);
      CHECK_FALSE(gesture.Update(false, 1500, false).back);
      gesture.Update(true, 1600);
      CHECK(gesture.Update(false, 2100).back); // the fresh hold is treated as a short press
   }
}
