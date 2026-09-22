//+------------------------------------------------------------------+
//|                                                     Execution.mqh|
//|  XAU_AVG_PRO v1.0.0 - OrderSend with verification and safe retry |
//|                                                                  |
//|  Rules:                                                          |
//|   - OrderSend() returning true is NOT success: the retcode and  |
//|     the actual position are both checked                        |
//|   - only transient failures are retried (requote / price / no    |
//|     quotes / connection / too many requests / locked / timeout); |
//|     request-level errors (volume, stops, filling, permissions,  |
//|     margin) are never retried                                   |
//|   - a DONE retcode whose position cannot be found is reported   |
//|     as "unverified": the caller must stop trading instead of     |
//|     assuming the basket is flat                                  |
//|   - the same code path works for hedging and netting accounts    |
//+------------------------------------------------------------------+
#ifndef XAU_AVG_PRO_EXECUTION_MQH
#define XAU_AVG_PRO_EXECUTION_MQH

#include "Types.mqh"
#include "BrokerSpec.mqh"
#include "Logger.mqh"

/// Result of one execution attempt.
struct SExecResult
  {
   bool     ok;
   bool     unverified;      // accepted by server but not visible in positions
   long     ticket;          // position ticket to manage
   double   price;           // fill price reported by the server
   double   volume;          // volume actually applied
   datetime time;
   int      retcode;
   string   text;
   int      attempts;
   long     deal;
  };

