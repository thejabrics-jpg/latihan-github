//+------------------------------------------------------------------+
//|                                                       Types.mqh  |
//|              XAU_AVG_PRO v1.0.0 - shared types and configuration |
//|                                                                  |
//|  Contents:                                                       |
//|    - version / naming constants                                  |
//|    - trade server return code constants (numeric, self defined) |
//|    - all enumerations used by the EA                             |
//|    - CConfig  : runtime copy of every input parameter           |
//|    - small data holders (SRt, SLayerRec, SCycleData, SDayStats) |
//|                                                                  |
//|  NOTE: this file contains NO trading logic. It is the single    |
//|  place where the vocabulary of the system is defined.           |
//+------------------------------------------------------------------+
#ifndef XAU_AVG_PRO_TYPES_MQH
#define XAU_AVG_PRO_TYPES_MQH

//------------------------------------------------------------------//
// Versioning and identity                                          |
//------------------------------------------------------------------//
#define XAU_EA_NAME          "XAU_AVG_PRO"
#define XAU_EA_VERSION       "1.0.0"
#define XAU_STATE_FORMAT     1
#define XAU_OBJ_PREFIX       "XAAP_"
#define XAU_STATE_FILE       "XAU_AVG_PRO"
#define XAU_MAX_LAYERS_HARD  50

// Log tags - keep every log line machine searchable.
#define XAU_T_INIT       "INIT"
#define XAU_T_ENTRY      "ENTRY"
#define XAU_T_AVG        "AVERAGING"
#define XAU_T_TP         "BASKET_TP"
#define XAU_T_CUT        "CUT_LOSS"
#define XAU_T_RISK       "RISK_BLOCK"
#define XAU_T_MAXLAYER   "MAX_LAYER"
#define XAU_T_MAXLOT     "MAX_LOT"
#define XAU_T_MAXDD      "MAX_DD"
#define XAU_T_SPREAD     "SPREAD_BLOCK"
#define XAU_T_NEWS       "NEWS_BLOCK"
#define XAU_T_SESSION    "SESSION_BLOCK"
#define XAU_T_TG         "TELEGRAM"
#define XAU_T_EXEC       "EXEC"
#define XAU_T_STATE      "STATE"
#define XAU_T_STATS      "STATS"
#define XAU_T_DASH       "DASHBOARD"
#define XAU_T_FILTER     "FILTER"
#define XAU_T_CFG        "CONFIG"
#define XAU_T_TEST       "SELFTEST"
#define XAU_T_ERR        "ERROR"

//------------------------------------------------------------------//
// Trade server return codes                                        |
// Values are taken from the MQL5 reference (Trade Server Return    |
// Codes). They are redefined here with an XAU_ prefix so the build |
// does not depend on which SDK constants a given terminal exposes. |
//------------------------------------------------------------------//
#define XAU_RC_REQUOTE             10004
#define XAU_RC_REJECT              10006
#define XAU_RC_CANCEL              10007
#define XAU_RC_PLACED              10008
#define XAU_RC_DONE                10009
#define XAU_RC_DONE_PARTIAL        10010
#define XAU_RC_ERROR               10011
#define XAU_RC_TIMEOUT             10012
#define XAU_RC_INVALID_REQUEST     10013
#define XAU_RC_INVALID_VOLUME      10014
#define XAU_RC_INVALID_PRICE       10015
#define XAU_RC_INVALID_STOPS       10016
#define XAU_RC_TRADE_DISABLED      10017
#define XAU_RC_MARKET_CLOSED       10018
#define XAU_RC_NO_MONEY            10019
#define XAU_RC_PRICE_CHANGED       10020
#define XAU_RC_PRICE_OFF           10021
#define XAU_RC_INVALID_EXPIRATION  10022
#define XAU_RC_ORDER_CHANGED       10023
#define XAU_RC_TOO_MANY_REQUESTS   10024
#define XAU_RC_NO_CHANGES          10025
#define XAU_RC_SERVER_DISABLES_AT  10026
#define XAU_RC_CLIENT_DISABLES_AT  10027
#define XAU_RC_LOCKED              10028
#define XAU_RC_FROZEN              10029
#define XAU_RC_INVALID_FILL        10030
#define XAU_RC_CONNECTION          10031
#define XAU_RC_ONLY_REAL           10032
#define XAU_RC_LIMIT_ORDERS        10033
#define XAU_RC_LIMIT_VOLUME        10034
#define XAU_RC_INVALID_ORDER       10035
#define XAU_RC_POSITION_CLOSED     10036
#define XAU_RC_INVALID_CLOSE_VOL   10038
#define XAU_RC_CLOSE_ORDER_EXIST   10039
#define XAU_RC_LIMIT_POSITIONS     10040
#define XAU_RC_LONG_ONLY           10042
#define XAU_RC_SHORT_ONLY          10043
#define XAU_RC_CLOSE_ONLY          10044
#define XAU_RC_FIFO_CLOSE          10045
#define XAU_RC_HEDGE_PROHIBITED    10046

