//+------------------------------------------------------------------+
//|                                                        Entry.mqh |
//|   XAU_AVG_PRO v1.0.0 - EMA crossover entry engine (replaceable) |
//|                                                                  |
//|  Determinism rules:                                              |
//|   - the signal is a STATE TRANSITION of (Fast>Slow), not a      |
//|     per-tick condition, so a cross cannot fire twice           |
//|   - in CLOSE_BAR mode the transition is evaluated once per new  |
//|     bar on the last CLOSED bar (index 1 vs index 2)             |
//|   - no signal is emitted on the first evaluated bar after attach |
//|     (no history of the previous state)                          |
//|   - a signal lives exactly one bar: if it cannot be executed it  |
//|     expires instead of queueing                                 |
//|   - after a cycle closes, RequireNewSignalAfterCycleClose forces |
//|     a brand new transition                                      |
//|                                                                  |
//|  The engine exposes only Signal()/Consume()/Reset(), which makes |
//|  it replaceable by any other entry model without touching the   |
//|  averaging or risk code.                                         |
//+------------------------------------------------------------------+
#ifndef XAU_AVG_PRO_ENTRY_MQH
#define XAU_AVG_PRO_ENTRY_MQH

#include "Types.mqh"
#include "BrokerSpec.mqh"
#include "Logger.mqh"

