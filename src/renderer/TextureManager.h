// license:GPLv3+

#pragma once

#include <deque>
#include <functional>
#include <mutex>

#include "unordered_dense.h"

#include "Texture.h"
#include "Sampler.h"
#include "typedefs3D.h"

class RenderDevice;

class TextureManager final
{
public:
   TextureManager(RenderDevice& rd) : m_rd(rd)
   { }

   ~TextureManager()
   {
      UnloadAll();
   }

   void AddPlaceHolder(ITexManCacheable* memtex);
   void AddPendingUpload(ITexManCacheable* memtex, std::shared_ptr<const BaseTexture> bitmap = nullptr);
   // A pinned texture is never evicted, downsized or replaced by the fallback for lack of GPU memory, for content that is
   // either held outside of the manager (ImGui font atlas) or wrong when degraded (color grading LUT). Pinning is sticky
   std::shared_ptr<Sampler> LoadTexture(ITexManCacheable* const memtex, const bool force_linear_rgb, const bool pinned = false);
   void SetDirty(ITexManCacheable* memtex);
   void UnloadTexture(ITexManCacheable* memtex);
   void UnloadAll();

   vector<ITexManCacheable*> GetLoadedTextures() const;
   bool IsLinearRGB(ITexManCacheable* memtex) const;

   // Total GPU memory budget override in bytes, replacing the driver's figure, 0 to use the driver's one (BGFX only)
   void SetBudgetOverride(int64_t bytes);

   // Notification sink, wired by the owner (Player routes it to LiveUI::PushNotification):
   // (message, lengthMs, reuseId) -> notification id
   std::function<unsigned int(const string&, int, unsigned int)> m_notify;

private:
   // A texture may be uploaded twice, once decoded as sRGB and once kept linear (see LoadTexture's force_linear_rgb).
   // Per variant state is indexed rather than paired up, so that state added later cannot silently apply to one variant only
   enum SamplerVariant : unsigned int { VARIANT_SRGB = 0, VARIANT_LINEAR = 1, VARIANT_COUNT = 2 };
   static constexpr SamplerVariant SamplerVariantOf(const bool force_linear_rgb) { return force_linear_rgb ? VARIANT_LINEAR : VARIANT_SRGB; }

   struct MapEntry
   {
      std::shared_ptr<Sampler> samplers[VARIANT_COUNT];
      bool dirty[VARIANT_COUNT] = { false, false };
      ITexManCacheable* tex = nullptr;
      bool isPlaceHolder = false;
      bool pinned = false;
      std::shared_ptr<const class BaseTexture> pendingUpload;
      uint32_t lastUsedFrame = 0; // Frame index of the last use, for LRU eviction
      size_t gpuBytes[VARIANT_COUNT] = { 0, 0 }; // Estimated resident bytes of each variant
      size_t fullBytes[VARIANT_COUNT] = { 0, 0 }; // Estimated bytes at full size of a variant uploaded downsized or as fallback, 0 if not degraded
      uint32_t upgradeRetryFrame = 0; // Frame index before which a degraded variant is not retried at full size
   };
   RenderDevice& m_rd;
   // Guards m_map, as loader threads register and upload textures while the main thread renders the loading UI.
   // Held for whole calls: code run under it (sampler creation, bitmap decode) must not call back into the manager.
   mutable std::mutex m_mapMutex;
   ankerl::unordered_dense::map<uint64_t, MapEntry> m_map;
   typedef ankerl::unordered_dense::map<uint64_t, MapEntry>::iterator Iter;
   typedef ankerl::unordered_dense::map<uint64_t, MapEntry>::const_iterator CIter;

#if defined(ENABLE_BGFX)
#pragma region GPU memory budget management (BGFX only)

   // Vulkan does not provide a driver managed fallback to system memory: when device memory is
   // exhausted, resource creation fails and the backend crashes. Other backends page GPU memory
   // instead, which avoids the crash but degrades to unusable framerates. To address both, the
   // resident texture set is kept inside a safety share of the budget reported through bgfx::Stats
   // (VK_EXT_memory_budget, QueryVideoMemoryInfo or NvAPI, depending on the backend and GPU): least
   // recently used samplers are evicted first (they are transparently re-uploaded on next use), then
   // images are downsized, and only then degraded to the fallback texture, instead of crashing.
   // On backends that do not report a budget (OpenGL, Metal, WebGPU, D3D11 on non NVIDIA GPUs),
   // gpuMemoryMax stays <= 0 and uploads remain unmanaged as before.

