// license:GPLv3+

#include "renderer/TextureBudget.h"

#include "doctest.h"

#include <vector>

using namespace VPX::TextureBudget;

TEST_CASE("Texture budget override: environment wins over the setting, 0 uses the driver")
{
   CHECK(ResolveBudgetOverride(nullptr, 0) == 0);
   CHECK(ResolveBudgetOverride(nullptr, 3072) == 3072ll << 20);
   CHECK(ResolveBudgetOverride(nullptr, -5) == 0);
   CHECK(ResolveBudgetOverride("4096", 3072) == 4096ll << 20);
   CHECK(ResolveBudgetOverride("0", 3072) == 0); // Explicit 0 in the environment forces the driver's figure
   CHECK(ResolveBudgetOverride("", 3072) == 3072ll << 20); // Malformed values fall back to the setting
   CHECK(ResolveBudgetOverride("2g", 3072) == 3072ll << 20);
   CHECK(ResolveBudgetOverride("-1", 3072) == 3072ll << 20);
   CHECK(ResolveBudgetOverride("99999999999", 0) == 0);

   CHECK(EffectiveBudget(1459ll << 20, 0) == 1459ll << 20);
   CHECK(EffectiveBudget(1459ll << 20, 4096ll << 20) == 4096ll << 20);
   CHECK(EffectiveBudget(-1, 0) == -1); // Unmanaged backend stays unmanaged
   CHECK(EffectiveBudget(-1, 512ll << 20) == 512ll << 20);
}

TEST_CASE("Texture budget estimate covers the mip chain")
{
   CHECK(MippedBytes(4, 1024, 1024) == (4u * 1024 * 1024 * 4) / 3);
   CHECK(MippedBytes(1, 0, 16) == 0);
}

TEST_CASE("Downsize dimension is the largest halving fitting the available bytes")
{
   const size_t full = MippedBytes(4, 4096, 4096); // ~85 MB
   CHECK(PickDownsizeDim(4096, full, static_cast<int64_t>(full), 8) == 2048); // Always at least one halving
   CHECK(PickDownsizeDim(4096, full, static_cast<int64_t>(full / 4), 8) == 2048);
   CHECK(PickDownsizeDim(4096, full, static_cast<int64_t>(full / 4) - 1, 8) == 1024);
   CHECK(PickDownsizeDim(4096, full, static_cast<int64_t>(full / 64), 8) == 512);
   CHECK(PickDownsizeDim(4096, full, 1, 8) == 0); // Not even the minimum size fits
   CHECK(PickDownsizeDim(4096, full, 0, 8) == 0);
   CHECK(PickDownsizeDim(4096, full, -100, 8) == 0);
   CHECK(PickDownsizeDim(8, MippedBytes(4, 8, 8), 1 << 20, 8) == 0); // Already at the minimum size
   CHECK(PickDownsizeDim(16, MippedBytes(4, 16, 16), 1 << 20, 8) == 8);
}

TEST_CASE("MemAvailable is read from /proc/meminfo content")
{
   CHECK(ParseMemAvailableKB("MemTotal:       15921400 kB\nMemFree:          812344 kB\nMemAvailable:    6656000 kB\nBuffers:  1 kB\n") == 6656000);
   CHECK(ParseMemAvailableKB("MemAvailable:0 kB") == 0);
   CHECK(ParseMemAvailableKB("MemTotal: 1 kB\n") == -1);
   CHECK(ParseMemAvailableKB("MemAvailable: kB") == -1);
}

TEST_CASE("2x box downsample of 8 bit and float images")
{
   // 4x2 RGBA8 -> 2x1
   const std::vector<uint8_t> src = {
      0, 0, 0, 255,      4, 8, 12, 255,      100, 100, 100, 0,   200, 200, 200, 0,
      8, 16, 24, 255,    12, 0, 0, 255,      50, 50, 50, 0,      254, 254, 254, 4,
   };
   std::vector<uint8_t> dst(2 * 1 * 4);
   Downsample2x(src.data(), 4, 2, 4, dst.data());
   CHECK(dst == std::vector<uint8_t> { 6, 6, 9, 255, 151, 151, 151, 1 }); // Rounded averages

   // Odd sizes fold the last row and column: 3x3 BW -> 1x1 averages the top left 2x2 box
   const std::vector<uint8_t> bw = { 10, 20, 99, 30, 40, 99, 99, 99, 99 };
   uint8_t bwDst = 0;
   Downsample2x(bw.data(), 3, 3, 1, &bwDst);
   CHECK(bwDst == 25);

   // Single row: 4x1 -> 2x1, each box reads its row twice
   const std::vector<float> row = { 1.f, 3.f, -2.f, 2.f };
   std::vector<float> rowDst(2);
   Downsample2x(row.data(), 4, 1, 1, rowDst.data());
   CHECK(rowDst[0] == doctest::Approx(2.f));
   CHECK(rowDst[1] == doctest::Approx(0.f));

   // 1x1 stays 1x1
   const float one[3] = { 0.25f, 0.5f, 1.f };
   float oneDst[3] = {};
   Downsample2x(one, 1, 1, 3, oneDst);
   CHECK(oneDst[2] == doctest::Approx(1.f));
}
