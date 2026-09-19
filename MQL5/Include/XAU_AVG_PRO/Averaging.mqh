//+------------------------------------------------------------------+
//|                                                  Averaging.mqh   |
//|  XAU_AVG_PRO v1.0.0 - averaging geometry: distance, level, gate |
//|                                                                  |
//|  This module answers two questions and nothing else:            |
//|    1) WHERE is the next averaging level and is it reached?       |
//|    2) MAY one more layer be opened right now (timing/dedupe)?   |
//|  Whether the layer is ALLOWED at all (layer cap, lot cap, DD,   |
//|  margin, filters) is decided by CRiskManager, which always has  |
//|  the final word.                                                |
//|                                                                  |
//|  Anti-runaway rules (see docs/05-averaging-algorithm.md):       |
//|   - at most ONE layer per call of the tick pipeline              |
//|   - OneLayerPerBar: max one layer per bar of the chart TF        |
//|   - MinimumSecondsBetweenAveraging                              |
//|   - duplicate level guard: a level already used cannot be reused |
//|   - a price gap that skips several levels opens ONE layer, the   |
//|     next level is then recomputed from the new fill              |
//+------------------------------------------------------------------+
#ifndef XAU_AVG_PRO_AVERAGING_MQH
#define XAU_AVG_PRO_AVERAGING_MQH

#include "Types.mqh"
#include "BrokerSpec.mqh"
#include "Logger.mqh"
#include "Cycle.mqh"

/// Plan produced for the current basket.
struct SAvgPlan
  {
   bool     basket_active;
   bool     enabled;
   bool     reached;
   double   level;
   double   reference_price;
   double   distance_points;
   double   distance_price;
   int      next_layer;
   string   why;
  };

