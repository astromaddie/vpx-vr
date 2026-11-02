// license:GPLv3+

#include "core/stdafx.h"

#include "TextureManager.h"
#include "RenderDevice.h"
#include "Texture.h"

#if defined(ENABLE_BGFX)
#include "TextureCompressor.h" // CompressedTexture
#include "TextureBudget.h"
#include <format>
#if defined(__linux__)
#include <fstream>
#include <sstream>
#endif
#endif

std::shared_ptr<Sampler> TextureManager::LoadTexture(ITexManCacheable* const memtex, const bool force_linear_rgb, const bool pinned)
{
   const std::lock_guard lock(m_mapMutex);
   const uint64_t hash = memtex->GetLiveHash();
   const SamplerVariant variant = SamplerVariantOf(force_linear_rgb);
   Iter it = m_map.find(hash);
   if (it == m_map.end())
   {
      MapEntry entry;
      entry.tex = memtex;
      it = m_map.emplace(hash, std::move(entry)).first;
   }

   MapEntry& entry = it->second;
   std::shared_ptr<Sampler>& sampler = entry.samplers[variant];
   entry.pinned |= pinned;
#if defined(ENABLE_BGFX)
   RefreshBudget();
   entry.lastUsedFrame = m_statsFrame;
#endif

   if (entry.pendingUpload)
   {
      // Consumed by whichever variant asks first, dropping the strong reference that was keeping the decoded
      // bitmap alive. A second variant requested later therefore falls in the branch below and calls
      // GetRawBitmap(), which only holds the bitmap weakly and so re-decodes the image from its compressed
      // data. Content is still correct, but will be a decode on the render thread then
#if defined(ENABLE_BGFX)
      sampler = CreateSampler(entry, variant, force_linear_rgb, std::move(entry.pendingUpload));
#else
      sampler = std::make_shared<Sampler>(&m_rd, memtex->GetName(), m_rd.OrFallback(std::move(entry.pendingUpload)), force_linear_rgb);
#endif
   }
   else if (sampler == nullptr)
   {
#if defined(ENABLE_BGFX)
      sampler = CreateSampler(entry, variant, force_linear_rgb, memtex->GetRawBitmap(false, 0));
#else
      sampler = std::make_shared<Sampler>(&m_rd, memtex->GetName(), m_rd.OrFallback(memtex->GetRawBitmap(false, 0)), force_linear_rgb);
#endif
   }
   else if (entry.dirty[variant])
   {
      entry.dirty[variant] = false; // Only the variant actually refreshed below, the other keeps waiting its turn
#if defined(ENABLE_BGFX)
      if (entry.isPlaceHolder)
         sampler->UpdateTexture(m_rd.OrFallback(memtex->GetRawBitmap(false, 0)), force_linear_rgb);
      else if (std::shared_ptr<const BaseTexture> bitmap = memtex->GetRawBitmap(false, 0); bitmap != nullptr) // Nothing decodable keeps the previous content
      {
         if (entry.fullBytes[variant] == 0 && bitmap->width() == static_cast<unsigned int>(sampler->GetWidth()) && bitmap->height() == static_cast<unsigned int>(sampler->GetHeight()))
            // Same size update, written into the existing allocation: the accounted bytes are unchanged (Reconcile below
            // catches a format change to an uncompressed upload)
            sampler->UpdateTexture(bitmap, force_linear_rgb);
         else
         {
            // A degraded (downsized or fallback) or resized sampler cannot be updated in place, as the allocation keeps
            // its size: recreate it through admission instead
            Retire(sampler, entry.gpuBytes[variant]);
            sampler = CreateSampler(entry, variant, force_linear_rgb, std::move(bitmap));
         }
      }
#else
      sampler->UpdateTexture(m_rd.OrFallback(memtex->GetRawBitmap(false, 0)), force_linear_rgb);
#endif
   }
#if defined(ENABLE_BGFX)
   else if (entry.fullBytes[variant] > 0 && (entry.pinned || m_statsFrame >= entry.upgradeRetryFrame))
   {
      // Degraded (downsized or fallback) under memory pressure: re-upload at full size once it fits below the
      // eviction target, not just the cap, so that it does not immediately evict other textures. A texture pinned
      // after it was degraded is restored right away
      entry.upgradeRetryFrame = m_statsFrame + kUpgradeRetryFrames;
      if (entry.pinned || (m_gpuMemBudget > 0 && ProjectedUse(static_cast<int64_t>(entry.fullBytes[variant]) - static_cast<int64_t>(entry.gpuBytes[variant])) <= (m_gpuMemBudget * kEvictTargetPct) / 100))
      {
         Retire(sampler, entry.gpuBytes[variant]);
         sampler = CreateSampler(entry, variant, force_linear_rgb, memtex->GetRawBitmap(false, 0));
      }
   }
   if (sampler && !entry.isPlaceHolder)
      Reconcile(entry, variant);
#endif
   return sampler;
}