/// Human readable meaning of a trade server return code.
/// @param retcode  value returned in MqlTradeResult::retcode
string XauRetcodeName(const int retcode)
  {
   switch(retcode)
     {
      case XAU_RC_REQUOTE:            return("REQUOTE");
      case XAU_RC_REJECT:             return("REJECT");
      case XAU_RC_CANCEL:             return("CANCEL");
      case XAU_RC_PLACED:             return("PLACED");
      case XAU_RC_DONE:               return("DONE");
      case XAU_RC_DONE_PARTIAL:       return("DONE_PARTIAL");
      case XAU_RC_ERROR:              return("PROCESSING_ERROR");
      case XAU_RC_TIMEOUT:            return("TIMEOUT");
      case XAU_RC_INVALID_REQUEST:    return("INVALID_REQUEST");
      case XAU_RC_INVALID_VOLUME:     return("INVALID_VOLUME");
      case XAU_RC_INVALID_PRICE:      return("INVALID_PRICE");
      case XAU_RC_INVALID_STOPS:      return("INVALID_STOPS");
      case XAU_RC_TRADE_DISABLED:     return("TRADE_DISABLED");
      case XAU_RC_MARKET_CLOSED:      return("MARKET_CLOSED");
      case XAU_RC_NO_MONEY:           return("INSUFFICIENT_MARGIN");
      case XAU_RC_PRICE_CHANGED:      return("PRICE_CHANGED");
      case XAU_RC_PRICE_OFF:          return("NO_QUOTES");
      case XAU_RC_TOO_MANY_REQUESTS:  return("TOO_MANY_REQUESTS");
      case XAU_RC_SERVER_DISABLES_AT: return("AUTOTRADING_DISABLED_BY_SERVER");
      case XAU_RC_CLIENT_DISABLES_AT: return("AUTOTRADING_DISABLED_BY_CLIENT");
      case XAU_RC_INVALID_FILL:       return("INVALID_FILLING");
      case XAU_RC_CONNECTION:         return("NO_CONNECTION");
      case XAU_RC_LIMIT_VOLUME:       return("VOLUME_LIMIT");
      case XAU_RC_LIMIT_POSITIONS:    return("POSITION_LIMIT");
      case XAU_RC_INVALID_CLOSE_VOL:  return("INVALID_CLOSE_VOLUME");
      case XAU_RC_CLOSE_ORDER_EXIST:  return("CLOSE_ORDER_EXISTS");
      case XAU_RC_FIFO_CLOSE:         return("FIFO_CLOSE_REQUIRED");
      case XAU_RC_HEDGE_PROHIBITED:   return("HEDGE_PROHIBITED");
     }
   return("RET_" + IntegerToString(retcode));
  }

/// True when a failure may legally be retried with the same parameters.
/// Anything that is a property of the request itself (volume, stops,
/// filling, permissions) is NOT retryable - retrying those only spams
/// the broker and can create duplicate exposure after a timeout.
bool XauRetcodeRetryable(const int retcode)
  {
   switch(retcode)
     {
      case XAU_RC_REQUOTE:
      case XAU_RC_PRICE_CHANGED:
      case XAU_RC_PRICE_OFF:
      case XAU_RC_CONNECTION:
      case XAU_RC_TOO_MANY_REQUESTS:
      case XAU_RC_LOCKED:
      case XAU_RC_TIMEOUT:
        return(true);
     }
   return(false);
  }

/// True when the failure means "the market/terminal currently refuses
/// trading" - used to suppress entry without entering an error state.
bool XauRetcodeMarketBlocked(const int retcode)
  {
   return(retcode == XAU_RC_MARKET_CLOSED ||
          retcode == XAU_RC_TRADE_DISABLED ||
          retcode == XAU_RC_SERVER_DISABLES_AT ||
          retcode == XAU_RC_CLIENT_DISABLES_AT ||
          retcode == XAU_RC_NO_CHANGES);
  }

