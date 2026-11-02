// license:GPLv3+

#pragma once

// Opt-in periodic performance log for headset tuning. Set VPX_VR_PERF=<seconds> to log, every
// <seconds>, the averaged logic/render thread sections and BGFX's total and per view GPU times.
// It enables the BGFX profiler (GPU timer queries per view), so it adds a little GPU work itself.

#if defined(ENABLE_BGFX)

#include <bgfx/bgfx.h>
#include <algorithm>
#include <cstdlib>
#include <iomanip>
#include <sstream>
#include <unordered_map>
#include <vector>

#include "utils/wintimer.h"

class VRPerfLog final
{
public:
   // Call once after bgfx::init
   static void Init()
   {
      const char* const env = std::getenv("VPX_VR_PERF");
      if (env == nullptr)
         return;
      const int seconds = std::atoi(env);
      if (seconds <= 0)
         return;
      Get().m_periodUs = static_cast<uint64_t>(seconds) * 1000000ull;
      bgfx::setDebug(BGFX_DEBUG_PROFILER);
      PLOGI << "[vr-perf] Logging performance every " << seconds << "s";
   }

   static bool IsEnabled() { return Get().m_periodUs != 0; }

   // Call on the render thread once per presented frame, after bgfx::frame
   static void OnFrame(const bgfx::Stats* stats, const FrameProfiler& logic, const FrameProfiler& render)
   {
      VRPerfLog& log = Get();
      if (log.m_periodUs == 0 || stats == nullptr)
         return;
      const uint64_t now = usec();
      if (log.m_windowStart == 0)
         log.m_windowStart = now;

      if (stats->gpuTimerFreq > 0 && stats->gpuTimeEnd > stats->gpuTimeBegin)
      {
         const double toMs = 1000. / static_cast<double>(stats->gpuTimerFreq);
         const double gpuMs = static_cast<double>(stats->gpuTimeEnd - stats->gpuTimeBegin) * toMs;
         log.m_gpuMs += gpuMs;
         log.m_gpuMaxMs = std::max(log.m_gpuMaxMs, gpuMs);
         log.m_gpuFrames++;
         for (uint16_t i = 0; i < stats->numViews; i++)
         {
            const bgfx::ViewStats& view = stats->viewStats[i];
            log.m_viewGpuMs[view.name] += static_cast<double>(view.gpuTimeElapsed) * toMs;
         }
      }
      if (stats->cpuTimerFreq > 0)
      {
         const double toMs = 1000. / static_cast<double>(stats->cpuTimerFreq);
         log.m_waitRenderMs += static_cast<double>(stats->waitRender) * toMs;
         log.m_waitSubmitMs += static_cast<double>(stats->waitSubmit) * toMs;
      }
      log.m_draws += stats->numDraw;
      log.m_frames++;

      if (now - log.m_windowStart < log.m_periodUs)
         return;

      const double frames = static_cast<double>(log.m_frames);
      const double gpuFrames = static_cast<double>(std::max(log.m_gpuFrames, 1u));
      std::ostringstream ss;
      ss << std::fixed << std::setprecision(2);
      ss << "[vr-perf] " << log.m_frames << " frames in " << std::setprecision(1) << ((now - log.m_windowStart) * 1e-6) << "s ("
         << (frames * 1e6 / static_cast<double>(now - log.m_windowStart)) << " fps)" << std::setprecision(2)
         << " | gpu avg " << (log.m_gpuMs / gpuFrames) << "ms max " << log.m_gpuMaxMs << "ms"
         << " | draws " << (log.m_draws / log.m_frames)
         << " | bgfx waitRender " << (log.m_waitRenderMs / frames) << "ms waitSubmit " << (log.m_waitSubmitMs / frames) << "ms";
      PLOGI << ss.str();

      ss.str({});
      ss << "[vr-perf] logic ms: frame " << (logic.GetSlidingAvg(FrameProfiler::PROFILE_FRAME) * 1e-3)
         << " script " << (logic.GetSlidingAvg(FrameProfiler::PROFILE_SCRIPT) * 1e-3)
         << " physics " << (logic.GetSlidingAvg(FrameProfiler::PROFILE_PHYSICS) * 1e-3)
         << " prepare " << (logic.GetSlidingAvg(FrameProfiler::PROFILE_PREPARE_FRAME) * 1e-3)
         << " sleep " << (logic.GetSlidingAvg(FrameProfiler::PROFILE_SLEEP) * 1e-3)
         << " misc " << (logic.GetSlidingAvg(FrameProfiler::PROFILE_MISC) * 1e-3)
         << " | render ms: frame " << (render.GetSlidingAvg(FrameProfiler::PROFILE_FRAME) * 1e-3)
         << " wait " << (render.GetSlidingAvg(FrameProfiler::PROFILE_RENDER_WAIT) * 1e-3)
         << " waitSC " << (render.GetSlidingAvg(FrameProfiler::PROFILE_RENDER_WAIT_SC) * 1e-3)
         << " submit " << (render.GetSlidingAvg(FrameProfiler::PROFILE_RENDER_SUBMIT) * 1e-3)
         << " flip " << (render.GetSlidingAvg(FrameProfiler::PROFILE_RENDER_FLIP) * 1e-3)
         << " sleep " << (render.GetSlidingAvg(FrameProfiler::PROFILE_RENDER_SLEEP) * 1e-3);
      PLOGI << ss.str();

      std::vector<std::pair<string, double>> views(log.m_viewGpuMs.begin(), log.m_viewGpuMs.end());
      std::sort(views.begin(), views.end(), [](const auto& a, const auto& b) { return a.second > b.second; });
      for (const auto& [name, ms] : views)
      {
         if (ms / gpuFrames < 0.05)
            break;
         ss.str({});
         ss << "[vr-perf]   view " << std::setw(6) << (ms / gpuFrames) << "ms  " << name;
         PLOGI << ss.str();
      }

      log.m_windowStart = now;
      log.m_frames = 0;
      log.m_gpuFrames = 0;
      log.m_gpuMs = 0.;
      log.m_gpuMaxMs = 0.;
      log.m_waitRenderMs = 0.;
      log.m_waitSubmitMs = 0.;
      log.m_draws = 0;
      log.m_viewGpuMs.clear();
   }

private:
   static VRPerfLog& Get()
   {
      static VRPerfLog log;
      return log;
   }

   uint64_t m_periodUs = 0;
   uint64_t m_windowStart = 0;
   unsigned int m_frames = 0;
   unsigned int m_gpuFrames = 0;
   double m_gpuMs = 0.;
   double m_gpuMaxMs = 0.;
   double m_waitRenderMs = 0.;
   double m_waitSubmitMs = 0.;
   uint64_t m_draws = 0;
   std::unordered_map<string, double> m_viewGpuMs;
};

#endif