void TextureManager::AddPendingUpload(ITexManCacheable* memtex, std::shared_ptr<const BaseTexture> bitmap)
{
   const std::lock_guard lock(m_mapMutex);
   const CIter it = m_map.find(memtex->GetLiveHash());
   if (it == m_map.end())
   {
      MapEntry entry;
      entry.pendingUpload = bitmap ? std::move(bitmap) : memtex->GetRawBitmap(false, 0);
      entry.tex = memtex;
      m_map[memtex->GetLiveHash()] = entry;
   }
}

void TextureManager::AddPlaceHolder(ITexManCacheable* memtex)
{
   const std::lock_guard lock(m_mapMutex);
   const CIter it = m_map.find(memtex->GetLiveHash());
   if (it == m_map.end())
   {
      MapEntry entry;
      // Uses the shared fallback tex, so a failed load and an uncreatable texture look alike.
      // Both variants share the one sampler, and it is replaced as soon as the real texture loads
      entry.samplers[VARIANT_SRGB]   = std::make_shared<Sampler>(&m_rd, memtex->GetName(), m_rd.m_fallbackTexture, false);
      entry.samplers[VARIANT_LINEAR] = entry.samplers[VARIANT_SRGB];
      entry.isPlaceHolder = true;
      entry.tex = memtex;
      m_map[memtex->GetLiveHash()] = entry;
   }
}

vector<ITexManCacheable*> TextureManager::GetLoadedTextures() const
{
   const std::lock_guard lock(m_mapMutex);
   std::vector<ITexManCacheable*> keys;
   for (const auto& it : m_map)
      if (!it.second.isPlaceHolder && !it.second.pendingUpload)
         keys.push_back(it.second.tex);
   return keys;
}

bool TextureManager::IsLinearRGB(ITexManCacheable* memtex) const
{
   const std::lock_guard lock(m_mapMutex);
   const CIter it = m_map.find(memtex->GetLiveHash());
   // A placeholder aliases both variants onto a single sRGB sampler, so it is not a linear upload
   return it != m_map.end() && !it->second.isPlaceHolder && it->second.samplers[VARIANT_LINEAR] != nullptr;
}

void TextureManager::SetDirty(ITexManCacheable* memtex)
{
   const std::lock_guard lock(m_mapMutex);
   const Iter it = m_map.find(memtex->GetLiveHash());
   if (it != m_map.end())
      for (bool& dirty : it->second.dirty) // Every live variant needs refreshing, not just the next one drawn
         dirty = true;
}

void TextureManager::UnloadTexture(ITexManCacheable* memtex)
{
   const std::lock_guard lock(m_mapMutex);
   const Iter it = m_map.find(memtex->GetLiveHash());
   if (it != m_map.end())
   {
#if defined(ENABLE_BGFX)
      for (unsigned int v = 0; v < VARIANT_COUNT; ++v)
         Retire(it->second.samplers[v], it->second.gpuBytes[v]);
#endif
      m_map.erase(it);
   }
}

void TextureManager::UnloadAll()
{
   const std::lock_guard lock(m_mapMutex);
#if defined(ENABLE_BGFX)
   // Samplers still referenced elsewhere stay accounted until destroyed, the deferred destroys still reach the driver
   for (auto& [hash, entry] : m_map)
      for (unsigned int v = 0; v < VARIANT_COUNT; ++v)
         Retire(entry.samplers[v], entry.gpuBytes[v]);
#endif
   m_map.clear();
}

void TextureManager::SetBudgetOverride([[maybe_unused]] const int64_t bytes)
{
#if defined(ENABLE_BGFX)
   const std::lock_guard lock(m_mapMutex);
   m_budgetOverride = std::max<int64_t>(bytes, 0);
   m_gpuMemBudget = VPX::TextureBudget::EffectiveBudget(m_driverBudget, m_budgetOverride);
   if (m_budgetOverride > 0)
      PLOGI << "TexBudget: GPU memory budget override " << (m_budgetOverride >> 20) << " MB (replaces the driver's figure)";
#endif
}