//------------------------------------------------------------------//
// Enumerations                                                     |
//------------------------------------------------------------------//
enum ENUM_XAU_DIRECTION
  {
   XAU_DIR_BOTH      = 0,   // BOTH
   XAU_DIR_BUY_ONLY  = 1,   // BUY_ONLY
   XAU_DIR_SELL_ONLY = 2    // SELL_ONLY
  };

enum ENUM_XAU_ENTRY_CONFIRM
  {
   XAU_CONFIRM_CLOSE_BAR = 0,  // closed bar (recommended)
   XAU_CONFIRM_CURRENT_BAR = 1 // current bar (repaints)
  };

enum ENUM_XAU_CANDLE_FILTER
  {
   XAU_CANDLE_NONE        = 0, // off
   XAU_CANDLE_BODY_DIR    = 1, // bar body must agree with signal
   XAU_CANDLE_CLOSE_STRONG= 2  // close in upper/lower 1/3 of range
  };

enum ENUM_XAU_AVG_MODE
  {
   XAU_AVG_FIXED = 0, // FIXED distance in points
   XAU_AVG_ATR   = 1  // ATR based distance
  };

enum ENUM_XAU_AVG_REF
  {
   XAU_AVGREF_LAST_LAYER = 0, // distance from last fill (default)
   XAU_AVGREF_AVERAGE    = 1, // distance from basket average
   XAU_AVGREF_FIRST      = 2  // distance from first entry
  };

enum ENUM_XAU_LOT_MODE
  {
   XAU_LOT_FIXED      = 0, // FIX LOT
   XAU_LOT_AUTO       = 1, // AUTO LOT (risk based)
   XAU_LOT_MULTIPLIER = 2  // LOT MULTIPLIER
  };

enum ENUM_XAU_LOT_BASIS
  {
   XAU_LOTBASIS_BALANCE = 0, // balance
   XAU_LOTBASIS_EQUITY  = 1  // equity
  };

enum ENUM_XAU_AUTLOT_MODE
  {
   XAU_AUTLOT_RISK_DISTANCE = 0, // risk % over assumed stop distance
   XAU_AUTLOT_MARGIN_CAP    = 1  // limit margin consumption per layer
  };

enum ENUM_XAU_TP_MODE
  {
   XAU_TP_NONE    = 0, // no basket TP
   XAU_TP_MONEY   = 1, // fixed money amount
   XAU_TP_POINTS  = 2, // points above/below average
   XAU_TP_PERCENT = 3, // percent of basket cost basis
   XAU_TP_PRICE   = 4  // price units above/below average
  };

enum ENUM_XAU_CUT_MODE
  {
   XAU_CUT_ANY     = 0, // first threshold reached wins
   XAU_CUT_MONEY   = 1, // money only
   XAU_CUT_PERCENT = 2, // percent only
   XAU_CUT_POINTS  = 3  // points only
  };

enum ENUM_XAU_CLOSE_ORDER
  {
   XAU_CLOSE_YOUNGEST_FIRST = 0,
   XAU_CLOSE_OLDEST_FIRST   = 1,
   XAU_CLOSE_LARGEST_FIRST  = 2
  };

enum ENUM_XAU_ACTION
  {
   XAU_ACT_BLOCK_ONLY    = 0, // block new trades only
   XAU_ACT_CLOSE_BASKET  = 1, // block + close EA basket
   XAU_ACT_CLOSE_ALL     = 2, // block + close all EA positions
   XAU_ACT_EMERGENCY     = 3  // close all + EMERGENCY_STOP
  };

enum ENUM_XAU_DD_REF
  {
   XAU_DD_PEAK_EQUITY   = 0, // drawdown from peak equity
   XAU_DD_DAY_BALANCE   = 1  // equity vs balance at day start
  };

enum ENUM_XAU_DAILY_MODE
  {
   XAU_DAILY_REALIZED          = 0, // closed trades only
   XAU_DAILY_REALIZED_PLUS_EA  = 1  // closed + EA floating P/L
  };

enum ENUM_XAU_EMR_RESET
  {
   XAU_EMR_MANUAL   = 0, // manual / Telegram only
   XAU_EMR_NEXT_DAY = 1  // auto reset at new server day
  };

enum ENUM_XAU_OPEN_REF
  {
   XAU_OPEN_SERVER_MIDNIGHT = 0, // 00:00 server time
   XAU_OPEN_SESSION_START   = 1  // SessionStart input
  };