class CAveragingEngine
  {
private:
   CConfig      *m_cfg;
   CSymbolSpec  *m_spec;
   CLogger      *m_log;
   CCycleManager*m_cycle;

   int      m_handle_atr;
   bool     m_have_atr;
   double   m_atr_price;
   double   m_distance_points;
   datetime m_cache_bar;
   int      m_copy_errors;
   double   m_last_opened_level;

   /// Read ATR of the configured timeframe. Only called when the cache
   /// is stale (new bar), never on every tick unless requested.
   bool ReadATR(void)
     {
      if(m_handle_atr == INVALID_HANDLE)
         return(false);
      double buf[];
      ArraySetAsSeries(buf, true);
      int got = CopyBuffer(m_handle_atr, 0, 1, 1, buf);
      if(got != 1 || buf[0] <= 0.0)
        {
         m_copy_errors++;
         m_have_atr = false;
         return(false);
        }
      m_atr_price    = buf[0];
      m_have_atr     = true;
      return(true);
     }

public:
                     CAveragingEngine(void) : m_cfg(NULL), m_spec(NULL), m_log(NULL), m_cycle(NULL),
                                              m_handle_atr(INVALID_HANDLE), m_have_atr(false), m_atr_price(0.0),
                                              m_distance_points(0.0), m_cache_bar(0), m_copy_errors(0), m_last_opened_level(0.0)
     {
     }

   bool Init(CConfig *cfg, CSymbolSpec *spec, CLogger *log, CCycleManager *cycle)
     {
      m_cfg   = cfg;
      m_spec  = spec;
      m_log   = log;
      m_cycle = cycle;
      if(m_cfg.AveragingDistanceMode == XAU_AVG_ATR)
        {
         m_handle_atr = iATR(m_spec.Symbol(), m_cfg.ATRTimeframe, m_cfg.ATRPeriod);
         if(m_handle_atr == INVALID_HANDLE)
           {
            m_log.Error(XAU_T_AVG, StringFormat("iATR handle creation failed err=%d - ATR distance unavailable", GetLastError()));
            return(false);
           }
        }
      return(true);
     }

   void Deinit(void)
     {
      if(m_handle_atr != INVALID_HANDLE)
        {
         IndicatorRelease(m_handle_atr);
         m_handle_atr = INVALID_HANDLE;
        }
      m_have_atr = false;
     }

   /// Refresh the cached distance when needed.
   /// @return false when the distance is not computable (no ATR yet).
   bool Refresh(const datetime bar_time, const bool new_bar)
     {
      if(m_cfg.AveragingDistanceMode == XAU_AVG_FIXED)
        {
         m_distance_points = (double)m_cfg.AveragingDistancePoints;
         return(true);
        }
      bool stale = (m_cache_bar != bar_time);
      if(!stale && !m_cfg.AllowIntraBarATRRefresh)
         return(m_have_atr);
      if(stale || !m_have_atr || m_cfg.AllowIntraBarATRRefresh)
        {
         if(!ReadATR())
           {
            m_log.Throttled(1, XAU_T_AVG, "atr_unavailable",
                            StringFormat("ATR(%s,%d) not available yet - averaging paused",
                                         EnumToString(m_cfg.ATRTimeframe), m_cfg.ATRPeriod), 300);
            return(false);
           }
         double pts = m_spec.PriceToPoints(m_atr_price) * m_cfg.ATRMultiplier;
         double lo  = (double)m_cfg.MinimumAveragingDistancePoints;
         double hi  = (double)m_cfg.MaximumAveragingDistancePoints;
         if(hi < lo)
            hi = lo;
         m_distance_points = XauClamp(pts, lo, hi);
         m_cache_bar       = bar_time;
         m_log.Debug(XAU_T_AVG, StringFormat("ATR=%s x%.2f = %.1f pts clamped[%.0f..%.0f] -> %.1f pts",
                                             DoubleToString(m_atr_price, m_spec.Digits()), m_cfg.ATRMultiplier,
                                             pts, lo, hi, m_distance_points));
        }
      return(true);
     }

   double DistancePoints(void) const { return(m_distance_points); }
   double ATRPrice(void)       const { return(m_atr_price); }
   bool   HaveATR(void)        const { return(m_have_atr); }
   int    CopyErrors(void)     const { return(m_copy_errors); }

   /// Smallest distance the broker/quote structure allows.
   double MinimumSafeDistancePoints(void) const
     {
      double by_spread = m_spec.SpreadPoints() * (m_cfg.MinimumDistanceSpreadMultiple > 0.0 ? m_cfg.MinimumDistanceSpreadMultiple : 2.0);
      double by_stops  = (double)m_spec.StopsLevelPoints();
      double v = MathMax(by_spread, by_stops);
      if(v < 1.0)
         v = 1.0;
      return(v);
     }

   /// Build the plan for the currently open basket.
   void BuildPlan(SAvgPlan &plan)
     {
      plan.basket_active   = m_cycle.IsActive();
      plan.enabled         = m_cfg.EnableAveraging;
      plan.reached         = false;
      plan.level           = 0.0;
      plan.reference_price = 0.0;
      plan.distance_points = m_distance_points;
      plan.distance_price  = 0.0;
      plan.next_layer      = m_cycle.LayerCount() + 1;
      plan.why             = "";

      if(!plan.basket_active)
        {
         plan.why = "no basket";
         return;
        }
      if(!plan.enabled)
        {
         plan.why = "averaging disabled";
         return;
        }
      if(m_cycle.IsUncertain())
        {
         plan.why = m_cycle.UncertainText();
         return;
        }
      if(m_distance_points <= 0.0)
        {
         plan.why = "distance not computed";
         return;
        }

      plan.reference_price = m_cycle.AveragingReferencePrice();
      plan.distance_price  = m_distance_points * m_spec.Point();
      bool is_buy          = m_cycle.IsBuyBasket();
      // BUY averages below, SELL averages above
      plan.level = (is_buy ? plan.reference_price - plan.distance_price
                           : plan.reference_price + plan.distance_price);
      plan.level = m_spec.NormalizePrice(plan.level);

      double market = (is_buy ? m_spec.Bid() : m_spec.Ask());
      plan.reached = (is_buy ? (market <= plan.level) : (market >= plan.level));
      if(!plan.reached)
         plan.why = StringFormat("price %.2f pts away from level %s",
                                 MathAbs(plan.reference_price - market) / (m_spec.Point() > 0 ? m_spec.Point() : 1.0),
                                 XauPrice(plan.level));
      else
         plan.why = "level reached";
     }

   /// Timing / duplicate protection. Must be called before the layer is
   /// sent, together with the risk verdict from CRiskManager.
   void CheckTiming(const SAvgPlan &plan, SRt &rt, const datetime bar_time, SVerdict &v)
     {
      XauPassV(v);
      double min_safe = MinimumSafeDistancePoints();
      if(plan.distance_points < min_safe)
        {
         XauFailV(v, XAU_BLK_DISTANCE_TOO_SMALL,
                  StringFormat("averaging distance %.0f pts is below the safe minimum %.0f pts (spread %.0f pts x %.2f, stop level %d)",
                               plan.distance_points, min_safe, m_spec.SpreadPoints(),
                               m_cfg.MinimumDistanceSpreadMultiple, (int)m_spec.StopsLevelPoints()), 0, min_safe);
         return;
        }
      if(m_cfg.OneLayerPerBar && rt.last_avg_open_bar == bar_time)
        {
         XauFailV(v, XAU_BLK_ONE_PER_BAR, "OneLayerPerBar: one layer already opened on this bar", 0, 0.0);
         return;
        }
      if(m_cfg.MinimumSecondsBetweenAveraging > 0 && rt.next_avg_allowed_at > 0 &&
         XauNow() < rt.next_avg_allowed_at)
        {
         XauFailV(v, XAU_BLK_TOO_SOON,
                  StringFormat("MinimumSecondsBetweenAveraging: %.0f s left",
                               (double)(rt.next_avg_allowed_at - XauNow())), rt.next_avg_allowed_at, 0.0);
         return;
        }
      // duplicate level guard: a level that has already produced a fill
      // cannot be used again until the geometry has actually moved
      if(rt.last_avg_level_used != 0.0 && m_spec.Point() > 0.0)
        {
         double gap = MathAbs(plan.level - rt.last_avg_level_used) / m_spec.Point();
         if(gap < plan.distance_points * 0.9)
           {
            XauFailV(v, XAU_BLK_DUPLICATE_LEVEL,
                     StringFormat("level %s already used (only %.0f pts apart, dedupe window is %.0f pts)",
                                  XauPrice(plan.level), gap, plan.distance_points * 0.9), 0, gap);
            return;
           }
        }
     }

   /// Record that a layer was opened at this level. Called only after a
   /// verified fill, so a rejected or failed order cannot shift the
   /// averaging geometry.
   void NoteLayerOpened(const double level, const datetime bar_time, SRt &rt)
     {
      m_last_opened_level    = level;
      rt.last_avg_level_used = level;
      rt.last_avg_open_bar   = bar_time;
      rt.next_avg_allowed_at = XauNow() + m_cfg.MinimumSecondsBetweenAveraging;
     }
   double LastOpenedLevel(void) const { return(m_last_opened_level); }

   string Describe(void) const
     {
      string mode = (m_cfg.AveragingDistanceMode == XAU_AVG_FIXED
                     ? StringFormat("FIXED %d pts", m_cfg.AveragingDistancePoints)
                     : StringFormat("ATR(%s,%d) x%.2f", EnumToString(m_cfg.ATRTimeframe), m_cfg.ATRPeriod, m_cfg.ATRMultiplier));
      return(StringFormat("%s -> %.1f pts (%s), ref=%s, min safe=%.0f pts",
                          mode, m_distance_points,
                          DoubleToString(m_distance_points * m_spec.Point(), m_spec.Digits()),
                          EnumToString(m_cfg.AveragingReference), MinimumSafeDistancePoints()));
     }
  };

#endif // XAU_AVG_PRO_AVERAGING_MQH
//+------------------------------------------------------------------+