#if defined(ENABLE_BGFX)
#pragma region GPU memory budget management (BGFX only)

namespace
{
// System RAM still available, which bounds Turnip's VK_EXT_memory_budget figure on unified memory. -1 where unknown
int64_t MemAvailableMB()
{
#if defined(__linux__)
   std::ifstream meminfo("/proc/meminfo");
   if (!meminfo)
      return -1;
   std::stringstream content;
   content << meminfo.rdbuf();
   const int64_t kb = VPX::TextureBudget::ParseMemAvailableKB(content.str());
   return kb < 0 ? -1 : kb / 1024;
#else
   return -1;
#endif
}

string FormatMB(const int64_t bytes) { return std::format("{:.1f}", static_cast<double>(bytes) / (1024. * 1024.)); }
}

size_t TextureManager::EstimateGpuBytes(const BaseTexture* tex, const bool allowCompressed) const
{
   if (tex == nullptr)
      return 0;
   if (allowCompressed && tex->m_compressed && m_rd.m_compressTextures) // Same condition as Sampler's precompressed upload
      return tex->m_compressed->data.size() + tex->m_compressed->GetMipSize(0); // Mip chain plus the no-mips alias
   // Bytes per texel of the GPU format (UncompressedBgfxFormat in Sampler.cpp), not of the bitmap: SRGB and SRGB565
   // upload as RGBA8, RGB float as RGBA float, and RGB8 is padded to 4 bytes by most drivers
   size_t texelBytes;
   switch (tex->m_format)
   {
   case BaseTexture::BW: texelBytes = 1; break;
   case BaseTexture::RGB_FP16:
   case BaseTexture::RGBA_FP16: texelBytes = 8; break;
   case BaseTexture::RGB_FP32:
   case BaseTexture::RGBA_FP32: texelBytes = 16; break;
   default: texelBytes = 4; break; // BW_FP32, RGB, SRGB, RGBA, SRGBA, SRGB565
   }
   // Mipmapped texture only: a sampler also sampled without mipmaps keeps the base level too, which Reconcile accounts
   // once allocated, rather than reserving it for every texture
   return VPX::TextureBudget::MippedBytes(texelBytes, tex->width(), tex->height());
}

void TextureManager::RefreshBudget()
{
   const RenderDevice::GpuMemorySnapshot stats = m_rd.GetGpuMemorySnapshot();
   if (stats.gpuFrameNum == m_statsFrame)
      return;
   m_statsFrame = stats.gpuFrameNum;
   m_driverBudget = stats.gpuMemoryMax;
   m_gpuMemBudget = VPX::TextureBudget::EffectiveBudget(m_driverBudget, m_budgetOverride);
   m_gpuMemUsed = stats.gpuMemoryUsed;
   // Retired samplers destroyed since the last sample now wait for their deferred destroy to reach the driver
   for (size_t i = 0; i < m_retired.size();)
   {
      if (m_retired[i].sampler.expired())
      {
         m_retiredBytes -= m_retired[i].bytes;
         m_pendingFree.emplace_back(m_statsFrame, m_retired[i].bytes);
         m_pendingFreeBytes += m_retired[i].bytes;
         m_retired[i] = m_retired.back();
         m_retired.pop_back();
      }
      else
         i++;
   }
   // Destroyed samplers take a few frames before their memory is actually freed by the driver (BGFX may then still keep
   // the allocation in its own reuse cache, which shows up in m_otherBytes)
   while (!m_pendingFree.empty() && m_statsFrame - m_pendingFree.front().first >= kFreeLatencyFrames)
   {
      m_pendingFreeBytes -= m_pendingFree.front().second;
      m_pendingFree.pop_front();
   }
   // gpuMemoryUsed covers the whole process: the share neither owned by this manager nor about to be freed
   // (render targets, buffers, staging, ...) acts as a baseline for projected usage between stats updates
   m_otherBytes = std::max<int64_t>(0, m_gpuMemUsed - m_managedBytes - m_retiredBytes - m_pendingFreeBytes);
   if (!m_loggedFirstSample && m_driverBudget > 0)
   {
      m_loggedFirstSample = true;
      LogBudget("first sample", ""s, 0, true);
   }
}