enum ENUM_XAU_FAILSAFE
  {
   XAU_FAILSAFE_BLOCK = 0, // do not trade when the filter cannot be evaluated
   XAU_FAILSAFE_ALLOW = 1, // trade anyway, log a warning
   XAU_FAILSAFE_WARN  = 2  // trade, log once per bar
  };

enum ENUM_XAU_IMPORTANCE
  {
   XAU_IMP_ALL      = 0, // any impact
   XAU_IMP_LOW      = 1, // low and above
   XAU_IMP_MODERATE = 2, // moderate and above
   XAU_IMP_HIGH     = 3  // high only
  };

enum ENUM_XAU_LOGLEVEL
  {
   XAU_LOG_NONE  = 0, // 0 = none
   XAU_LOG_ERROR = 1, // 1 = errors
   XAU_LOG_INFO  = 2, // 2 = info
   XAU_LOG_DEBUG = 3  // 3 = debug
  };

/// States of the EA state machine (see docs/03-state-machine.md).
enum ENUM_XAU_STATE
  {
   XAU_ST_IDLE              = 0,  // no cycle, no blocking condition
   XAU_ST_WAITING_ENTRY     = 1,  // no cycle, waiting for a valid signal
   XAU_ST_IN_CYCLE          = 2,  // basket open, monitoring
   XAU_ST_WAITING_AVERAGING = 3,  // basket open, waiting for next level
   XAU_ST_RISK_BLOCKED      = 4,  // a risk limit is active
   XAU_ST_PAUSED            = 5,  // user pause
   XAU_ST_EMERGENCY_STOP    = 6,  // hard stop, manual reset
   XAU_ST_CLOSING           = 7,  // basket close in progress
   XAU_ST_ERROR             = 8,  // inconsistent state, trading disabled
   XAU_ST_SELFTEST          = 9   // self test finished, trading halted
  };

/// Why a trading decision was blocked. Used for logs, dashboard and
/// Telegram so the operator always knows which control fired.
enum ENUM_XAU_BLOCK
  {
   XAU_BLK_NONE = 0,
   XAU_BLK_EMERGENCY,
   XAU_BLK_PAUSED,
   XAU_BLK_NEWCYCLES_OFF,
   XAU_BLK_EA_DISABLED,
   XAU_BLK_STATE_ERROR,
   XAU_BLK_BASKET_OPEN,
   XAU_BLK_ACCOUNT_DD,
   XAU_BLK_CYCLE_DD,
   XAU_BLK_DAILY_LOSS,
   XAU_BLK_FLOATING_LOSS,
   XAU_BLK_MARGIN,
   XAU_BLK_MAX_LAYER,
   XAU_BLK_MAX_LOT_ORDER,
   XAU_BLK_MAX_TOTAL_LOT,
   XAU_BLK_SPREAD,
   XAU_BLK_VOLATILITY,
   XAU_BLK_GAP,
   XAU_BLK_SESSION,
   XAU_BLK_WEEKEND,
   XAU_BLK_OPEN_PROTECT,
   XAU_BLK_NEWS,
   XAU_BLK_DAILY_ENTRIES,
   XAU_BLK_COOLDOWN,
   XAU_BLK_DIRECTION,
   XAU_BLK_SPEC_INVALID,
   XAU_BLK_NO_SIGNAL,
   XAU_BLK_LEVEL_NOT_REACHED,
   XAU_BLK_ONE_PER_BAR,
   XAU_BLK_TOO_SOON,
   XAU_BLK_DUPLICATE_LEVEL,
   XAU_BLK_DISTANCE_TOO_SMALL,
   XAU_BLK_NETTING_UNCERTAIN,
   XAU_BLK_EXEC_FAILED,
   XAU_BLK_NOT_CONNECTED
  };

/// Trading intents - the risk engine answers per intent so that
/// "close everything" is never blocked by an entry filter.
enum ENUM_XAU_INTENT
  {
   XAU_INT_ENTRY = 0,
   XAU_INT_AVERAGING = 1,
   XAU_INT_CLOSE = 2
  };

//------------------------------------------------------------------//
// Small data holders                                               |
//------------------------------------------------------------------//
/// One averaging layer. On hedging accounts a layer is exactly one
/// position ticket. On netting accounts a layer is a virtual record
/// attached to the single merged position of the symbol.
struct SLayerRec
  {
   long     ticket;        // position ticket (hedging) / 0 for netting
   int      index;         // 1 based layer number
   double   volume;        // volume of this layer
   double   open_price;    // fill price of this layer
   datetime open_time;     // fill time
  };