class CEntryEngine
  {
private:
   CConfig     *m_cfg;
   CSymbolSpec *m_spec;
   CLogger     *m_log;

   int         m_handle_fast;
   int         m_handle_slow;
   bool        m_ready;
   bool        m_prev_above;          // last known EMA relationship
   bool        m_prev_known;
   double      m_fast_now;            // evaluated bar values
   double      m_slow_now;
   double      m_fast_prev;
   double      m_slow_prev;
   int         m_signal_dir;          // +1 buy, -1 sell, 0 none
   datetime    m_signal_bar;
   bool        m_signal_consumed;
   datetime    m_evaluated_bar;       // bar the relationship was last sampled
   string      m_reason;
   int         m_copy_errors;

   bool ReadSeries(const int handle, const int shift, double &value)
     {
      double buf[];
      ArraySetAsSeries(buf, true);
      if(CopyBuffer(handle, 0, shift, 1, buf) != 1)
        {
         m_copy_errors++;
         return(false);
        }
      value = buf[0];
      return(true);
     }
   bool ReadCandle(const int shift, MqlRates &rate)
     {
      MqlRates rates[];
      ArraySetAsSeries(rates, true);
      if(CopyRates(m_spec.Symbol(), m_cfg.EMATimeframe, 0, shift + 1, rates) < shift + 1)
        {
         m_copy_errors++;
         return(false);
        }
      rate = rates[shift];
      return(true);
     }

public:
                     CEntryEngine(void) : m_cfg(NULL), m_spec(NULL), m_log(NULL),
                                          m_handle_fast(INVALID_HANDLE), m_handle_slow(INVALID_HANDLE),
                                          m_ready(false), m_prev_above(false), m_prev_known(false),
                                          m_fast_now(0.0), m_slow_now(0.0), m_fast_prev(0.0), m_slow_prev(0.0),
                                          m_signal_dir(0), m_signal_bar(0), m_signal_consumed(false),
                                          m_evaluated_bar(0), m_reason("no signal yet"), m_copy_errors(0)
     {
     }

   bool Init(CConfig *cfg, CSymbolSpec *spec, CLogger *log)
     {
      m_cfg  = cfg;
      m_spec = spec;
      m_log  = log;
      // iMA(symbol, timeframe, ma_period, ma_shift, ma_method, applied_price) - both lines
      // are built on the same timeframe, method and price source, because a cross created
      // from two different timeframes or price sources is not a crossover signal.
      m_handle_fast = iMA(m_spec.Symbol(), m_cfg.EMATimeframe, m_cfg.FastEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
      m_handle_slow = iMA(m_spec.Symbol(), m_cfg.EMATimeframe, m_cfg.SlowEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
      if(m_handle_fast == INVALID_HANDLE || m_handle_slow == INVALID_HANDLE)
        {
         m_log.Error(XAU_T_ENTRY, StringFormat("indicator handle creation failed (fast=%d slow=%d) err=%d",
                                               m_handle_fast, m_handle_slow, GetLastError()));
         m_ready = false;
         return(false);
        }
      if(m_cfg.FastEMAPeriod >= m_cfg.SlowEMAPeriod)
         m_log.Warn(XAU_T_ENTRY, StringFormat("FastEMAPeriod(%d) >= SlowEMAPeriod(%d): the fast line is normally the shorter one, signals will be inverted/less frequent",
                                              m_cfg.FastEMAPeriod, m_cfg.SlowEMAPeriod));
      if(m_cfg.EntryConfirmation == XAU_CONFIRM_CURRENT_BAR)
         m_log.Warn(XAU_T_ENTRY, "current-bar confirmation repaints: a signal can disappear before the bar closes - close-bar mode is recommended");
      m_ready = true;
      return(true);
     }

   void Deinit(void)
     {
      if(m_handle_fast != INVALID_HANDLE)
        {
         IndicatorRelease(m_handle_fast);
         m_handle_fast = INVALID_HANDLE;
        }
      if(m_handle_slow != INVALID_HANDLE)
        {
         IndicatorRelease(m_handle_slow);
         m_handle_slow = INVALID_HANDLE;
        }
      m_ready = false;
     }

   /// Sample the EMA relationship. Called from OnTick, but the expensive
   /// part (CopyBuffer/CopyRates) runs only when the evaluation bar is new.
   /// @param bar_time open time of the current chart bar
   /// @param new_bar  true on the first tick of that bar
   void Update(const datetime bar_time, const bool new_bar)
     {
      if(!m_ready || !m_cfg.EnableEMAEntry)
         return;
      // signal expires when its bar is over
      if(m_signal_dir != 0 && m_signal_bar != 0 && m_signal_bar != bar_time &&
         m_cfg.EntryConfirmation == XAU_CONFIRM_CLOSE_BAR)
        {
         m_log.Debug(XAU_T_ENTRY, StringFormat("signal expired unused | bar=%s", TimeToString(m_signal_bar)));
         m_signal_dir  = 0;
         m_signal_bar  = 0;
         m_signal_consumed = false;
        }

      bool do_close_bar = (m_cfg.EntryConfirmation == XAU_CONFIRM_CLOSE_BAR && new_bar);
      bool do_current   = (m_cfg.EntryConfirmation == XAU_CONFIRM_CURRENT_BAR);
      if(!do_close_bar && !do_current)
         return;
      if(!do_current && m_evaluated_bar == bar_time)
         return;                                     // already sampled this bar

      int closed = (m_cfg.EntryConfirmation == XAU_CONFIRM_CLOSE_BAR ? 1 : 0);
      double f_now, s_now, f_prev, s_prev;
      if(!ReadSeries(m_handle_fast, closed, f_now) || !ReadSeries(m_handle_slow, closed, s_now) ||
         !ReadSeries(m_handle_fast, closed + 1, f_prev) || !ReadSeries(m_handle_slow, closed + 1, s_prev))
        {
         m_reason = "waiting for indicator data";
         return;
        }
      m_fast_now  = f_now;
      m_slow_now  = s_now;
      m_fast_prev = f_prev;
      m_slow_prev = s_prev;
      m_evaluated_bar = bar_time;

      bool above = (f_now > s_now);
      if(!m_prev_known)
        {
         m_prev_known = true;
         m_prev_above = above;
         m_reason     = "baseline set, waiting for a new cross";
         return;
        }
      if(above == m_prev_above)
        {
         m_prev_above = above;
         m_reason     = "no cross";
         return;
        }
      m_prev_above = above;

      int dir = (above ? 1 : -1);
      string dir_name = (dir > 0 ? "BUY" : "SELL");

      //--- direction switch -----------------------------------------
      if(m_cfg.TradingDirection == XAU_DIR_BUY_ONLY && dir < 0)
        {
         m_reason = "cross is SELL but direction is BUY_ONLY";
         return;
        }
      if(m_cfg.TradingDirection == XAU_DIR_SELL_ONLY && dir > 0)
        {
         m_reason = "cross is BUY but direction is SELL_ONLY";
         return;
        }
      if(dir > 0 && !m_cfg.BuyEnabled)
        {
         m_reason = "BUY disabled by input";
         return;
        }
      if(dir < 0 && !m_cfg.SellEnabled)
        {
         m_reason = "SELL disabled by input";
         return;
        }

      //--- optional candle quality filter -----------------------------
      MqlRates rate;
      bool candle_ok = true;
      string candle_why = "";
      if(m_cfg.EntryCandleFilter != XAU_CANDLE_NONE || m_cfg.MinimumBarRangePoints > 0)
        {
         if(!ReadCandle(closed, rate))
           {
            m_reason = "waiting for candle data";
            return;
           }
         double range = rate.high - rate.low;
         if(m_cfg.MinimumBarRangePoints > 0 &&
            m_spec.Point() > 0.0 &&
            range / m_spec.Point() < (double)m_cfg.MinimumBarRangePoints)
           {
            candle_ok = false;
            candle_why = StringFormat("bar range %.1f pts < required %d",
                                      (m_spec.Point() > 0.0 ? range / m_spec.Point() : 0.0),
                                      m_cfg.MinimumBarRangePoints);
           }
         if(candle_ok && m_cfg.EntryCandleFilter == XAU_CANDLE_BODY_DIR)
           {
            bool body_ok = (dir > 0 ? rate.close > rate.open : rate.close < rate.open);
            if(!body_ok)
              {
               candle_ok  = false;
               candle_why = "candle body disagrees with signal direction";
              }
           }
         if(candle_ok && m_cfg.EntryCandleFilter == XAU_CANDLE_CLOSE_STRONG)
           {
            if(range <= 0.0)
              {
               candle_ok  = false;
               candle_why = "zero range bar";
              }
            else
              {
               double pos = (dir > 0 ? (rate.close - rate.low) / range : (rate.high - rate.close) / range);
               if(pos < 0.6666)
                 {
                  candle_ok  = false;
                  candle_why = StringFormat("close position %.2f < 0.67 of bar range", pos);
                 }
              }
           }
        }
      if(!candle_ok)
        {
         m_reason = candle_why;
         m_log.Throttled(2, XAU_T_ENTRY, "candle:" + candle_why,
                         "EMA cross " + dir_name + " rejected by candle filter | " + candle_why, 300);
         return;
        }

      m_signal_dir      = dir;
      m_signal_bar      = bar_time;
      m_signal_consumed = false;
      m_reason          = "cross detected on bar " + TimeToString(bar_time);
      m_log.Info(XAU_T_ENTRY, StringFormat("EMA cross %s | bar=%s fast=%s slow=%s prev_fast=%s prev_slow=%s",
                                           dir_name, TimeToString(bar_time),
                                           XauPrice(f_now), XauPrice(s_now),
                                           XauPrice(f_prev), XauPrice(s_prev)));
     }

   /// +1 = buy signal, -1 = sell signal, 0 = none.
   int  Signal(void) const
     {
      if(!m_cfg.EnableEMAEntry || m_signal_consumed)
         return(0);
      return(m_signal_dir);
   }
   void Consume(void)
     {
      m_signal_consumed = true;
      m_signal_dir      = 0;
     }
   /// Called when a cycle closes (or after a restart) so that the EA
   /// waits for a brand new transition instead of re-firing the state it
   /// just saw.
   void ResetState(const bool clear_signal)
     {
      m_prev_known = false;
      m_prev_above = false;
      if(clear_signal)
        {
         m_signal_dir      = 0;
         m_signal_bar      = 0;
         m_signal_consumed = false;
        }
     }
   double FastValue(void) const { return(m_fast_now); }
   double SlowValue(void) const { return(m_slow_now); }
   int    CopyErrors(void) const { return(m_copy_errors); }
   bool   Ready(void)     const { return(m_ready); }
   string Reason(void)    const { return(m_reason); }
   datetime SignalBar(void) const { return(m_signal_bar); }
   string Describe(void) const
     {
      return(StringFormat("EMA%d/%d on %s, %s | fast=%s slow=%s",
                          m_cfg.FastEMAPeriod, m_cfg.SlowEMAPeriod,
                          EnumToString(m_cfg.EMATimeframe),
                          (m_cfg.EntryConfirmation == XAU_CONFIRM_CLOSE_BAR ? "closed bar" : "current bar"),
                          DoubleToString(m_fast_now, m_spec.Digits()),
                          DoubleToString(m_slow_now, m_spec.Digits())));
     }
  };

#endif // XAU_AVG_PRO_ENTRY_MQH
//+------------------------------------------------------------------+
