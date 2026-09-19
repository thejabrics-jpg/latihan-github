//+------------------------------------------------------------------+
//|                                                MarketFilters.mqh |
//|  XAU_AVG_PRO v1.0.0 - spread / volatility / gap / session /      |
//|                       weekend / open market protection           |
//|                                                                  |
//|  Every filter:                                                   |
//|   - is individually switchable                                   |
//|   - returns a verdict with an explicit reason and block code     |
//|   - blocks entries, and optionally averaging; a filter NEVER     |
//|     closes an existing basket - only risk limits may do that    |
//|   - fails safe: when its own input data is unavailable the       |
//|     filter blocks (documented per filter below)                 |
//|                                                                  |
//|  All times are BROKER SERVER TIME (XauNow() = time of the last  |
//|  server tick, the same clock the chart bars use).               |
//+------------------------------------------------------------------+
#ifndef XAU_AVG_PRO_MARKETFILTERS_MQH
#define XAU_AVG_PRO_MARKETFILTERS_MQH

#include "Types.mqh"
#include "BrokerSpec.mqh"
#include "Logger.mqh"

class CMarketFilters
  {
private:
   CConfig     *m_cfg;
   CSymbolSpec *m_spec;
   CLogger     *m_log;

   int      m_handle_atr;
   double   m_atr_points;
   datetime m_atr_bar;
   bool     m_atr_ok;

   datetime m_gap_bar;
   double   m_last_gap_points;
   bool     m_gap_known;
   int      m_pass_count;
   int      m_block_count;

   void Pass(SVerdict &v)              { XauPassV(v); }
   void Fail(SVerdict &v, const ENUM_XAU_BLOCK code, const string why,
             const datetime until, const double value)
     {
      XauFailV(v, code, why, until, value);
     }
   /// Does this filter apply to the current intent? Entries are always
   /// filtered; averaging only when the filter's own switch allows it.
   bool Applies(const ENUM_XAU_INTENT intent, const bool blocks_averaging)
     {
      if(intent == XAU_INT_ENTRY)
         return(true);
      return(blocks_averaging);
     }
   /// Minutes from server midnight.
   int MinutesOfDay(void) { return(XauMinutesOfDay(XauNow())); }

public:
                     CMarketFilters(void) : m_cfg(NULL), m_spec(NULL), m_log(NULL),
                                            m_handle_atr(INVALID_HANDLE), m_atr_points(0.0), m_atr_bar(0),
                                            m_atr_ok(false), m_gap_bar(0), m_last_gap_points(0.0),
                                            m_gap_known(false), m_pass_count(0), m_block_count(0)
     {
     }

   bool Init(CConfig *cfg, CSymbolSpec *spec, CLogger *log)
     {
      m_cfg  = cfg;
      m_spec = spec;
      m_log  = log;
      if(m_cfg.EnableVolatilityFilter)
        {
         m_handle_atr = iATR(m_spec.Symbol(), m_cfg.VolatilityTimeframe, m_cfg.VolatilityATRPeriod);
         if(m_handle_atr == INVALID_HANDLE)
           {
            m_log.Error(XAU_T_FILTER, StringFormat("volatility filter: iATR handle failed err=%d", GetLastError()));
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
      m_atr_ok = false;
     }

   /// New-bar work only: ATR sampling and gap detection. Called once per
   /// bar from the tick pipeline, never per tick.
   void Update(const datetime bar_time, const bool new_bar, SRt &rt)
     {
      if(!new_bar)
         return;
      if(m_cfg.EnableVolatilityFilter && m_handle_atr != INVALID_HANDLE)
        {
         double buf[];
         ArraySetAsSeries(buf, true);
         if(CopyBuffer(m_handle_atr, 0, 1, 1, buf) == 1 && buf[0] > 0.0 && m_spec.Point() > 0.0)
           {
            m_atr_points = buf[0] / m_spec.Point();
            m_atr_bar    = bar_time;
            m_atr_ok     = true;
           }
         else
           {
            m_atr_ok = false;
            m_log.Throttled(1, XAU_T_FILTER, "vol_atr",
                            "volatility filter has no ATR data yet - filter blocks (fail safe)", 300);
           }
        }
      if(m_cfg.EnableGapFilter)
        {
         int need = (int)XauClampI(m_cfg.GapLookbackBars, 1, 50) + 1;
         MqlRates rates[];
         ArraySetAsSeries(rates, true);
         if(CopyRates(m_spec.Symbol(), _Period, 0, need, rates) >= need)
           {
            // a gap is the distance between one bar's open and the
            // previous bar's close; the largest one in the lookback wins
            double worst = 0.0;
            for(int i = 1; i < need; i++)
              {
               double gpts = MathAbs(rates[i - 1].open - rates[i].close) / (m_spec.Point() > 0.0 ? m_spec.Point() : 1.0);
               if(gpts > worst)
                  worst = gpts;
              }
            m_last_gap_points = worst;
            m_gap_known       = true;
            m_gap_bar         = bar_time;
            if(worst > (double)m_cfg.MaximumGapPoints)
              {
               datetime until = XauNow() + (datetime)(MathMax(1, m_cfg.GapBlockDurationMinutes) * 60);
               rt.last_gap_block_until = until;
               m_log.Throttled(2, XAU_T_FILTER, "gap",
                               StringFormat("gap of %.0f pts > limit %d pts - trading blocked until %s",
                                            worst, m_cfg.MaximumGapPoints, TimeToString(until)), 60);
              }
           }
         else
           {
            m_gap_known = false;
            m_log.Throttled(1, XAU_T_FILTER, "gap_data", "gap filter has no bar data yet - filter blocks (fail safe)", 300);
           }
        }
     }

   //--- individual filters ------------------------------------------
   //  Spread: measured from the live quote, not SYMBOL_SPREAD (which can
   //  be one tick stale on fast XAUUSD moves).
   void CheckSpread(const ENUM_XAU_INTENT intent, SVerdict &v)
     {
      Pass(v);
      if(!m_cfg.EnableSpreadFilter || !Applies(intent, m_cfg.SpreadFilterBlocksAveraging))
         return;
      double limit  = (double)(m_cfg.MaximumSpreadPoints > 0 ? m_cfg.MaximumSpreadPoints : 1);
      double spread = m_spec.SpreadPoints();
      if(!m_spec.QuoteOk())
        {
         Fail(v, XAU_BLK_SPREAD, "no fresh quote - spread unknown", 0, 0.0);
         return;
        }
      if(spread > limit)
         Fail(v, XAU_BLK_SPREAD,
              StringFormat("spread %.0f pts > MaximumSpreadPoints %d", spread, m_cfg.MaximumSpreadPoints),
              0, spread);
     }

   void CheckVolatility(const ENUM_XAU_INTENT intent, SVerdict &v)
     {
      Pass(v);
      if(!m_cfg.EnableVolatilityFilter || !Applies(intent, m_cfg.VolatilityFilterBlocksAveraging))
         return;
      if(!m_atr_ok)
        {
         Fail(v, XAU_BLK_VOLATILITY, "ATR unavailable for volatility filter", 0, 0.0);
         return;
        }
      double lo = (double)m_cfg.MinimumATRPoints;
      double hi = (double)m_cfg.MaximumATRPoints;
      if(m_atr_points < lo)
        {
         Fail(v, XAU_BLK_VOLATILITY,
              StringFormat("ATR %.0f pts < MinimumATRPoints %.0f (dead market)", m_atr_points, lo), 0, m_atr_points);
         return;
        }
      if(hi > lo && m_atr_points > hi)
        {
         Fail(v, XAU_BLK_VOLATILITY,
              StringFormat("ATR %.0f pts > MaximumATRPoints %.0f (excessive volatility)", m_atr_points, hi), 0, m_atr_points);
         return;
        }
     }

   void CheckGap(const ENUM_XAU_INTENT intent, const SRt &rt, SVerdict &v)
     {
      Pass(v);
      if(!m_cfg.EnableGapFilter || !Applies(intent, m_cfg.GapBlocksAveraging))
         return;
      if(!m_gap_known)
        {
         Fail(v, XAU_BLK_GAP, "gap filter has no bar data yet", 0, 0.0);
         return;
        }
      if(rt.last_gap_block_until > XauNow())
        {
         Fail(v, XAU_BLK_GAP,
              StringFormat("gap of %.0f pts (limit %d) - blocked for %d more s",
                           m_last_gap_points, m_cfg.MaximumGapPoints, (int)(rt.last_gap_block_until - XauNow())),
              rt.last_gap_block_until, m_last_gap_points);
         return;
        }
      if(m_last_gap_points > (double)m_cfg.MaximumGapPoints)
        {
         // gap detected on a bar that is still the newest one
         Fail(v, XAU_BLK_GAP,
              StringFormat("gap of %.0f pts > limit %d pts on the current bar", m_last_gap_points, m_cfg.MaximumGapPoints),
              0, m_last_gap_points);
         return;
        }
     }

   void CheckSession(const ENUM_XAU_INTENT intent, SVerdict &v)
     {
      Pass(v);
      if(!m_cfg.EnableSessionFilter || !Applies(intent, m_cfg.SessionBlocksAveraging))
         return;
      int now = MinutesOfDay();
      int a   = XauClampI(m_cfg.SessionStartHour, 0, 23) * 60 + XauClampI(m_cfg.SessionStartMinute, 0, 59);
      int b   = XauClampI(m_cfg.SessionEndHour, 0, 23) * 60 + XauClampI(m_cfg.SessionEndMinute, 0, 59);
      bool inside;
      if(a == b)
         inside = true;                                   // 24 hours session
      else
         if(a < b)
            inside = (now >= a && now < b);
         else
            inside = (now >= a || now < b);               // window crosses midnight
      if(!inside)
         Fail(v, XAU_BLK_SESSION,
               StringFormat("outside session %s-%s server time (now %s)",
                            XauHHMM(m_cfg.SessionStartHour, m_cfg.SessionStartMinute),
                            XauHHMM(m_cfg.SessionEndHour, m_cfg.SessionEndMinute),
                            XauHHMM(now / 60, now % 60)), 0, 0.0);
     }

   void CheckWeekend(const ENUM_XAU_INTENT intent, SVerdict &v)
     {
      Pass(v);
      if(!m_cfg.EnableWeekendProtection || !Applies(intent, m_cfg.WeekendBlocksAveraging))
         return;
      int dow = XauDayOfWeek(XauNow());
      int mod = MinutesOfDay();
      int fri = XauClampI(m_cfg.FridayStopHour, 0, 23) * 60 + XauClampI(m_cfg.FridayStopMinute, 0, 59);
      int mon = XauClampI(m_cfg.MondayResumeHour, 0, 23) * 60 + XauClampI(m_cfg.MondayResumeMinute, 0, 59);
      bool blocked = false;
      string why   = "";
      if(dow == 5 && mod >= fri)
        {
         blocked = true;
         why     = StringFormat("after Friday stop %s server time", XauHHMM(m_cfg.FridayStopHour, m_cfg.FridayStopMinute));
        }
      else
         if(dow == 6 || dow == 0)
           {
            blocked = true;
            why     = "weekend (Saturday/Sunday)";
           }
         else
            if(dow == 1 && mod < mon)
              {
               blocked = true;
               why     = StringFormat("before Monday resume %s server time", XauHHMM(m_cfg.MondayResumeHour, m_cfg.MondayResumeMinute));
              }
      if(blocked)
         Fail(v, XAU_BLK_WEEKEND, why, 0, 0.0);
     }

   void CheckOpenMarket(const ENUM_XAU_INTENT intent, SVerdict &v)
     {
      Pass(v);
      if(!m_cfg.EnableOpenMarketProtection || m_cfg.ProtectionMinutes <= 0)
         return;
      datetime now    = XauNow();
      datetime day    = XauServerDayStart(now);
      datetime open_at = day;
      if(m_cfg.OpenMarketReference == XAU_OPEN_SESSION_START)
         open_at += (XauClampI(m_cfg.SessionStartHour, 0, 23) * 3600 +
                     XauClampI(m_cfg.SessionStartMinute, 0, 59) * 60);
      int limit = m_cfg.ProtectionMinutes * 60;
      if(now >= open_at && (int)(now - open_at) < limit)
         Fail(v, XAU_BLK_OPEN_PROTECT,
              StringFormat("open market protection: %d s of %d s remaining (open %s)",
                           limit - (int)(now - open_at), limit, TimeToString(open_at)),
              open_at + limit, 0.0);
     }

   /// Friday pre-close check used by the engine when
   /// CloseBasketBeforeFridayStop is on. Returns true when the basket
   /// must be flattened.
   bool ShouldFlattenBeforeWeekend(void)
     {
      if(!m_cfg.CloseBasketBeforeFridayStop || !m_cfg.EnableWeekendProtection)
         return(false);
      int dow = XauDayOfWeek(XauNow());
      int mod = MinutesOfDay();
      int fri = XauClampI(m_cfg.FridayStopHour, 0, 23) * 60 + XauClampI(m_cfg.FridayStopMinute, 0, 59);
      return(dow == 5 && mod >= fri);
     }

   /// Aggregate decision. XAU_INT_CLOSE always passes: closing must never
   /// be blocked by a market filter.
   void Check(const ENUM_XAU_INTENT intent, SRt &rt, SVerdict &v)
     {
      SVerdict t;
      Pass(v);
      if(intent == XAU_INT_CLOSE)
         return;
      CheckSession(intent, t);
      if(!t.allowed) { m_block_count++; v = t; return; }
      CheckWeekend(intent, t);
      if(!t.allowed) { m_block_count++; v = t; return; }
      CheckOpenMarket(intent, t);
      if(!t.allowed) { m_block_count++; v = t; return; }
      CheckGap(intent, rt, t);
      if(!t.allowed) { m_block_count++; v = t; return; }
      CheckSpread(intent, t);
      if(!t.allowed) { m_block_count++; v = t; return; }
      CheckVolatility(intent, t);
      if(!t.allowed) { m_block_count++; v = t; return; }
      m_pass_count++;
     }

   //--- publish for dashboard / runtime ------------------------------
   double ATRPointsValue(void) const { return(m_atr_points); }
   bool   ATRAvailable(void)   const { return(m_atr_ok); }
   double LastGapPoints(void)  const { return(m_last_gap_points); }
   int    PassCount(void)      const { return(m_pass_count); }
   int    BlockCount(void)     const { return(m_block_count); }
   void   ResetCounters(void)  { m_pass_count = 0; m_block_count = 0; }

   /// Comma separated one-line state for the dashboard and Telegram.
   string Describe(void)
     {
      string s = "";
      s += (m_cfg.EnableSpreadFilter
            ? StringFormat("SPREAD:%s(%.0f/%d)",
                           (m_spec.SpreadPoints() <= (double)m_cfg.MaximumSpreadPoints ? "PASS" : "BLOCK"),
                           m_spec.SpreadPoints(), m_cfg.MaximumSpreadPoints)
            : "SPREAD:off");
      s += (m_cfg.EnableVolatilityFilter
            ? StringFormat(" | VOL:%s(ATR %.0f)", (m_atr_ok ? "PASS" : "N/A"), m_atr_points)
            : " | VOL:off");
      s += (m_cfg.EnableGapFilter
            ? StringFormat(" | GAP:%s(%.0f)", (m_last_gap_points <= (double)m_cfg.MaximumGapPoints ? "PASS" : "BLOCK"), m_last_gap_points)
            : " | GAP:off");
      s += (m_cfg.EnableSessionFilter ? " | SESSION:on" : " | SESSION:off");
      s += (m_cfg.EnableWeekendProtection ? " | WKND:on" : " | WKND:off");
      s += (m_cfg.EnableOpenMarketProtection ? " | OPENPROT:on" : " | OPENPROT:off");
      return(s);
     }
  };

#endif // XAU_AVG_PRO_MARKETFILTERS_MQH
//+------------------------------------------------------------------+