class CExecution
  {
private:
   CConfig     *m_cfg;
   CSymbolSpec *m_spec;
   CLogger     *m_log;
   int      m_fill_variant;   // filling mode index after a 10030 fallback
   int      m_ok;
   int      m_failed;
   int      m_retries;
   int      m_unverified;

   /// Collect the tickets this EA currently owns on the chart symbol so
   /// a newly opened position can be recognised after the send.
   int SnapshotTickets(long &tickets[])
     {
      ArrayResize(tickets, 0);
      int total = PositionsTotal();
      for(int i = 0; i < total; i++)
        {
         long tk = (long)PositionGetTicket(i);
         if(tk <= 0)
            continue;
         if(PositionGetInteger(POSITION_MAGIC) != m_cfg.MagicNumber)
            continue;
         if(PositionGetString(POSITION_SYMBOL) != m_spec.Symbol())
            continue;
         int n = ArraySize(tickets);
         ArrayResize(tickets, n + 1);
         tickets[n] = tk;
        }
      return(ArraySize(tickets));
     }
   /// Look for this EA's position on the symbol. On hedging accounts the
   /// new layer is the ticket that was not present before; on netting
   /// accounts the single position grows instead.
   bool FindResult(const bool is_buy, const double expected_volume, const long &before[],
                   long &ticket_out, double &price_out, double &volume_out, datetime &time_out)
     {
      ticket_out = 0;
      price_out  = 0.0;
      volume_out = 0.0;
      time_out   = 0;
      double best_time = 0.0;
      int total = PositionsTotal();
      for(int i = 0; i < total; i++)
        {
         long tk = (long)PositionGetTicket(i);
         if(tk <= 0)
            continue;
         if(PositionGetInteger(POSITION_MAGIC) != m_cfg.MagicNumber)
            continue;
         if(PositionGetString(POSITION_SYMBOL) != m_spec.Symbol())
            continue;
         ENUM_POSITION_TYPE t = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         if(t != (is_buy ? POSITION_TYPE_BUY : POSITION_TYPE_SELL))
            continue;
         datetime pt = (datetime)PositionGetInteger(POSITION_TIME);
         double   pv = PositionGetDouble(POSITION_VOLUME);
         double   pp = PositionGetDouble(POSITION_PRICE_OPEN);
         if(m_spec.IsHedgingAccount())
           {
            bool is_new = true;
            for(int j = 0; j < ArraySize(before); j++)
               if(before[j] == tk)
                 {
                  is_new = false;
                  break;
                 }
            if(!is_new)
               continue;
            if((double)pt >= best_time)
              {
               best_time  = (double)pt;
               ticket_out = tk;
               price_out  = pp;
               volume_out = pv;
               time_out   = pt;
              }
           }
         else
           {
            // netting: one position, volume must have grown
            if(volume_out == 0.0 || pv >= expected_volume - 1.0e-8)
              {
               ticket_out = tk;
               price_out  = pp;
               volume_out = pv;
               time_out   = pt;
              }
           }
        }
      return(ticket_out > 0);
     }

   /// Read the authoritative fill details from the deal history.
   /// This is especially important on NETTING accounts: POSITION_VOLUME is
   /// the merged basket volume, not the volume of the individual fill/layer.
   bool DealFillDetails(const long deal, const bool is_buy,
                        double &price_out, double &volume_out, datetime &time_out)
     {
      price_out  = 0.0;
      volume_out = 0.0;
      time_out   = 0;
      if(deal <= 0 || !HistoryDealSelect((ulong)deal))
         return(false);
      if(HistoryDealGetString((ulong)deal, DEAL_SYMBOL) != m_spec.Symbol())
         return(false);
      if((long)HistoryDealGetInteger((ulong)deal, DEAL_MAGIC) != m_cfg.MagicNumber)
         return(false);
      ENUM_DEAL_TYPE dt = (ENUM_DEAL_TYPE)HistoryDealGetInteger((ulong)deal, DEAL_TYPE);
      if(dt != (is_buy ? DEAL_TYPE_BUY : DEAL_TYPE_SELL))
         return(false);
      price_out  = HistoryDealGetDouble((ulong)deal, DEAL_PRICE);
      volume_out = HistoryDealGetDouble((ulong)deal, DEAL_VOLUME);
      time_out   = (datetime)HistoryDealGetInteger((ulong)deal, DEAL_TIME);
      return(price_out > 0.0 && volume_out > 0.0);
     }

   void SleepMs(const int ms)
     {
      // Sleep() is ignored inside the Strategy Tester, which is exactly
      // what we want: no artificial delays during a backtest.
      if(ms > 0 && !MQLInfoInteger(MQL_TESTER))
         Sleep(ms);
     }

public:
                     CExecution(void) : m_cfg(NULL), m_spec(NULL), m_log(NULL),
                                        m_fill_variant(0),
                                        m_ok(0), m_failed(0), m_retries(0), m_unverified(0)
     {
     }

   void Init(CConfig *cfg, CSymbolSpec *spec, CLogger *log)
     {
      m_cfg  = cfg;
      m_spec = spec;
      m_log  = log;
     }

   int  OkCount(void)      const { return(m_ok); }
   int  FailedCount(void)  const { return(m_failed); }
   int  RetryCount(void)   const { return(m_retries); }
   int  UnverifiedCount(void) const { return(m_unverified); }
   void ResetCounters(void) { m_ok = 0; m_failed = 0; m_retries = 0; m_unverified = 0; }

   /// Open a market position (initial entry or averaging layer).
   void Open(const bool is_buy, const double volume, const string comment, SExecResult &r)
     {
      r.ok = false; r.unverified = false; r.ticket = 0; r.price = 0.0;
      r.volume = 0.0; r.time = 0; r.retcode = 0; r.text = ""; r.attempts = 0; r.deal = 0;

      long before[];
      SnapshotTickets(before);

      int attempts_max = (int)XauClampI(m_cfg.MaxOrderRetries, 1, 10);
      int retcode      = 0;
      string last_text = "";
      for(int attempt = 0; attempt < attempts_max; attempt++)
        {
         r.attempts = attempt + 1;
         if(attempt > 0)
           {
            m_retries++;
            SleepMs(m_cfg.RetryDelayMs);
           }
         // a fresh quote for every attempt: never send a stale price
         if(!m_spec.UpdateQuote() || !m_spec.QuoteOk())
           {
            last_text = "no live quote";
            retcode   = 0;
            continue;
           }
         double price = (is_buy ? m_spec.Ask() : m_spec.Bid());

         MqlTradeRequest req;
         MqlTradeResult  res;
         ZeroMemory(req);
         ZeroMemory(res);
         req.action       = TRADE_ACTION_DEAL;
         req.symbol       = m_spec.Symbol();
         req.volume       = volume;
         req.type         = (is_buy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
         req.price        = m_spec.NormalizePrice(price);
         req.deviation    = (ulong)XauClampI(m_cfg.MaximumDeviationPoints, 0, 100000);
         req.magic        = (ulong)m_cfg.MagicNumber;
         req.comment      = comment;
         req.type_time    = ORDER_TIME_GTC;
         req.type_filling = m_spec.FillingByIndex(m_fill_variant);

         if(m_cfg.UseOrderCheckBeforeSend)
           {
            MqlTradeCheckResult chk;
            ZeroMemory(chk);
            if(!OrderCheck(req, chk))
              {
               last_text = StringFormat("OrderCheck refused the request (GetLastError=%d, check retcode=%d, margin=%s, free=%s)",
                                       GetLastError(), chk.retcode, DoubleToString(chk.margin, 2),
                                       DoubleToString(chk.margin_free, 2));
               retcode   = XAU_RC_INVALID_REQUEST;
               continue;                                  // recompute price and retry once
              }
           }

         bool sent = OrderSend(req, res);
         retcode   = (int)res.retcode;
         last_text = StringFormat("%s | %s", XauRetcodeName(retcode), res.comment);
         if(!sent)
           {
            int err = GetLastError();
            last_text = StringFormat("OrderSend() returned false, terminal error %d, retcode %d", err, retcode);
            if(!XauRetcodeRetryable(retcode) && retcode != 0)
              {
               r.retcode = retcode;
               r.text    = last_text;
               m_failed++;
               return;
               }
            continue;
           }
         if(retcode == XAU_RC_DONE || retcode == XAU_RC_DONE_PARTIAL || retcode == XAU_RC_PLACED)
           {
            //--- verify: the position must actually exist ----------------
            r.deal = (long)res.deal;
            long     tk = 0;
            double   fp = 0.0;
            double   fv = 0.0;
            datetime ft = 0;
            for(int v = 0; v <= (int)XauClampI(m_cfg.FillVerificationRetries, 0, 10); v++)
              {
               if(FindResult(is_buy, volume, before, tk, fp, fv, ft))
                 {
                  // MqlTradeResult::price/volume are broker-confirmed DEAL
                  // values. On NETTING, the visible position volume is the
                  // merged basket volume and must never be recorded as one
                  // layer. Prefer the deal history when it is available.
                  double deal_price = 0.0;
                  double deal_volume = 0.0;
                  datetime deal_time = 0;
                  bool have_deal = DealFillDetails(r.deal, is_buy, deal_price, deal_volume, deal_time);
                  r.ok        = true;
                  r.ticket    = tk;
                  r.price     = (have_deal ? deal_price : (res.price > 0.0 ? res.price : fp));
                  if(res.volume > 0.0)
                     r.volume = res.volume;
                  else if(have_deal)
                     r.volume = deal_volume;
                  else if(m_spec.IsHedgingAccount())
                     r.volume = fv;
                  else
                     r.volume = expected_volume; // netting fallback: requested layer size
                  r.time      = (have_deal && deal_time > 0 ? deal_time : (ft > 0 ? ft : XauNow()));
                  r.retcode   = retcode;
                  r.text      = last_text;
                  m_ok++;
                  return;
                 }
               SleepMs(m_cfg.FillVerificationDelayMs);
              }
            // accepted but invisible: never guess, never re-send
            r.unverified = true;
            r.retcode    = retcode;
            r.price      = res.price;
            r.volume     = res.volume;
            r.text       = "ACCEPTED BUT NOT VERIFIED: retcode " + XauRetcodeName(retcode) +
                           " reported a fill but no matching EA position exists (deal " +
                           IntegerToString((long)res.deal) + ")";
            m_unverified++;
            m_failed++;
            return;
           }
         // 10030 INVALID_FILL is a broker policy mismatch, not a market
         // problem: switch to the next filling mode this symbol allows and
         // retry once per allowed mode, then give up with an explicit reason.
         if(retcode == XAU_RC_INVALID_FILL)
           {
            int modes = m_spec.FillingCount();
            if(modes > 1 && m_fill_variant < modes - 1)
              {
               m_fill_variant++;
               last_text = StringFormat("%s | retrying with filling=%s", last_text,
                                        EnumToString(m_spec.FillingByIndex(m_fill_variant)));
               m_log.Warn(XAU_T_EXEC, last_text);
               continue;
              }
            r.retcode = retcode;
            r.text    = last_text + " (no other filling mode is allowed by the symbol)";
            m_failed++;
            return;
           }
         if(!XauRetcodeRetryable(retcode))
           {
            r.retcode = retcode;
            r.text    = last_text;
            m_failed++;
            return;
           }
        }
      r.retcode = retcode;
      r.text    = (StringLen(last_text) > 0 ? last_text : "no attempt executed") + " (attempts: " +
                  IntegerToString(r.attempts) + ")";
      m_failed++;
     }

   /// Close one EA position completely. 10036/10039 mean "already gone /
   /// close already pending" and are treated as success after verification.
   void Close(const long ticket, SExecResult &r)
     {
      r.ok = false; r.unverified = false; r.ticket = ticket; r.price = 0.0;
      r.volume = 0.0; r.time = 0; r.retcode = 0; r.text = ""; r.attempts = 0; r.deal = 0;

      if(!m_spec.UpdateQuote() || !m_spec.QuoteOk())
        {
         r.text = "no live quote - close refused";
         m_failed++;
         return;
        }
      int attempts_max = (int)XauClampI(m_cfg.MaxOrderRetries, 1, 10);
      string last_text = "";
      int    retcode   = 0;
      for(int attempt = 0; attempt < attempts_max; attempt++)
        {
         r.attempts = attempt + 1;
         if(attempt > 0)
           {
            m_retries++;
            SleepMs(m_cfg.RetryDelayMs);
           }
         if(!PositionSelectByTicket(ticket))
           {
            r.ok   = true;                    // already closed elsewhere
            r.text = "position already closed";
            return;
           }
         ENUM_POSITION_TYPE pt = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         double vol  = PositionGetDouble(POSITION_VOLUME);
         bool   is_buy_close = (pt == POSITION_TYPE_SELL);   // closing a SELL means buying
         double price = (is_buy_close ? m_spec.Ask() : m_spec.Bid());

         MqlTradeRequest req;
         MqlTradeResult  res;
         ZeroMemory(req);
         ZeroMemory(res);
         req.action       = TRADE_ACTION_DEAL;
         req.position     = (ulong)ticket;
         req.symbol       = m_spec.Symbol();
         req.volume       = vol;
         req.type         = (is_buy_close ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
         req.price        = m_spec.NormalizePrice(price);
         req.deviation    = (ulong)XauClampI(m_cfg.MaximumDeviationPoints, 0, 100000);
         req.magic        = (ulong)m_cfg.MagicNumber;
         req.comment      = m_cfg.EntryComment + "-close";
         req.type_time    = ORDER_TIME_GTC;
         req.type_filling = m_spec.FillingByIndex(m_fill_variant);

         bool sent = OrderSend(req, res);
         retcode   = (int)res.retcode;
         last_text = StringFormat("%s | %s", XauRetcodeName(retcode), res.comment);
         if(retcode == XAU_RC_DONE || retcode == XAU_RC_DONE_PARTIAL)
           {
            for(int v = 0; v <= (int)XauClampI(m_cfg.FillVerificationRetries, 0, 10); v++)
              {
               if(!PositionSelectByTicket(ticket))
                 {
                  r.ok      = true;
                  r.price   = res.price;
                  r.volume  = res.volume;
                  r.retcode = retcode;
                  r.text    = last_text;
                  r.time    = XauNow();
                  m_ok++;
                  return;
                 }
               // netting partial close: the remaining volume shrank
               double left = PositionGetDouble(POSITION_VOLUME);
               if(left < vol - 1.0e-8)
                 {
                  r.ok      = true;
                  r.price   = res.price;
                  r.volume  = vol - left;
                  r.retcode = retcode;
                  r.text    = last_text + " (partial, " + DoubleToString(left, 2) + " left)";
                  m_ok++;
                  return;
                 }
               SleepMs(m_cfg.FillVerificationDelayMs);
              }
            r.unverified = true;
            r.retcode    = retcode;
            r.text       = "CLOSE ACCEPTED BUT NOT VERIFIED for ticket " + IntegerToString(ticket);
            m_unverified++;
            m_failed++;
            return;
           }
         if(retcode == XAU_RC_INVALID_FILL)
           {
            int modes = m_spec.FillingCount();
            if(modes > 1 && m_fill_variant < modes - 1)
              {
               m_fill_variant++;
               m_log.Warn(XAU_T_EXEC, StringFormat("close: 10030 on ticket %s, retrying with filling=%s",
                                                   IntegerToString(ticket),
                                                   EnumToString(m_spec.FillingByIndex(m_fill_variant))));
               continue;
              }
           }
         if(retcode == XAU_RC_POSITION_CLOSED || retcode == XAU_RC_CLOSE_ORDER_EXIST)
           {
            if(!PositionSelectByTicket(ticket))
              {
               r.ok      = true;
               r.retcode = retcode;
               r.text    = "position was closed concurrently: " + last_text;
               return;
              }
            continue;                      // a close order is in flight: wait
           }
         if(!sent)
           {
            last_text = StringFormat("OrderSend() false, terminal error %d, retcode %d", GetLastError(), retcode);
            if(!XauRetcodeRetryable(retcode) && retcode != 0)
               break;
            continue;
           }
         if(!XauRetcodeRetryable(retcode))
            break;
        }
      r.retcode = retcode;
      r.text    = (StringLen(last_text) > 0 ? last_text : "close failed") + " (attempts " + IntegerToString(r.attempts) + ")";
      m_failed++;
     }

   /// True while the position is still alive on the account.
   bool PositionAlive(const long ticket)
     {
      if(ticket <= 0)
         return(false);
      return(PositionSelectByTicket(ticket));
     }

   string Describe(void) const
     {
      return(StringFormat("filling=%s deviation=%d retries=%d ordercheck=%s",
                          m_spec.FillingModeName(), m_cfg.MaximumDeviationPoints, m_cfg.MaxOrderRetries,
                          (m_cfg.UseOrderCheckBeforeSend ? "on" : "off")));
     }
  };

#endif // XAU_AVG_PRO_EXECUTION_MQH
//+------------------------------------------------------------------+
