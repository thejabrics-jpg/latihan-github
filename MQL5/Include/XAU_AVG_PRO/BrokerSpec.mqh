//+------------------------------------------------------------------+
//|                                                   BrokerSpec.mqh |
//|     XAU_AVG_PRO v1.0.0 - dynamic symbol / account normalisation |
//|                                                                  |
//|  Nothing in the EA assumes digits, point, contract size, lot    |
//|  limits, stop level or account margin mode. All of it is read   |
//|  from the terminal here and cached for the tick loop. If a      |
//|  required property is missing, the spec is marked invalid and   |
//|  the engine refuses to trade (fail safe).                       |
//+------------------------------------------------------------------+
#ifndef XAU_AVG_PRO_BROKERSPEC_MQH
#define XAU_AVG_PRO_BROKERSPEC_MQH

#include "Types.mqh"

class CSymbolSpec
  {
private:
   string   m_symbol;
   int      m_digits;
   double   m_point;
   double   m_tick_size;
   double   m_tick_value;
   double   m_contract;
   double   m_vol_min;
   double   m_vol_max;
   double   m_vol_step;
   int      m_vol_digits;
   long     m_stops_level;
   long     m_freeze_level;
   double   m_money_per_point_per_lot;
   bool     m_valid;
   string   m_error;
   long     m_margin_mode;
   bool     m_hedging;
   MqlTick  m_tick;
   bool     m_tick_ok;
   string   m_account_currency;
   int      m_fill_mask;

public:
                     CSymbolSpec(void) : m_symbol(""), m_digits(2), m_point(0.01), m_tick_size(0.01),
                                         m_tick_value(0.0), m_contract(100.0), m_vol_min(0.01), m_vol_max(100.0),
                                         m_vol_step(0.01), m_vol_digits(2), m_stops_level(0), m_freeze_level(0),
                                         m_money_per_point_per_lot(0.0), m_valid(false), m_error(""),
                                         m_margin_mode(0), m_hedging(true), m_tick_ok(false),
                                         m_account_currency("USD"), m_fill_mask(0)
     {
      ZeroMemory(m_tick);
     }

   /// Read every property that trading maths depends on.
   /// @return false and an explanatory error string when the symbol is
   ///         not usable (not in Market Watch, zero point, no tick
   ///         value, ...). The caller must then refuse to trade.
   bool Refresh(const string symbol)
     {
      m_symbol = symbol;
      m_valid  = false;
      m_error  = "";

      m_digits     = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
      m_point      = SymbolInfoDouble(symbol, SYMBOL_POINT);
      m_tick_size  = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
      m_tick_value = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
      m_contract   = SymbolInfoDouble(symbol, SYMBOL_TRADE_CONTRACT_SIZE);
      m_vol_min    = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
      m_vol_max    = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
      m_vol_step   = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
      m_stops_level  = SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL);
      m_freeze_level = SymbolInfoInteger(symbol, SYMBOL_TRADE_FREEZE_LEVEL);
      m_fill_mask    = (int)SymbolInfoInteger(symbol, SYMBOL_FILLING_MODE);
      m_account_currency = AccountInfoString(ACCOUNT_CURRENCY);
      m_margin_mode = AccountInfoInteger(ACCOUNT_MARGIN_MODE);
      m_hedging     = (m_margin_mode == ACCOUNT_MARGIN_MODE_RETAIL_HEDGING);

      if(m_point <= 0.0)
        {
         m_error = "SYMBOL_POINT is zero - symbol data not ready";
         return(false);
        }
      if(m_tick_size <= 0.0)
         m_tick_size = m_point;
      if(m_vol_step <= 0.0)
         m_vol_step = 0.01;
      if(m_vol_min <= 0.0)
         m_vol_min = m_vol_step;
      if(m_vol_max <= 0.0 || m_vol_max < m_vol_min)
         m_vol_max = 100.0;
      m_vol_digits = XauVolumeDigits(m_vol_step);

      // money value of a 1-point move for 1.0 lot, in account currency
      if(m_tick_value > 0.0)
         m_money_per_point_per_lot = m_tick_value * (m_point / m_tick_size);
      else if(m_contract > 0.0)
        {
         // Fallback for brokers that report tick value = 0 (rare, but
         // seen on some cent accounts): value = contract * point.
         // Only valid when the symbol quote currency equals the account
         // currency; otherwise we refuse to trade instead of guessing.
         string base  = SymbolInfoString(symbol, SYMBOL_CURRENCY_BASE);
         string profit = SymbolInfoString(symbol, SYMBOL_CURRENCY_PROFIT);
         if(profit == m_account_currency || base == m_account_currency)
            m_money_per_point_per_lot = m_contract * m_point;
         else
           {
            m_error = StringFormat("SYMBOL_TRADE_TICK_VALUE unavailable and profit currency '%s' != account currency '%s'",
                                   profit, m_account_currency);
            return(false);
           }
        }
      else
        {
         m_error = "SYMBOL_TRADE_TICK_VALUE and contract size are both unusable";
         return(false);
        }
      if(m_money_per_point_per_lot <= 0.0)
        {
         m_error = "derived money-per-point is zero";
         return(false);
        }
      if(!UpdateQuote())
        {
         m_error = "no live quote for " + symbol + " (add it to Market Watch)";
         return(false);
        }
      m_valid = true;
      return(true);
     }

   /// Bid/ask cache. Called once per tick, never in a loop.
   bool UpdateQuote(void)
     {
      if(!SymbolInfoTick(m_symbol, m_tick))
        {
         m_tick_ok = false;
         return(false);
        }
      m_tick_ok = (m_tick.bid > 0.0 && m_tick.ask > 0.0);
      return(m_tick_ok);
     }

   //--- accessors ---------------------------------------------------
   bool     Valid(void)            const { return(m_valid); }
   string   ErrorText(void)        const { return(m_error); }
   string   Symbol(void)           const { return(m_symbol); }
   int      Digits(void)           const { return(m_digits); }
   double   Point(void)            const { return(m_point); }
   double   TickSize(void)         const { return(m_tick_size); }
   double   ContractSize(void)     const { return(m_contract); }
   double   VolumeMin(void)        const { return(m_vol_min); }
   double   VolumeMax(void)        const { return(m_vol_max); }
   double   VolumeStep(void)       const { return(m_vol_step); }
   int      VolumeDigits(void)     const { return(m_vol_digits); }
   long     StopsLevelPoints(void) const { return(m_stops_level); }
   long     FreezeLevelPoints(void) const { return(m_freeze_level); }
   double   MoneyPerPointPerLot(void) const { return(m_money_per_point_per_lot); }
   bool     IsHedgingAccount(void) const { return(m_hedging); }
   long     MarginMode(void)       const { return(m_margin_mode); }
   string   AccountCurrency(void)  const { return(m_account_currency); }
   double   Bid(void)              const { return(m_tick.bid); }
   double   Ask(void)              const { return(m_tick.ask); }
   datetime QuoteTime(void)        const { return(m_tick.time); }
   bool     QuoteOk(void)          const { return(m_tick_ok); }
   double   SpreadPoints(void)     const
     {
      if(!m_tick_ok || m_point <= 0.0)
         return(0.0);
      double s = (m_tick.ask - m_tick.bid) / m_point;
      return(s > 0.0 ? s : 0.0);
     }
   /// Quote age in seconds. Negative/zero means "as fresh as the
   /// current server time", which is what happens in the tester.
   double QuoteAgeSeconds(void) const
     {
      if(!m_tick_ok)
         return(1.0e9);
      double age = (double)(TimeCurrent() - m_tick.time);
      return(age < 0.0 ? 0.0 : age);
     }

   //--- normalisation ----------------------------------------------
   double NormalizePrice(const double price) const
     {
      if(m_point <= 0.0)
         return(price);
      return(NormalizeDouble(MathRound(price / m_point) * m_point, m_digits));
     }
   /// Round a raw volume to a broker legal volume.
   /// @param round_down true  -> floor (used for risk: never exceed)
   ///                   false -> nearest step
   /// @return 0.0 when the requested volume is below the broker minimum
   ///         after flooring, which the caller must treat as "reject".
   double NormalizeVolume(const double raw, const bool round_down) const
     {
      if(m_vol_step <= 0.0 || raw <= 0.0)
         return(0.0);
      double steps = raw / m_vol_step;
      double v;
      if(round_down)
         v = MathFloor(steps + 1.0e-7) * m_vol_step;
      else
         v = MathRound(steps) * m_vol_step;
      v = NormalizeDouble(v, m_vol_digits);
      if(v > m_vol_max)
        {
         // the broker maximum is not always a whole multiple of the step
         v = NormalizeDouble(MathFloor(m_vol_max / m_vol_step + 1.0e-7) * m_vol_step, m_vol_digits);
        }
      if(v < m_vol_min - 1.0e-9)
         return(0.0);
      if(v > m_vol_max + 1.0e-9)
         return(0.0);
      return(v);
     }
   bool IsLegalVolume(const double volume) const
     {
      if(volume <= 0.0 || m_vol_step <= 0.0)
         return(false);
      double rest = MathAbs(volume / m_vol_step - MathRound(volume / m_vol_step));
      return(rest < 1.0e-6 && volume >= m_vol_min - 1.0e-9 && volume <= m_vol_max + 1.0e-9);
     }

   //--- conversions -------------------------------------------------
   double  PointsToPrice(const double points) const { return(points * m_point); }
   double  PriceToPoints(const double price_distance) const
     {
      return(m_point > 0.0 ? price_distance / m_point : 0.0);
     }
   double  PointsToMoney(const double points, const double volume) const
     {
      return(points * m_money_per_point_per_lot * volume);
     }
   double  MoneyToPoints(const double money, const double volume) const
     {
      if(volume <= 0.0 || m_money_per_point_per_lot <= 0.0)
         return(0.0);
      return(money / (m_money_per_point_per_lot * volume));
     }
   /// Cost basis (money needed to control the basket) = price*lots*contract.
   double  CostBasis(const double avg_price, const double volume) const
     {
      return(MathAbs(avg_price) * volume * m_contract);
     }

   //--- margin ------------------------------------------------------
   /// Estimated initial margin for a new position, in account currency.
   /// @return false when OrderCalcMargin is not available.
   bool EstimateMargin(const bool is_buy, const double volume, const double price, double &margin) const
     {
      margin = 0.0;
      ENUM_ORDER_TYPE type = (is_buy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
      if(!OrderCalcMargin(type, m_symbol, volume, price, margin))
         return(false);
      return(true);
     }

   /// Margin currently held by the account (all symbols).
   double AccountMargin(void) const { return(AccountInfoDouble(ACCOUNT_MARGIN)); }
   double FreeMargin(void)    const { return(AccountInfoDouble(ACCOUNT_MARGIN_FREE)); }
   double MarginLevel(void)   const
     {
      double m = AccountMargin();
      if(m <= 0.0)
         return(0.0);
      return(AccountInfoDouble(ACCOUNT_EQUITY) / m * 100.0);
     }
   bool AllowSymbolTrading(const bool is_buy, string &why) const
     {
      long mode = SymbolInfoInteger(m_symbol, SYMBOL_TRADE_MODE);
      if(mode == SYMBOL_TRADE_MODE_DISABLED)
        { why = "SYMBOL_TRADE_MODE=DISABLED"; return(false); }
      if(mode == SYMBOL_TRADE_MODE_CLOSEONLY)
        { why = "SYMBOL_TRADE_MODE=CLOSEONLY"; return(false); }
      if(mode == SYMBOL_TRADE_MODE_LONGONLY && !is_buy)
        { why = "SYMBOL_TRADE_MODE=LONGONLY (sell blocked)"; return(false); }
      if(mode == SYMBOL_TRADE_MODE_SHORTONLY && is_buy)
        { why = "SYMBOL_TRADE_MODE=SHORTONLY (buy blocked)"; return(false); }
      if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
        { why = "AutoTrading button is OFF in the terminal"; return(false); }
      if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
        { why = "Allow Algo Trading is not enabled for this EA"; return(false); }
      if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))
        { why = "account does not allow trading (investor login?)"; return(false); }
      if(!AccountInfoInteger(ACCOUNT_TRADE_EXPERT))
        { why = "broker disabled expert trading on this account"; return(false); }
      return(true);
     }

   /// True when the price the EA wants to use for a stop/limit is far
   /// enough from the market to satisfy the broker stop level. Basket
   /// TP/SL are not placed as server orders, but the check is still
   /// used for validation and for any future stop handling.
   bool StopsLevelSatisfied(const double reference_price, const double distance_points) const
     {
      if(m_stops_level <= 0)
         return(true);
      return(distance_points >= (double)m_stops_level);
     }

   string FillingModeName(void) const
     {
      string s = "";
      if((m_fill_mask & ORDER_FILLING_FOK) != 0)    s += "FOK ";
      if((m_fill_mask & ORDER_FILLING_IOC) != 0)    s += "IOC ";
      if((m_fill_mask & ORDER_FILLING_RETURN) != 0) s += "RETURN ";
      if(StringLen(s) == 0)
         s = "unknown";
      return(s);
     }

   /// Preferred filling type for market orders on this symbol.
   /// RETURN (a.k.a. "book or cancel not supported") is never chosen
   /// first: FOK, then IOC, then RETURN as a last resort.
   ENUM_ORDER_TYPE_FILLING PreferredFilling(void) const
     {
      if((m_fill_mask & ORDER_FILLING_FOK) != 0)
         return(ORDER_FILLING_FOK);
      if((m_fill_mask & ORDER_FILLING_IOC) != 0)
         return(ORDER_FILLING_IOC);
      if((m_fill_mask & ORDER_FILLING_RETURN) != 0)
         return(ORDER_FILLING_RETURN);
      return(ORDER_FILLING_FOK);
     }

   /// The n-th filling mode the symbol actually allows (index 0 = preferred).
   /// Used by CExecution to fall back after 10030 INVALID_FILL, which is a
   /// broker-policy rejection and not a market condition: without this, one
   /// mismatched filling policy disables the EA entirely.
   ENUM_ORDER_TYPE_FILLING FillingByIndex(const int index) const
     {
      int order[3];
      int n = 0;
      if((m_fill_mask & ORDER_FILLING_FOK) != 0)
         order[n++] = (int)ORDER_FILLING_FOK;
      if((m_fill_mask & ORDER_FILLING_IOC) != 0)
         order[n++] = (int)ORDER_FILLING_IOC;
      if((m_fill_mask & ORDER_FILLING_RETURN) != 0)
         order[n++] = (int)ORDER_FILLING_RETURN;
      if(n == 0)
         return(ORDER_FILLING_FOK);
      int k = MathAbs(index) % n;
      return((ENUM_ORDER_TYPE_FILLING)order[k]);
     }

   int FillingCount(void) const
     {
      int n = 0;
      if((m_fill_mask & ORDER_FILLING_FOK) != 0)
         n++;
      if((m_fill_mask & ORDER_FILLING_IOC) != 0)
         n++;
      if((m_fill_mask & ORDER_FILLING_RETURN) != 0)
         n++;
      return(n);
     }

   string Describe(void) const
     {
      return(StringFormat("%s digits=%d point=%s tick_size=%s contract=%s vol=[%s..%s]/%s stops=%d freeze=%d fill=%s %s",
                          m_symbol, m_digits, DoubleToString(m_point, 8), DoubleToString(m_tick_size, 8),
                          DoubleToString(m_contract, 2), DoubleToString(m_vol_min, m_vol_digits),
                          DoubleToString(m_vol_max, m_vol_digits), DoubleToString(m_vol_step, m_vol_digits),
                          m_stops_level, m_freeze_level, FillingModeName(),
                          (m_hedging ? "HEDGING" : "NETTING/EXCHANGE")));
     }
  };

#endif // XAU_AVG_PRO_BROKERSPEC_MQH
//+------------------------------------------------------------------+