   size_t EstimateGpuBytes(const BaseTexture* tex, bool allowCompressed = true) const;
   std::shared_ptr<Sampler> CreateSampler(MapEntry& entry, SamplerVariant variant, bool force_linear_rgb, std::shared_ptr<const BaseTexture> bitmap);
   void Retire(std::shared_ptr<Sampler>& sampler, size_t& bytes); // Drops the manager's reference, keeping its bytes accounted until the sampler is actually destroyed
   void Reconcile(MapEntry& entry, SamplerVariant variant); // Raises the estimate to what the sampler actually allocated (base and mipmapped textures)

   void RefreshBudget(); // Samples the render thread's bgfx::Stats copy, at most once per frame
   int64_t BudgetCap() const { return (m_gpuMemBudget * kBudgetCapPct) / 100; }
   int64_t ProjectedUse(int64_t added) const; // Best effort estimate of the usage once deferred frees have reached the driver
   bool MakeRoom(size_t needed, unsigned int* evicted = nullptr); // Evicts LRU samplers until 'needed' fits the budget cap
   void NotifyPressure();
   void LogBudget(const char* decision, const string& name, size_t upload, bool force = false); // One rate limited line with the whole budget state

   static constexpr int kBudgetCapPct = 85; // Headroom left for render targets, buffers and transient growth
   static constexpr int kEvictTargetPct = 70; // Hysteresis: evict down to this share of the budget
   static constexpr uint32_t kEvictGraceFrames = 3; // Do not evict samplers used this recently
   static constexpr uint32_t kFreeLatencyFrames = 4; // Frames for a bgfx::destroy to reach the driver
   static constexpr uint32_t kUpgradeRetryFrames = 60; // Delay between attempts to restore a degraded variant to full size
   static constexpr uint32_t kLogIntervalMs = 2000; // Minimum delay between two budget log lines

   int64_t m_gpuMemBudget = -1; // Budget the policy works against: m_budgetOverride if set, else m_driverBudget. <= 0 when unmanaged
   int64_t m_driverBudget = -1; // bgfx::Stats::gpuMemoryMax (VK_EXT_memory_budget on Vulkan, a total allocation budget, not free memory)
   int64_t m_budgetOverride = 0; // [Player] GPUMemoryBudget or VPX_GPU_MEMORY_BUDGET, in bytes, 0 if unset
   int64_t m_gpuMemUsed = -1; // bgfx::Stats::gpuMemoryUsed (whole process, including non texture memory)
   int64_t m_otherBytes = 0; // gpuMemUsed share neither owned by this manager, retired, nor pending free (render targets, buffers, staging, ...)
   int64_t m_managedBytes = 0; // Estimated bytes held by the samplers this manager references
   uint32_t m_statsFrame = 0; // Frame index of the last stats sample, also used as the LRU clock
   // Samplers the manager dropped while something else still referenced them (shader state, ImGui, queued uploads,
   // recorded render commands): their memory is still allocated, so their bytes stay accounted until they are destroyed
   struct RetiredSampler
   {
      std::weak_ptr<Sampler> sampler;
      int64_t bytes;
   };
   vector<RetiredSampler> m_retired;
   int64_t m_retiredBytes = 0;
   std::deque<std::pair<uint32_t, int64_t>> m_pendingFree; // Bytes of destroyed samplers not yet freed by the driver (frame, bytes)
   int64_t m_pendingFreeBytes = 0;
   uint32_t m_logNextMs = 0;
   unsigned int m_logSuppressed = 0;
   bool m_loggedFirstSample = false;
   unsigned int m_pressureNotifId = 0;
   unsigned int m_downsizeNotifId = 0;
   uint32_t m_pressureNotifCooldown = 0;

#pragma endregion
#endif
};
