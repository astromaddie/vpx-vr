// license:GPLv3+

#pragma once

#include "InputManager.h"
#include "input/XRInputBindings.h"

#include "input/PlungerHandler.h"
#include "physics/cabinet/GamepadNudge.h"

#include <vector>
#include <string>
#include <string_view>
#include <iostream>
#include <algorithm>

#include <openxr/openxr.h>


class XRInputHandler final : public InputManager::InputHandler
{
private:
   struct ActionTracker
   {
      std::string path;
      XrAction action;
      XrActionType type;
      bool isActive = false;
      bool isPressed = false;
      uint16_t pinInputId;
      uint16_t secondPinInputId = 0;
      VPX::XRInput::StickSource stickSource = VPX::XRInput::StickSource::None;
      VPX::XRInput::StickAxisRoute stickAxisRoute;
      bool isLeftHand = false;
   };

   template <size_t N> void CopyToXrBuffer(char (&dest)[N], const std::string_view& src)
   {
      size_t count = std::min(src.size(), N - 1);
      std::copy(src.begin(), src.begin() + count, dest);
      dest[count] = '\0';
   }

public:
   XRInputHandler(InputManager& pininput, XrInstance instance, XrSession session, bool frameControllerProfileSupported)
      : m_pininput(pininput)
      , m_instance(instance)
      , m_session(session)
   {
      m_frameControllerProfileSupported = frameControllerProfileSupported;
      xrStringToPath(m_instance, "/interaction_profiles/valve/frame_controller_valve", &m_frameProfilePath);
      xrStringToPath(m_instance, "/user/hand/left", &m_leftHandPath);
      xrStringToPath(m_instance, "/user/hand/right", &m_rightHandPath);

      XrActionSetCreateInfo actionSetInfo { XR_TYPE_ACTION_SET_CREATE_INFO };
      CopyToXrBuffer(actionSetInfo.actionSetName, "vpx_generic_input"s);
      CopyToXrBuffer(actionSetInfo.localizedActionSetName, "VPX Generic Input"s);
      xrCreateActionSet(m_instance, &actionSetInfo, &m_actionSet);

      m_joyId = m_pininput.RegisterDevice("OpenXR", InputManager::DeviceType::VRController, "VR Controller");

      // There is no way to enumerate and listen for change in OpenXR, so we do it the other way: we define all known input paths and listen for changes on all of them
      // Bind them
      uint16_t actionId = 0;
      std::vector<XrActionSuggestedBinding> bindings;
      for (const VPX::XRInput::ActionPath& definition : VPX::XRInput::ActionPaths)
      {
         ActionTracker tracker;
         tracker.path = definition.path;
         tracker.type = ToXrActionType(definition.type);
         tracker.pinInputId = actionId;
         actionId++;
         tracker.stickSource = VPX::XRInput::GetStickSource(definition);
         tracker.isLeftHand = VPX::XRInput::IsLeftHandPath(definition.path);
         if (definition.type == VPX::XRInput::ActionType::Vector2)
         {
            const std::size_t xIndex = VPX::XRInput::FindActionPath(definition.vector2XAxisPath);
            const std::size_t yIndex = VPX::XRInput::FindActionPath(definition.vector2YAxisPath);
            assert(xIndex < VPX::XRInput::ActionPaths.size() && yIndex < VPX::XRInput::ActionPaths.size());
            tracker.pinInputId = static_cast<uint16_t>(xIndex);
            tracker.secondPinInputId = static_cast<uint16_t>(yIndex);
         }

         XrActionCreateInfo actionInfo { XR_TYPE_ACTION_CREATE_INFO };
         actionInfo.actionType = tracker.type;

         // Sanitize name for OpenXR (no slashes)
         const std::string name = SanitizePath(tracker.path);

         CopyToXrBuffer(actionInfo.actionName, name);
         CopyToXrBuffer(actionInfo.localizedActionName, tracker.path);

         xrCreateAction(m_actionSet, &actionInfo, &tracker.action);

         XrPath xrPath;
         xrStringToPath(m_instance, tracker.path.c_str(), &xrPath);
         // Legacy profiles continue using the existing scalar X/Y paths. The Frame profile
         // receives only its explicitly supported vector2 stick actions below.
         if (tracker.type != XR_ACTION_TYPE_VECTOR2F_INPUT)
            bindings.push_back({ tracker.action, xrPath });
         m_trackers.push_back(tracker);

         if (tracker.type == XR_ACTION_TYPE_BOOLEAN_INPUT || tracker.type == XR_ACTION_TYPE_FLOAT_INPUT)
            m_pininput.RegisterElementName(m_joyId, tracker.type == XR_ACTION_TYPE_FLOAT_INPUT, tracker.pinInputId, name);
         else if (tracker.type == XR_ACTION_TYPE_VECTOR2F_INPUT)
         {
            const std::string xName = SanitizePath(VPX::XRInput::ActionPaths[tracker.pinInputId].path);
            const std::string yName = SanitizePath(VPX::XRInput::ActionPaths[tracker.secondPinInputId].path);
            m_pininput.RegisterElementName(m_joyId, true, tracker.pinInputId, xName);
            m_pininput.RegisterElementName(m_joyId, true, tracker.secondPinInputId, yName);
         }
         else if (tracker.type == XR_ACTION_TYPE_VIBRATION_OUTPUT)
            m_hapticActions.push_back(tracker.action);
      }

      // Register these bindings for major profiles
      static const std::array<const char*, 6> profiles { //
         "/interaction_profiles/khr/simple_controller", //
         "/interaction_profiles/oculus/touch_controller", //
         "/interaction_profiles/valve/index_controller", //
         "/interaction_profiles/htc/vive_controller", //
         "/interaction_profiles/microsoft/motion_controller", //
         "/interaction_profiles/google/daydream_controller" };
      for (const char* p : profiles)
      {
         SuggestBindings(p, bindings);
      }
      if (frameControllerProfileSupported)
      {
         std::vector<XrActionSuggestedBinding> frameBindings;
         frameBindings.reserve(VPX::XRInput::FrameProfileActionIndices.size());
         for (std::size_t index : VPX::XRInput::FrameProfileActionIndices)
         {
            assert(index < m_trackers.size());
            XrPath xrPath;
            const XrResult pathResult = xrStringToPath(m_instance, m_trackers[index].path.c_str(), &xrPath);
            if (pathResult == XR_SUCCESS)
               frameBindings.push_back({ m_trackers[index].action, xrPath });
            else
               PLOGE << "Failed to resolve Frame controller input path " << m_trackers[index].path << " (" << pathResult << ')';
         }
         if (frameBindings.size() == VPX::XRInput::FrameProfileActionIndices.size())
            SuggestBindingsExact("/interaction_profiles/valve/frame_controller_valve", frameBindings);
         else
            PLOGE << "Frame controller binding was not suggested because one or more declared paths could not be resolved";
      }

      XrSessionActionSetsAttachInfo attachInfo { XR_TYPE_SESSION_ACTION_SETS_ATTACH_INFO };
      attachInfo.countActionSets = 1;
      attachInfo.actionSets = &m_actionSet;
      xrAttachSessionActionSets(m_session, &attachInfo);

      auto defaultMapping = [this](InputManager::MappingSetupHandler& map)
      {
         for (const VPX::XRInput::ButtonBinding& binding : VPX::XRInput::DefaultButtonBindings)
         {
            if (binding.frameOnly && !frameControllerProfileSupported)
               continue;
            const auto actionIndex = VPX::XRInput::FindActionPath(binding.path);
            assert(actionIndex != VPX::XRInput::MissingActionPath);
            const uint16_t inputId = static_cast<uint16_t>(actionIndex);
            unsigned int targetAction = 0;
            switch (binding.action)
            {
            case VPX::XRInput::PinballAction::LeftFlipper: targetAction = m_pininput.GetLeftFlipperActionId(); break;
            case VPX::XRInput::PinballAction::RightFlipper: targetAction = m_pininput.GetRightFlipperActionId(); break;
            case VPX::XRInput::PinballAction::StagedLeftFlipper: targetAction = m_pininput.GetStagedLeftFlipperActionId(); break;
            case VPX::XRInput::PinballAction::StagedRightFlipper: targetAction = m_pininput.GetStagedRightFlipperActionId(); break;
            case VPX::XRInput::PinballAction::LeftMagna: targetAction = m_pininput.GetLeftMagnaActionId(); break;
            case VPX::XRInput::PinballAction::RightMagna: targetAction = m_pininput.GetRightMagnaActionId(); break;
            case VPX::XRInput::PinballAction::LeftStickClick: targetAction = m_pininput.GetVRControllerViewCenteringActionId(); break;
            case VPX::XRInput::PinballAction::RightStickClick: targetAction = m_pininput.GetLaunchBallActionId(); break;
            case VPX::XRInput::PinballAction::Start: targetAction = m_pininput.GetStartActionId(); break;
            case VPX::XRInput::PinballAction::Back: targetAction = m_pininput.GetAddCreditActionId(0); break;
            case VPX::XRInput::PinballAction::Credit: targetAction = m_pininput.GetAddCreditActionId(0); break;
            case VPX::XRInput::PinballAction::Pause: targetAction = m_pininput.GetOpenInGameUIActionId(); break;
            case VPX::XRInput::PinballAction::UIUp: targetAction = m_pininput.GetUIUpActionId(); break;
            case VPX::XRInput::PinballAction::UIDown: targetAction = m_pininput.GetUIDownActionId(); break;
            case VPX::XRInput::PinballAction::UILeft: targetAction = m_pininput.GetUILeftActionId(); break;
            case VPX::XRInput::PinballAction::UIRight: targetAction = m_pininput.GetUIRightActionId(); break;
            case VPX::XRInput::PinballAction::OpenInGameUI: targetAction = m_pininput.GetOpenInGameUIActionId(); break;
            case VPX::XRInput::PinballAction::ExitGame: targetAction = m_pininput.GetExitGameActionId(); break;
            }
            if (binding.threshold == 0.f && !binding.reversed)
               map.MapAction(ButtonMapping::Create(m_joyId, inputId), targetAction);
            else
               map.MapAction(ButtonMapping::Create(m_joyId, inputId, binding.threshold, binding.reversed), targetAction);
            if (frameControllerProfileSupported && binding.action == VPX::XRInput::PinballAction::Start)
               map.MapAction(ButtonMapping::Create(m_joyId, inputId), m_pininput.GetUIRightActionId()); // A confirms while the in-game UI is open
         }

         std::unique_ptr<PlungerSensor> plunger = std::make_unique<PlungerSensor>(&m_pininput);
         plunger->GetPositionSensor()->SetMapping(SensorMapping::Create(m_joyId,
            static_cast<uint16_t>(VPX::XRInput::FindActionPath(VPX::XRInput::DefaultAxisBindings[0].path)), SensorMapping::Type::Position));
         plunger->GetPositionSensor()->GetMapping().SetScale(-1.f);
         map.MapPlunger(std::move(plunger));
         std::unique_ptr<VPX::Physics::GamepadNudge> nudge = std::make_unique<VPX::Physics::GamepadNudge>(&m_pininput);
         nudge->GetXSensor().SetMapping(SensorMapping::Create(m_joyId,
            static_cast<uint16_t>(VPX::XRInput::FindActionPath(VPX::XRInput::DefaultAxisBindings[1].path)), SensorMapping::Type::Position));
         nudge->GetYSensor().SetMapping(SensorMapping::Create(m_joyId,
            static_cast<uint16_t>(VPX::XRInput::FindActionPath(VPX::XRInput::DefaultAxisBindings[2].path)), SensorMapping::Type::Position));
         map.MapNudge(std::move(nudge));
      };
      m_pininput.SetDeviceDefaultMapping(m_joyId, defaultMapping, frameControllerProfileSupported);

      m_viewBackActionSlot = m_pininput.GetInputActions()[m_pininput.GetExitGameActionId()]->NewDirectStateSlot();
      m_buttonBackActionSlot = m_pininput.GetInputActions()[m_pininput.GetExitGameActionId()]->NewDirectStateSlot();
      m_recenterActionSlot = m_pininput.GetInputActions()[m_pininput.GetVRViewCenterActionId()]->NewDirectStateSlot();
   }

