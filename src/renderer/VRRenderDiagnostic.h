// license:GPLv3+

#pragma once

#include <algorithm>
#include <charconv>
#include <cstdint>
#include <string_view>
#include <system_error>

namespace VPX::VRDiagnostics
{

inline constexpr uint32_t MaxForcedRenderFrames = 240;

inline uint32_t ParseForcedRenderFrameLimit(const std::string_view value)
{
   if (value.empty())
      return 0;
   uint32_t requested = 0;
   const auto [end, error] = std::from_chars(value.data(), value.data() + value.size(), requested);
   if (error != std::errc{} || end != value.data() + value.size() || requested == 0)
      return 0;
   return std::min(requested, MaxForcedRenderFrames);
}

inline constexpr bool ShouldForceStandbyRender(const bool synchronized, const bool runtimeShouldRender, const uint32_t attempts,
   const uint32_t frameLimit)
{
   return synchronized && !runtimeShouldRender && frameLimit != 0 && attempts < frameLimit;
}

} // namespace VPX::VRDiagnostics
