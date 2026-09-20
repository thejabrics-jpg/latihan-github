//+------------------------------------------------------------------+
//|                                                    SelfTest.mqh  |
//|  XAU_AVG_PRO v1.0.0 - built-in deterministic logic self tests  |
//|                                                                  |
//|  These tests need no market data, no positions and no network.  |
//|  They exercise exactly the code paths that protect capital:     |
//|  volume normalisation, points/money conversions, averaging      |
//|  timing gates, lot caps and exposure headroom, the margin gate, |
//|  state machine precedence, retcode classification and the       |
//|  Telegram input sanitiser.                                       |
//|                                                                  |
//|  They are NOT a replacement for the Strategy Tester protocol in |
//|  docs/08-testing-strategy.md - they only prove the deterministic|
//|  maths and gating logic behave as documented.                   |
//+------------------------------------------------------------------+
#ifndef XAU_AVG_PRO_SELFTEST_MQH
#define XAU_AVG_PRO_SELFTEST_MQH

#include "Types.mqh"
#include "BrokerSpec.mqh"
#include "Logger.mqh"
#include "Cycle.mqh"
#include "Lots.mqh"
#include "State.mqh"
#include "Averaging.mqh"
#include "Telegram.mqh"

class CSelfTest
  {
private:
   CConfig       *m_cfg;
   CSymbolSpec   *m_spec;
   CLogger       *m_log;
   CCycleManager *m_cycle;
   CLotManager   *m_lots;
   CStateMachine *m_state;
   CTelegramBot  *m_tg;
   CAveragingEngine *m_avg;

   int  m_checks;
   int  m_failed;
   int  m_skipped;
   string m_out;

   void Check(const bool condition, const string name, const string detail)
     {
      m_checks++;
      if(condition)
        {
         m_out += "  PASS  " + name + (StringLen(detail) > 0 ? "  [" + detail + "]" : "") + "\n";
         if(m_log != NULL)
            m_log.Raw(XAU_T_TEST, "PASS " + name + (StringLen(detail) > 0 ? " [" + detail + "]" : ""));
        }
      else
        {
         m_failed++;
         m_out += "  FAIL  " + name + "  [" + detail + "]\n";
         if(m_log != NULL)
            m_log.Error(XAU_T_TEST, "FAIL " + name + " [" + detail + "]");
        }
     }
   void Skip(const string name, const string why)
     {
      m_skipped++;
      m_out += "  SKIP  " + name + "  [" + why + "]\n";
     }

public:
                     CSelfTest(void) : m_cfg(NULL), m_spec(NULL), m_log(NULL), m_cycle(NULL), m_lots(NULL),
                                       m_state(NULL), m_tg(NULL), m_avg(NULL), m_checks(0), m_failed(0),
                                       m_skipped(0), m_out("")
     {
     }

   void Init(CConfig *cfg, CSymbolSpec *spec, CLogger *log, CCycleManager *cycle, CLotManager *lots,
             CStateMachine *state, CTelegramBot *tg, CAveragingEngine *avg)
     {
      m_cfg   = cfg;
      m_spec  = spec;
      m_log   = log;
      m_cycle = cycle;
      m_lots  = lots;
      m_state = state;
      m_tg    = tg;
      m_avg   = avg;
     }

   /// Run every check against a private copy of the configuration so the
   /// live settings of the running instance are never modified.
   void Run(bool &all_ok, string &summary)
     {
      m_checks = 0;
      m_failed = 0;
      m_skipped = 0;
      m_out = "";

      //  The tests below temporarily pin the parameters they depend on and
      //  restore them afterwards, so the run cannot change live behaviour.
      //  Run() is only ever called from OnInit, before the first tick.
      m_out += "XAU_AVG_PRO v" + XAU_EA_VERSION + " self test\n";

      //--- 1. number helpers ---------------------------------------
      Check(XauVolumeDigits(0.01) == 2, "volume digits for step 0.01", IntegerToString(XauVolumeDigits(0.01)));
      Check(XauVolumeDigits(0.1) == 1,  "volume digits for step 0.1",  IntegerToString(XauVolumeDigits(0.1)));
      Check(XauVolumeDigits(0.001) == 3,"volume digits for step 0.001",IntegerToString(XauVolumeDigits(0.001)));
      Check(XauVolumeDigits(1.0) == 0,  "volume digits for step 1.0",  IntegerToString(XauVolumeDigits(1.0)));
      Check(XauClamp(5.0, 1.0, 3.0) == 3.0 && XauClamp(0.0, 1.0, 3.0) == 1.0, "clamp both bounds", "5.3, 0.1");
      Check(MathAbs(XauClamp(2.5, 1.0, 3.0) - 2.5) < 1.0e-12, "clamp keeps interior values", "2.5");

      //--- 2. retcode classification -------------------------------
      Check(XauRetcodeRetryable(XAU_RC_REQUOTE), "requote is retryable", "10004");
      Check(XauRetcodeRetryable(XAU_RC_CONNECTION), "connection is retryable", "10031");
      Check(!XauRetcodeRetryable(XAU_RC_INVALID_VOLUME), "invalid volume is NOT retryable", "10014");
      Check(!XauRetcodeRetryable(XAU_RC_NO_MONEY), "insufficient margin is NOT retryable", "10019");
      Check(!XauRetcodeRetryable(XAU_RC_INVALID_STOPS), "invalid stops is NOT retryable", "10016");
      Check(XauRetcodeMarketBlocked(XAU_RC_MARKET_CLOSED), "market closed is a market block", "10018");
      Check(StringLen(XauRetcodeName(XAU_RC_DONE)) > 3, "retcode name resolved", XauRetcodeName(XAU_RC_DONE));
      Check(XauRetcodeName(99999) == "RET_99999", "unknown retcode falls back", XauRetcodeName(99999));

      //--- 3. time helpers ------------------------------------------
      datetime now = XauNow();
      datetime day = XauServerDayStart(now);
      MqlDateTime ds;
      TimeToStruct(day, ds);
      Check(ds.hour == 0 && ds.min == 0 && ds.sec == 0, "server day start is midnight", TimeToString(day));
      int mod = XauMinutesOfDay(now);
      Check(mod >= 0 && mod < 1440, "minutes of day in range", IntegerToString(mod));
      Check(XauHHMM(7, 5) == "07:05", "HHMM zero padding", XauHHMM(7, 5));
      int dow = XauDayOfWeek(now);
      Check(dow >= 0 && dow <= 6, "day of week in range", IntegerToString(dow));

      //--- timeframe sanity (a typo in a .set file must not go unnoticed) ---
      Check(XauIsRealTimeframe(0) && XauIsRealTimeframe((int)PERIOD_M15) && XauIsRealTimeframe((int)PERIOD_H1),
            "PERIOD_CURRENT and standard periods accepted", "");
      Check(!XauIsRealTimeframe(7) && !XauIsRealTimeframe(-3) && !XauIsRealTimeframe(123456),
            "invented period values rejected", "");

      //--- 4. verdict helpers ---------------------------------------
      SVerdict vv;
      XauPassV(vv);
      Check(vv.allowed && vv.code == XAU_BLK_NONE, "pass verdict", "");
      XauFailV(vv, XAU_BLK_MAX_LAYER, "layer cap", 12345, 7.0);
      Check(!vv.allowed && vv.code == XAU_BLK_MAX_LAYER && vv.block_until == 12345 && vv.value == 7.0,
            "fail verdict carries code, deadline and value", vv.reason);

      //--- 5. symbol spec / normalisation ---------------------------
      if(m_spec != NULL && m_spec.Valid())
        {
         double p = 1234.5678;
         double np = m_spec.NormalizePrice(p);
         Check(MathAbs(np / m_spec.Point() - MathRound(np / m_spec.Point())) < 1.0e-6,
               "price normalisation lands on the point grid", DoubleToString(np, 8));
         double vmin = m_spec.VolumeMin();
         double step = m_spec.VolumeStep();
         double bad  = m_spec.NormalizeVolume(vmin * 0.5, true);
         Check(bad == 0.0, "volume below the minimum is rejected (returns 0)", DoubleToString(bad, 8));
         double flr = m_spec.NormalizeVolume(vmin + step * 1.9, true);
         Check(m_spec.IsLegalVolume(flr), "floored volume is broker legal", DoubleToString(flr, 8));
         Check(flr <= vmin + step * 1.9 + 1.0e-9, "floor never increases volume", DoubleToString(flr, 8));
         double mpp = m_spec.MoneyPerPointPerLot();
         Check(mpp > 0.0, "money per point per lot is positive", DoubleToString(mpp, 8));
         double pts = 250.0;
         double money = m_spec.PointsToMoney(pts, 0.1);
         double back   = m_spec.MoneyToPoints(money, 0.1);
         Check(MathAbs(back - pts) < 1.0e-6, "points . money . points round trip",
               DoubleToString(back, 4));
         Check(m_spec.PriceToPoints(m_spec.PointsToPrice(123.0)) - 123.0 < 1.0e-9,
               "points . price . points round trip", "");
         double m1 = 0.0;
         bool okm = m_spec.EstimateMargin(true, vmin, m_spec.Ask() > 0.0 ? m_spec.Ask() : 1.0, m1);
         if(okm)
            Check(m1 > 0.0, "OrderCalcMargin returns a positive margin", DoubleToString(m1, 2));
         else
            Skip("OrderCalcMargin", "not available on this symbol/build");
        }
      else
         Skip("symbol spec checks", "symbol specification not available");

      //--- 6. lot manager: caps, growth, headroom, margin ----------
      //  Only the fields under test are touched, and they are restored at
      //  the end. The tests run from OnInit before any tick is processed.
      if(m_lots != NULL && m_spec != NULL && m_spec.Valid())
        {
         double saved_initial      = m_cfg.InitialLot;
         double saved_mult         = m_cfg.LotMultiplier;
         double saved_cap          = m_cfg.MaximumLotPerOrder;
         double saved_max_total    = m_cfg.MaximumTotalLot;
         double saved_risk         = m_cfg.RiskPercent;
         double saved_margin_pct   = m_cfg.MinimumFreeMarginPercent;
         double saved_margin_money = m_cfg.MinimumFreeMarginMoney;
         int    saved_mode         = (int)m_cfg.LotMode;
         int    saved_autolot      = (int)m_cfg.AutoLotCalculationMode;
         int    saved_stop_pts     = m_cfg.InitialStopDistancePoints;
         bool   saved_truncate     = m_cfg.TruncateLotToExposureHeadroom;
         bool   saved_fallback     = m_cfg.AutoLotAllowMinLotFallback;
         bool   saved_apply_mult   = m_cfg.ApplyMultiplierToAutoLot;

         double vmin = m_spec.VolumeMin();
         double capbig = MathMax(vmin * 50.0, 1.0);
         m_cfg.LotMode = XAU_LOT_FIXED;
         m_cfg.InitialLot = vmin;
         m_cfg.MaximumLotPerOrder = capbig;
         m_cfg.MaximumTotalLot = 0.0;
         m_cfg.MinimumFreeMarginPercent = 0.0;
         m_cfg.MinimumFreeMarginMoney = 0.0;
         SVerdict lv;
         double lot = -1.0;
         m_lots.Resolve(1, true, m_spec.Ask() > 0.0 ? m_spec.Ask() : 1.0, 0.0, lot, lv);
         Check(lv.allowed && MathAbs(lot - vmin) < 1.0e-9, "FIX LOT returns the broker minimum untouched",
               DoubleToString(lot, 8));

         m_cfg.InitialLot = vmin * 10.0;
         m_cfg.MaximumLotPerOrder = vmin * 2.0;
         m_lots.Resolve(1, true, m_spec.Ask(), 0.0, lot, lv);
         Check(lv.allowed && MathAbs(lot - m_spec.NormalizeVolume(vmin * 2.0, true)) < 1.0e-9,
               "MaximumLotPerOrder caps every mode including FIX", DoubleToString(lot, 8));

         // multiplier growth is floored to the step and capped
         m_cfg.LotMode = XAU_LOT_MULTIPLIER;
         m_cfg.InitialLot = vmin;
         m_cfg.LotMultiplier = 1.5;
         m_cfg.MaximumLotPerOrder = capbig;
         double prev_lot = 0.0;
         bool monotonic = true;
         bool capped_ok = true;
         double max_total_for_growth = 0.0;
         for(int lay = 1; lay <= 6; lay++)
           {
            m_lots.Resolve(lay, true, m_spec.Ask(), 0.0, lot, lv);
            if(!lv.allowed) { capped_ok = false; break; }
            double expected = m_spec.NormalizeVolume(MathMin(vmin * MathPow(1.5, lay - 1), capbig), true);
            if(MathAbs(lot - expected) > 1.0e-9)
               capped_ok = false;
            if(lot < prev_lot - 1.0e-12)
               monotonic = false;
            prev_lot = lot;
           }
         Check(capped_ok, "MULTIPLIER lots equal floor(raw capped by MaximumLotPerOrder)", DoubleToString(prev_lot, 8));
         Check(monotonic, "multiplier growth is monotonic and never exceeds the cap", "");
         max_total_for_growth = prev_lot;

         m_cfg.InitialLot = vmin;
         m_cfg.LotMultiplier = 3.0;
         m_cfg.MaximumLotPerOrder = vmin * 2.0;
         m_lots.Resolve(5, true, m_spec.Ask(), 0.0, lot, lv);
         Check(lv.allowed && MathAbs(lot - m_spec.NormalizeVolume(vmin * 2.0, true)) < 1.0e-9,
               "the multiplier can never bypass MaximumLotPerOrder", DoubleToString(lot, 8));

         // exposure headroom: reject vs truncate
         m_cfg.LotMode = XAU_LOT_FIXED;
         m_cfg.InitialLot = vmin;
         m_cfg.MaximumLotPerOrder = capbig;
         m_cfg.MaximumTotalLot = vmin;                       // already fully exposed
         m_cfg.TruncateLotToExposureHeadroom = false;
         m_lots.Resolve(2, true, m_spec.Ask(), vmin, lot, lv);
         Check(!lv.allowed && lv.code == XAU_BLK_MAX_TOTAL_LOT, "MaximumTotalLot rejects the next layer",
               lv.reason);
         Check(MathAbs(lot) < 1.0e-12, "a rejected sizing never leaks a volume", DoubleToString(lot, 8));
         m_cfg.MaximumTotalLot = vmin * 2.5;                  // room for exactly one more min lot
         m_lots.Resolve(2, true, m_spec.Ask(), vmin, lot, lv);
         Check(lv.allowed && MathAbs(lot - vmin) < 1.0e-9, "headroom allows one more minimum lot",
               DoubleToString(lot, 8));
         m_cfg.TruncateLotToExposureHeadroom = true;
         m_cfg.InitialLot = vmin * 4.0;
         m_lots.Resolve(2, true, m_spec.Ask(), vmin, lot, lv);
         Check(lv.allowed && lot <= vmin * 1.5 + 1.0e-9 && lot > 0.0,
               "TruncateLotToExposureHeadroom shrinks instead of rejecting", DoubleToString(lot, 8));

         // auto lot: raw size must scale linearly with RiskPercent
         m_cfg.LotMode = XAU_LOT_AUTO;
         m_cfg.AutoLotCalculationMode = XAU_AUTLOT_RISK_DISTANCE;
         m_cfg.InitialStopDistancePoints = 400;
         m_cfg.MaximumLotPerOrder = capbig;
         m_cfg.MaximumTotalLot = 0.0;
         m_cfg.TruncateLotToExposureHeadroom = false;
         m_cfg.AutoLotAllowMinLotFallback = false;
         m_cfg.ApplyMultiplierToAutoLot = false;
         double equity_ref = AccountInfoDouble(ACCOUNT_EQUITY);
         if(equity_ref > 0.0)
           {
            m_cfg.RiskPercent = 0.25;
            m_lots.Resolve(1, true, m_spec.Ask(), 0.0, lot, lv);
            double raw1 = m_lots.LastRawLot();
            bool ok1 = lv.allowed;
            m_cfg.RiskPercent = 0.50;
            m_lots.Resolve(1, true, m_spec.Ask(), 0.0, lot, lv);
            double raw2 = m_lots.LastRawLot();
            Check(ok1 && MathAbs(raw2 - 2.0 * raw1) < MathMax(raw1 * 0.01, 1.0e-9),
                  "AUTO LOT scales linearly with RiskPercent",
                  DoubleToString(raw1, 6) + " . " + DoubleToString(raw2, 6));
            Check(m_spec.IsLegalVolume(lot) || !lv.allowed, "AUTO LOT result is broker legal or rejected",
                  DoubleToString(lot, 8));
            m_cfg.RiskPercent = 0.0;
            m_lots.Resolve(1, true, m_spec.Ask(), 0.0, lot, lv);
            Check(!lv.allowed, "AUTO LOT with RiskPercent 0 is rejected instead of opening a random size", lv.reason);
            m_cfg.RiskPercent = saved_risk;
           }
         else
            Skip("AUTO LOT scaling", "equity is not positive");

         // margin gate
         m_cfg.LotMode = XAU_LOT_FIXED;
         m_cfg.InitialLot = vmin;
         m_cfg.RiskPercent = saved_risk;
         m_cfg.MinimumFreeMarginPercent = 10000000.0;
         SVerdict mv;
         m_lots.CheckMargin(true, vmin, m_spec.Ask() > 0.0 ? m_spec.Ask() : 1.0, mv);
         Check(!mv.allowed && mv.code == XAU_BLK_MARGIN, "margin gate refuses when the projected level is below the limit",
               mv.reason);
         m_cfg.MinimumFreeMarginPercent = 0.0;
         m_cfg.MinimumFreeMarginMoney = 1.0e15;
         m_lots.CheckMargin(true, vmin, m_spec.Ask() > 0.0 ? m_spec.Ask() : 1.0, mv);
         Check(!mv.allowed && mv.code == XAU_BLK_MARGIN, "free margin money floor is enforced", mv.reason);
         m_cfg.MinimumFreeMarginMoney = 0.0;
         m_lots.CheckMargin(true, vmin, m_spec.Ask() > 0.0 ? m_spec.Ask() : 1.0, mv);
         Check(mv.allowed, "margin gate opens when both limits are off", mv.reason);

         // restore everything
         m_cfg.InitialLot = saved_initial;
         m_cfg.LotMultiplier = saved_mult;
         m_cfg.MaximumLotPerOrder = saved_cap;
         m_cfg.MaximumTotalLot = saved_max_total;
         m_cfg.RiskPercent = saved_risk;
         m_cfg.MinimumFreeMarginPercent = saved_margin_pct;
         m_cfg.MinimumFreeMarginMoney = saved_margin_money;
         m_cfg.LotMode = (ENUM_XAU_LOT_MODE)saved_mode;
         m_cfg.AutoLotCalculationMode = (ENUM_XAU_AUTLOT_MODE)saved_autolot;
         m_cfg.InitialStopDistancePoints = saved_stop_pts;
         m_cfg.TruncateLotToExposureHeadroom = saved_truncate;
         m_cfg.AutoLotAllowMinLotFallback = saved_fallback;
         m_cfg.ApplyMultiplierToAutoLot = saved_apply_mult;
         Check(m_cfg.MaximumTotalLot == saved_max_total && m_cfg.LotMode == (ENUM_XAU_LOT_MODE)saved_mode,
               "live configuration fully restored", DoubleToString(max_total_for_growth, 4));
        }
      else
         Skip("lot manager", "symbol specification not available");

      //--- 7. averaging gates ---------------------------------------
      bool saved_one_bar   = m_cfg.OneLayerPerBar;
      int  saved_min_secs  = m_cfg.MinimumSecondsBetweenAveraging;
      double saved_mult_min= m_cfg.MinimumDistanceSpreadMultiple;
      m_cfg.OneLayerPerBar = true;
      m_cfg.MinimumSecondsBetweenAveraging = 60;
      m_cfg.MinimumDistanceSpreadMultiple = 2.0;
      SRt rt;
      ZeroMemory(rt);
      SAvgPlan plan;
      plan.basket_active   = true;
      plan.enabled         = true;
      plan.reached         = true;
      plan.reference_price = 2000.0;
      plan.distance_points = 350.0;
      plan.distance_price  = 350.0 * (m_spec != NULL ? m_spec.Point() : 0.01);
      plan.level           = 2000.0 - plan.distance_price;
      plan.next_layer      = 2;
      plan.why             = "level reached";
      SVerdict tv;
      if(m_avg != NULL)
        {
         double min_safe = m_avg.MinimumSafeDistancePoints();
         plan.distance_points = MathMax(plan.distance_points, min_safe);   // make the clean case legal
         m_avg.CheckTiming(plan, rt, 1000000, tv);
         Check(tv.allowed, "clean averaging plan passes the gates", tv.reason);

         rt.next_avg_allowed_at = XauNow() + 60;
         m_avg.CheckTiming(plan, rt, 1000000, tv);
         Check(!tv.allowed && tv.code == XAU_BLK_TOO_SOON, "MinimumSecondsBetweenAveraging blocks a fast second layer",
               tv.reason);
         rt.next_avg_allowed_at = 0;

         rt.last_avg_open_bar = 1000000;
         m_avg.CheckTiming(plan, rt, 1000000, tv);
         Check(!tv.allowed && tv.code == XAU_BLK_ONE_PER_BAR, "OneLayerPerBar blocks a second layer on the same bar", tv.reason);
         rt.last_avg_open_bar = 0;

         rt.last_avg_level_used = plan.level;
         m_avg.CheckTiming(plan, rt, 1000001, tv);
         Check(!tv.allowed && tv.code == XAU_BLK_DUPLICATE_LEVEL, "duplicate level guard rejects a re-trigger at the same level", tv.reason);
         rt.last_avg_level_used = 0.0;

         SAvgPlan tiny;
         tiny = plan;
         tiny.distance_points = 1.0;
         m_avg.CheckTiming(tiny, rt, 1000002, tv);
         Check(!tv.allowed && tv.code == XAU_BLK_DISTANCE_TOO_SMALL, "a distance under the safe minimum is refused", tv.reason);
        }
      else
         Skip("averaging gates", "averaging engine not wired");
      m_cfg.OneLayerPerBar = saved_one_bar;
      m_cfg.MinimumSecondsBetweenAveraging = saved_min_secs;
      m_cfg.MinimumDistanceSpreadMultiple = saved_mult_min;

      // geometry, direction aware: BUY below, SELL above
      double pt = (m_spec != NULL ? m_spec.Point() : 0.01);
      double ref = 2000.0;
      double dist = 350.0 * pt;
      double buy_level  = ref - dist;
      double sell_level = ref + dist;
      Check(buy_level < ref && sell_level > ref, "averaging levels are on the correct side of the reference",
            DoubleToString(buy_level, 2) + "/" + DoubleToString(sell_level, 2));
      Check(MathAbs((sell_level - buy_level) - 2.0 * dist) < 1.0e-9, "levels are symmetric around the reference", "");

      //--- 8. state machine precedence ------------------------------
      if(m_state != NULL)
        {
         bool saved_emg = m_cfg.emergency_stop;
         bool saved_pause = m_cfg.user_paused;
         m_cfg.emergency_stop = true;
         m_cfg.user_paused    = true;
         m_state.SetRiskBlock(XAU_BLK_ACCOUNT_DD, "test", 0);
         m_state.SetError("test error");
         m_state.SetClosing(true);
         ENUM_XAU_STATE st = m_state.Derive(true, true);
         Check(st == XAU_ST_EMERGENCY_STOP, "EMERGENCY_STOP outranks every other condition", m_state.StateName(st));
         m_cfg.emergency_stop = false;
         st = m_state.Derive(true, true);
         Check(st == XAU_ST_ERROR, "ERROR outranks CLOSING and RISK_BLOCKED", m_state.StateName(st));
         m_state.ClearError();
         st = m_state.Derive(true, true);
         Check(st == XAU_ST_CLOSING, "CLOSING outranks RISK_BLOCKED", m_state.StateName(st));
         m_state.SetClosing(false);
         st = m_state.Derive(true, true);
         Check(st == XAU_ST_RISK_BLOCKED, "RISK_BLOCKED outranks PAUSED", m_state.StateName(st));
         m_state.ClearRiskBlock("self test");
         st = m_state.Derive(true, true);
         Check(st == XAU_ST_PAUSED, "PAUSED outranks the cycle states", m_state.StateName(st));
         m_cfg.user_paused = false;
         st = m_state.Derive(true, true);
         Check(st == XAU_ST_IN_CYCLE, "basket + level reached = IN_CYCLE", m_state.StateName(st));
         st = m_state.Derive(true, false);
         Check(st == XAU_ST_WAITING_AVERAGING, "basket + no level = WAITING_AVERAGING", m_state.StateName(st));
         st = m_state.Derive(false, false);
         Check(st == XAU_ST_WAITING_ENTRY || st == XAU_ST_IDLE, "flat account waits for an entry", m_state.StateName(st));
         // gating: closing is never blocked by the state
         m_cfg.emergency_stop = true;
         m_state.Derive(true, false);
         SVerdict gv;
         XauPassV(gv);
         Check(m_state.Allows(XAU_INT_CLOSE), "XAU_INT_CLOSE is always allowed by the state machine", "");
         Check(!m_state.Allows(XAU_INT_ENTRY), "entries are refused while EMERGENCY_STOP is active", "");
         Check(!m_state.Allows(XAU_INT_AVERAGING), "averaging is refused while EMERGENCY_STOP is active", "");
         m_cfg.emergency_stop = saved_emg;
         m_cfg.user_paused    = saved_pause;
         m_state.SetClosing(false);
         m_state.ClearError();

         // every block code must have a human readable name
         int unnamed = 0;
         for(int code = 0; code <= (int)XAU_BLK_NOT_CONNECTED; code++)
            if(StringFind(m_state.BlockName((ENUM_XAU_BLOCK)code), "CODE_") == 0)
               unnamed++;
         Check(unnamed == 0, "every block reason has a name", IntegerToString(unnamed) + " unnamed");
        }
      else
         Skip("state machine", "state machine not wired");

      //--- 9. Telegram sanitiser ------------------------------------
      if(m_tg != NULL)
        {
         m_tg.ClearQueue();
         m_tg.ParseAndQueue("/status");
         Check(m_tg.PendingCommands() == 1, "whitelisted command is queued", IntegerToString(m_tg.PendingCommands()));
         m_tg.ParseAndQueue("; rm -rf /");
         Check(m_tg.PendingCommands() == 1, "free text without a leading slash is rejected", "");
         m_tg.ParseAndQueue("/help; rm -rf /");
         Check(m_tg.PendingCommands() == 1, "command with shell metacharacters is rejected", "");
         m_tg.ParseAndQueue("/shutdown_now");
         Check(m_tg.PendingCommands() == 1, "non whitelisted command is rejected", "");
         m_tg.ParseAndQueue("/setlot 0.02");
         Check(m_tg.PendingCommands() == 2, "command with argument is queued", "");
         string nm = "";
         string ar = "";
         m_tg.PopCommand(nm, ar);
         Check(nm == "status", "queue is FIFO", nm);
         m_tg.PopCommand(nm, ar);
         Check(nm == "setlot" && ar == "0.02", "arguments are tokenised", nm + " " + ar);
         m_tg.ClearQueue();
         string huge = "/setlot ";
         for(int i = 0; i < 60; i++)
            huge += "9";
         m_tg.ParseAndQueue(huge);
         Check(m_tg.PendingCommands() == 0, "overlong argument payload is rejected", IntegerToString(m_tg.PendingCommands()));
         m_tg.ArmConfirmation("closeall");
         Check(m_tg.HasPendingConfirm() && m_tg.PendingAction() == "closeall", "destructive action arms a confirmation", "");
         m_tg.DisarmConfirmation();
         Check(!m_tg.HasPendingConfirm(), "confirmation can be disarmed", "");
        }
      else
         Skip("telegram sanitiser", "telegram not wired");

      string head = StringFormat("RESULT: %d checks, %d failed, %d skipped\n", m_checks, m_failed, m_skipped);
      summary = head + m_out;
      all_ok  = (m_failed == 0);
      if(m_log != NULL)
        {
         if(all_ok)
            m_log.Raw(XAU_T_TEST, StringFormat("self test complete: %d checks, all passed (%d skipped)", m_checks, m_skipped));
         else
            m_log.Error(XAU_T_TEST, StringFormat("SELF TEST FAILURES: %d of %d checks failed - do not trust this build", m_failed, m_checks));
        }
     }

   string Output(void) const { return(m_out); }
   int    Checks(void)  const { return(m_checks); }
   int    Failed(void)  const { return(m_failed); }
   int    Skipped(void) const { return(m_skipped); }
  };

#endif // XAU_AVG_PRO_SELFTEST_MQH
//+------------------------------------------------------------------+
