//+------------------------------------------------------------------+
//|                                                   Statistics.mqh |
//|  XAU_AVG_PRO v1.0.0 - daily statistics, reconstructed by design |
//|                                                                  |
//|  Two sources, clearly separated:                                 |
//|   - REALIZED P/L, open/close deal counts: always read from the   |
//|     account history (HistorySelect/HistoryDeal*), so they are    |
//|     correct even after a terminal or VPS restart                 |
//|   - CYCLE level counters (cycles, wins, losses, TP events, cut   |
//|     loss events, max layer, max basket volume, worst floating    |
//|     drawdown): maintained by the EA and persisted per day. When   |
//|     the cache is missing the report is marked PARTIAL instead of |
//|     inventing numbers.                                           |
//+------------------------------------------------------------------+
#ifndef XAU_AVG_PRO_STATISTICS_MQH
#define XAU_AVG_PRO_STATISTICS_MQH

#include "Types.mqh"
#include "BrokerSpec.mqh"
#include "Logger.mqh"
#include "StateStore.mqh"

class CStatistics
  {
private:
   CConfig     *m_cfg;
   CSymbolSpec *m_spec;
   CLogger     *m_log;
   CStateStore *m_store;

   SDayStats m_d;
   double  m_hist_realized;
   int     m_hist_open_deals;
   int     m_hist_close_deals;
   datetime m_hist_last_scan;
   bool    m_partial;

   string Key(const string name) { return("d_" + name); }
   void LoadDay(void)
     {
      if(m_store == NULL || !m_store->Enabled())
        {
         m_partial = true;
         return;
        }
      long day = 0;
      if(!m_store->GetInt(Key("day"), day) || day != (long)m_d.day)
        {
         m_partial = true;
         return;
        }
      m_d.start_balance      = m_store->GetDblOr(Key("start_balance"), AccountInfoDouble(ACCOUNT_BALANCE));
      m_d.start_equity       = m_store->GetDblOr(Key("start_equity"), AccountInfoDouble(ACCOUNT_EQUITY));
      m_d.closed_cycles      = (int)m_store->GetIntOr(Key("cycles"), 0);
      m_d.win_cycles          = (int)m_store->GetIntOr(Key("wins"), 0);
      m_d.loss_cycles         = (int)m_store->GetIntOr(Key("losses"), 0);
      m_d.entries             = (int)m_store->GetIntOr(Key("entries"), 0);
      m_d.avg_orders          = (int)m_store->GetIntOr(Key("avgs"), 0);
      m_d.cut_loss_events     = (int)m_store->GetIntOr(Key("cutloss"), 0);
      m_d.basket_tp_events    = (int)m_store->GetIntOr(Key("tp"), 0);
      m_d.max_layers_seen     = (int)m_store->GetIntOr(Key("maxlayer"), 0);
      m_d.max_basket_volume   = m_store->GetDblOr(Key("maxvol"), 0.0);
      m_d.max_dd_money        = m_store->GetDblOr(Key("maxdd"), 0.0);
      m_d.max_dd_percent      = m_store->GetDblOr(Key("maxddpct"), 0.0);
      m_d.blocked_events      = (int)m_store->GetIntOr(Key("blocked"), 0);
      m_partial               = false;
     }
   void SaveDay(void)
     {
      if(m_store == NULL || !m_store->Enabled())
         return;
      m_store->SetInt(Key("day"), (long)m_d.day);
      m_store->SetDbl(Key("start_balance"), m_d.start_balance);
      m_store->SetDbl(Key("start_equity"), m_d.start_equity);
      m_store->SetInt(Key("cycles"), m_d.closed_cycles);
      m_store->SetInt(Key("wins"), m_d.win_cycles);
      m_store->SetInt(Key("losses"), m_d.loss_cycles);
      m_store->SetInt(Key("entries"), m_d.entries);
      m_store->SetInt(Key("avgs"), m_d.avg_orders);
      m_store->SetInt(Key("cutloss"), m_d.cut_loss_events);
      m_store->SetInt(Key("tp"), m_d.basket_tp_events);
      m_store->SetInt(Key("maxlayer"), m_d.max_layers_seen);
      m_store->SetDbl(Key("maxvol"), m_d.max_basket_volume);
      m_store->SetDbl(Key("maxdd"), m_d.max_dd_money);
      m_store->SetDbl(Key("maxddpct"), m_d.max_dd_percent);
      m_store->SetInt(Key("blocked"), m_d.blocked_events);
     }
   /// Read the account history for the current server day.
   void ReadHistory(const bool force)
     {
      datetime now  = XauNow();
      datetime day  = XauServerDayStart(now);
      if(!force && (int)(now - m_hist_last_scan) < 20 && m_hist_last_scan != 0 && day == m_d.day)
         return;
      m_hist_last_scan = now;
      m_hist_realized  = 0.0;
      m_hist_open_deals  = 0;
      m_hist_close_deals = 0;
      if(!HistorySelect(day, day + 86400))
        {
         m_log.Throttled(1, XAU_T_STATS, "hist", StringFormat("HistorySelect failed err=%d", GetLastError()), 300);
         return;
        }
      int total = HistoryDealsTotal();
      for(int i = 0; i < total; i++)
        {
         long deal = HistoryDealGetTicket(i);
         if(deal <= 0)
            continue;
         if(HistoryDealGetInteger(deal, DEAL_MAGIC) != m_cfg.MagicNumber)
            continue;
         string ds = HistoryDealGetString(deal, DEAL_SYMBOL);
         if(m_cfg.ManageCurrentSymbolOnly && ds != m_spec.Symbol())
            continue;
         long entry = HistoryDealGetInteger(deal, DEAL_ENTRY);
         if(entry == DEAL_ENTRY_IN)
            m_hist_open_deals++;
         else
            if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_INOUT || entry == DEAL_ENTRY_OUT_BY)
              {
               m_hist_close_deals++;
               m_hist_realized += HistoryDealGetDouble(deal, DEAL_PROFIT) +
                                  HistoryDealGetDouble(deal, DEAL_SWAP) +
                                  HistoryDealGetDouble(deal, DEAL_COMMISSION);
              }
        }
      m_d.realized_pl = m_hist_realized;
     }

