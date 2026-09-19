//+------------------------------------------------------------------+
//|                                                     Basket.mqh   |
//|  XAU_AVG_PRO v1.0.0 - basket P/L, take profit, cut loss, closing|
//|                                                                  |
//  Cost aware maths (the part most averaging EAs get wrong):        |
//   net = SUM(position profit) + SUM(swap, if enabled)             |
//         - round-turn commission estimate                          |
//   For the MONEY / PERCENT targets the level is anchored on the    |
//   price the basket would actually be closed at (Bid for a BUY     |
//   basket, Ask for a SELL basket), so the spread is included       |
//   automatically and the level is drift free:                      |
//        tp = close_ref + (target - net) / (moneyPerPoint * volume) |
//   Moving the market by dX raises net by dX*moneyPerPoint*volume   |
//   and lowers the remaining distance by exactly dX.                |
//   For POINTS / PRICE modes the level is anchored on the weighted  |
//   average price, which is the literal meaning of those modes.     |
//+------------------------------------------------------------------+
#ifndef XAU_AVG_PRO_BASKET_MQH
#define XAU_AVG_PRO_BASKET_MQH

#include "Types.mqh"
#include "BrokerSpec.mqh"
#include "Logger.mqh"
#include "Cycle.mqh"
#include "Execution.mqh"