/// Basket level numbers, recomputed from real positions.
struct SCycleData
  {
   long               id;
   ENUM_POSITION_TYPE dir;
   datetime           start_time;
   double             initial_volume;
   int                layers;
   double             total_volume;
   double             avg_price;
   double             basket_tp;
   double             next_level;
   double             distance_points;
   double             floating_pl;      // profit + swap of all layers
   double             max_dd_money;     // worst floating loss this cycle
   double             max_dd_percent;
   double             balance_at_start;
   double             margin_used;
   bool               active;
   bool               recovered;        // rebuilt after restart
   datetime           last_fill_time;
   double             last_fill_price;
   int                exit_code;        // 0 open, 1 basket TP, 2 cut loss, 3 risk close, 4 manual
  };

/// Daily statistics. Reconstructed from account history on start.
struct SDayStats
  {
   datetime day;
   bool     initialised;
   double   start_balance;
   double   start_equity;
   double   realized_pl;
   int      closed_cycles;
   int      win_cycles;
   int      loss_cycles;
   int      entries;
   int      avg_orders;
   int      cut_loss_events;
   int      basket_tp_events;
   int      max_layers_seen;
   double   max_basket_volume;
   double   max_dd_money;
   double   max_dd_percent;
   int      blocked_events;
  };

/// Action the risk engine asks the orchestrator to perform. Keeping this
/// as data (instead of letting the risk module call OrderSend) makes the
/// order of operations explicit and testable: RISK decides, ENGINE acts.
struct SActionReq
  {
   bool     need_close_basket;
   bool     need_close_all;
   bool     need_emergency;
   bool     need_pause;
   int      exit_code;        // 1 tp, 2 cut loss, 3 risk close, 4 manual, 6 weekend
   string   reason;
  };

/// Result of a pre-trade decision.
struct SVerdict
  {
   bool           allowed;
   ENUM_XAU_BLOCK code;
   string         reason;
   datetime       block_until;   // 0 = until condition clears
   double         value;         // numeric detail (e.g. current spread)
  };

/// Transient runtime data. Never the source of truth for positions -
/// it only caches values that are safe to lose on restart.
struct SRt
  {
   datetime bar_time;          // open time of the current chart bar
   bool     new_bar;
   datetime last_bar_time;
   double   bid;
   double   ask;
   double   spread_points;
   bool     tick_fresh;        // quote within MaxQuoteAgeSeconds
   bool     locked;            // re-entrancy guard
   datetime started_at;
   int      ticks;
   int      errors_total;
   datetime last_open_attempt;
   int      open_failures_streak;
   datetime next_entry_allowed_at;
   datetime next_avg_allowed_at;
   datetime last_avg_open_bar;
   double   last_avg_level_used;
   datetime state_saved_at;
   bool     state_dirty;
   datetime last_gap_block_until;
   datetime day_stamp;
   double   peak_equity;
   double   worst_equity;
   int      consecutive_exec_failures;
  };