   ~XRInputHandler() override
   {
      for (auto& t : m_trackers)
         xrDestroyAction(t.action);
      xrDestroyActionSet(m_actionSet);
   }

   void Update() override
   {
      XrActiveActionSet activeSet { m_actionSet, XR_NULL_PATH };
      XrActionsSyncInfo syncInfo { XR_TYPE_ACTIONS_SYNC_INFO };
      syncInfo.countActiveActionSets = 1;
      syncInfo.activeActionSets = &activeSet;
      xrSyncActions(m_session, &syncInfo);
      const uint64_t nowMs = usec() / 1000;
      const bool frameLeftProfileActive = m_frameControllerProfileSupported && IsFrameProfileActive(m_leftHandPath);
      const bool frameRightProfileActive = m_frameControllerProfileSupported && IsFrameProfileActive(m_rightHandPath);

      for (auto& t : m_trackers)
      {
         if (t.stickSource != VPX::XRInput::StickSource::None)
            continue;

         XrActionStateGetInfo getInfo { XR_TYPE_ACTION_STATE_GET_INFO, nullptr, t.action };

         if (t.type == XR_ACTION_TYPE_BOOLEAN_INPUT)
         {
            XrActionStateBoolean state { XR_TYPE_ACTION_STATE_BOOLEAN };
            xrGetActionStateBoolean(m_session, &getInfo, &state);

            if (t.path == "/user/hand/left/input/view/click")
            {
               const VPX::XRInput::ViewHoldEvents events = m_viewHoldGesture.Update(
                  frameLeftProfileActive && state.isActive && state.currentState, nowMs, frameLeftProfileActive && state.isActive != XR_FALSE);
               if (events.back && m_pininput.IsInGameUIOpened())
                  TriggerAction(m_pininput.GetExitGameActionId(), m_viewBackActionSlot);
               if (events.recenter)
                  TriggerAction(m_pininput.GetVRViewCenterActionId(), m_recenterActionSlot);
               continue;
            }

            if (t.path == "/user/hand/right/input/b/click" && frameRightProfileActive)
            {
               if (state.isActive && state.changedSinceLastSync && state.currentState && m_pininput.IsInGameUIOpened())
                  TriggerAction(m_pininput.GetExitGameActionId(), m_buttonBackActionSlot);
               if (t.isPressed)
                  m_pininput.PushButtonEvent(m_joyId, t.pinInputId, usec() * 1000ULL, false);
               t.isPressed = false;
               t.isActive = state.isActive;
               continue;
            }

            if (!state.isActive && t.isActive)
            {
               m_pininput.PushButtonEvent(m_joyId, t.pinInputId, usec() * 1000ULL, false);
               t.isActive = false;
               t.isPressed = false;
            }
            else if (state.isActive && (state.changedSinceLastSync || !t.isActive || state.currentState != t.isPressed))
            {
               //PLOGI << "[BTN] " << t.path << " -> " << (state.currentState ? "ON" : "OFF");
               m_pininput.PushButtonEvent(m_joyId, t.pinInputId, usec() * 1000ULL, state.currentState);
               t.isActive = true;
               t.isPressed = state.currentState;
            }
         }
         else if (t.type == XR_ACTION_TYPE_FLOAT_INPUT)
         {
            XrActionStateFloat state { XR_TYPE_ACTION_STATE_FLOAT };
            xrGetActionStateFloat(m_session, &getInfo, &state);

            if (!state.isActive && t.isActive)
            {
               m_pininput.PushAxisEvent(m_joyId, t.pinInputId, usec() * 1000ULL, 0.f);
               t.isActive = false;
            }
            else if (state.isActive && (state.changedSinceLastSync || !t.isActive))
            {
               // -1 .. 1 for sticks / 0 (unpressed) .. 1 (pressed) for triggers
               //PLOGI << "[ANA] " << t.path << " -> " << state.currentState;
               m_pininput.PushAxisEvent(m_joyId, t.pinInputId, usec() * 1000ULL, state.currentState);
               t.isActive = true;
            }
         }
      }

      UpdateThumbstickSources(true, frameLeftProfileActive);
      UpdateThumbstickSources(false, frameRightProfileActive);
   }

