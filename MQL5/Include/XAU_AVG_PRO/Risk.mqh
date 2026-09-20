//+------------------------------------------------------------------+
//|                                                        Risk.mqh  |
//|  XAU_AVG_PRO v1.0.0 - the arbiter: every trading decision      |
//|                     passes through this module                   |
//|                                                                  |
//|  Fixed evaluation order (the FIRST failing check is reported,   |
//|  every check must pass). This order is the risk priority of     |
//|  the whole system:                                              |
//|    1. operator/state gates      (emergency, pause, error)       |
//|    2. hard capital limits       (account DD, daily loss,        |
//|                                 floating loss, cycle DD)        |
//|    3. structural caps           (max layer, max lot/order,      |
//|                                 max total exposure)             |
//|    4. margin safety             (projected level & free margin) |
//|    5. market filters            (spread, volatility, gap,       |
//|                                 session, weekend, open market)  |
//|    6. news filter                                                 |
//|  A filter can never increase exposure, therefore keeping the    |
//|  hard limits in front of the filters costs nothing and means a  |
//|  limit is never bypassed by a filter being switched off.        |
//+------------------------------------------------------------------+
#ifndef XAU_AVG_PRO_RISK_MQH
#define XAU_AVG_PRO_RISK_MQH

#include "Types.mqh"
#include "BrokerSpec.mqh"
#include "Logger.mqh"
#include "Cycle.mqh"
#include "Basket.mqh"
#include "MarketFilters.mqh"
#include "News.mqh"
#include "State.mqh"
#include "Lots.mqh"
#include "Averaging.mqh"

