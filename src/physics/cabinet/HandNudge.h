// license:GPLv3+

#pragma once

#include "math/vector.h"
#include "physics/cabinet/CabinetPhysics.h"
#include "physics/cabinet/NudgeHandler.h"

namespace VPX::Physics
{

// Analog nudge from a tracked shove of the player's hands (Vision Pro hand controls).
//
// Each shove gives a peak cabinet acceleration in m/s^2, with any direction and strength.
// Like the keyboard and gamepad models, it drives the cabinet model with a 25 ms raised
// cosine impulse, so the cabinet moves a few mm, springs back, and the plumb sees it.
// A shove that is still growing can raise its impulse while it runs.
class HandNudge final : public NudgeSource
{
public:
   static constexpr int ImpulseLength = 25; // ms, as the keyboard and intent models

   void Shove(const Vertex2D& peak, bool update)
   {
      if (update && !m_impulses.empty())
      {
         Impulse& last = m_impulses.back();
         const float growth = sqrtf(peak.LengthSquared()) - sqrtf(last.peak.LengthSquared());
         if (growth <= 0.f)
            return;
         if (last.elapsed < ImpulseLength / 2)
            last.peak = peak; // Still rising: raise it
         else
            m_impulses.push_back({ peak * (growth / sqrtf(peak.LengthSquared())), 0 }); // Add what the first part missed
      }
      else
         m_impulses.push_back({ peak, 0 });
      m_deactivationDelay = 10000;
   }

   void StepOneMillisecond() override
   {
      if (m_deactivationDelay > 0)
         m_deactivationDelay--;
      Vertex2D acceleration { 0.f, 0.f };
      for (auto it = m_impulses.begin(); it != m_impulses.end();)
      {
         it->elapsed++;
         if (it->elapsed > ImpulseLength)
         {
            it = m_impulses.erase(it);
            continue;
         }
         const float t = static_cast<float>(it->elapsed) / static_cast<float>(ImpulseLength);
         acceleration += it->peak * (m_strength * 0.5f * (1.0f - cosf((float)(2. * M_PI) * t)));
         ++it;
      }
      m_cabinet.StepOneMillisecond(m_cabinet.GetMass() * acceleration);
   }

   bool IsActive() const override { return m_deactivationDelay > 0; }
   float GetStrengthScale() const override { return m_strength; }
   void SetStrengthScale(float scale) override { m_strength = scale; }
   const Vertex2D& GetCabinetAcceleration() const override { return m_cabinet.GetCabinetAcceleration(); }
   const Vertex2D& GetCabinetOffset() const override { return m_cabinet.GetCabinetOffset(); }

private:
   struct Impulse
   {
      Vertex2D peak;
      int elapsed;
   };
   vector<Impulse> m_impulses;
   CabinetPhysics m_cabinet;
   float m_strength = 1.f;
   int m_deactivationDelay = 0;
};

}