   void PlayRumble(const float lowFrequencySpeed, const float highFrequencySpeed, const int ms_duration, const bool kickLow, const bool kickHigh) override
   {
      const float amplitude = saturate(max(lowFrequencySpeed, highFrequencySpeed));
      if (amplitude <= 0.f || ms_duration <= 0)
      {
         for (XrAction action : m_hapticActions)
         {
            XrHapticActionInfo hapticInfo { XR_TYPE_HAPTIC_ACTION_INFO };
            hapticInfo.action = action;
            hapticInfo.subactionPath = XR_NULL_PATH;
            xrStopHapticFeedback(m_session, &hapticInfo);
         }
         return;
      }
      XrHapticVibration vibration { XR_TYPE_HAPTIC_VIBRATION };
      vibration.amplitude = amplitude;
      vibration.duration = static_cast<XrDuration>(ms_duration) * 1000000LL;
      vibration.frequency = XR_FREQUENCY_UNSPECIFIED;
      for (XrAction action : m_hapticActions)
      {
         XrHapticActionInfo hapticInfo { XR_TYPE_HAPTIC_ACTION_INFO };
         hapticInfo.action = action;
         hapticInfo.subactionPath = XR_NULL_PATH;
         xrApplyHapticFeedback(m_session, &hapticInfo, reinterpret_cast<const XrHapticBaseHeader*>(&vibration));
      }
   }

private:
   void UpdateThumbstickSources(const bool leftHand, const bool frameProfileActive)
   {
      const VPX::XRInput::StickSource selectedSource = frameProfileActive ? VPX::XRInput::StickSource::FrameVector : VPX::XRInput::StickSource::LegacyScalar;
      const uint64_t timestamp = usec() * 1000ULL;
      for (const VPX::XRInput::StickSource source : VPX::XRInput::StickSamplingOrder(frameProfileActive))
      {
         for (auto& tracker : m_trackers)
         {
            if (tracker.stickSource != source || tracker.isLeftHand != leftHand)
               continue;

            XrActionStateGetInfo getInfo { XR_TYPE_ACTION_STATE_GET_INFO, nullptr, tracker.action };
            const bool selected = source == selectedSource;
            if (tracker.type == XR_ACTION_TYPE_FLOAT_INPUT)
            {
               XrActionStateFloat state { XR_TYPE_ACTION_STATE_FLOAT };
               xrGetActionStateFloat(m_session, &getInfo, &state);
               if (tracker.stickAxisRoute.ShouldEmit(selected, state.isActive, state.changedSinceLastSync))
                  m_pininput.PushAxisEvent(m_joyId, tracker.pinInputId, timestamp, selected && state.isActive ? state.currentState : 0.f);
            }
            else if (tracker.type == XR_ACTION_TYPE_VECTOR2F_INPUT)
            {
               XrActionStateVector2f state { XR_TYPE_ACTION_STATE_VECTOR2F };
               xrGetActionStateVector2f(m_session, &getInfo, &state);
               if (tracker.stickAxisRoute.ShouldEmit(selected, state.isActive, state.changedSinceLastSync))
               {
                  m_pininput.PushAxisEvent(m_joyId, tracker.pinInputId, timestamp, selected && state.isActive ? state.currentState.x : 0.f);
                  m_pininput.PushAxisEvent(m_joyId, tracker.secondPinInputId, timestamp, selected && state.isActive ? state.currentState.y : 0.f);
               }
            }
         }
      }
   }