//------------------------------------------------------------------//
// CConfig - runtime copy of all inputs                             |
//                                                                  |
// Inputs in MQL5 are read-only, therefore every parameter is       |
// copied here once in OnInit(). Telegram overrides modify this      |
// object only, never the input block, and the resulting values are |
// re-validated by CEngine::ApplyConfig() before use.               |
//------------------------------------------------------------------//
class CConfig
  {
public:
   // === GENERAL ===
   string              EANameLabel;
   long                MagicNumber;
   bool                ManageCurrentSymbolOnly;
   ENUM_XAU_DIRECTION  TradingDirection;
   bool                BuyEnabled;
   bool                SellEnabled;
   bool                AllowNewCycles;
   int                 MaxQuoteAgeSeconds;
   // === ENTRY ===
   bool                EnableEMAEntry;
   int                 FastEMAPeriod;
   int                 SlowEMAPeriod;
   ENUM_TIMEFRAMES     EMATimeframe;
   ENUM_XAU_ENTRY_CONFIRM EntryConfirmation;
   ENUM_XAU_CANDLE_FILTER EntryCandleFilter;
   int                 MinimumBarRangePoints;
   bool                OneEntryPerBar;
   int                 MaximumEntriesPerDay;
   bool                RequireNewSignalAfterCycleClose;
   int                 CooldownAfterBasketTPMinutes;
   int                 CooldownAfterCutLossMinutes;
   // === AVERAGING ===
   bool                EnableAveraging;
   ENUM_XAU_AVG_MODE   AveragingDistanceMode;
   int                 AveragingDistancePoints;
   ENUM_XAU_AVG_REF    AveragingReference;
   int                 ATRPeriod;
   ENUM_TIMEFRAMES     ATRTimeframe;
   double              ATRMultiplier;
   int                 MinimumAveragingDistancePoints;
   int                 MaximumAveragingDistancePoints;
   double              MinimumDistanceSpreadMultiple;
   bool                AllowIntraBarATRRefresh;
   int                 MinimumSecondsBetweenAveraging;
   bool                OneLayerPerBar;
   bool                AllowMultipleLayersPerTick;
   int                 MaximumLayer;
   string              EntryComment;
   string              AveragingComment;
   // === LOT MANAGEMENT ===
   ENUM_XAU_LOT_MODE   LotMode;
   double              InitialLot;
   double              LotMultiplier;
   double              MaximumLotPerOrder;
   double              RiskPercent;
   ENUM_XAU_LOT_BASIS  AutoLotEquityBasis;
   ENUM_XAU_AUTLOT_MODE AutoLotCalculationMode;
   int                 InitialStopDistancePoints;
   double              AutoLotMaxMarginUsagePercent;
   bool                AutoLotAllowMinLotFallback;
   bool                ApplyMultiplierToAutoLot;
   // === BASKET TP ===
   ENUM_XAU_TP_MODE    BasketTPMode;
   double              BasketTakeProfitMoney;
   int                 BasketTakeProfitPoints;
   double              BasketTakeProfitPercent;
   double              BasketTakeProfitPrice;
   bool                AccountForSpreadInTP;
   bool                AccountForSwapInTP;
   double              EstimatedCommissionPerLot;
   double              RequireMinimumProfitMoney;
   int                 BasketTPSafetyBufferPoints;
   // === CUT LOSS ===
   bool                EnableBasketCutLoss;
   ENUM_XAU_CUT_MODE   CutLossMode;
   double              BasketCutLossMoney;
   double              BasketCutLossPercentOfBalance;
   int                 BasketCutLossPoints;
   ENUM_XAU_CLOSE_ORDER CutLossCloseOrder;
   // === RISK MANAGEMENT ===
   double              MaximumTotalLot;
   bool                TruncateLotToExposureHeadroom;
   double              MinimumFreeMarginPercent;
   double              MinimumFreeMarginMoney;
   double              MaximumAccountDrawdownPercent;
   ENUM_XAU_DD_REF     DrawdownReference;
   double              MaximumCycleDrawdownPercent;
   double              MaximumFloatingLossMoney;
   double              MaximumDailyLossMoney;
   double              MaximumDailyLossPercent;
   ENUM_XAU_DAILY_MODE DailyLossBasis;
   ENUM_XAU_ACTION     ActionOnAccountDD;
   ENUM_XAU_ACTION     ActionOnCycleDD;
   ENUM_XAU_ACTION     ActionOnDailyLoss;
   ENUM_XAU_ACTION     ActionOnFloatingLoss;
   bool                AutoResetRiskBlock;
   double              RiskBlockResetHysteresisPercent;
   ENUM_XAU_EMR_RESET  EmergencyResetMode;
   // === MARKET FILTERS ===
   bool                EnableSpreadFilter;
   int                 MaximumSpreadPoints;
   bool                SpreadFilterBlocksAveraging;
   bool                EnableVolatilityFilter;
   ENUM_TIMEFRAMES     VolatilityTimeframe;
   int                 VolatilityATRPeriod;
   int                 MinimumATRPoints;
   int                 MaximumATRPoints;
   bool                VolatilityFilterBlocksAveraging;
   bool                EnableGapFilter;
   int                 MaximumGapPoints;
   int                 GapLookbackBars;
   int                 GapBlockDurationMinutes;
   bool                GapBlocksAveraging;
   // === SESSION ===
   bool                EnableSessionFilter;
   int                 SessionStartHour;
   int                 SessionStartMinute;
   int                 SessionEndHour;
   int                 SessionEndMinute;
   bool                SessionBlocksAveraging;
   bool                EnableWeekendProtection;
   int                 FridayStopHour;
   int                 FridayStopMinute;
   int                 MondayResumeHour;
   int                 MondayResumeMinute;
   bool                WeekendBlocksAveraging;
   bool                CloseBasketBeforeFridayStop;
   bool                EnableOpenMarketProtection;
   ENUM_XAU_OPEN_REF   OpenMarketReference;
   int                 ProtectionMinutes;
   // === NEWS ===
   bool                EnableNewsFilter;
   string              NewsCurrency;
   string              NewsCountryCode;
   ENUM_XAU_IMPORTANCE MinimumNewsImportance;
   int                 MinutesBeforeNews;
   int                 MinutesAfterNews;
   bool                NewsBlocksAveraging;
   ENUM_XAU_FAILSAFE   NewsFailSafePolicy;
   int                 NewsRefreshSeconds;
   // === DASHBOARD ===
   bool                EnableDashboard;
   ENUM_BASE_CORNER    DashboardCorner;
   int                 DashboardXOffset;
   int                 DashboardYOffset;
   int                 DashboardUpdateIntervalMs;
   string              DashboardFontName;
   int                 DashboardFontSize;
   bool                DashboardShowFilters;
   bool                EnableDashboardButton;
   bool                RemoveDashboardOnDetach;
   color               ColorHeader;
   color               ColorNormal;
   color               ColorWarning;
   color               ColorDanger;
   // === TELEGRAM ===
   bool                EnableTelegram;
   string              TelegramBotToken;
   string              TelegramChatID;
   int                 TelegramPollingIntervalSeconds;
   int                 TelegramRequestTimeoutMs;
   bool                RequireConfirmationForDestructive;
   bool                TelegramEnableOverrides;
   int                 TelegramMaxMessagesPerMinute;
   bool                TelegramNotifyOnEvents;
   int                 TelegramStatusIntervalMinutes;
   bool                PersistTelegramOverrides;
   // === EXECUTION ===
   int                 MaximumDeviationPoints;
   int                 MaxOrderRetries;
   int                 RetryDelayMs;
   bool                UseOrderCheckBeforeSend;
   int                 FillVerificationRetries;
   int                 FillVerificationDelayMs;
   bool                BlockTradingIfNotConnected;
   bool                AllowNettingAccounts;
   bool                AllowStateAdoptionOnNetting;
   bool                AllowNettingLayerReconstruction;
   // === DEBUG ===
   ENUM_XAU_LOGLEVEL   LogLevel;
   bool                LogToFile;
   int                 LogThrottleSeconds;
   bool                EnableDebugTickLog;
   bool                RunSelfTestsOnInit;
   bool                HaltAfterSelfTests;
   int                 StateSaveIntervalSeconds;
   int                 DailyReportTelegramHour;   // server hour for the automatic daily report, -1 = off
   bool                EnableCsvDailyReport;
   // --- state -----------------------------------------------------
   bool                emergency_stop;      // persisted
   bool                user_paused;         // persisted
   int                 override_flags;      // bit mask of active overrides

   bool  IsEmergency(void)     const { return(emergency_stop); }
   bool  IsPaused(void)        const { return(user_paused); }
   /// One line summary of the risk relevant settings, logged at INIT.
   string Describe(void) const;
  };

