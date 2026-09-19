//+------------------------------------------------------------------+
//|                                                        Lots.mqh  |
//|  XAU_AVG_PRO v1.0.0 - lot sizing (FIX / AUTO / MULTIPLIER)      |
//|                                                                  |
//  Guarantees:                                                      |
//   - the produced volume is always broker legal (step/min/max) or  |
//     the request is rejected with an explicit reason               |
//   - MaximumLotPerOrder can never be bypassed by the multiplier    |
//   - MaximumTotalLot is applied to the PROJECTED basket exposure   |
//   - risk-relevant rounding is always DOWN, never up               |
//   - margin safety is evaluated here so the caller cannot forget it|
//+------------------------------------------------------------------+
#ifndef XAU_AVG_PRO_LOTS_MQH
#define XAU_AVG_PRO_LOTS_MQH

#include "Types.mqh"
#include "BrokerSpec.mqh"
#include "Logger.mqh"

class CLotManager
  {
private:
   CConfig        *m_cfg;
   CSymbolSpec    *m_spec;
   CLogger        *m_log;
   string          m_reason;
   ENUM_XAU_BLOCK  m_code;
   double          m_raw;             // pre-normalisation value (logs/tests)
   double          m_last_lot;

   void Block(const ENUM_XAU_BLOCK code, const string why)
     {
      m_code   = code;
      m_reason = why;
     }
   /// Geometric growth with a hard sanity ceiling. An explicit loop is
   /// used instead of MathPow so the value can never silently overflow.
   double GrowByMultiplier(const double base, const int layers) const
     {
      double lot  = base;
      double mult = m_cfg.LotMultiplier;
      if(mult <= 1.0)
         return(lot);
      for(int i = 1; i < layers; i++)
        {
         lot *= mult;
         if(lot > 1.0e6)
            return(1.0e6);
        }
      return(lot);
     }

public:
                     CLotManager(void) : m_cfg(NULL), m_spec(NULL), m_log(NULL),
                                         m_reason(""), m_code(XAU_BLK_NONE), m_raw(0.0), m_last_lot(0.0)
     {
     }

   void Init(CConfig *cfg, CSymbolSpec *spec, CLogger *log)
     {
      m_cfg  = cfg;
      m_spec = spec;
      m_log  = log;
     }

   double FixedLot(void) const { return(m_cfg.InitialLot); }

   /// Layer volume before caps: InitialLot * multiplier^(layer-1).
   double MultiplierLot(const int layer) const
     {
      int l = (layer < 1 ? 1 : layer);
      return(GrowByMultiplier(m_cfg.InitialLot, l));
     }

   /// Risk aware per-layer volume.
   /// @param basis  balance or equity, already resolved by the caller
   double AutoLot(const int layer, const double price, const bool is_buy, const double basis)
     {
      double lot = 0.0;
      if(basis <= 0.0)
        {
         Block(XAU_BLK_MARGIN, "auto lot: balance/equity is not positive");
         return(0.0);
        }
      if(m_cfg.AutoLotCalculationMode == XAU_AUTLOT_RISK_DISTANCE)
        {
         double risk_money  = basis * m_cfg.RiskPercent / 100.0;
         double per_lot_pts = m_spec.MoneyPerPointPerLot();
         double stop_pts    = (double)(m_cfg.InitialStopDistancePoints > 0 ? m_cfg.InitialStopDistancePoints : 1);
         if(per_lot_pts <= 0.0 || risk_money <= 0.0)
           {
            Block(XAU_BLK_SPEC_INVALID, "auto lot: money-per-point or risk amount is not positive");
            return(0.0);
           }
         double risk_per_lot = per_lot_pts * stop_pts;
         if(risk_per_lot <= 0.0)
           {
            Block(XAU_BLK_SPEC_INVALID, "auto lot: computed risk per lot is zero");
            return(0.0);
           }
         lot = risk_money / risk_per_lot;
        }
      else
        {
         double margin_per_lot = 0.0;
         if(!m_spec.EstimateMargin(is_buy, 1.0, price, margin_per_lot) || margin_per_lot <= 0.0)
           {
            Block(XAU_BLK_MARGIN, "auto lot: OrderCalcMargin unavailable for 1.0 lot");
            return(0.0);
           }
         double allowed = basis * m_cfg.AutoLotMaxMarginUsagePercent / 100.0;
         lot = allowed / margin_per_lot;
        }
      if(!MathIsValidNumber(lot))
        {
         Block(XAU_BLK_SPEC_INVALID, "auto lot: calculation produced a non-finite number");
         return(0.0);
        }
      if(m_cfg.ApplyMultiplierToAutoLot && layer > 1)
         lot = GrowByMultiplier(lot, layer);
      return(lot);
     }

   /// Complete sizing decision for one layer.
   /// @param layer            1 based layer index
   /// @param current_exposure lots already controlled by this EA
   /// @param lot              normalised, cap-respecting volume on success
   /// @param v                verdict (allowed=false => lot is 0.0)
   void Resolve(const int layer, const bool is_buy, const double price,
                const double current_exposure, double &lot, SVerdict &v)
     {
      XauPassV(v);
      lot           = 0.0;
      m_code        = XAU_BLK_NONE;
      m_reason      = "";
      m_raw         = 0.0;

      double raw = 0.0;
      double basis = (m_cfg.AutoLotEquityBasis == XAU_LOTBASIS_BALANCE
                      ? AccountInfoDouble(ACCOUNT_BALANCE)
                      : AccountInfoDouble(ACCOUNT_EQUITY));

      if(m_cfg.LotMode == XAU_LOT_FIXED)
         raw = m_cfg.InitialLot;
      else
         if(m_cfg.LotMode == XAU_LOT_MULTIPLIER)
           {
            raw = MultiplierLot(layer);
           }
         else
            if(m_cfg.LotMode == XAU_LOT_AUTO)
              {
               raw = AutoLot(layer, price, is_buy, basis);
               if(raw <= 0.0)
                 {
                  lot = 0.0;
                  XauFailV(v, (m_code != XAU_BLK_NONE ? m_code : XAU_BLK_MAX_LOT_ORDER),
                           (StringLen(m_reason) > 0 ? m_reason : "auto lot sizing failed"), 0, 0.0);
                  return;
                 }
              }
            else
              {
               XauFailV(v, XAU_BLK_SPEC_INVALID, "unknown LotMode", 0, 0.0);
               return;
              }
      m_raw = raw;

      //--- hard per-order cap, applies to every mode -----------------
      double cap = m_cfg.MaximumLotPerOrder;
      if(cap <= 0.0)
         cap = m_spec.VolumeMax();
      if(raw > cap)
        {
         m_log.Throttled(2, XAU_T_MAXLOT, "cap",
                         StringFormat("lot %.4f reduced to MaximumLotPerOrder %.4f (mode=%s layer=%d)",
                                      raw, cap, EnumToString(m_cfg.LotMode), layer), 600);
         raw = cap;
        }

      //--- broker normalisation (floor: never risk more than computed)
      double norm = m_spec.NormalizeVolume(raw, true);
      if(norm <= 0.0)
        {
         if(m_cfg.LotMode == XAU_LOT_AUTO && m_cfg.AutoLotAllowMinLotFallback)
           {
            norm = m_spec.NormalizeVolume(m_spec.VolumeMin(), false);
            m_log.Throttled(2, XAU_T_MAXLOT, "minfallback",
                            StringFormat("auto lot %.4f is below broker minimum %.2f - using the minimum, so real risk is HIGHER than RiskPercent implies",
                                         raw, m_spec.VolumeMin()), 600);
           }
         else
           {
            m_code   = XAU_BLK_MAX_LOT_ORDER;
            m_reason = StringFormat("computed lot %.4f is below broker minimum %.2f after step rounding (mode=%s)",
                                    raw, m_spec.VolumeMin(), EnumToString(m_cfg.LotMode));
            XauFailV(v, m_code, m_reason, 0, raw);
            return;
           }
        }
      if(!m_spec.IsLegalVolume(norm))
        {
         XauFailV(v, XAU_BLK_SPEC_INVALID,
                  StringFormat("volume %s is not legal for this symbol (step %s min %s max %s)",
                               DoubleToString(norm, 8), DoubleToString(m_spec.VolumeStep(), 8),
                               DoubleToString(m_spec.VolumeMin(), 8), DoubleToString(m_spec.VolumeMax(), 8)), 0, norm);
         return;
        }

      //--- projected total exposure ---------------------------------
      double max_total = m_cfg.MaximumTotalLot;
      if(max_total > 0.0)
        {
         double projected = current_exposure + norm;
         if(projected > max_total + 1.0e-9)
           {
            double headroom = (max_total - current_exposure > 0.0 ? max_total - current_exposure : 0.0);
            double shrunk   = m_spec.NormalizeVolume(headroom, true);
            if(m_cfg.TruncateLotToExposureHeadroom && shrunk >= m_spec.VolumeMin())
              {
               m_log.Throttled(2, XAU_T_MAXLOT, "shrink",
                               StringFormat("projected exposure %.2f > MaximumTotalLot %.2f - lot truncated to %.2f",
                                            projected, max_total, shrunk), 600);
               norm = shrunk;
              }
            else
              {
               m_code   = XAU_BLK_MAX_TOTAL_LOT;
               m_reason = StringFormat("projected exposure %.2f lots exceeds MaximumTotalLot %.2f lots (current %.2f, requested %.2f)",
                                       projected, max_total, current_exposure, norm);
               XauFailV(v, m_code, m_reason, 0, projected);
               return;
              }
           }
        }

      lot        = norm;
      m_last_lot = norm;
      v.allowed  = true;
      v.value    = norm;
      v.reason   = StringFormat("lot %.2f (raw %.4f, layer %d, mode %s)", norm, raw, layer, EnumToString(m_cfg.LotMode));
     }

   /// Margin safety check for a projected position. Must run before
   /// opening anything - initial entry and averaging layers alike.
   void CheckMargin(const bool is_buy, const double lot, const double price, SVerdict &v)
     {
      XauPassV(v);
      double need = 0.0;
      if(!m_spec.EstimateMargin(is_buy, lot, price, need))
        {
         XauFailV(v, XAU_BLK_MARGIN, "OrderCalcMargin failed - cannot verify margin, refusing to trade", 0, 0.0);
         return;
        }
      double equity           = AccountInfoDouble(ACCOUNT_EQUITY);
      double margin           = m_spec.AccountMargin();
      double projected_margin = margin + need;
      if(projected_margin <= 0.0)
        {
         XauFailV(v, XAU_BLK_MARGIN, "projected margin is zero - account data not ready", 0, 0.0);
         return;
        }
      double projected_level = (equity / projected_margin) * 100.0;
      v.value = projected_level;
      if(m_cfg.MinimumFreeMarginPercent > 0.0 && projected_level < m_cfg.MinimumFreeMarginPercent)
        {
         XauFailV(v, XAU_BLK_MARGIN,
                  StringFormat("projected margin level %.1f%% < MinimumFreeMarginPercent %.1f%% (margin needed %s, free %s)",
                               projected_level, m_cfg.MinimumFreeMarginPercent,
                               XauMoney(need), XauMoney(AccountInfoDouble(ACCOUNT_MARGIN_FREE))), 0, projected_level);
         return;
        }
      if(m_cfg.MinimumFreeMarginMoney > 0.0)
        {
         double free_after = AccountInfoDouble(ACCOUNT_MARGIN_FREE) - need;
         if(free_after < m_cfg.MinimumFreeMarginMoney)
           {
            XauFailV(v, XAU_BLK_MARGIN,
                     StringFormat("free margin after this order %s < MinimumFreeMarginMoney %s",
                                  XauMoney(free_after), XauMoney(m_cfg.MinimumFreeMarginMoney)), 0, free_after);
            return;
           }
        }
      v.reason = StringFormat("margin ok: need %s, projected level %.1f%%", XauMoney(need), projected_level);
     }

   /// Margin that the whole projected basket would consume - used by the
   /// dashboard "next layer preview" and by the stress report.
   double ProjectedBasketMargin(const bool is_buy, const double total_volume, const double price)
     {
      double m = 0.0;
      if(!m_spec.EstimateMargin(is_buy, total_volume, price, m))
         return(-1.0);
      return(m);
     }

   string LastReason(void) const { return(m_reason); }
   ENUM_XAU_BLOCK LastCode(void) const { return(m_code); }
   double LastRawLot(void) const { return(m_raw); }
   double LastLot(void)    const { return(m_last_lot); }
  };

#endif // XAU_AVG_PRO_LOTS_MQH
//+------------------------------------------------------------------+