   static std::string SanitizePath(std::string_view path)
   {
      std::string name(path);
      std::replace(name.begin(), name.end(), '/', '_');
      name.erase(0, 1);
      return name;
   }

   bool IsFrameProfileActive(const XrPath userPath) const
   {
      XrInteractionProfileState state { XR_TYPE_INTERACTION_PROFILE_STATE };
      return xrGetCurrentInteractionProfile(m_session, userPath, &state) == XR_SUCCESS && state.interactionProfile == m_frameProfilePath;
   }

   static XrActionType ToXrActionType(const VPX::XRInput::ActionType type)
   {
      switch (type)
      {
      case VPX::XRInput::ActionType::Boolean: return XR_ACTION_TYPE_BOOLEAN_INPUT;
      case VPX::XRInput::ActionType::Float: return XR_ACTION_TYPE_FLOAT_INPUT;
      case VPX::XRInput::ActionType::Vector2: return XR_ACTION_TYPE_VECTOR2F_INPUT;
      case VPX::XRInput::ActionType::Pose: return XR_ACTION_TYPE_POSE_INPUT;
      case VPX::XRInput::ActionType::Haptic: return XR_ACTION_TYPE_VIBRATION_OUTPUT;
      }
      assert(false && "Unknown XR input action type");
      return XR_ACTION_TYPE_BOOLEAN_INPUT;
   }

