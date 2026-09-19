//+------------------------------------------------------------------+
//|                                                    Dashboard.mqh |
//|  XAU_AVG_PRO v1.0.0 - throttled, non-intrusive chart panel      |
//|                                                                  |
//  The dashboard is a pure renderer: the engine pushes rows with    |
//  Begin()/Add()/End() and the panel decides when to repaint. It    |
//  never calls trading functions and never blocks a tick - if the  |
//  interval has not elapsed, End() returns immediately.            |
//                                                                  |
//  In a non-visual Strategy Tester pass chart objects are useless, |
//  so rendering is skipped entirely.                                |
//+------------------------------------------------------------------+
#ifndef XAU_AVG_PRO_DASHBOARD_MQH
#define XAU_AVG_PRO_DASHBOARD_MQH

#include "Types.mqh"
#include "BrokerSpec.mqh"
#include "Logger.mqh"

class CDashboard
  {
private:
   CConfig     *m_cfg;
   CSymbolSpec *m_spec;
   CLogger     *m_log;

   long     m_chart;
   bool     m_active;
   datetime m_last_paint;
   uint     m_last_paint_ms;
   int      m_pending;
   int      m_painted;
   string   m_lbl[];
   string   m_val[];
   color    m_col[];
   string   m_created[];
   int      m_button_state;

   string Name(const int index) const { return(XAU_OBJ_PREFIX + "row" + IntegerToString(index)); }
   string ButtonName(void) const { return(XAU_OBJ_PREFIX + "btn_pause"); }

   void EnsureRowObject(const int index)
     {
      string nm = Name(index);
      if(ObjectFind(m_chart, nm) < 0)
        {
         if(!ObjectCreate(m_chart, nm, OBJ_LABEL, 0, 0, 0))
           {
            m_log.Debug(XAU_T_DASH, StringFormat("ObjectCreate(%s) failed err=%d", nm, GetLastError()));
            return;
           }
         ObjectSetInteger(m_chart, nm, OBJPROP_CORNER, m_cfg.DashboardCorner);
         ObjectSetInteger(m_chart, nm, OBJPROP_SELECTABLE, false);
         ObjectSetInteger(m_chart, nm, OBJPROP_HIDDEN, true);
         ObjectSetInteger(m_chart, nm, OBJPROP_BACK, false);
         ObjectSetInteger(m_chart, nm, OBJPROP_FONTSIZE, m_cfg.DashboardFontSize);
         ObjectSetString(m_chart, nm, OBJPROP_FONT, m_cfg.DashboardFontName);
         // OBJPROP_ANCHOR is an integer property (ENUM_ANCHOR_POINT)
         ObjectSetInteger(m_chart, nm, OBJPROP_ANCHOR, ANCHOR_LEFT_UPPER);
         int n = ArraySize(m_created);
         ArrayResize(m_created, n + 1);
         m_created[n] = nm;
        }
     }
   int RowHeight(void) const
     {
      int h = (int)MathRound(m_cfg.DashboardFontSize * 1.55);
      return(h < 10 ? 14 : h);
     }

public:
                     CDashboard(void) : m_cfg(NULL), m_spec(NULL), m_log(NULL), m_chart(0), m_active(false),
                                       m_last_paint(0), m_last_paint_ms(0), m_pending(0), m_painted(0),
                                       m_button_state(0)
     {
     }

   bool Init(CConfig *cfg, CSymbolSpec *spec, CLogger *log)
     {
      m_cfg   = cfg;
      m_spec  = spec;
      m_log   = log;
      m_chart = ChartID();
      m_active = false;
      if(!m_cfg.EnableDashboard)
        {
         m_log.Debug(XAU_T_DASH, "dashboard disabled by input");
         return(true);
        }
      bool visual = (bool)MQLInfoInteger(MQL_VISUAL_MODE);
      if((bool)MQLInfoInteger(MQL_TESTER) && !visual)
        {
         m_log.Debug(XAU_T_DASH, "dashboard skipped: non-visual Strategy Tester");
         return(true);
        }
      m_active = true;
      CreateButton();
      return(true);
     }

   void CreateButton(void)
     {
      if(!m_active || !m_cfg.EnableDashboardButton)
         return;
      if(ObjectFind(m_chart, ButtonName()) < 0)
        {
         if(!ObjectCreate(m_chart, ButtonName(), OBJ_BUTTON, 0, 0, 0))
            return;
         ObjectSetInteger(m_chart, ButtonName(), OBJPROP_CORNER, m_cfg.DashboardCorner);
         ObjectSetInteger(m_chart, ButtonName(), OBJPROP_XDISTANCE, m_cfg.DashboardXOffset + 175);
         ObjectSetInteger(m_chart, ButtonName(), OBJPROP_YDISTANCE, m_cfg.DashboardYOffset - 2);
         ObjectSetInteger(m_chart, ButtonName(), OBJPROP_XSIZE, 90);
         ObjectSetInteger(m_chart, ButtonName(), OBJPROP_YSIZE, 20);
         ObjectSetInteger(m_chart, ButtonName(), OBJPROP_FONTSIZE, m_cfg.DashboardFontSize - 1);
         ObjectSetString(m_chart, ButtonName(), OBJPROP_FONT, m_cfg.DashboardFontName);
         ObjectSetString(m_chart, ButtonName(), OBJPROP_TOOLTIP, "Click to pause/resume new trading activity (chart button)");
         ObjectSetInteger(m_chart, ButtonName(), OBJPROP_STATE, false);
         ObjectSetInteger(m_chart, ButtonName(), OBJPROP_SELECTABLE, false);
         ObjectSetInteger(m_chart, ButtonName(), OBJPROP_HIDDEN, true);
        }
     }

   /// Remove every object this instance created. Safe to call twice.
   void Destroy(const bool full_cleanup)
     {
      if(m_chart == 0)
         return;
      for(int i = ArraySize(m_created) - 1; i >= 0; i--)
        {
         ObjectDelete(m_chart, m_created[i]);
         ArrayResize(m_created, i);
        }
      int total = ObjectsTotal(m_chart, 0, -1);
      if(full_cleanup)
        {
         for(int i = total - 1; i >= 0; i--)
           {
            string nm = ObjectName(m_chart, i, 0, -1);
            if(StringFind(nm, XAU_OBJ_PREFIX) == 0)
               ObjectDelete(m_chart, nm);
           }
        }
      else
         ObjectDelete(m_chart, ButtonName());
      ChartRedraw(m_chart);
      m_pending = 0;
     }

   void Begin(void)
     {
      m_pending = 0;
      ArrayResize(m_lbl, 0);
      ArrayResize(m_val, 0);
      ArrayResize(m_col, 0);
     }
   void Add(const string label, const string value, const color clr)
     {
      if(!m_active)
         return;
      int n = ArraySize(m_lbl);
      ArrayResize(m_lbl, n + 1);
      ArrayResize(m_val, n + 1);
      ArrayResize(m_col, n + 1);
      m_lbl[n] = label;
      m_val[n] = (StringLen(value) > 90 ? StringSubstr(value, 0, 87) + "..." : value);
      m_col[n] = clr;
      m_pending = n + 1;
     }
   void AddAlert(const string label, const string value)
     {
      Add(label, value, m_cfg.ColorDanger);
     }

   /// Repaint only when the configured interval elapsed.
   void End(void)
     {
      if(!m_active)
         return;
      uint now_ms = GetTickCount();
      int  elapsed = (int)(now_ms - m_last_paint_ms);
      if(elapsed < 0)
         elapsed = m_cfg.DashboardUpdateIntervalMs;    // tick counter wrapped
      if(elapsed < m_cfg.DashboardUpdateIntervalMs)
         return;
      m_last_paint_ms = now_ms;
      m_last_paint    = XauNow();
      Paint();
      m_painted++;
     }

   void Paint(void)
     {
      if(!m_active)
         return;
      int x = m_cfg.DashboardXOffset;
      int y = m_cfg.DashboardYOffset;
      int h = RowHeight();
      for(int i = 0; i < m_pending; i++)
        {
         EnsureRowObject(i);
         string nm = Name(i);
         if(ObjectFind(m_chart, nm) < 0)
            continue;
         ObjectSetInteger(m_chart, nm, OBJPROP_XDISTANCE, x);
         ObjectSetInteger(m_chart, nm, OBJPROP_YDISTANCE, y + i * h);
         ObjectSetString(m_chart, nm, OBJPROP_TEXT, m_lbl[i] + ": " + m_val[i]);
         ObjectSetInteger(m_chart, nm, OBJPROP_COLOR, m_col[i]);
        }
      // hide leftovers from a previous, longer panel
      for(int i = m_pending; i < ArraySize(m_created); i++)
         ObjectSetString(m_chart, m_created[i], OBJPROP_TEXT, "");
      ObjectSetString(m_chart, ButtonName(), OBJPROP_CAPTION,
                      (m_cfg.user_paused ? "RESUME" : "PAUSE"));
      ChartRedraw(m_chart);
     }

   /// Chart button handler, called from OnChartEvent.
   /// @return true when the click belongs to this EA's button
   bool OnChartEventClick(const string object_name, bool &toggle_pause)
     {
      toggle_pause = false;
      if(StringLen(object_name) == 0 || object_name != ButtonName())
         return(false);
      m_button_state = 1 - m_button_state;
      toggle_pause   = true;
      return(true);
     }

   string   ButtonObject(void) const { return(ButtonName()); }
   bool     Active(void)   const { return(m_active); }
   int      Paints(void)   const { return(m_painted); }
   datetime LastPaint(void) const { return(m_last_paint); }
   int      Rows(void)     const { return(m_pending); }
   string   Describe(void) const
     {
      return(StringFormat("%s rows=%d every %d ms%s", (m_active ? "on" : "off"), m_pending,
                          m_cfg.DashboardUpdateIntervalMs, (m_active ? "" : " (not rendering)")));
     }
  };

#endif // XAU_AVG_PRO_DASHBOARD_MQH
//+------------------------------------------------------------------+