class CBasketManager
  {
private:
   CConfig      *m_cfg;
   CSymbolSpec  *m_spec;
   CLogger      *m_log;
   CCycleManager*m_cycle;
   CExecution   *m_exec;

   double  m_net_pl;
   double  m_gross_pl;
   double  m_swap_total;
   double  m_commission_estimate;
   double  m_tp_price;
   double  m_tp_points;
   double  m_target_money;
   string  m_tp_note;
   bool    m_close_in_progress;
   int     m_close_failures;

   bool IsBuy(void) const { return(m_cycle.Dir() == POSITION_TYPE_BUY); }
   /// The price at which the basket would be closed right now.
   double CloseRefPrice(void) const { return(IsBuy() ? m_spec.Bid() : m_spec.Ask()); }
   /// Money value of a 1-point move of the whole basket.
   double MoneyPerPoint(void) const
     {
      return(m_spec.MoneyPerPointPerLot() * m_cycle.TotalVolume());
     }

public:
                     CBasketManager(void) : m_cfg(NULL), m_spec(NULL), m_log(NULL), m_cycle(NULL), m_exec(NULL),
                                           m_net_pl(0.0), m_gross_pl(0.0), m_swap_total(0.0),
                                           m_commission_estimate(0.0), m_tp_price(0.0), m_tp_points(0.0),
                                           m_target_money(0.0), m_tp_note(""), m_close_in_progress(false),
                                           m_close_failures(0)
     {
     }

   void Init(CConfig *cfg, CSymbolSpec *spec, CLogger *log, CCycleManager *cycle, CExecution *exec)
     {
      m_cfg   = cfg;
      m_spec  = spec;
      m_log   = log;
      m_cycle = cycle;
      m_exec  = exec;
     }

   /// Recompute the live basket numbers from the positions themselves.
   /// Every position ticket is counted exactly once: on netting accounts
   /// all layers share one ticket, on hedging accounts each layer has its
   /// own. Summing blindly would multiply the netting profit by N.
   void Recompute(void)
     {
      m_gross_pl   = 0.0;
      m_swap_total = 0.0;
      if(!m_cycle.IsActive())
        {
         m_net_pl                = 0.0;
         m_commission_estimate   = 0.0;
         m_tp_price              = 0.0;
         m_tp_points             = 0.0;
         m_target_money          = 0.0;
         m_tp_note               = "no basket";
         return;
        }
      long seen[];
      SLayerRec layers[];
      int n = m_cycle.Layers(layers);
      for(int i = 0; i < n; i++)
        {
         if(layers[i].ticket <= 0)
            continue;
         bool duplicate = false;
         for(int j = 0; j < ArraySize(seen); j++)
            if(seen[j] == layers[i].ticket)
               duplicate = true;
         if(duplicate)
            continue;
         int m = ArraySize(seen);
         ArrayResize(seen, m + 1);
         seen[m] = layers[i].ticket;
         if(PositionSelectByTicket(layers[i].ticket))
           {
            m_gross_pl   += PositionGetDouble(POSITION_PROFIT);
            m_swap_total += PositionGetDouble(POSITION_SWAP);
           }
        }
      if(ArraySize(seen) == 0 && PositionSelect(m_spec.Symbol()))
        {
         m_gross_pl   = PositionGetDouble(POSITION_PROFIT);
         m_swap_total = PositionGetDouble(POSITION_SWAP);
        }
      // round-turn commission estimate (per lot, per side)
      m_commission_estimate = 2.0 * MathAbs(m_cfg.EstimatedCommissionPerLot) * m_cycle.TotalVolume();
      m_net_pl = m_gross_pl + (m_cfg.AccountForSwapInTP ? m_swap_total : 0.0) - m_commission_estimate;
     }

   /// Weighted average price that already reflects the trading costs:
   /// the price at which the basket is exactly break even.
   double BreakEvenPrice(void) const
     {
      if(!m_cycle.IsActive() || m_cycle.TotalVolume() <= 0.0)
         return(0.0);
      double mpp = MoneyPerPoint();
      if(mpp <= 0.0)
         return(m_cycle.AvgPrice());
      double need_points = (m_commission_estimate - (m_cfg.AccountForSwapInTP ? m_swap_total : 0.0)) / mpp;
      return(IsBuy() ? m_cycle.AvgPrice() + need_points * m_spec.Point()
                     : m_cycle.AvgPrice() - need_points * m_spec.Point());
     }

   /// Target money for the current basket according to BasketTPMode.
   double ResolveTargetMoney(void) const
     {
      switch(m_cfg.BasketTPMode)
        {
         case XAU_TP_MONEY:
            return(MathAbs(m_cfg.BasketTakeProfitMoney));
         case XAU_TP_PERCENT:
           {
            double basis = m_spec.CostBasis(m_cycle.AvgPrice(), m_cycle.TotalVolume());
            return(basis * MathAbs(m_cfg.BasketTakeProfitPercent) / 100.0);
           }
        }
      return(0.0);
     }

   /// Compute the basket TP level and publish it on the cycle manager.
   /// @return true when a TP level exists
   bool UpdateTakeProfit(void)
     {
      m_tp_price  = 0.0;
      m_tp_points = 0.0;
      m_tp_note   = "";
      if(!m_cycle.IsActive() || m_cycle.TotalVolume() <= 0.0)
        {
         m_cycle.SetBasketTP(0.0);
         return(false);
        }
      if(m_cfg.BasketTPMode == XAU_TP_NONE)
        {
         m_tp_note = "basket TP disabled";
         m_cycle.SetBasketTP(0.0);
         return(false);
        }
      double mpp = MoneyPerPoint();
      if(mpp <= 0.0)
        {
         m_tp_note = "money per point is zero";
         return(false);
        }
      double pts    = 0.0;
      double anchor = 0.0;              // price the level is measured from
      if(m_cfg.BasketTPMode == XAU_TP_POINTS)
        {
         pts = MathMax(1.0, (double)m_cfg.BasketTakeProfitPoints);
         m_tp_price = (IsBuy() ? m_cycle.AvgPrice() + pts * m_spec.Point()
                              : m_cycle.AvgPrice() - pts * m_spec.Point());
         m_target_money = pts * mpp;
         anchor      = m_cycle.AvgPrice();
         m_tp_note   = "POINTS mode, anchored on average price";
        }
      else
         if(m_cfg.BasketTPMode == XAU_TP_PRICE)
           {
            double offset = MathAbs(m_cfg.BasketTakeProfitPrice);
            m_tp_price = (IsBuy() ? m_cycle.AvgPrice() + offset : m_cycle.AvgPrice() - offset);
            m_target_money = m_spec.PriceToPoints(offset) * mpp;
            anchor    = m_cycle.AvgPrice();
            m_tp_note = "PRICE mode, anchored on average price";
           }
         else
           {
            // MONEY / PERCENT: cost aware, anchored on the close price
            double target = ResolveTargetMoney();
            if(target <= 0.0)
              {
               m_tp_note = "target money is zero";
               return(false);
              }
            m_target_money = target;
            if(m_cfg.AccountForSpreadInTP)
              {
               double need = target - m_net_pl;
               pts         = need / mpp;
               m_tp_price  = CloseRefPrice() + pts * m_spec.Point();
               anchor      = CloseRefPrice();
               m_tp_note   = StringFormat("cost aware, %.1f pts from current close price", pts);
              }
            else
              {
               pts         = target / mpp;
               m_tp_price  = (IsBuy() ? m_cycle.AvgPrice() + pts * m_spec.Point()
                                     : m_cycle.AvgPrice() - pts * m_spec.Point());
               anchor      = m_cycle.AvgPrice();
               m_tp_note   = "spread ignored, anchored on average price";
              }
           }
      // safety buffer pushes the target further away, never closer
      if(m_cfg.BasketTPSafetyBufferPoints > 0)
        {
         double b = m_cfg.BasketTPSafetyBufferPoints * m_spec.Point();
         m_tp_price = (IsBuy() ? m_tp_price + b : m_tp_price - b);
        }
      // reported distance from the anchor, after the buffer was applied
      pts = m_spec.PriceToPoints(MathAbs(m_tp_price - anchor));
      if(m_cfg.RequireMinimumProfitMoney > 0.0 && m_target_money < m_cfg.RequireMinimumProfitMoney)
         m_target_money = m_cfg.RequireMinimumProfitMoney;
      m_tp_price  = m_spec.NormalizePrice(m_tp_price);
      m_tp_points = pts;
      m_cycle.SetBasketTP(m_tp_price);
      return(true);
     }

   /// TP reached? Uses the real close price so the spread cannot cause a
   /// false positive (a BUY basket is closed at Bid).
   bool TakeProfitReached(void) const
     {
      if(!m_cycle.IsActive() || m_tp_price <= 0.0)
         return(false);
      if(m_cfg.RequireMinimumProfitMoney > 0.0 && m_net_pl < m_cfg.RequireMinimumProfitMoney)
         return(false);
      return(IsBuy() ? (m_spec.Bid() >= m_tp_price) : (m_spec.Ask() <= m_tp_price));
     }

   /// Adverse distance in points measured from the average price.
   double AdversePoints(void) const
     {
      if(!m_cycle.IsActive())
         return(0.0);
      double d = (IsBuy() ? m_cycle.AvgPrice() - m_spec.Bid() : m_spec.Ask() - m_cycle.AvgPrice());
      return(d > 0.0 ? m_spec.PriceToPoints(d) : 0.0);
     }

   /// Fill a verdict when the basket must be cut.
   void CheckCutLoss(SVerdict &v)
     {
      XauPassV(v);
      if(!m_cfg.EnableBasketCutLoss || !m_cycle.IsActive())
         return;
      double loss      = -m_net_pl;                       // positive when losing
      double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
      double pct_limit = (balance > 0.0 ? balance * m_cfg.BasketCutLossPercentOfBalance / 100.0 : 0.0);
      double money_lim = MathAbs(m_cfg.BasketCutLossMoney);
      double adv_pts   = AdversePoints();

      bool hit_money  = (money_lim > 0.0 && loss >= money_lim);
      bool hit_percent= (pct_limit > 0.0 && loss >= pct_limit);
      bool hit_points = (m_cfg.BasketCutLossPoints > 0 && adv_pts >= (double)m_cfg.BasketCutLossPoints);

      bool fire = false;
      string why = "";
      switch(m_cfg.CutLossMode)
        {
         case XAU_CUT_MONEY:
            fire = hit_money;
            why  = StringFormat("basket loss %s >= BasketCutLossMoney %s", XauMoney(-loss), XauMoney(-money_lim));
            break;
         case XAU_CUT_PERCENT:
            fire = hit_percent;
            why  = StringFormat("basket loss %s >= %.2f%% of balance (%s)",
                                XauMoney(-loss), m_cfg.BasketCutLossPercentOfBalance, XauMoney(-pct_limit));
            break;
         case XAU_CUT_POINTS:
            fire = hit_points;
            why  = StringFormat("price %.0f pts against average >= BasketCutLossPoints %d",
                                adv_pts, m_cfg.BasketCutLossPoints);
            break;
         default:
            fire = (hit_money || hit_percent || hit_points);
            if(hit_money)
               why = StringFormat("money: loss %s >= %s", XauMoney(-loss), XauMoney(-money_lim));
            else
               if(hit_percent)
                  why = StringFormat("percent: loss %s >= %s (%.2f%% of balance)",
                                     XauMoney(-loss), XauMoney(-pct_limit), m_cfg.BasketCutLossPercentOfBalance);
                else
                   if(hit_points)
                      why = StringFormat("points: %.0f pts against average >= %d", adv_pts, m_cfg.BasketCutLossPoints);
            break;
        }
      if(fire)
         XauFailV(v, XAU_BLK_CYCLE_DD, "CUT LOSS " + why, 0, loss);
     }

   /// Close every EA position of the basket. Failures are reported, the
   /// caller keeps the state as CLOSING and retries on the next tick, so
   /// a broker error can never leave the EA thinking it is flat.
   /// @return number of positions still open afterwards
   int CloseAllLayers(const int exit_code, const string reason)
     {
      m_close_in_progress = true;
      m_cycle.MarkClosing(exit_code);
      SLayerRec layers[];
      int n = m_cycle.Layers(layers);
      int order_idx[];
      ArrayResize(order_idx, n);
      for(int i = 0; i < n; i++)
         order_idx[i] = i;
      // ordering policy
      if(m_cfg.CutLossCloseOrder == XAU_CLOSE_OLDEST_FIRST)
        {
         for(int i = 1; i < n; i++)
           {
            int key = order_idx[i];
            int j = i - 1;
            while(j >= 0 && (layers[order_idx[j]].open_time > layers[key].open_time))
              {
               order_idx[j + 1] = order_idx[j];
               j--;
              }
            order_idx[j + 1] = key;
           }
        }
      else
         if(m_cfg.CutLossCloseOrder == XAU_CLOSE_LARGEST_FIRST)
           {
            for(int i = 1; i < n; i++)
              {
               int key = order_idx[i];
               int j = i - 1;
               while(j >= 0 && (layers[order_idx[j]].volume < layers[key].volume))
                 {
                  order_idx[j + 1] = order_idx[j];
                  j--;
                 }
               order_idx[j + 1] = key;
              }
           }
         else
           {
            // youngest first: newest (largest, most risky) layer dies first
            for(int i = 0; i < n / 2; i++)
              {
               int tmp = order_idx[i];
               order_idx[i] = order_idx[n - 1 - i];
               order_idx[n - 1 - i] = tmp;
              }
           }
      m_log.Info(exit_code == 2 ? XAU_T_CUT : XAU_T_TP,
                 StringFormat("closing basket of cycle #%d | reason=%s layers=%d vol=%s net=%s",
                              m_cycle.CycleId(), reason, n,
                              DoubleToString(m_cycle.TotalVolume(), m_spec.VolumeDigits()), XauMoney(m_net_pl)));
      for(int k = 0; k < n; k++)
        {
         SLayerRec lay = layers[order_idx[k]];
         if(lay.ticket <= 0)
           {
            // netting: close the merged position by symbol
            if(!PositionSelect(m_spec.Symbol()))
               continue;
            long tk = 0;
            int total = PositionsTotal();
            for(int i = 0; i < total; i++)
              {
               long t2 = PositionGetTicket(i);
               if(t2 <= 0)
                  continue;
               if(PositionGetInteger(POSITION_MAGIC) == m_cfg.MagicNumber &&
                  PositionGetString(POSITION_SYMBOL) == m_spec.Symbol())
                 {
                  tk = t2;
                  break;
                 }
              }
            if(tk <= 0)
               continue;
            SExecResult r;
            m_exec.Close(tk, r);
            if(!r.ok)
              {
               m_close_failures++;
               m_log.Error(XAU_T_EXEC, StringFormat("netting close failed ticket=%d | %s", tk, r.text));
              }
            continue;
           }
         SExecResult r;
         m_exec.Close(lay.ticket, r);
         if(r.ok)
            m_log.Info(XAU_T_EXEC, StringFormat("closed L%d ticket=%s vol=%s | %s",
                                                lay.index, IntegerToString(lay.ticket),
                                                DoubleToString(r.volume, 2), r.text));
         else
           {
            m_close_failures++;
            m_log.Error(XAU_T_EXEC, StringFormat("close failed L%d ticket=%s retcode=%d | %s",
                                                 lay.index, IntegerToString(lay.ticket), r.retcode, r.text));
           }
        }
      int left = m_cycle.PositionCount();
      if(left == 0)
        {
         m_close_in_progress = false;
         m_cycle.MarkClosed(exit_code, m_net_pl);
        }
      return(left);
     }

   /// Close only one direction (Telegram /closebuy /closesell).
   int CloseDirection(const ENUM_POSITION_TYPE type)
     {
      int closed = 0;
      int total  = PositionsTotal();
      for(int i = total - 1; i >= 0; i--)
        {
         long tk = PositionGetTicket(i);
         if(tk <= 0)
            continue;
         if(PositionGetInteger(POSITION_MAGIC) != m_cfg.MagicNumber)
            continue;
         if(PositionGetString(POSITION_SYMBOL) != m_spec.Symbol())
            continue;
         if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != type)
            continue;
         SExecResult r;
         m_exec.Close(tk, r);
         if(r.ok)
            closed++;
         else
            m_log.Error(XAU_T_EXEC, StringFormat("direction close failed ticket=%s | %s", IntegerToString(tk), r.text));
        }
      m_log.Info(XAU_T_EXEC, StringFormat("CloseDirection %s: %d position(s) closed",
                                          (type == POSITION_TYPE_BUY ? "BUY" : "SELL"), closed));
      return(closed);
     }

   /// Close every position of this EA on any symbol (Telegram /closeall).
   int CloseEverything(void)
     {
      int closed = 0;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         long tk = PositionGetTicket(i);
         if(tk <= 0)
            continue;
         if(PositionGetInteger(POSITION_MAGIC) != m_cfg.MagicNumber)
            continue;
         if(m_cfg.ManageCurrentSymbolOnly && PositionGetString(POSITION_SYMBOL) != m_spec.Symbol())
            continue;
         SExecResult r;
         m_exec.Close(tk, r);
         if(r.ok)
            closed++;
         else
            m_log.Error(XAU_T_EXEC, StringFormat("close-all failed ticket=%s | %s", IntegerToString(tk), r.text));
        }
      return(closed);
     }

   double NetPL(void)                const { return(m_net_pl); }
   double GrossPL(void)               const { return(m_gross_pl); }
   double SwapTotal(void)             const { return(m_swap_total); }
   double CommissionEstimate(void)    const { return(m_commission_estimate); }
   double TPPrice(void)               const { return(m_tp_price); }
   double TPPoints(void)              const { return(m_tp_points); }
   double TargetMoney(void)           const { return(m_target_money); }
   string TPNote(void)                const { return(m_tp_note); }
   bool   ClosingInProgress(void)     const { return(m_close_in_progress); }
   int    CloseFailures(void)         const { return(m_close_failures); }
   void   ClearClosingFlag(void)      { m_close_in_progress = false; }

   string Describe(void) const
     {
      if(!m_cycle.IsActive())
         return("basket: none");
      return(StringFormat("basket: vol=%s avg=%s net=%s tp=%s (%.1f pts) adverse=%.0f pts",
                          DoubleToString(m_cycle.TotalVolume(), m_spec.VolumeDigits()),
                          XauPrice(m_cycle.AvgPrice()), XauMoney(m_net_pl),
                          XauPrice(m_tp_price), m_tp_points, AdversePoints()));
     }
  };

#endif // XAU_AVG_PRO_BASKET_MQH
//+------------------------------------------------------------------+