   void TriggerAction(const unsigned int actionId, const int directStateSlot)
   {
      InputAction* action = m_pininput.GetInputActions()[actionId].get();
      action->SetDirectState(directStateSlot, true);
      action->SetDirectState(directStateSlot, false);
   }

   void SuggestBindings(const char* profile, std::vector<XrActionSuggestedBinding>& bindings)
   {
      XrPath profilePath;
      if (xrStringToPath(m_instance, profile, &profilePath) != XR_SUCCESS)
         return;

      vector<XrActionSuggestedBinding> acceptedBindings;
      for (XrActionSuggestedBinding& binding : bindings)
      {
         XrInteractionProfileSuggestedBinding suggested { XR_TYPE_INTERACTION_PROFILE_SUGGESTED_BINDING };
         suggested.interactionProfile = profilePath;
         suggested.suggestedBindings = &binding;
         suggested.countSuggestedBindings = 1;
         if (xrSuggestInteractionProfileBindings(m_instance, &suggested) == XR_SUCCESS)
            acceptedBindings.push_back(binding);
      }

      XrInteractionProfileSuggestedBinding suggested { XR_TYPE_INTERACTION_PROFILE_SUGGESTED_BINDING };
      suggested.interactionProfile = profilePath;
      suggested.suggestedBindings = acceptedBindings.data();
      suggested.countSuggestedBindings = (uint32_t)acceptedBindings.size();
      if (xrSuggestInteractionProfileBindings(m_instance, &suggested) != XR_SUCCESS)
      {
         PLOGE << "Failed to setup OpenXR controller bindings for profile " << profile;
      }
      else
      {
         PLOGI << "Successfully defined " << acceptedBindings.size() << " OpenXR controller bindings for profile " << profile;
      }
   }

