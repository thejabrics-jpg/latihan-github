//+------------------------------------------------------------------+
//|                                                        Cycle.mqh |
//|   XAU_AVG_PRO v1.0.0 - trading cycle / basket state and recovery|
//|                                                                  |
//|  A CYCLE is one basket: initial entry plus every averaging      |
//|  layer, closed by basket TP, basket cut loss, a risk action or  |
//|  a manual/Telegram close. Orders are not cycles.                |
//|                                                                  |
//|  Every number below is DERIVED from live positions first and    |
//|  from the persisted cache second, which is what makes restart    |
//|  recovery correct. The cached file only stores what cannot be    |
//|  read from the terminal: cycle id, layer history of netting     |
//|  accounts, cycle start balance and worst drawdown.               |
//+------------------------------------------------------------------+
#ifndef XAU_AVG_PRO_CYCLE_MQH
#define XAU_AVG_PRO_CYCLE_MQH

#include "Types.mqh"
#include "BrokerSpec.mqh"
#include "Logger.mqh"
#include "StateStore.mqh"

class CCycleManager
  {
private:
   CConfig     *m_cfg;
   CSymbolSpec *m_spec;
   CLogger     *m_log;
   CStateStore *m_store;

   SCycleData  m_c;
   SLayerRec   m_layers[];
   int         m_position_count;     // EA positions on the chart symbol
   double      m_foreign_volume;     // EA volume on other symbols (exposure only)
   long        m_foreign_positions;
   bool        m_conflict;           // EA holds BOTH directions
   string      m_conflict_text;
   bool        m_uncertain;          // basket cannot be fully reconstructed
   string      m_uncertain_text;
   long        m_next_cycle_id;
   bool        m_have_state;
   int         m_closed_cycle_count; // observed by this process

   //--- internal ---------------------------------------------------
   void LoadCachedLayers(void)
     {
      ArrayResize(m_layers, 0);
      if(m_store == NULL || !m_store.Enabled())
         return;
      long count = 0;
      if(!m_store.GetInt("lay_count", count) || count <= 0)
         return;
      for(int i = 0; i < (int)count && i < XAU_MAX_LAYERS_HARD; i++)
        {
         string prefix = "lay" + IntegerToString(i) + "_";
         SLayerRec rec;
         long tk = 0;
         if(!m_store.GetInt(prefix + "ticket", tk))
            break;
         rec.ticket     = tk;
         rec.index      = i + 1;
         rec.volume     = m_store.GetDblOr(prefix + "vol", 0.0);
         rec.open_price = m_store.GetDblOr(prefix + "price", 0.0);
         rec.open_time  = m_store.GetTimeOr(prefix + "time", 0);
         if(rec.volume <= 0.0)
            break;
         int n = ArraySize(m_layers);
         ArrayResize(m_layers, n + 1);
         m_layers[n] = rec;
        }
     }
   void SaveLayers(void)
     {
      if(m_store == NULL || !m_store.Enabled())
         return;
      m_store.SetInt("lay_count", ArraySize(m_layers));
      for(int i = 0; i < ArraySize(m_layers); i++)
        {
         string prefix = "lay" + IntegerToString(i) + "_";
         m_store.SetInt(prefix + "ticket", m_layers[i].ticket);
         m_store.SetDbl(prefix + "vol", m_layers[i].volume);
         m_store.SetDbl(prefix + "price", m_layers[i].open_price);
         m_store.SetTime(prefix + "time", m_layers[i].open_time);
        }
      for(int i = ArraySize(m_layers); i < ArraySize(m_layers) + 4; i++)
         m_store.Erase("lay" + IntegerToString(i) + "_ticket");
     }
   void SaveCycle(void)
     {
      if(m_store == NULL || !m_store.Enabled())
         return;
      m_store.SetInt("cyc_id", m_c.id);
      m_store.SetInt("cyc_next", m_next_cycle_id);
      m_store.SetInt("cyc_dir", (long)m_c.dir);
      m_store.SetTime("cyc_start", m_c.start_time);
      m_store.SetDbl("cyc_init_vol", m_c.initial_volume);
      m_store.SetDbl("cyc_total_vol", m_c.total_volume);
      m_store.SetDbl("cyc_avg", m_c.avg_price);
      m_store.SetDbl("cyc_bal_start", m_c.balance_at_start);
      m_store.SetDbl("cyc_dd_money", m_c.max_dd_money);
      m_store.SetDbl("cyc_dd_percent", m_c.max_dd_percent);
      m_store.SetTime("cyc_last_fill", m_c.last_fill_time);
      m_store.SetDbl("cyc_last_price", m_c.last_fill_price);
      m_store.SetBool("cyc_active", m_c.active);
      SaveLayers();
     }
   void RestoreCycle(void)
     {
      m_c.id               = m_store.GetIntOr("cyc_id", 0);
      m_next_cycle_id      = m_store.GetIntOr("cyc_next", 1);
      m_c.dir              = (ENUM_POSITION_TYPE)m_store.GetIntOr("cyc_dir", (long)POSITION_TYPE_BUY);
      m_c.start_time       = m_store.GetTimeOr("cyc_start", 0);
      m_c.initial_volume   = m_store.GetDblOr("cyc_init_vol", 0.0);
      m_c.balance_at_start = m_store.GetDblOr("cyc_bal_start", 0.0);
      m_c.max_dd_money     = m_store.GetDblOr("cyc_dd_money", 0.0);
      m_c.max_dd_percent   = m_store.GetDblOr("cyc_dd_percent", 0.0);
      m_c.last_fill_time   = m_store.GetTimeOr("cyc_last_fill", 0);
      m_c.last_fill_price  = m_store.GetDblOr("cyc_last_price", 0.0);
      m_c.total_volume     = m_store.GetDblOr("cyc_total_vol", 0.0);
      m_c.avg_price        = m_store.GetDblOr("cyc_avg", 0.0);
      m_c.active           = m_store.GetBoolOr("cyc_active", false);
     }
   /// Add a layer record keeping index order.
   void PushLayer(const long ticket, const double volume, const double price, const datetime when)
     {
      int n = ArraySize(m_layers);
      ArrayResize(m_layers, n + 1);
      m_layers[n].ticket     = ticket;
      m_layers[n].volume     = volume;
      m_layers[n].open_price = price;
      m_layers[n].open_time  = when;
      m_layers[n].index      = n + 1;
      // stable sort by time then ticket: layer 1 is always the oldest
      for(int i = 1; i < ArraySize(m_layers); i++)
        {
         SLayerRec key = m_layers[i];
         int j = i - 1;
         while(j >= 0 && (m_layers[j].open_time > key.open_time ||
                          (m_layers[j].open_time == key.open_time && m_layers[j].ticket > key.ticket)))
           {
            m_layers[j + 1] = m_layers[j];
            j--;
           }
         m_layers[j + 1] = key;
        }
      for(int i = 0; i < ArraySize(m_layers); i++)
         m_layers[i].index = i + 1;
     }

public:
                     CCycleManager(void) : m_cfg(NULL), m_spec(NULL), m_log(NULL), m_store(NULL),
                                           m_position_count(0), m_foreign_volume(0.0), m_foreign_positions(0),
                                           m_conflict(false), m_conflict_text(""), m_uncertain(false),
                                           m_uncertain_text(""), m_next_cycle_id(1), m_have_state(false),
                                           m_closed_cycle_count(0)
     {
      ZeroMemory(m_c);
     }

   void Init(CConfig *cfg, CSymbolSpec *spec, CLogger *log, CStateStore *store)
     {
      m_cfg   = cfg;
      m_spec  = spec;
      m_log   = log;
      m_store = store;
      ZeroMemory(m_c);
      m_c.id            = 0;
      m_c.layers        = 0;
      m_c.active        = false;
      m_c.exit_code     = 0;
      m_have_state      = (store != NULL && store.Load());
      if(m_have_state)
        {
         RestoreCycle();
         LoadCachedLayers();
        }
      if(m_next_cycle_id < 1)
         m_next_cycle_id = 1;
      if(m_c.id < 1)
         m_c.id = 0;
     }

   /// Rebuild the whole basket from live positions. Cheap enough to be
   /// called on every tick: a single pass over PositionsTotal().
   void Reconcile(void)
     {
      ENUM_POSITION_TYPE found_dir = POSITION_TYPE_BUY;
      bool  have_dir   = false;
      bool  other_dir  = false;
      int   live_count = 0;
      double live_volume = 0.0;
      double live_cost   = 0.0;      // sum(price*volume)
      double live_pl     = 0.0;
      double live_swap   = 0.0;
      datetime first_time = 0;
      long     first_ticket = 0;
      int      net_ticket_index = -1;

      m_foreign_volume    = 0.0;
      m_foreign_positions = 0;
      m_conflict          = false;
      m_conflict_text     = "";

      long   live_tickets[];
      double live_vols[];
      double live_prices[];
      datetime live_times[];

      int total = PositionsTotal();
      for(int i = 0; i < total; i++)
        {
         long ticket = (long)PositionGetTicket(i);
         if(ticket <= 0)
            continue;
         if(PositionGetInteger(POSITION_MAGIC) != m_cfg.MagicNumber)
            continue;
         string pos_symbol = PositionGetString(POSITION_SYMBOL);
         bool   same_symbol = (pos_symbol == m_spec.Symbol());
         if(!same_symbol)
           {
            // Other symbols are only counted for exposure, never managed.
            if(!m_cfg.ManageCurrentSymbolOnly)
              {
               m_foreign_volume    += PositionGetDouble(POSITION_VOLUME);
               m_foreign_positions++;
              }
            continue;
           }
         if(m_cfg.ManageCurrentSymbolOnly && pos_symbol != _Symbol)
            continue;
         ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         if(!have_dir)
           {
            found_dir = type;
            have_dir  = true;
           }
         else
            if(type != found_dir)
               other_dir = true;

         double vol   = PositionGetDouble(POSITION_VOLUME);
         double price = PositionGetDouble(POSITION_PRICE_OPEN);
         datetime t   = (datetime)PositionGetInteger(POSITION_TIME);
         int n = ArraySize(live_tickets);
         ArrayResize(live_tickets, n + 1);
         ArrayResize(live_vols, n + 1);
         ArrayResize(live_prices, n + 1);
         ArrayResize(live_times, n + 1);
         live_tickets[n] = ticket;
         live_vols[n]    = vol;
         live_prices[n]  = price;
         live_times[n]   = t;
         live_count++;
         live_volume += vol;
         live_cost   += price * vol;
         live_pl     += PositionGetDouble(POSITION_PROFIT);
         live_swap   += PositionGetDouble(POSITION_SWAP);
         if(first_time == 0 || t < first_time || (t == first_time && ticket < first_ticket))
           {
            first_time   = t;
            first_ticket = ticket;
           }
         if(!m_spec.IsHedgingAccount())
            net_ticket_index = n;
        }

      m_position_count = live_count;

      if(other_dir)
        {
         m_conflict      = true;
         m_conflict_text = "EA magic holds both BUY and SELL positions on " + m_spec.Symbol();
         m_uncertain     = true;
         m_uncertain_text = "direction conflict - averaging disabled until the basket is flat";
         m_log.Error(XAU_T_STATE, m_conflict_text + " | manual intervention required");
        }

      if(live_count == 0)
        {
         if(m_c.active)
           {
            // basket disappeared (closed by TP/cut loss, manually, or by
            // the broker). Statistics are rebuilt from history by
            // CStatistics; here we only retire the cycle.
            m_closed_cycle_count++;
            m_log.Info(XAU_T_STATE, StringFormat("cycle #%d closed (0 EA positions left) | recorded exit=%d",
                                                 m_c.id, m_c.exit_code));
            m_c.active    = false;
            m_c.exit_code = (m_c.exit_code == 0 ? 5 : m_c.exit_code);   // 5 = external close
            m_next_cycle_id = m_c.id + 1;
            ArrayResize(m_layers, 0);
            m_uncertain = false;
            m_uncertain_text = "";
            SaveCycle();
           }
         m_c.layers        = 0;
         m_c.total_volume  = 0.0;
         m_c.avg_price     = 0.0;
         m_c.floating_pl   = 0.0;
         m_c.basket_tp     = 0.0;
         m_c.next_level    = 0.0;
         if(!m_conflict)
           {
            m_uncertain      = false;
            m_uncertain_text = "";
           }
         return;
        }

      //--- basket is live: rebuild layer history ----------------------
      int cached = ArraySize(m_layers);
      bool cached_valid = (cached > 0);
      for(int i = 0; i < cached && cached_valid; i++)
        {
         bool found = false;
         for(int j = 0; j < live_count; j++)
            if(live_tickets[j] == m_layers[i].ticket)
               found = true;
         if(!found)
            cached_valid = false;                    // a layer was closed outside the EA
        }
      if(cached_valid && m_spec.IsHedgingAccount())
        {
         // refresh volume/price from the live position (partial changes)
         for(int i = 0; i < ArraySize(m_layers); i++)
            for(int j = 0; j < live_count; j++)
               if(live_tickets[j] == m_layers[i].ticket)
                 {
                  m_layers[i].volume     = live_vols[j];
                  m_layers[i].open_price = live_prices[j];
                 }
        }
      else
        {
         ArrayResize(m_layers, 0);
         for(int j = 0; j < live_count; j++)
            PushLayer(live_tickets[j], live_vols[j], live_prices[j], live_times[j]);
        }

      // netting accounts merge everything into one position: the layer
      // history must come from the cache, or be reconstructed when the
      // lot schedule is a fixed volume (deterministic ratio).
      if(!m_spec.IsHedgingAccount() && !cached_valid && live_count > 0)
        {
         double base = m_cfg.InitialLot;
         if(m_cfg.AllowNettingLayerReconstruction && m_cfg.LotMode == XAU_LOT_FIXED && base > 0.0)
           {
            double ratio = live_volume / base;
            int    guess = (int)MathRound(ratio);
            if(guess >= 1 && MathAbs(ratio - (double)guess) < 1.0e-6)
              {
               ArrayResize(m_layers, 0);
               for(int i = 0; i < guess; i++)
                  PushLayer(live_tickets[net_ticket_index >= 0 ? net_ticket_index : 0],
                            base, m_c.avg_price > 0.0 ? m_c.avg_price : live_prices[0],
                            (datetime)(first_time + i));
               m_log.Warn(XAU_T_STATE, StringFormat("netting: layer count reconstructed from volume ratio = %d", guess));
              }
            else
              {
               m_uncertain      = true;
               m_uncertain_text = "netting account, layer history not reconstructable (volume ratio not a whole multiple)";
              }
           }
         else
           {
            m_uncertain      = true;
            m_uncertain_text = "netting account without usable layer cache - averaging is blocked until the basket is flat";
           }
        }

      double vol_sum = 0.0;
      double cost    = 0.0;
      for(int i = 0; i < ArraySize(m_layers); i++)
        {
         vol_sum += m_layers[i].volume;
         cost    += m_layers[i].open_price * m_layers[i].volume;
        }
      if(vol_sum <= 0.0)
        {
         vol_sum = live_volume;
         cost    = live_cost;
        }

      bool was_active   = m_c.active;
      m_c.active        = true;
      m_c.layers        = ArraySize(m_layers);
      m_c.dir           = found_dir;
      m_c.total_volume  = live_volume;
      m_c.avg_price     = (vol_sum > 0.0 ? cost / vol_sum : 0.0);
      m_c.floating_pl   = live_pl + (m_cfg.AccountForSwapInTP ? live_swap : 0.0);
      m_c.margin_used   = m_spec.AccountMargin();
      m_c.exit_code     = 0;
      if(!was_active)
        {
         // adopted after a restart, or the state file was lost
         m_c.id = m_next_cycle_id++;
         m_c.start_time      = first_time;
         m_c.initial_volume  = live_vols[0];
         m_c.balance_at_start = AccountInfoDouble(ACCOUNT_BALANCE);
         m_c.max_dd_money    = 0.0;
         m_c.max_dd_percent  = 0.0;
         m_c.recovered       = true;
         m_c.last_fill_time  = live_times[0];
         m_c.last_fill_price = live_prices[0];
         // newest fill drives the "last layer" reference
         for(int j = 1; j < live_count; j++)
            if(live_times[j] >= m_c.last_fill_time)
              {
               m_c.last_fill_time  = live_times[j];
               m_c.last_fill_price = live_prices[j];
              }
         m_log.Warn(XAU_T_STATE, StringFormat("cycle #%d ADOPTED from live positions | %s dir=%s layers=%d lot=%s avg=%s",
                                              m_c.id, (m_have_state ? "state cache merged" : "no state cache"),
                                              (found_dir == POSITION_TYPE_BUY ? "BUY" : "SELL"),
                                              m_c.layers, DoubleToString(live_volume, m_spec.VolumeDigits()),
                                              XauPrice(m_c.avg_price)));
        }
      else
        {
         if(live_count > m_c.layers || ArraySize(m_layers) > m_c.layers)
           {
            m_c.last_fill_time  = first_time;
            m_c.last_fill_price = live_prices[0];
            for(int j = 0; j < live_count; j++)
               if(live_times[j] >= m_c.last_fill_time)
                 {
                  m_c.last_fill_time  = live_times[j];
                  m_c.last_fill_price = live_prices[j];
                 }
           }
         if(first_time > 0 && m_c.start_time == 0)
            m_c.start_time = first_time;
        }
      if(m_c.balance_at_start <= 0.0)
         m_c.balance_at_start = AccountInfoDouble(ACCOUNT_BALANCE);

      SaveCycle();
     }

   /// Force the "last fill" pointers after a successful new layer.
   void NoteFill(const long ticket, const double volume, const double price, const datetime when)
     {
      m_c.last_fill_time  = when;
      m_c.last_fill_price = price;
      if(m_spec.IsHedgingAccount())
         PushLayer(ticket, volume, price, when);
      else
        {
         // netting: append a virtual layer on top of the merged position
         int n = ArraySize(m_layers);
         ArrayResize(m_layers, n + 1);
         m_layers[n].ticket     = ticket;
         m_layers[n].index      = n + 1;
         m_layers[n].volume     = volume;
         m_layers[n].open_price = price;
         m_layers[n].open_time  = when;
        }
      m_c.layers       = ArraySize(m_layers);
      m_c.recovered    = false;
      m_uncertain      = false;
      m_uncertain_text = "";
      SaveCycle();
     }

   /// First position of a new cycle.
   void BeginCycle(const ENUM_POSITION_TYPE dir, const double volume, const double price,
                   const long ticket, const datetime when)
     {
      ArrayResize(m_layers, 0);
      m_c.id             = m_next_cycle_id++;
      m_c.dir            = dir;
      m_c.start_time     = when;
      m_c.initial_volume = volume;
      m_c.layers         = 1;
      m_c.total_volume   = volume;
      m_c.avg_price      = price;
      m_c.floating_pl    = 0.0;
      m_c.max_dd_money   = 0.0;
      m_c.max_dd_percent = 0.0;
      m_c.balance_at_start = AccountInfoDouble(ACCOUNT_BALANCE);
      m_c.last_fill_time  = when;
      m_c.last_fill_price = price;
      m_c.active         = true;
      m_c.recovered      = false;
      m_c.exit_code      = 0;
      m_uncertain        = false;
      m_uncertain_text   = "";
      PushLayer(ticket, volume, price, when);
      SaveCycle();
      m_log.Info(XAU_T_STATE, StringFormat("cycle #%d started | dir=%s lot=%s price=%s",
                                           m_c.id, (dir == POSITION_TYPE_BUY ? "BUY" : "SELL"),
                                           DoubleToString(volume, m_spec.VolumeDigits()), XauPrice(price)));
     }

   /// Called right before/after the EA closes its basket so the exit is
   /// attributed correctly in logs, statistics and Telegram.
   void MarkClosing(const int exit_code)
     {
      m_c.exit_code = exit_code;
      SaveCycle();
     }
   void MarkClosed(const int exit_code, const double realized_pl)
     {
      if(!m_c.active)
         return;
      m_log.Info(XAU_T_STATE, StringFormat("cycle #%d finished | exit=%s realized=%s layers=%d worst_dd=%.2f (%.2f%%)",
                                           m_c.id, ExitName(exit_code), XauMoney(realized_pl), m_c.layers,
                                           m_c.max_dd_money, m_c.max_dd_percent));
      m_c.active  = false;
      m_c.layers  = 0;
      m_c.exit_code = exit_code;
      m_next_cycle_id = m_c.id + 1;
      ArrayResize(m_layers, 0);
      m_uncertain      = false;
      m_uncertain_text = "";
      m_c.total_volume = 0.0;
      m_c.floating_pl  = 0.0;
      m_c.basket_tp    = 0.0;
      m_c.next_level   = 0.0;
      SaveCycle();
     }

   string ExitName(const int code)
     {
      switch(code)
        {
         case 1:  return("BASKET_TP");
         case 2:  return("CUT_LOSS");
         case 3:  return("RISK_CLOSE");
         case 4:  return("MANUAL");
         case 5:  return("EXTERNAL");
         case 6:  return("WEEKEND");
        }
      return("OPEN");
     }

   /// Track the worst floating P/L of the cycle. max_dd_money is stored
   /// as the worst (most negative) floating result, max_dd_percent as the
   /// matching percentage of the balance recorded at cycle start. Used by
   /// cycle drawdown protection and by the daily report.
   void UpdateDrawdown(const double balance)
     {
      if(!m_c.active || m_c.total_volume <= 0.0)
         return;
      if(m_c.floating_pl < m_c.max_dd_money)
        {
         m_c.max_dd_money   = m_c.floating_pl;
         double ref = (m_c.balance_at_start > 0.0 ? m_c.balance_at_start : balance);
         m_c.max_dd_percent = (ref > 0.0 ? m_c.floating_pl / ref * 100.0 : 0.0);
         SaveCycle();
        }
     }

   void SetBasketTP(const double tp)   { m_c.basket_tp = tp; }
   void SetNextLevel(const double lvl) { m_c.next_level = lvl; }
   void SetDistancePoints(const double pts) { m_c.distance_points = pts; }

   //--- queries ------------------------------------------------------
   bool  IsActive(void)          const { return(m_c.active); }
   bool  HasConflict(void)       const { return(m_conflict); }
   string ConflictText(void)     const { return(m_conflict_text); }
   bool  IsUncertain(void)       const { return(m_uncertain); }
   string UncertainText(void)    const { return(m_uncertain_text); }
   int   PositionCount(void)     const { return(m_position_count); }
   int   LayerCount(void)        const { return(ArraySize(m_layers)); }
   double ForeignVolume(void)    const { return(m_foreign_volume); }
   long   ForeignPositions(void) const { return(m_foreign_positions); }
   long   CycleId(void)          const { return(m_c.id); }
   int   ClosedObserved(void)    const { return(m_closed_cycle_count); }
   bool  HaveState(void)         const { return(m_have_state); }
   bool  IsBuyBasket(void)       const { return(m_c.dir == POSITION_TYPE_BUY); }

   double TotalVolume(void)      const { return(m_c.total_volume); }
   double AvgPrice(void)         const { return(m_c.avg_price); }
   double FloatingPL(void)       const { return(m_c.floating_pl); }
   double BasketTP(void)         const { return(m_c.basket_tp); }
   double NextLevel(void)        const { return(m_c.next_level); }
   double DistancePoints(void)   const { return(m_c.distance_points); }
   double LastFillPrice(void)    const { return(m_c.last_fill_price); }
   double MaxDDMoney(void)       const { return(m_c.max_dd_money); }
   double MaxDDPercent(void)     const { return(m_c.max_dd_percent); }
   double BalanceAtStart(void)   const { return(m_c.balance_at_start); }
   datetime StartTime(void)      const { return(m_c.start_time); }
   datetime LastFillTime(void)   const { return(m_c.last_fill_time); }
   ENUM_POSITION_TYPE Dir(void)  const { return(m_c.dir); }
   int  ExitCode(void)           const { return(m_c.exit_code); }

   /// Combined EA exposure on this symbol plus (optionally) other
   /// symbols managed by the same magic number.
   double TotalExposure(void) const
     {
      return(m_c.total_volume + m_foreign_volume);
     }

   void   Data(SCycleData &out) const { out = m_c; }
   int   Layers(SLayerRec &arr[]) const
     {
      int n = ArraySize(m_layers);
      ArrayResize(arr, n);
      for(int i = 0; i < n; i++)
         arr[i] = m_layers[i];
      return(n);
     }
   bool  GetLayer(const int index_zero_based, SLayerRec &out) const
     {
      if(index_zero_based < 0 || index_zero_based >= ArraySize(m_layers))
         return(false);
      out = m_layers[index_zero_based];
      return(true);
     }
   /// Reference price the next averaging level is measured from.
   double AveragingReferencePrice(void) const
     {
      int n = ArraySize(m_layers);
      if(n <= 0)
         return(m_c.avg_price);
      switch(m_cfg.AveragingReference)
        {
         case XAU_AVGREF_LAST_LAYER: return(m_layers[n - 1].open_price);
         case XAU_AVGREF_AVERAGE:    return(m_c.avg_price);
         case XAU_AVGREF_FIRST:      return(m_layers[0].open_price);
        }
      return(m_layers[n - 1].open_price);
     }

   /// Money value of one point of movement for the whole basket.
   double BasketMoneyPerPoint(void) const
     {
      return(m_spec.MoneyPerPointPerLot() * m_c.total_volume);
     }
   /// Money value of one price unit (e.g. 1.00 USD of gold) for the basket.
   double BasketMoneyPerPriceUnit(void) const
     {
      return(m_spec.MoneyPerPointPerLot() * m_c.total_volume / (m_spec.Point() > 0.0 ? m_spec.Point() : 1.0));
     }

   string LayerList(void) const
     {
      string s = "";
      for(int i = 0; i < ArraySize(m_layers); i++)
        {
         if(i > 0)
            s += ", ";
         s += StringFormat("L%d %s@%s", m_layers[i].index,
                           DoubleToString(m_layers[i].volume, m_spec.VolumeDigits()),
                           XauPrice(m_layers[i].open_price));
        }
      return(s);
     }

   string Describe(void) const
     {
      if(!m_c.active)
         return("no active cycle");
      return(StringFormat("#%d %s L%d/%d lot=%s avg=%s next=%.1f pts tp=%s pl=%s dd=%.2f",
                          m_c.id, (m_c.dir == POSITION_TYPE_BUY ? "BUY" : "SELL"),
                          m_c.layers, m_cfg.MaximumLayer,
                          DoubleToString(m_c.total_volume, m_spec.VolumeDigits()),
                          XauPrice(m_c.avg_price), m_c.distance_points, XauPrice(m_c.basket_tp),
                          XauMoney(m_c.floating_pl), m_c.max_dd_money));
     }
  };

#endif // XAU_AVG_PRO_CYCLE_MQH
//+------------------------------------------------------------------+