public:
                     CStatistics(void) : m_cfg(NULL), m_spec(NULL), m_log(NULL), m_store(NULL),
                                        m_hist_realized(0.0), m_hist_open_deals(0), m_hist_close_deals(0),
                                        m_hist_last_scan(0), m_partial(false)
     {
      ZeroMemory(m_d);
     }

   void Init(CConfig *cfg, CSymbolSpec *spec, CLogger *log, CStateStore *store)
     {
      m_cfg   = cfg;
      m_spec  = spec;
      m_log   = log;
      m_store = store;
      ZeroMemory(m_d);
      m_d.day          = XauServerDayStart(XauNow());
      m_d.initialised  = true;
      m_d.start_balance = AccountInfoDouble(ACCOUNT_BALANCE);
      m_d.start_equity  = AccountInfoDouble(ACCOUNT_EQUITY);
      LoadDay();
      ReadHistory(true);
      if(m_partial)
        {
         m_log.Warn(XAU_T_STATS, "cycle counters could not be restored from the state cache (first run or cache lost) - "
                  "realized P/L and deal counts below are taken from account history and remain exact");
         // reconstruct what IS derivable so the report is never empty
         m_d.entries      = m_hist_open_deals;
         m_d.avg_orders   = MathMax(0, m_hist_open_deals - 1);
         m_d.closed_cycles = m_hist_close_deals;
        }
      SaveDay();
     }

   /// Called from OnTimer: rolls the day over and refreshes history data.
   /// @return true when a new day started
   bool Tick(void)
     {
      datetime day = XauServerDayStart(XauNow());
      if(day != m_d.day)
        {
         if(m_cfg.EnableCsvDailyReport)
            WriteCsv();
         m_log.Info(XAU_T_STATS, StringFormat("new server day %s - daily counters reset (previous day realized %s, %d closed deals)",
                                              TimeToString(day, TIME_DATE), XauMoney(m_hist_realized), m_hist_close_deals));
         ZeroMemory(m_d);
         m_d.day          = day;
         m_d.initialised  = true;
         m_d.start_balance = AccountInfoDouble(ACCOUNT_BALANCE);
         m_d.start_equity  = AccountInfoDouble(ACCOUNT_EQUITY);
         m_partial         = false;
         ReadHistory(true);
         SaveDay();
         return(true);
        }
      ReadHistory(false);
      return(false);
     }

   //--- event counters ------------------------------------------------
   void RegisterEntry(void)     { m_d.entries++;     SaveDay(); }
   void RegisterAveraging(void) { m_d.avg_orders++;  SaveDay(); }
   void RegisterBlocked(void)   { m_d.blocked_events++; SaveDay(); }

   /// One call per finished cycle - the only place that decides whether a
   /// cycle is a win or a loss, so no double counting is possible.
   /// @param exit_code  1 basket TP, 2 cut loss, 3 risk close, 4 manual,
   ///                   5 external, 6 weekend flatten
   /// @param net_pl     realised basket result including swap/commission
   void RegisterCycleEnd(const long cycle_id, const int exit_code, const double net_pl)
     {
      m_d.closed_cycles++;
      if(exit_code == 1)
         m_d.basket_tp_events++;
      else
         if(exit_code == 2)
            m_d.cut_loss_events++;
      if(net_pl > 0.0)
         m_d.win_cycles++;
      else
         if(net_pl < 0.0)
            m_d.loss_cycles++;
      SaveDay();
      m_log.Info(XAU_T_STATS, StringFormat("cycle #%s recorded | exit_code=%d net=%s (day: %d cycles, W%d/L%d, TP %d, CL %d)",
                                           IntegerToString(cycle_id), exit_code, XauMoney(net_pl),
                                           m_d.closed_cycles, m_d.win_cycles, m_d.loss_cycles,
                                           m_d.basket_tp_events, m_d.cut_loss_events));
     }

   /// Observe the basket shape (max layer, max volume, worst floating).
   void Observe(const int layers, const double volume, const double net_pl, const double net_pct)
     {
      bool changed = false;
      if(layers > m_d.max_layers_seen)      { m_d.max_layers_seen = layers;  changed = true; }
      if(volume > m_d.max_basket_volume)    { m_d.max_basket_volume = volume; changed = true; }
      if(net_pl < m_d.max_dd_money)         { m_d.max_dd_money = net_pl;      changed = true; }
      if(net_pct < m_d.max_dd_percent)      { m_d.max_dd_percent = net_pct;   changed = true; }
      if(changed)
         SaveDay();
     }

   void   Get(SDayStats &out) const { out = m_d; }
   double RealizedToday(void)  const { return(m_hist_realized); }
   int    OpenDealsToday(void) const { return(m_hist_open_deals); }
   int    CloseDealsToday(void) const { return(m_hist_close_deals); }
   bool   Partial(void)        const { return(m_partial); }

   string DailyReport(void)
     {
      double balance = AccountInfoDouble(ACCOUNT_BALANCE);
      double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
      string nl = "\n";
      string s = "";
      s += "=== DAILY REPORT " + TimeToString(m_d.day, TIME_DATE) + " (server) ===" + nl;
      s += StringFormat("EA            : %s v%s  magic %s\n", XAU_EA_NAME, XAU_EA_VERSION, IntegerToString(m_cfg.MagicNumber));
      s += StringFormat("Symbol        : %s\n", m_spec.Symbol());
      s += StringFormat("Realized P/L  : %s  (from account history, %d close deals)\n",
                        XauMoney(m_hist_realized), m_hist_close_deals);
      s += StringFormat("Closed profit : %s\n", XauMoney(m_d.realized_pl));
      s += StringFormat("Cycles        : %d  (win %d / loss %d)\n", m_d.closed_cycles, m_d.win_cycles, m_d.loss_cycles);
      s += StringFormat("Entries       : %d  |  averaging orders: %d\n", m_d.entries, m_d.avg_orders);
      s += StringFormat("Basket TP     : %d  |  cut loss events : %d\n", m_d.basket_tp_events, m_d.cut_loss_events);
      s += StringFormat("Max layer     : %d  |  max basket lot  : %s\n", m_d.max_layers_seen,
                        DoubleToString(m_d.max_basket_volume, m_spec.VolumeDigits()));
      s += StringFormat("Max floating  : %.2f (%.2f%% of cycle balance)\n", m_d.max_dd_money, m_d.max_dd_percent);
      s += StringFormat("Day start bal : %s  |  now: %s\n", XauMoney(m_d.start_balance), XauMoney(balance));
      s += StringFormat("Equity        : %s\n", XauMoney(equity));
      s += StringFormat("Risk blocks   : %d\n", m_d.blocked_events);
      if(m_partial)
         s += "NOTE: cycle counters are partial (state cache was not available at start)." + nl;
      return(s);
     }

   /// One compact line for the dashboard.
   string StatusLine(const double floating)
     {
      return(StringFormat("REALIZED %s | FLOAT %s | CYCLES %d (W%d/L%d) | TP %d CL %d",
                          XauMoney(m_hist_realized), XauMoney(floating), m_d.closed_cycles,
                          m_d.win_cycles, m_d.loss_cycles, m_d.basket_tp_events, m_d.cut_loss_events));
     }

   /// Append one row per day to MQL5\Files\XAU_AVG_PRO_daily_<magic>.csv
   bool WriteCsv(void)
     {
      if(!m_cfg.EnableCsvDailyReport)
         return(false);
      if(MQLInfoInteger(MQL_TESTER))
        {
         m_log.Debug(XAU_T_STATS, "CSV report skipped in Strategy Tester");
         return(false);
        }
      string name = XAU_STATE_FILE + "_daily_" + IntegerToString(m_cfg.MagicNumber) + ".csv";
      bool   need_header = !FileIsExist(name);
      int h = FileOpen(name, FILE_READ | FILE_WRITE | FILE_CSV | FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_ANSI, ',');
      if(h == INVALID_HANDLE)
        {
         m_log.Throttled(1, XAU_T_STATS, "csv_open", StringFormat("cannot open %s err=%d", name, GetLastError()), 600);
         return(false);
        }
      FileSeek(h, 0, SEEK_END);
      if(need_header)
        {
         FileWrite(h, "date","ea","version","magic","symbol","realized_pl","closed_profit","floating_at_write",
                   "cycles","win","loss","entries","averaging","cut_loss","basket_tp","max_layer","max_lot",
                   "max_dd_money","max_dd_percent","balance","equity","generated");
        }
      FileWrite(h,
                TimeToString(m_d.day, TIME_DATE),
                XAU_EA_NAME,
                XAU_EA_VERSION,
                IntegerToString(m_cfg.MagicNumber),
                m_spec.Symbol(),
                DoubleToString(m_hist_realized, 2),
                DoubleToString(m_d.realized_pl, 2),
                DoubleToString(m_d.max_dd_money, 2),
                IntegerToString(m_d.closed_cycles),
                IntegerToString(m_d.win_cycles),
                IntegerToString(m_d.loss_cycles),
                IntegerToString(m_d.entries),
                IntegerToString(m_d.avg_orders),
                IntegerToString(m_d.cut_loss_events),
                IntegerToString(m_d.basket_tp_events),
                IntegerToString(m_d.max_layers_seen),
                DoubleToString(m_d.max_basket_volume, 2),
                DoubleToString(m_d.max_dd_money, 2),
                DoubleToString(m_d.max_dd_percent, 3),
                DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2),
                DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2),
                TimeToString(XauNow(), TIME_DATE | TIME_SECONDS));
      FileClose(h);
      m_log.Info(XAU_T_STATS, "daily report appended to " + name);
      return(true);
     }
  };

#endif // XAU_AVG_PRO_STATISTICS_MQH
//+------------------------------------------------------------------+