   void SuggestBindingsExact(const char* profile, std::vector<XrActionSuggestedBinding>& bindings)
   {
      XrPath profilePath;
      if (xrStringToPath(m_instance, profile, &profilePath) != XR_SUCCESS)
      {
         PLOGE << "Failed to resolve Frame controller interaction profile " << profile;
         return;
      }

      XrInteractionProfileSuggestedBinding suggested { XR_TYPE_INTERACTION_PROFILE_SUGGESTED_BINDING };
      suggested.interactionProfile = profilePath;
      suggested.suggestedBindings = bindings.data();
      suggested.countSuggestedBindings = static_cast<uint32_t>(bindings.size());
      const XrResult result = xrSuggestInteractionProfileBindings(m_instance, &suggested);
      if (result != XR_SUCCESS)
         PLOGE << "Failed to setup " << bindings.size() << " explicit Steam Frame OpenXR bindings (" << result << ')';
      else
         PLOGI << "Successfully defined " << bindings.size() << " explicit Steam Frame OpenXR bindings";
   }

public:
   XrAction GetAction(const std::string& path) const
   {
      for (const auto& t : m_trackers)
         if (t.path == path)
            return t.action;
      return XR_NULL_HANDLE;
   }

private:

   InputManager& m_pininput;
   XrInstance m_instance;
   XrSession m_session;
   XrActionSet m_actionSet;
   std::vector<ActionTracker> m_trackers;
   std::vector<XrAction> m_hapticActions;
   VPX::XRInput::ViewHoldGesture m_viewHoldGesture;
   int m_buttonBackActionSlot = -1;
   int m_viewBackActionSlot = -1;
   int m_recenterActionSlot = -1;

   uint16_t m_joyId;
   XrPath m_frameProfilePath = XR_NULL_PATH;
   XrPath m_leftHandPath = XR_NULL_PATH;
   XrPath m_rightHandPath = XR_NULL_PATH;
   bool m_frameControllerProfileSupported = false;
};
