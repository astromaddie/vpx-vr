// license:GPLv3+

#pragma once

// Pure helpers of the texture manager GPU memory budget (no renderer dependency, unit tested)

#include <algorithm>
#include <charconv>
#include <cstddef>
#include <cstdint>
#include <string_view>
#include <system_error>
#include <type_traits>

namespace VPX::TextureBudget
{

// Bytes of an uncompressed 2D texture with its full mip chain (base level plus ~1/3)
constexpr size_t MippedBytes(const size_t texelBytes, const unsigned int width, const unsigned int height)
{
   return (texelBytes * width * height * 4) / 3;
}

// Parses a whole number of megabytes, as given by VPX_GPU_MEMORY_BUDGET. Returns -1 when missing or malformed
inline int64_t ParseMegabytes(const std::string_view value)
{
   if (value.empty() || value.size() > 9)
      return -1;
   int64_t mb = 0;
   const auto [end, error] = std::from_chars(value.data(), value.data() + value.size(), mb);
   return (error == std::errc() && end == value.data() + value.size() && mb >= 0) ? mb : -1;
}

// Budget override in bytes, 0 to use the driver's figure. A valid environment value wins over the setting, so that
// a device A/B does not need to edit the settings file
inline int64_t ResolveBudgetOverride(const char* const env, const int settingMB)
{
   const int64_t envMB = env ? ParseMegabytes(env) : -1;
   const int64_t mb = envMB >= 0 ? envMB : std::max(settingMB, 0);
   return mb << 20;
}

// Budget the admission policy works against: the override if any, otherwise what the driver reports (<= 0 means unmanaged)
constexpr int64_t EffectiveBudget(const int64_t driverBudget, const int64_t overrideBytes)
{
   return overrideBytes > 0 ? overrideBytes : driverBudget;
}

// Largest dimension maxDim >> k (k >= 1) at which an image needing bytesAtMaxDim at maxDim fits in available bytes, as
// bytes scale with the area. Returns 0 when even minDim does not fit (or when maxDim cannot be halved above minDim)
constexpr unsigned int PickDownsizeDim(const unsigned int maxDim, const size_t bytesAtMaxDim, const int64_t available, const unsigned int minDim)
{
   if (available <= 0)
      return 0;
   size_t bytes = bytesAtMaxDim;
   for (unsigned int dim = maxDim / 2; dim >= minDim && dim > 0; dim /= 2)
   {
      bytes /= 4;
      if (static_cast<int64_t>(bytes) <= available)
         return dim;
   }
   return 0;
}

// Reads MemAvailable from the content of /proc/meminfo, in kB. Returns -1 if absent
inline int64_t ParseMemAvailableKB(const std::string_view meminfo)
{
   constexpr std::string_view key = "MemAvailable:";
   const size_t pos = meminfo.find(key);
   if (pos == std::string_view::npos)
      return -1;
   size_t start = pos + key.size();
   while (start < meminfo.size() && meminfo[start] == ' ')
      start++;
   int64_t kb = 0;
   const auto [end, error] = std::from_chars(meminfo.data() + start, meminfo.data() + meminfo.size(), kb);
   return (error == std::errc() && end != meminfo.data() + start) ? kb : -1;
}

// Halves an image (tightly packed, 'channels' interleaved values per texel) with a 2x2 box filter. The destination
// is max(1, width / 2) x max(1, height / 2); with an odd size, the last row or column is folded into its neighbour's box
template <typename T> void Downsample2x(const T* const src, const unsigned int width, const unsigned int height, const unsigned int channels, T* const dst)
{
   const unsigned int dstWidth = std::max(1u, width / 2), dstHeight = std::max(1u, height / 2);
   for (unsigned int y = 0; y < dstHeight; y++)
   {
      const size_t y0 = std::min(2 * y, height - 1), y1 = std::min(2 * y + 1, height - 1);
      for (unsigned int x = 0; x < dstWidth; x++)
      {
         const size_t x0 = std::min(2 * x, width - 1), x1 = std::min(2 * x + 1, width - 1);
         for (unsigned int c = 0; c < channels; c++)
         {
            const T a = src[(y0 * width + x0) * channels + c], b = src[(y0 * width + x1) * channels + c];
            const T d = src[(y1 * width + x0) * channels + c], e = src[(y1 * width + x1) * channels + c];
            if constexpr (std::is_floating_point_v<T>)
               dst[(static_cast<size_t>(y) * dstWidth + x) * channels + c] = (a + b + d + e) * static_cast<T>(0.25);
            else
               dst[(static_cast<size_t>(y) * dstWidth + x) * channels + c] = static_cast<T>((static_cast<unsigned int>(a) + b + d + e + 2) / 4);
         }
      }
   }
}

}