//------------------------------------------------------------------//
// Helpers shared by all modules                                    |
//------------------------------------------------------------------//
/// Number of digits implied by a broker volume step (0.01 -> 2).
int XauVolumeDigits(const double step)
  {
   if(step <= 0.0)
      return(2);
   int d = (int)MathRound(-MathLog10(step));
   if(d < 0)
      d = 0;
   if(d > 8)
      d = 8;
   return(d);
  }

/// Clamp helper (double).
double XauClamp(const double value, const double lo, const double hi)
  {
   if(value < lo) return(lo);
   if(value > hi) return(hi);
   return(value);
  }

/// Clamp helper (int).
int XauClampI(const int value, const int lo, const int hi)
  {
   if(value < lo) return(lo);
   if(value > hi) return(hi);
   return(value);
  }

/// Single source of "now" for the whole EA.
/// TimeCurrent() is the time of the last trade-server tick, i.e. broker
/// server time, and in the Strategy Tester it is the simulated bar time.
/// Using anything else (TimeLocal/TimeTradeServer mixes) would make the
/// session, weekend and daily-report boundaries disagree with the chart.
datetime XauNow(void)
  {
   return(TimeCurrent());
  }

/// Is `tf` a timeframe MetaTrader can actually build a series for?
/// 0 (PERIOD_CURRENT) is valid and is resolved by the indicator call itself.
/// Anything else must be one of the standard values: a typo'd or hand-edited
/// .set file otherwise produces an indicator handle that returns no data,
/// which would freeze the entry logic without any visible error.
bool XauIsRealTimeframe(const int tf)
  {
   if(tf == 0)
      return(true);
   if(tf == PERIOD_M1  || tf == PERIOD_M2  || tf == PERIOD_M3  || tf == PERIOD_M4
      || tf == PERIOD_M5  || tf == PERIOD_M6  || tf == PERIOD_M10 || tf == PERIOD_M12
      || tf == PERIOD_M15 || tf == PERIOD_M20 || tf == PERIOD_M30
      || tf == PERIOD_H1  || tf == PERIOD_H2  || tf == PERIOD_H3  || tf == PERIOD_H4
      || tf == PERIOD_H6  || tf == PERIOD_H8  || tf == PERIOD_H12
      || tf == PERIOD_D1  || tf == PERIOD_W1  || tf == PERIOD_MN1)
      return(true);
   return(false);
  }