int64_t TextureManager::ProjectedUse(const int64_t added) const
{
   // Bytes of destroyed samplers leave the projection right away, so that eviction actually makes room. They are still
   // resident for a few frames (kFreeLatencyFrames), a transient overshoot covered by the headroom above BudgetCap()
   return m_otherBytes + m_managedBytes + m_retiredBytes + added;
}

void TextureManager::Retire(std::shared_ptr<Sampler>& sampler, size_t& bytes)
{
   m_managedBytes -= static_cast<int64_t>(bytes);
   const int64_t retired = static_cast<int64_t>(bytes);
   bytes = 0;
   if (sampler == nullptr)
      return;
   std::weak_ptr<Sampler> weak = sampler;
   sampler.reset();
   if (retired == 0)
      return;
   if (weak.expired())
   {
      // Destroyed right now: BGFX releases its textures with the next frames
      m_pendingFree.emplace_back(m_statsFrame, retired);
      m_pendingFreeBytes += retired;
   }
   else
   {
      m_retired.push_back({ std::move(weak), retired });
      m_retiredBytes += retired;
   }
}

void TextureManager::Reconcile(MapEntry& entry, const SamplerVariant variant)
{
   const size_t actual = entry.samplers[variant]->GetGpuBytes();
   if (actual > entry.gpuBytes[variant])
   {
      m_managedBytes += static_cast<int64_t>(actual - entry.gpuBytes[variant]);
      entry.gpuBytes[variant] = actual;
   }
}

bool TextureManager::MakeRoom(const size_t needed, unsigned int* const evicted)
{
   if (m_gpuMemBudget <= 0 || ProjectedUse(static_cast<int64_t>(needed)) <= BudgetCap())
      return true;

   NotifyPressure();

   // Evict least recently used samplers, excluding placeholders (tiny shared fallback), pinned ones, recently used ones
   // which are likely referenced by in-flight draws, and ones referenced outside of the manager (bound shader state,
   // ImGui, queued uploads) since dropping them would not free anything
   vector<std::pair<uint32_t, Iter>> victims;
   for (Iter it = m_map.begin(); it != m_map.end(); ++it)
   {
      const MapEntry& entry = it->second;
      if (entry.isPlaceHolder || entry.pinned || entry.lastUsedFrame + kEvictGraceFrames >= m_statsFrame)
         continue;
      for (const auto& sampler : entry.samplers)
         if (sampler && sampler.use_count() == 1)
         {
            victims.emplace_back(entry.lastUsedFrame, it);
            break;
         }
   }
   std::sort(victims.begin(), victims.end(), [](const auto& a, const auto& b) { return a.first < b.first; }); // Least recently used first

   const int64_t target = (m_gpuMemBudget * kEvictTargetPct) / 100;
   for (const auto& victim : victims)
   {
      if (ProjectedUse(static_cast<int64_t>(needed)) <= target)
         break;
      MapEntry& entry = victim.second->second;
      for (unsigned int v = 0; v < VARIANT_COUNT; ++v)
         if (entry.samplers[v] && entry.samplers[v].use_count() == 1)
         {
            PLOGI << "GPU memory limit: evicting texture '" << entry.tex->GetName() << '\'';
            Retire(entry.samplers[v], entry.gpuBytes[v]);
            entry.fullBytes[v] = 0;
            entry.dirty[v] = false;
            if (evicted)
               (*evicted)++;
         }
      // The entry stays registered: the texture is transparently re-uploaded on next use
   }

   return ProjectedUse(static_cast<int64_t>(needed)) <= BudgetCap();
}

