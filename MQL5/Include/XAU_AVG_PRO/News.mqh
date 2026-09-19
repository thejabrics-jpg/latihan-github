//+------------------------------------------------------------------+
//|                                                        News.mqh  |
//|  XAU_AVG_PRO v1.0.0 - MT5 economic calendar news filter         |
//|                                                                  |
//|  Implementation facts (verified against the MQL5 reference):     |
//|   - there is NO "future events" function in MT5. The only way to |
//|     see scheduled events is CalendarValueHistory() with a range  |
//|     that ends in the future; the database contains future rows   |
//|     whose actual value is LONG_MIN.                              |
//|   - importance lives in MqlCalendarEvent (via CalendarEventById) |
//|     MqlCalendarValue::impact_type is the POSITIVE/NEGATIVE       |
//|     direction, NOT the importance - using it as impact would be  |
//|     a silent bug, so it is deliberately not used here.          |
//|   - calendar functions use TRADE SERVER time (TimeTradeServer). |
//|   - calendar functions are NOT allowed in the Strategy Tester    |
//|     (they return -1 / error 4014). This module therefore reports |
//|     "unavailable" and the configured fail-safe policy decides.  |
//|   - no fake news data is generated anywhere.                    |
//+------------------------------------------------------------------+
#ifndef XAU_AVG_PRO_NEWS_MQH
#define XAU_AVG_PRO_NEWS_MQH

#include "Types.mqh"
#include "Logger.mqh"