/// Wall-clock time for log stamps and throttle windows.
/// TimeCurrent() is the time of the last tick, so a quiet feed would freeze
/// the journal timestamps; TimeTradeServer() keeps advancing while staying on
/// the server clock that all position times use.
datetime XauStampTime(void)
  {
   datetime t = TimeTradeServer();
   if(t <= 0)
      t = TimeCurrent();
   if(t <= 0)
      t = TimeLocal();
   return(t);
  }

/// Verdict helpers. MQL5 code in this project never returns a struct by
/// value: verdicts are filled through out-parameters so the semantics do
/// not depend on the return-value rules of a given compiler build.
void XauPassV(SVerdict &v)
  {
   v.allowed     = true;
   v.code        = XAU_BLK_NONE;
   v.reason      = "pass";
   v.block_until = 0;
   v.value       = 0.0;
  }
void XauFailV(SVerdict &v, const ENUM_XAU_BLOCK code, const string why,
              const datetime until, const double value)
  {
   v.allowed     = false;
   v.code        = code;
   v.reason      = why;
   v.block_until = until;
   v.value       = value;
  }

/// Server time of the current trading day, 00:00:00.
/// Broker/server time is used everywhere in this EA on purpose: all
/// session, weekend and daily statistics logic must agree with the
/// trade server clock, not with the local PC clock.
datetime XauServerDayStart(const datetime server_time)
  {
   MqlDateTime st;
   TimeToStruct(server_time, st);
   st.hour = 0;
   st.min  = 0;
   st.sec  = 0;
   return(StructToTime(st));
  }

/// Minutes since midnight of the given server timestamp.
int XauMinutesOfDay(const datetime server_time)
  {
   MqlDateTime st;
   TimeToStruct(server_time, st);
   return(st.hour * 60 + st.min);
  }

/// Day of week, 0 = Sunday .. 6 = Saturday (server time).
int XauDayOfWeek(const datetime server_time)
  {
   MqlDateTime st;
   TimeToStruct(server_time, st);
   return(st.day_of_week);
  }

/// "HH:MM" from hour/minute inputs.
string XauHHMM(const int hour, const int minute)
  {
   return(StringFormat("%02d:%02d", hour, minute));
  }

/// Short money string, sign always shown for P/L.
string XauMoney(const double value)
  {
   string cur = AccountInfoString(ACCOUNT_CURRENCY);
   return(StringFormat("%s%.2f %s", (value >= 0.0 ? "+" : "-"), MathAbs(value), cur));
  }

/// Compact price formatting using the symbol digits.
string XauPrice(const double value)
  {
   return(DoubleToString(value, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)));
  }

/// Bit mask of the Telegram overrides that are currently active.
#define XAU_OVR_LOT        (1 << 0)
#define XAU_OVR_MULTIPLIER (1 << 1)
#define XAU_OVR_DISTANCE   (1 << 2)
#define XAU_OVR_TP         (1 << 3)
#define XAU_OVR_CUTLOSS    (1 << 4)
#define XAU_OVR_DIRECTION  (1 << 5)
#define XAU_OVR_MAXLAYER   (1 << 6)
#define XAU_OVR_MAXLOT     (1 << 7)

#endif // XAU_AVG_PRO_TYPES_MQH
//+------------------------------------------------------------------+