std::shared_ptr<Sampler> TextureManager::CreateSampler(MapEntry& entry, const SamplerVariant variant, const bool force_linear_rgb, std::shared_ptr<const BaseTexture> bitmap)
{
   bitmap = m_rd.OrFallback(std::move(bitmap));
   size_t est = EstimateGpuBytes(bitmap.get());
   entry.fullBytes[variant] = 0;

   unsigned int evicted = 0;
   if (!MakeRoom(est, &evicted))
   {
      if (entry.pinned)
         // Never degraded: uploaded over the cap, the next uploads make room again (or degrade) against it
         LogBudget("pinned, admitted over the cap", entry.tex->GetName(), est, true);
      else
      {
         // Out of budget even after evicting: try a downsized copy before degrading to the fallback texture. The size is
         // chosen to fit the room left, from the loaded size (not the declared one, which is larger when capped by the
         // max texture dimension setting). The copy is uncompressed, so it is sized from the uncompressed estimate
         entry.fullBytes[variant] = est;
         entry.upgradeRetryFrame = m_statsFrame + kUpgradeRetryFrames;
         const unsigned int maxDim = std::max(bitmap->width(), bitmap->height());
         const unsigned int dim = VPX::TextureBudget::PickDownsizeDim(maxDim, EstimateGpuBytes(bitmap.get(), false), BudgetCap() - ProjectedUse(0), MIN_TEXTURE_SIZE);
         std::shared_ptr<const BaseTexture> downsized = (dim > 0 && bitmap != m_rd.m_fallbackTexture) ? entry.tex->GetDownsizedBitmap(dim) : nullptr;
         if (downsized != nullptr && std::max(downsized->width(), downsized->height()) < maxDim && MakeRoom(EstimateGpuBytes(downsized.get())))
         {
            PLOGW << "GPU memory limit: image '" << entry.tex->GetName() << "' was downsized to " << downsized->width() << 'x' << downsized->height();
            LogBudget(std::format("downsized to {}x{}", downsized->width(), downsized->height()).c_str(), entry.tex->GetName(), est);
            if (m_notify)
               m_downsizeNotifId = m_notify("Image '" + entry.tex->GetName() + "' was downsized due to low GPU memory"s, 5000, m_downsizeNotifId);
            bitmap = std::move(downsized);
         }
         else
         {
            PLOGW << "GPU memory limit: image '" << entry.tex->GetName() << "' skipped (out of GPU memory)";
            LogBudget("fallback texture", entry.tex->GetName(), est);
            if (m_notify)
               m_downsizeNotifId = m_notify("Image '" + entry.tex->GetName() + "' could not be uploaded, out of GPU memory"s, 5000, m_downsizeNotifId);
            bitmap = m_rd.m_fallbackTexture;
         }
         est = EstimateGpuBytes(bitmap.get());
      }
   }
   else if (evicted > 0)
      LogBudget(std::format("admitted after evicting {} textures", evicted).c_str(), entry.tex->GetName(), est);

   m_managedBytes += static_cast<int64_t>(est) - static_cast<int64_t>(entry.gpuBytes[variant]);
   entry.gpuBytes[variant] = est;
   return std::make_shared<Sampler>(&m_rd, entry.tex->GetName(), std::move(bitmap), force_linear_rgb);
}

void TextureManager::LogBudget(const char* const decision, const string& name, const size_t upload, const bool force)
{
   const uint32_t now = msec();
   if (!force && now < m_logNextMs)
   {
      m_logSuppressed++;
      return;
   }
   m_logNextMs = now + kLogIntervalMs;
   const int64_t memAvailable = MemAvailableMB();
   // Grep 'TexBudget:'. Byte figures are MB. 'used' and 'driver budget' are bgfx::Stats gpuMemoryUsed/gpuMemoryMax as
   // sampled after the last frame, the others are this manager's estimates
   PLOGW << std::format("TexBudget: {} '{}' upload={} | budget={} (driver {}, override {}) cap={} used={} managed={} retired={} pendingFree={} other={} "
                        "projected={} | MemAvailable={} | gpuFrame={} suppressed={}",
      decision, name, FormatMB(upload), FormatMB(m_gpuMemBudget), FormatMB(m_driverBudget), FormatMB(m_budgetOverride), FormatMB(BudgetCap()), FormatMB(m_gpuMemUsed), FormatMB(m_managedBytes),
      FormatMB(m_retiredBytes), FormatMB(m_pendingFreeBytes), FormatMB(m_otherBytes), FormatMB(ProjectedUse(static_cast<int64_t>(upload))), memAvailable < 0 ? "n/a"s : std::to_string(memAvailable),
      m_statsFrame, m_logSuppressed);
   m_logSuppressed = 0;
}

void TextureManager::NotifyPressure()
{
   const uint32_t now = msec();
   if (now < m_pressureNotifCooldown || !m_notify)
      return;
   m_pressureNotifCooldown = now + 30 * 1000; // Rate limit the notifications
   m_pressureNotifId = m_rd.m_compressTextures
      ? m_notify("GPU memory limit reached, releasing least recently used textures"s, 8000, m_pressureNotifId)
      : m_notify("GPU memory limit reached and 'Compress Textures' is disabled. Enabling it in the graphic settings reduces texture memory ~4x."s, 10000, m_pressureNotifId);
}

#pragma endregion
#endif