class CRiskManager
  {
private:
   CConfig       *m_cfg;
   CSymbolSpec   *m_spec;
   CLogger       *m_log;
   CCycleManager *m_cycle;
   CBasketManager*m_basket;
   CMarketFilters*m_filters;
   CNewsFilter   *m_news;
   CStateMachine *m_state;
   CLotManager   *m_lots;
   CAveragingEngine *m_avg;

   double   m_balance;
   double   m_equity;
   double   m_peak_equity;
   double   m_day_start_balance;
   double   m_day_realized;
   double   m_daily_pl_effective;
   double   m_daily_loss;
   double   m_account_dd_pct;
   double   m_cycle_dd_pct;
   double   m_float_loss;
   int      m_today_entries;
   datetime m_last_evaluated;
   int      m_hard_limit_hits;
   int      m_blocks_entry;
   int      m_blocks_avg;
   bool     m_account_dd_hit;
   bool     m_daily_hit;
   bool     m_float_hit;
   bool     m_cycle_dd_hit;
   string   m_last_action_text;

   ENUM_XAU_ACTION Strongest(const ENUM_XAU_ACTION a, const ENUM_XAU_ACTION b)
     {
      return((int)a >= (int)b ? a : b);
     }
   double EffectiveDailyLoss(void)
     {
      double floating = (m_cycle.IsActive() ? m_basket.NetPL() : 0.0);
      m_daily_pl_effective = m_day_realized +
                             (m_cfg.DailyLossBasis == XAU_DAILY_REALIZED_PLUS_EA ? floating : 0.0);
      return(m_daily_pl_effective < 0.0 ? -m_daily_pl_effective : 0.0);
     }
   void Act(const ENUM_XAU_ACTION action, const ENUM_XAU_BLOCK code, const string why,
            const datetime until, SActionReq &act)
     {
      m_state.SetRiskBlock(code, why, until);
      m_hard_limit_hits++;
      switch(action)
        {
         case XAU_ACT_CLOSE_BASKET:
            act.need_close_basket = true;
            act.exit_code         = 3;
            break;
         case XAU_ACT_CLOSE_ALL:
            act.need_close_all = true;
            act.exit_code      = 3;
            break;
         case XAU_ACT_EMERGENCY:
            act.need_close_all  = true;
            act.need_emergency   = true;
            act.exit_code        = 3;
            break;
         default:
            break;
        }
      if(StringLen(act.reason) == 0)
         act.reason = why;
      m_log.Throttled(1, XAU_T_MAXDD, m_state.BlockName(code),
                      StringFormat("%s | action=%s | %s", m_state.BlockName(code), EnumToString(action), why), 60);
     }

public:
                     CRiskManager(void) : m_cfg(NULL), m_spec(NULL), m_log(NULL), m_cycle(NULL), m_basket(NULL),
                                          m_filters(NULL), m_news(NULL), m_state(NULL), m_lots(NULL), m_avg(NULL),
                                          m_balance(0.0), m_equity(0.0), m_peak_equity(0.0), m_day_start_balance(0.0),
                                          m_day_realized(0.0), m_daily_pl_effective(0.0), m_daily_loss(0.0),
                                          m_account_dd_pct(0.0), m_cycle_dd_pct(0.0), m_float_loss(0.0),
                                          m_today_entries(0), m_last_evaluated(0), m_hard_limit_hits(0),
                                          m_blocks_entry(0), m_blocks_avg(0), m_account_dd_hit(false),
                                          m_daily_hit(false), m_float_hit(false), m_cycle_dd_hit(false),
                                          m_last_action_text("")
     {
     }

   void Init(CConfig *cfg, CSymbolSpec *spec, CLogger *log, CCycleManager *cycle, CBasketManager *basket,
             CMarketFilters *filters, CNewsFilter *news, CStateMachine *state, CLotManager *lots,
             CAveragingEngine *avg)
     {
      m_cfg     = cfg;
      m_spec    = spec;
      m_log     = log;
      m_cycle   = cycle;
      m_basket  = basket;
      m_filters = filters;
      m_news    = news;
      m_state   = state;
      m_lots    = lots;
      m_avg     = avg;
     }

   //--- inputs from the engine ---------------------------------------
   void SetDaySnapshot(const double day_start_balance, const double realized_pl)
     {
      m_day_start_balance = day_start_balance;
      m_day_realized      = realized_pl;
     }
   void SetTodayEntries(const int n) { m_today_entries = n; }
   void SetPeakEquity(const double peak) { m_peak_equity = peak; }

   double PeakEquity(void)     const { return(m_peak_equity); }
   double AccountDDPercent(void) const { return(m_account_dd_pct); }
   double CycleDDPercent(void)   const { return(m_cycle_dd_pct); }
   double DailyLoss(void)        const { return(m_daily_loss); }
   double DailyRealized(void)    const { return(m_day_realized); }
   double DailyEffectivePL(void) const { return(m_daily_pl_effective); }
   int    HardLimitHits(void)    const { return(m_hard_limit_hits); }
   int    BlockedEntries(void)   const { return(m_blocks_entry); }
   int    BlockedAveraging(void) const { return(m_blocks_avg); }
   string LastActionText(void)   const { return(m_last_action_text); }

   /// Measure the limits and, when one is exceeded, request the
   /// configured action. Runs on every pipeline pass - it is pure data
   /// arithmetic, no OrderSend here.
   void EvaluateLimits(SActionReq &act)
     {
      m_last_evaluated = XauNow();
      m_balance = AccountInfoDouble(ACCOUNT_BALANCE);
      m_equity  = AccountInfoDouble(ACCOUNT_EQUITY);
      if(m_peak_equity <= 0.0 || m_equity > m_peak_equity)
         m_peak_equity = m_equity;
      if(m_day_start_balance <= 0.0)
         m_day_start_balance = m_balance;

      double ref = (m_cfg.DrawdownReference == XAU_DD_PEAK_EQUITY ? m_peak_equity : m_day_start_balance);
      if(ref <= 0.0)
         ref = m_balance;
      m_account_dd_pct = (ref > 0.0 ? (ref - m_equity) / ref * 100.0 : 0.0);
      if(m_account_dd_pct < 0.0)
         m_account_dd_pct = 0.0;

      m_float_loss = (m_cycle.IsActive() ? -m_basket.NetPL() : 0.0);
      double cyc_ref = m_cycle.BalanceAtStart();
      if(cyc_ref <= 0.0)
         cyc_ref = m_balance;
      m_cycle_dd_pct = (m_cycle.IsActive() && cyc_ref > 0.0 ? (-m_basket.NetPL()) / cyc_ref * 100.0 : 0.0);
      m_daily_loss   = EffectiveDailyLoss();

      // keep the worst cycle drawdown in the cycle record (reports)
      m_cycle.UpdateDrawdown(m_balance);

      m_account_dd_hit = (m_cfg.MaximumAccountDrawdownPercent > 0.0 &&
                          m_account_dd_pct >= m_cfg.MaximumAccountDrawdownPercent);
      m_daily_hit      = ((m_cfg.MaximumDailyLossMoney > 0.0 && m_daily_loss >= m_cfg.MaximumDailyLossMoney) ||
                          (m_cfg.MaximumDailyLossPercent > 0.0 && m_day_start_balance > 0.0 &&
                           m_daily_loss >= m_day_start_balance * m_cfg.MaximumDailyLossPercent / 100.0));
      m_float_hit      = (m_cfg.MaximumFloatingLossMoney > 0.0 && m_cycle.IsActive() &&
                          m_float_loss >= m_cfg.MaximumFloatingLossMoney);
      m_cycle_dd_hit   = (m_cfg.MaximumCycleDrawdownPercent > 0.0 && m_cycle.IsActive() &&
                          m_cycle_dd_pct >= m_cfg.MaximumCycleDrawdownPercent);

      if(!m_account_dd_hit && !m_daily_hit && !m_float_hit && !m_cycle_dd_hit)
         return;

      //--- most severe wins, and the reason of the first hit is kept ---
      ENUM_XAU_ACTION action = XAU_ACT_BLOCK_ONLY;
      ENUM_XAU_BLOCK  code   = XAU_BLK_NONE;
      string          why    = "";
      datetime        until  = 0;
      if(m_account_dd_hit)
        {
         action = m_cfg.ActionOnAccountDD;
         code   = XAU_BLK_ACCOUNT_DD;
         why    = StringFormat("account drawdown %.2f%% >= %.2f%% (equity %s, reference %s, mode=%s)",
                               m_account_dd_pct, m_cfg.MaximumAccountDrawdownPercent,
                               XauMoney(m_equity), XauMoney(ref), EnumToString(m_cfg.DrawdownReference));
        }
      if(m_daily_hit && code == XAU_BLK_NONE)
        {
         action = m_cfg.ActionOnDailyLoss;
         code   = XAU_BLK_DAILY_LOSS;
         why    = StringFormat("daily loss %s >= limit (money %s, percent %s of day start balance %s; realized %s, basis %s)",
                               XauMoney(-m_daily_loss), XauMoney(-m_cfg.MaximumDailyLossMoney),
                               DoubleToString(m_cfg.MaximumDailyLossPercent, 2) + "%",
                               XauMoney(m_day_start_balance), XauMoney(m_day_realized),
                               EnumToString(m_cfg.DailyLossBasis));
         until  = XauServerDayStart(XauNow()) + 86400;    // released on the next server day
        }
      if(m_float_hit && code == XAU_BLK_NONE)
        {
         action = m_cfg.ActionOnFloatingLoss;
         code   = XAU_BLK_FLOATING_LOSS;
         why    = StringFormat("floating basket loss %s >= MaximumFloatingLossMoney %s",
                               XauMoney(-m_float_loss), XauMoney(-m_cfg.MaximumFloatingLossMoney));
        }
      if(m_cycle_dd_hit && code == XAU_BLK_NONE)
        {
         action = Strongest(action, m_cfg.ActionOnCycleDD);
         code   = XAU_BLK_CYCLE_DD;
         why    = StringFormat("cycle drawdown %.2f%% >= %.2f%% of cycle start balance (cycle #%d)",
                               m_cycle_dd_pct, m_cfg.MaximumCycleDrawdownPercent, m_cycle.CycleId());
        }
      // emergency stop requests are never downgraded by another limit
      if(m_cfg.ActionOnAccountDD == XAU_ACT_EMERGENCY && m_account_dd_hit)
        {
         action = Strongest(action, XAU_ACT_EMERGENCY);
         if(code == XAU_BLK_NONE)
            code = XAU_BLK_ACCOUNT_DD;
        }
      m_last_action_text = why;
      Act(action, code, why, until, act);
     }

   /// Release auto risk blocks once the condition has cleared with the
   /// configured hysteresis, or once the day has rolled over.
   void ResetCheck(SRt &rt)
     {
      if(!m_state.RiskBlocked())
         return;
      if(m_state.Emergency())                 // emergency is manual only
         return;
      datetime now = XauNow();
      datetime until = m_state.RiskUntil();
      if(until > 0 && now < until)
         return;
      // A daily-loss block carries block_until = next server midnight, so
      // reaching this point means the day has rolled over.
      if(m_state.RiskCode() == XAU_BLK_DAILY_LOSS)
        {
         if(!m_cfg.AutoResetRiskBlock)
            return;
         m_daily_hit = false;
         m_state.ClearRiskBlock("new server day, daily limits re-armed");
         return;
        }
      if(!m_cfg.AutoResetRiskBlock)
         return;
      double hyst = XauClamp(m_cfg.RiskBlockResetHysteresisPercent, 10.0, 100.0) / 100.0;
      bool clear = true;
      if(m_account_dd_hit && m_cfg.MaximumAccountDrawdownPercent > 0.0 &&
         m_account_dd_pct > m_cfg.MaximumAccountDrawdownPercent * hyst)
         clear = false;
      if(m_cycle_dd_hit && m_cfg.MaximumCycleDrawdownPercent > 0.0 &&
         m_cycle_dd_pct > m_cfg.MaximumCycleDrawdownPercent * hyst)
         clear = false;
      if(m_float_hit && m_cfg.MaximumFloatingLossMoney > 0.0 &&
         m_float_loss > m_cfg.MaximumFloatingLossMoney * hyst)
         clear = false;
      if(clear)
        {
         m_state.ClearRiskBlock("conditions back inside hysteresis band");
         m_account_dd_hit = false;
         m_daily_hit      = false;
         m_float_hit      = false;
         m_cycle_dd_hit   = false;
        }
      if(rt.next_entry_allowed_at > 0 && now >= rt.next_entry_allowed_at)
         rt.next_entry_allowed_at = 0;
     }

   /// Gate 1: shared gates for both intents.
   void CommonGates(const ENUM_XAU_INTENT intent, SVerdict &v)
     {
      XauPassV(v);
      if(m_state.Emergency())
        {
         XauFailV(v, XAU_BLK_EMERGENCY, "EMERGENCY STOP is active - reset it explicitly (Telegram /emergency_clear or input)", 0, 0.0);
         return;
        }
      if(m_state.ErrorFlag())
        {
         XauFailV(v, XAU_BLK_STATE_ERROR, "EA state ERROR: " + m_state.ErrorText(), 0, 0.0);
         return;
        }
      if(m_state.Paused())
        {
         XauFailV(v, XAU_BLK_PAUSED, "EA is paused by the operator", 0, 0.0);
         return;
        }
      if(m_state.RiskBlocked())
        {
         XauFailV(v, m_state.RiskCode(), "risk block active: " + m_state.RiskReason(),
                  m_state.RiskUntil(), 0.0);
         return;
        }
      if(!m_spec.Valid())
        {
         XauFailV(v, XAU_BLK_SPEC_INVALID, "symbol specification invalid: " + m_spec.ErrorText(), 0, 0.0);
         return;
        }
      if(!m_spec.QuoteOk() || m_spec.QuoteAgeSeconds() > (double)MathMax(1, m_cfg.MaxQuoteAgeSeconds))
        {
         XauFailV(v, XAU_BLK_SPEC_INVALID,
                  StringFormat("quote is stale (%.0f s old, limit %d s)",
                               m_spec.QuoteAgeSeconds(), m_cfg.MaxQuoteAgeSeconds), 0, 0.0);
         return;
        }
      if(m_cfg.BlockTradingIfNotConnected && !TerminalInfoInteger(TERMINAL_CONNECTED))
        {
         XauFailV(v, XAU_BLK_NOT_CONNECTED, "terminal has no connection to the trade server", 0, 0.0);
         return;
        }
      string why = "";
      if(!m_spec.AllowSymbolTrading(intent != XAU_INT_CLOSE, why))
        {
         XauFailV(v, XAU_BLK_EA_DISABLED, "trading not allowed: " + why, 0, 0.0);
         return;
        }
     }

   /// Full entry decision. `lot` is returned so the caller does not
   /// recompute it (and cannot use a stale value).
   void CheckEntry(const bool is_buy, const double price, double &lot, SRt &rt, SVerdict &v)
     {
      CommonGates(XAU_INT_ENTRY, v);
      if(!v.allowed)
        {
         m_blocks_entry++;
         return;
        }
      if(!m_cfg.AllowNewCycles)
        {
         XauFailV(v, XAU_BLK_NEWCYCLES_OFF, "AllowNewCycles=false (Telegram /stop keeps the basket, blocks new cycles)", 0, 0.0);
         m_blocks_entry++;
         return;
        }
      if(m_cycle.IsActive())
        {
         XauFailV(v, XAU_BLK_BASKET_OPEN, StringFormat("cycle #%d is still open - one basket per magic+symbol", m_cycle.CycleId()), 0, 0.0);
         m_blocks_entry++;
         return;
        }
      if(m_cycle.HasConflict())
        {
         XauFailV(v, XAU_BLK_STATE_ERROR, m_cycle.ConflictText(), 0, 0.0);
         m_blocks_entry++;
         return;
        }
      if(!m_cfg.BuyEnabled && is_buy)
        {
         XauFailV(v, XAU_BLK_DIRECTION, "BuyEnabled=false", 0, 0.0);
         m_blocks_entry++;
         return;
        }
      if(!m_cfg.SellEnabled && !is_buy)
        {
         XauFailV(v, XAU_BLK_DIRECTION, "SellEnabled=false", 0, 0.0);
         m_blocks_entry++;
         return;
        }
      if(m_cfg.TradingDirection == XAU_DIR_BUY_ONLY && !is_buy)
        {
         XauFailV(v, XAU_BLK_DIRECTION, "TradingDirection=BUY_ONLY", 0, 0.0);
         m_blocks_entry++;
         return;
        }
      if(m_cfg.TradingDirection == XAU_DIR_SELL_ONLY && is_buy)
        {
         XauFailV(v, XAU_BLK_DIRECTION, "TradingDirection=SELL_ONLY", 0, 0.0);
         m_blocks_entry++;
         return;
        }
      // cooldown after the last basket close
      if(rt.next_entry_allowed_at > 0 && XauNow() < rt.next_entry_allowed_at)
        {
         XauFailV(v, XAU_BLK_COOLDOWN,
                  StringFormat("cooldown after %s: %d s left", m_state.BlockName(XAU_BLK_COOLDOWN),
                               (int)(rt.next_entry_allowed_at - XauNow())), rt.next_entry_allowed_at, 0.0);
         m_blocks_entry++;
         return;
        }
      if(m_cfg.MaximumEntriesPerDay > 0 && m_today_entries >= m_cfg.MaximumEntriesPerDay)
        {
         XauFailV(v, XAU_BLK_DAILY_ENTRIES,
                  StringFormat("MaximumEntriesPerDay %d reached today", m_cfg.MaximumEntriesPerDay), 0, (double)m_today_entries);
         m_blocks_entry++;
         return;
        }
      // hard capital limits are re-evaluated here so a stale block list
      // cannot let an entry through
      if(m_account_dd_hit || m_daily_hit || m_float_hit || m_cycle_dd_hit)
        {
         XauFailV(v, (m_account_dd_hit ? XAU_BLK_ACCOUNT_DD :
                     (m_daily_hit ? XAU_BLK_DAILY_LOSS :
                      (m_float_hit ? XAU_BLK_FLOATING_LOSS : XAU_BLK_CYCLE_DD))),
                  "hard limit active: " + m_last_action_text, 0, 0.0);
         m_blocks_entry++;
         return;
        }

      // sizing (max lot per order + max total exposure are enforced here)
      SVerdict lv;
      m_lots.Resolve(1, is_buy, price, m_cycle.TotalExposure(), lot, lv);
      if(!lv.allowed)
        {
         XauFailV(v, lv.code, lv.reason, 0, lv.value);
         m_blocks_entry++;
         return;
        }
      // margin safety on the projected position
      SVerdict mv;
      m_lots.CheckMargin(is_buy, lot, price, mv);
      if(!mv.allowed)
        {
         XauFailV(v, mv.code, mv.reason, 0, mv.value);
         m_blocks_entry++;
         return;
        }
      // market filters, then news
      SVerdict fv;
      m_filters.Check(XAU_INT_ENTRY, rt, fv);
      if(!fv.allowed)
        {
         XauFailV(v, fv.code, fv.reason, fv.block_until, fv.value);
         m_blocks_entry++;
         return;
        }
      SVerdict nv;
      m_news.Check(XAU_INT_ENTRY, nv);
      if(!nv.allowed)
        {
         XauFailV(v, nv.code, nv.reason, nv.block_until, nv.value);
         m_blocks_entry++;
         return;
        }
      v.reason = StringFormat("entry allowed: lot %.2f at %s | %s", lot, XauPrice(price), lv.reason);
     }

   /// Full averaging decision for one candidate layer.
   void CheckAveraging(const SAvgPlan &plan, double &lot, SRt &rt, const datetime bar_time, SVerdict &v)
     {
      CommonGates(XAU_INT_AVERAGING, v);
      if(!v.allowed)
        {
         m_blocks_avg++;
         return;
        }
      if(!m_cfg.EnableAveraging)
        {
         XauFailV(v, XAU_BLK_EA_DISABLED, "EnableAveraging=false", 0, 0.0);
         m_blocks_avg++;
         return;
        }
      if(!m_cycle.IsActive())
        {
         XauFailV(v, XAU_BLK_STATE_ERROR, "no basket to average into", 0, 0.0);
         m_blocks_avg++;
         return;
        }
      if(m_cycle.IsUncertain())
        {
         XauFailV(v, XAU_BLK_NETTING_UNCERTAIN, m_cycle.UncertainText(), 0, 0.0);
         m_blocks_avg++;
         return;
        }
      // MAX LAYER overrides the averaging signal, always
      if(m_cycle.LayerCount() >= m_cfg.MaximumLayer)
        {
         XauFailV(v, XAU_BLK_MAX_LAYER,
                  StringFormat("MaximumLayer %d reached (layer %d) - no further averaging",
                               m_cfg.MaximumLayer, m_cycle.LayerCount()), 0, (double)m_cycle.LayerCount());
         m_blocks_avg++;
         m_log.Throttled(2, XAU_T_MAXLAYER, "hit", v.reason, 60);
         return;
        }
      // hard capital limits override the averaging signal as well
      if(m_account_dd_hit || m_daily_hit || m_float_hit || m_cycle_dd_hit)
        {
         XauFailV(v, (m_account_dd_hit ? XAU_BLK_ACCOUNT_DD :
                     (m_daily_hit ? XAU_BLK_DAILY_LOSS :
                      (m_float_hit ? XAU_BLK_FLOATING_LOSS : XAU_BLK_CYCLE_DD))),
                  "hard limit active: " + m_last_action_text, 0, 0.0);
         m_blocks_avg++;
         return;
        }
      // timing / duplicate protection of the geometry
      SVerdict tv;
      m_avg.CheckTiming(plan, rt, bar_time, tv);
      if(!tv.allowed)
        {
         XauFailV(v, tv.code, tv.reason, tv.block_until, tv.value);
         m_blocks_avg++;
         return;
        }
      if(!plan.reached)
        {
         XauFailV(v, XAU_BLK_LEVEL_NOT_REACHED, plan.why, 0, 0.0);
         m_blocks_avg++;
         return;
        }
      // sizing: MAX LOT PER ORDER and MAX TOTAL EXPOSURE
      SVerdict lv;
      m_lots.Resolve(m_cycle.LayerCount() + 1, m_cycle.IsBuyBasket(), (m_cycle.IsBuyBasket() ? m_spec.Ask() : m_spec.Bid()),
                      m_cycle.TotalExposure(), lot, lv);
      if(!lv.allowed)
        {
         XauFailV(v, lv.code, lv.reason, 0, lv.value);
         m_blocks_avg++;
         return;
        }
      SVerdict mv;
      m_lots.CheckMargin(m_cycle.IsBuyBasket(), lot, (m_cycle.IsBuyBasket() ? m_spec.Ask() : m_spec.Bid()), mv);
      if(!mv.allowed)
        {
         XauFailV(v, mv.code, mv.reason, 0, mv.value);
         m_blocks_avg++;
         return;
        }
      SVerdict fv;
      m_filters.Check(XAU_INT_AVERAGING, rt, fv);
      if(!fv.allowed)
        {
         XauFailV(v, fv.code, fv.reason, fv.block_until, fv.value);
         m_blocks_avg++;
         return;
        }
      SVerdict nv;
      m_news.Check(XAU_INT_AVERAGING, nv);
      if(!nv.allowed)
        {
         XauFailV(v, nv.code, nv.reason, nv.block_until, nv.value);
         m_blocks_avg++;
         return;
        }
      v.reason = StringFormat("averaging allowed: L%d lot %.2f at level %s | %s",
                              m_cycle.LayerCount() + 1, lot, XauPrice(plan.level), lv.reason);
     }

   /// One line summary for the dashboard / Telegram "RISK" row.
   string DescribeLimits(void)
     {
      string s = StringFormat("DD acct %.2f%%/%.2f%% | cycle %.2f%%/%.2f%% | float %s/%s | daily %s/%s | margin lvl %.0f%%/%.0f%%",
                              m_account_dd_pct, m_cfg.MaximumAccountDrawdownPercent,
                              m_cycle_dd_pct, m_cfg.MaximumCycleDrawdownPercent,
                              DoubleToString(m_float_loss, 2), DoubleToString(m_cfg.MaximumFloatingLossMoney, 2),
                              DoubleToString(m_daily_loss, 2), DoubleToString(m_cfg.MaximumDailyLossMoney, 2),
                              m_spec.MarginLevel(), m_cfg.MinimumFreeMarginPercent);
      return(s);
     }

   double ExposurePercent(void) const
     {
      if(m_cfg.MaximumTotalLot <= 0.0)
         return(0.0);
      return(m_cycle.TotalExposure() / m_cfg.MaximumTotalLot * 100.0);
     }
  };

#endif // XAU_AVG_PRO_RISK_MQH
//+------------------------------------------------------------------+