class CNewsFilter
  {
private:
   CConfig *m_cfg;
   CLogger *m_log;

   bool     m_supported;
   bool     m_checked;
   bool     m_blocking;
   datetime m_next_refresh;
   datetime m_block_until;
   datetime m_event_time;
   string   m_event_name;
   string   m_status;
   int      m_scanned;
   int      m_matched;
   int      m_errors;

   /// Calendar functions are aligned to the trade server clock, which in
   /// the terminal is TimeTradeServer(); in the tester it is the
   /// simulated clock, so fall back to the EA's own "now".
   datetime CalendarNow(void)
     {
      if(MQLInfoInteger(MQL_TESTER))
         return(XauNow());
      datetime t = TimeTradeServer();
      return(t > 0 ? t : XauNow());
     }
   /// Threshold on the MQL5 importance scale:
   /// 0=not set, 1=low, 2=moderate, 3=high.
   int RequiredImportance(void) const
     {
      switch(m_cfg.MinimumNewsImportance)
        {
         case XAU_IMP_LOW:      return(1);
         case XAU_IMP_MODERATE: return(2);
         case XAU_IMP_HIGH:     return(3);
        }
      return(0);
     }

public:
                     CNewsFilter(void) : m_cfg(NULL), m_log(NULL), m_supported(false), m_checked(false),
                                         m_blocking(false), m_next_refresh(0), m_block_until(0),
                                         m_event_time(0), m_event_name(""), m_status("not initialised"),
                                         m_scanned(0), m_matched(0), m_errors(0)
     {
     }

   void Init(CConfig *cfg, CLogger *log)
     {
      m_cfg  = cfg;
      m_log  = log;
      if(!m_cfg.EnableNewsFilter)
        {
         m_status = "disabled";
         return;
        }
      if(MQLInfoInteger(MQL_TESTER))
        {
         m_supported = false;
         m_status    = "unavailable in Strategy Tester (calendar functions are blocked)";
         m_log.Warn(XAU_T_NEWS, "news filter cannot be evaluated in the tester: " +
                  (m_cfg.NewsFailSafePolicy == XAU_FAILSAFE_BLOCK ? "trading will stay BLOCKED (fail-safe)"
                                                                   : "trading continues, policy=ALLOW/WARN"));
         return;
        }
      m_next_refresh = 0;
      Refresh();
     }

   /// Throttled refresh of the event window. Never called per tick.
   void Refresh(void)
     {
      if(!m_cfg.EnableNewsFilter)
         return;
      datetime now = CalendarNow();
      if(m_next_refresh > 0 && now < m_next_refresh)
         return;
      m_next_refresh = now + (datetime)(MathMax(10, m_cfg.NewsRefreshSeconds));
      if(MQLInfoInteger(MQL_TESTER))
         return;

      int before = (int)XauClampI(m_cfg.MinutesBeforeNews, 0, 1440) * 60;
      int after  = (int)XauClampI(m_cfg.MinutesAfterNews, 0, 1440) * 60;
      datetime from = now - after - 120;
      datetime to   = now + before + 120;

      MqlCalendarValue values[];
      int cnt = CalendarValueHistory(values, from, to, m_cfg.NewsCountryCode, m_cfg.NewsCurrency);
      if(cnt < 0)
        {
         int err = GetLastError();
         m_errors++;
         m_supported = false;
         m_status    = StringFormat("query failed (err=%d)", err);
         m_log.Throttled(1, XAU_T_NEWS, "query",
                         StringFormat("CalendarValueHistory failed err=%d for currency=%s - fail-safe policy=%s",
                                      err, m_cfg.NewsCurrency, EnumToString(m_cfg.NewsFailSafePolicy)), 300);
         return;
        }
      m_supported = true;
      m_scanned   = ArraySize(values);
      int need    = RequiredImportance();
      datetime nearest_time = 0;
      string   nearest_name = "";
      datetime block_until  = 0;
      int      matched      = 0;
      int      limit        = ArraySize(values);
      if(limit > 2000)
        {
         m_log.Warn(XAU_T_NEWS, StringFormat("calendar returned %d rows in the window, only the first 2000 are scanned", limit));
         limit = 2000;
        }
      for(int i = 0; i < limit; i++)
        {
         datetime t = values[i].time;
         if(t < now - after || t > now + before)
            continue;                       // outside the protection window
         MqlCalendarEvent ev;
         if(!CalendarEventById(values[i].event_id, ev))
            continue;                       // description not available -> ignore, conservative
         if((int)ev.importance < need)
            continue;
         matched++;
         if(block_until == 0 || t < nearest_time)
           {
            nearest_time = t;
            nearest_name = ev.name;
            block_until  = t + after;
           }
        }
      m_checked    = true;
      m_matched    = matched;
      m_event_time = nearest_time;
      m_event_name = nearest_name;
      m_block_until = block_until;
      m_blocking   = (matched > 0);
      m_status     = (matched > 0
                      ? StringFormat("BLOCKED by %s at %s (%d event(s))", nearest_name, TimeToString(nearest_time), matched)
                      : "clear");
      if(matched > 0)
         m_log.Info(XAU_T_NEWS, StringFormat("%d high impact event(s) for %s in the window | nearest: %s at %s | blocked until %s",
                                             matched, m_cfg.NewsCurrency, nearest_name,
                                             TimeToString(nearest_time), TimeToString(block_until)));
     }

   /// Entry is always filtered; averaging only when configured to be.
   void Check(const ENUM_XAU_INTENT intent, SVerdict &v)
     {
      XauPassV(v);
      if(!m_cfg.EnableNewsFilter)
         return;
      bool applies = (intent == XAU_INT_ENTRY || m_cfg.NewsBlocksAveraging);
      if(!applies)
         return;
      // data unavailable -> fail safe according to policy
      if(!m_supported || !m_checked)
        {
         if(m_cfg.NewsFailSafePolicy == XAU_FAILSAFE_BLOCK)
           {
            XauFailV(v, XAU_BLK_NEWS, "news filter has no calendar data (" + m_status + ") and policy is BLOCK", 0, 0.0);
            return;
           }
         m_log.Throttled(1, XAU_T_NEWS, "unavail",
                         "news filter unavailable (" + m_status + ") - policy allows trading", 600);
         return;
        }
      if(m_blocking && XauNow() <= m_block_until)
        {
         XauFailV(v, XAU_BLK_NEWS,
                  StringFormat("inside news window: %s at %s, blocked until %s",
                               m_event_name, TimeToString(m_event_time), TimeToString(m_block_until)),
                  m_block_until, 0.0);
         return;
        }
      if(m_blocking)
        {
         m_blocking = false;
         m_log.Info(XAU_T_NEWS, "news window passed - trading resumed");
        }
     }

   bool     Supported(void) const { return(m_supported); }
   bool     Blocking(void)  const { return(m_blocking); }
   int      MatchedEvents(void) const { return(m_matched); }
   int      ScannedRows(void)   const { return(m_scanned); }
   int      Errors(void)        const { return(m_errors); }
   string   Status(void)        const { return(m_status); }
   datetime BlockUntil(void)    const { return(m_block_until); }
   string   Describe(void)      const
     {
      if(!m_cfg.EnableNewsFilter)
         return("NEWS:off");
      return("NEWS:" + m_status);
     }
  };

#endif // XAU_AVG_PRO_NEWS_MQH
//+------------------------------------------------------------------+
