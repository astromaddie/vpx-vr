// license:GPLv3+

#pragma once

namespace VPX::Input
{

constexpr bool HasAnyDeviceMappings(const bool actionMappings, const bool plungerMappings, const bool nudgeMappings)
{
   return actionMappings || plungerMappings || nudgeMappings;
}

constexpr bool ShouldAutoApplyVRControllerLayout(const bool preserveExistingMappings, const bool hasExistingMappings)
{
   return !(preserveExistingMappings && hasExistingMappings);
}

} // namespace VPX::Input
