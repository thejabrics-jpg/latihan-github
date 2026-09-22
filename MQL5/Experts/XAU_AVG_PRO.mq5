//+------------------------------------------------------------------+
//|                                                   XAU_AVG_PRO.mq5|
//|        XAU_AVG_PRO v1.0.0 - production grade MT5 XAUUSD EA       |
//|                                                                  |
//  Architecture: EMA entry -> controlled averaging basket ->        |
//  basket level TP / cut loss, with hard exposure and drawdown      |
//  protection, market filters, chart dashboard, Telegram control    |
//  and daily statistics. See /docs in the source repository.        |
//                                                                  |
//  OnTick() below is only an orchestrator: every rule lives in a    |
//  module under MQL5/Include/XAU_AVG_PRO so each one can be         |
//  unit tested and replaced independently.                          |
//                                                                  |
//  RISK PRIORITY (this is the design contract of the whole EA):     |
//     capital protection > deterministic behaviour > execution     |
//     correctness > observability > performance > optimisation.      |
//  When a profit opportunity conflicts with a risk limit, the risk  |
//  limit wins. Averaging increases exposure while the market moves  |
//  against you: there is no configuration of this EA that makes     |
//  profit guaranteed. See docs/14-risk-disclaimer.md.               |
//+------------------------------------------------------------------+
#property copyright "XAU_AVG_PRO - reference implementation"
#property link      "https://github.com/thejabrics-jpg/latihan-github"
#property version   "1.00"
#property description "XAU_AVG_PRO v1.0.0 - EMA entry, controlled averaging, basket TP/cut loss,"
#property description "hard exposure and drawdown protection, filters, dashboard, Telegram, daily report."
#property description "Averaging can lose money faster than a single-stop EA. Use the demo first."

#include <XAU_AVG_PRO/Types.mqh>
#include <XAU_AVG_PRO/Logger.mqh>
#include <XAU_AVG_PRO/BrokerSpec.mqh>
#include <XAU_AVG_PRO/StateStore.mqh>
#include <XAU_AVG_PRO/Cycle.mqh>
#include <XAU_AVG_PRO/Execution.mqh>
#include <XAU_AVG_PRO/Entry.mqh>
#include <XAU_AVG_PRO/Averaging.mqh>
#include <XAU_AVG_PRO/Lots.mqh>
#include <XAU_AVG_PRO/MarketFilters.mqh>
#include <XAU_AVG_PRO/News.mqh>
#include <XAU_AVG_PRO/Basket.mqh>
#include <XAU_AVG_PRO/State.mqh>
#include <XAU_AVG_PRO/Risk.mqh>
#include <XAU_AVG_PRO/Statistics.mqh>
#include <XAU_AVG_PRO/Dashboard.mqh>
#include <XAU_AVG_PRO/Telegram.mqh>
#include <XAU_AVG_PRO/SelfTest.mqh>

//==================================================================//
// SECTION 1 - INPUTS                                               |
// Every value is copied into g_cfg once in OnInit; Telegram        |
// overrides change g_cfg only, and every override is re-validated. |
//==================================================================//
input group                "=== GENERAL ==="
input string              EANameLabel                  = "XAU_AVG_PRO";    // Display name on chart / Telegram
input long                MagicNumber                  = 20260919;         // Unique magic number (do not reuse)
input bool                ManageCurrentSymbolOnly      = true;             // Only manage the chart symbol
input ENUM_XAU_DIRECTION  TradingDirection             = XAU_DIR_BOTH;      // BUY_ONLY / SELL_ONLY / BOTH
input bool                BuyEnabled                   = true;             // Allow BUY entries
input bool                SellEnabled                  = true;             // Allow SELL entries
input bool                AllowNewCycles               = true;             // Allow opening new cycles (Telegram /stop turns this off)
input int                 MaxQuoteAgeSeconds           = 30;               // Block trading if the quote is older (s)

input group                "=== ENTRY ==="
input bool                EnableEMAEntry               = true;             // Use the EMA crossover entry engine
input int                 FastEMAPeriod                = 13;               // Fast EMA period
input int                 SlowEMAPeriod                = 48;               // Slow EMA period
input ENUM_TIMEFRAMES     EMATimeframe                 = PERIOD_CURRENT;   // EMA timeframe
input ENUM_XAU_ENTRY_CONFIRM EntryConfirmation         = XAU_CONFIRM_CLOSE_BAR; // Signal evaluation bar
input ENUM_XAU_CANDLE_FILTER EntryCandleFilter         = XAU_CANDLE_NONE;  // Optional candle quality filter
input int                 MinimumBarRangePoints        = 0;                // Minimum signal bar range (pts, 0=off)
input bool                OneEntryPerBar               = true;             // At most one entry signal per bar
input int                 MaximumEntriesPerDay         = 5;                // Max initial entries per server day (0=unlimited)
input bool                RequireNewSignalAfterCycleClose= true;           // Require a fresh cross after a cycle closes
input int                 CooldownAfterBasketTPMinutes = 15;               // Cooldown after a basket TP (minutes)
input int                 CooldownAfterCutLossMinutes  = 60;               // Cooldown after a cut loss (minutes)

input group                "=== AVERAGING ==="
input bool                EnableAveraging              = true;             // Enable controlled averaging
input ENUM_XAU_AVG_MODE   AveragingDistanceMode        = XAU_AVG_FIXED;    // FIXED points or ATR based
input int                 AveragingDistancePoints      = 350;              // FIXED distance in points
input ENUM_XAU_AVG_REF    AveragingReference           = XAU_AVGREF_LAST_LAYER; // Distance measured from
input int                 ATRPeriod                    = 14;               // ATR period (ATR mode)
input ENUM_TIMEFRAMES     ATRTimeframe                 = PERIOD_CURRENT;   // ATR timeframe (ATR mode)
input double              ATRMultiplier                = 1.5;              // ATR multiplier (ATR mode)
input int                 MinimumAveragingDistancePoints = 200;            // Distance floor in points
input int                 MaximumAveragingDistancePoints = 1500;           // Distance ceiling in points
input double              MinimumDistanceSpreadMultiple= 2.0;              // Distance must be >= spread x this
input bool                AllowIntraBarATRRefresh       = false;            // Recompute ATR distance every tick
input int                 MinimumSecondsBetweenAveraging = 60;             // Minimum seconds between two layers
input bool                OneLayerPerBar               = true;             // At most one layer per bar
input bool                AllowMultipleLayersPerTick   = false;            // Advanced: allow up to 3 layers in one tick pass
input int                 MaximumLayer                 = 6;                // Maximum layer count (1 = no averaging)
input string              EntryComment                 = "XAUAVG";          // Order comment for initial entries
input string              AveragingComment             = "XAUAVG-avg";      // Order comment for averaging layers

input group                "=== LOT MANAGEMENT ==="
input ENUM_XAU_LOT_MODE   LotMode                      = XAU_LOT_FIXED;    // FIX LOT / AUTO LOT / MULTIPLIER
input double              InitialLot                   = 0.01;             // Base lot
input double              LotMultiplier                = 1.5;              // Multiplier per layer (>=1.0)
input double              MaximumLotPerOrder           = 0.10;             // Hard cap per single order
input double              RiskPercent                  = 0.5;              // AUTO LOT: risk % of balance/equity
input ENUM_XAU_LOT_BASIS  AutoLotEquityBasis           = XAU_LOTBASIS_EQUITY; // AUTO LOT basis
input ENUM_XAU_AUTLOT_MODE AutoLotCalculationMode      = XAU_AUTLOT_RISK_DISTANCE; // AUTO LOT method
input int                 InitialStopDistancePoints    = 400;              // AUTO LOT: assumed stop distance (pts)
input double              AutoLotMaxMarginUsagePercent = 30.0;             // AUTO LOT: max margin use of basis (%)
input bool                AutoLotAllowMinLotFallback   = false;            // AUTO LOT: allow rounding up to broker min lot
input bool                ApplyMultiplierToAutoLot     = false;            // Apply LotMultiplier on top of AUTO LOT

input group                "=== BASKET TP ==="
input ENUM_XAU_TP_MODE    BasketTPMode                 = XAU_TP_MONEY;     // MONEY/POINTS/PERCENT/PRICE/NONE
input double              BasketTakeProfitMoney        = 5.0;              // Target money for the whole basket
input int                 BasketTakeProfitPoints       = 350;              // Target points above/below average
input double              BasketTakeProfitPercent      = 0.05;             // Target % of basket cost basis
input double              BasketTakeProfitPrice        = 3.50;             // Target price units above/below average
input bool                AccountForSpreadInTP         = true;             // Anchor the TP on the real close price
input bool                AccountForSwapInTP           = true;             // Include swap in basket P/L
input double              EstimatedCommissionPerLot    = 0.0;              // Commission per lot PER SIDE (0 if unknown)
input double              RequireMinimumProfitMoney    = 0.0;              // Never close a basket below this profit
input int                 BasketTPSafetyBufferPoints    = 0;               // Extra distance before the TP triggers

input group                "=== CUT LOSS ==="
input bool                EnableBasketCutLoss          = true;             // Enable basket cut loss
input ENUM_XAU_CUT_MODE   CutLossMode                  = XAU_CUT_ANY;      // Which threshold may trigger
input double              BasketCutLossMoney           = 50.0;             // Cut loss in money
input double              BasketCutLossPercentOfBalance= 5.0;              // Cut loss % of balance
input int                 BasketCutLossPoints          = 2000;             // Cut loss in points from average
input ENUM_XAU_CLOSE_ORDER CutLossCloseOrder           = XAU_CLOSE_YOUNGEST_FIRST; // Which layer to close first

input group                "=== RISK MANAGEMENT ==="
input double              MaximumTotalLot              = 0.50;             // Maximum total EA exposure (lots)
input bool                TruncateLotToExposureHeadroom= false;            // Shrink instead of rejecting when near the cap
input double              MinimumFreeMarginPercent     = 200.0;            // Required projected margin level (%)
input double              MinimumFreeMarginMoney       = 0.0;             // Required free margin after the order (money)
input double              MaximumAccountDrawdownPercent= 20.0;             // Account drawdown limit (%)
input ENUM_XAU_DD_REF     DrawdownReference            = XAU_DD_PEAK_EQUITY; // Drawdown reference
input double              MaximumCycleDrawdownPercent  = 10.0;             // Cycle drawdown limit (% of cycle start balance)
input double              MaximumFloatingLossMoney     = 100.0;            // Maximum basket floating loss (money)
input double              MaximumDailyLossMoney        = 150.0;            // Maximum daily loss (money)
input double              MaximumDailyLossPercent      = 5.0;              // Maximum daily loss (% of day start balance)
input ENUM_XAU_DAILY_MODE DailyLossBasis               = XAU_DAILY_REALIZED_PLUS_EA; // What counts as daily loss
input ENUM_XAU_ACTION     ActionOnAccountDD            = XAU_ACT_EMERGENCY; // When the account DD limit is hit
input ENUM_XAU_ACTION     ActionOnCycleDD              = XAU_ACT_CLOSE_BASKET; // When the cycle DD limit is hit
input ENUM_XAU_ACTION     ActionOnDailyLoss            = XAU_ACT_BLOCK_ONLY;  // When the daily loss limit is hit
input ENUM_XAU_ACTION     ActionOnFloatingLoss         = XAU_ACT_BLOCK_ONLY;  // When the floating loss limit is hit
input bool                AutoResetRiskBlock           = true;             // Release soft blocks when conditions clear
input double              RiskBlockResetHysteresisPercent = 80.0;          // Must recover to x% of the limit to clear
input ENUM_XAU_EMR_RESET  EmergencyResetMode           = XAU_EMR_MANUAL;   // How EMERGENCY STOP is released

input group                "=== MARKET FILTERS ==="
input bool                EnableSpreadFilter           = true;             // Spread filter
input int                 MaximumSpreadPoints          = 500;              // Maximum spread (points)
input bool                SpreadFilterBlocksAveraging  = true;             // Spread filter also blocks averaging
input bool                EnableVolatilityFilter       = false;            // ATR volatility filter
input ENUM_TIMEFRAMES     VolatilityTimeframe          = PERIOD_CURRENT;   // Volatility ATR timeframe
input int                 VolatilityATRPeriod          = 14;               // Volatility ATR period
input int                 MinimumATRPoints             = 30;               // Block below this ATR (points)
input int                 MaximumATRPoints             = 1500;             // Block above this ATR (points, <=min=off)
input bool                VolatilityFilterBlocksAveraging = false;         // Volatility filter also blocks averaging
input bool                EnableGapFilter              = true;             // Gap filter
input int                 MaximumGapPoints             = 1500;             // Maximum bar-to-bar gap (points)
input int                 GapLookbackBars              = 2;                // Bars scanned for gaps
input int                 GapBlockDurationMinutes      = 15;               // Block duration after a gap
input bool                GapBlocksAveraging           = true;             // Gap filter also blocks averaging

input group                "=== SESSION ==="
input bool                EnableSessionFilter          = true;             // Trading session filter
input int                 SessionStartHour             = 7;                // Session start hour (server time)
input int                 SessionStartMinute           = 0;                // Session start minute
input int                 SessionEndHour               = 20;               // Session end hour (server time)
input int                 SessionEndMinute             = 30;               // Session end minute
input bool                SessionBlocksAveraging       = false;            // Session filter also blocks averaging
input bool                EnableWeekendProtection      = true;             // Weekend protection
input int                 FridayStopHour               = 20;               // Friday stop hour (server time)
input int                 FridayStopMinute             = 30;               // Friday stop minute
input int                 MondayResumeHour             = 3;                // Monday resume hour (server time)
input int                 MondayResumeMinute           = 0;                // Monday resume minute
input bool                WeekendBlocksAveraging       = true;             // Weekend protection also blocks averaging
input bool                CloseBasketBeforeFridayStop  = false;            // Flatten the basket at the Friday stop
input bool                EnableOpenMarketProtection   = true;             // Protection right after market open
input ENUM_XAU_OPEN_REF   OpenMarketReference          = XAU_OPEN_SESSION_START; // What counts as "open"
input int                 ProtectionMinutes            = 15;               // Protection length after open (minutes)

input group                "=== NEWS ==="
input bool                EnableNewsFilter             = false;            // MT5 economic calendar filter
input string              NewsCurrency                 = "USD";            // Currency to watch
input string              NewsCountryCode              = "";               // Optional ISO country code (e.g. US)
input ENUM_XAU_IMPORTANCE MinimumNewsImportance        = XAU_IMP_HIGH;     // Minimum importance to block on
input int                 MinutesBeforeNews            = 30;               // Block this many minutes before
input int                 MinutesAfterNews             = 30;               // Block this many minutes after
input bool                NewsBlocksAveraging          = true;             // News window also blocks averaging
input ENUM_XAU_FAILSAFE   NewsFailSafePolicy           = XAU_FAILSAFE_BLOCK; // What to do when the calendar is unavailable
input int                 NewsRefreshSeconds           = 60;               // Calendar refresh interval (s)

input group                "=== DASHBOARD ==="
input bool                EnableDashboard              = true;             // Draw the chart panel
input ENUM_BASE_CORNER    DashboardCorner              = CORNER_LEFT_UPPER;  // Panel corner
input int                 DashboardXOffset              = 8;               // X offset (px)
input int                 DashboardYOffset              = 22;              // Y offset (px)
input int                 DashboardUpdateIntervalMs    = 500;              // Repaint interval (ms)
input string              DashboardFontName            = "Consolas";       // Font
input int                 DashboardFontSize            = 9;                // Font size
input bool                DashboardShowFilters         = true;             // Show filter detail rows
input bool                EnableDashboardButton        = true;             // Show PAUSE/RESUME button
input bool                RemoveDashboardOnDetach      = true;             // Delete chart objects on detach
input color               ColorHeader                  = clrDodgerBlue;     // Header colour
input color               ColorNormal                  = clrGainsboro;      // Normal text colour
input color               ColorWarning                 = clrOrange;         // Warning colour
input color               ColorDanger                  = clrTomato;        // Danger colour

input group                "=== TELEGRAM ==="
input bool                EnableTelegram               = false;            // Enable Telegram integration
input string              TelegramBotToken             = "";               // Bot token (never logged)
input string              TelegramChatID               = "";               // Your chat id
input int                 TelegramPollingIntervalSeconds = 5;              // getUpdates polling interval (s)
input int                 TelegramRequestTimeoutMs     = 5000;             // WebRequest timeout (ms)
input bool                RequireConfirmationForDestructive = true;        // closeall/closebuy/closesell need /confirm
input bool                TelegramEnableOverrides      = true;             // Allow parameter changing commands
input int                 TelegramMaxMessagesPerMinute = 12;               // Outbound rate limit
input bool                TelegramNotifyOnEvents       = true;             // Send event notifications
input int                 TelegramStatusIntervalMinutes= 0;                // Periodic status (0 = off)
input bool                PersistTelegramOverrides     = true;             // Keep overrides after restart

input group                "=== EXECUTION ==="
input int                 MaximumDeviationPoints       = 30;               // Maximum slippage (points)
input int                 MaxOrderRetries              = 3;               // Attempts per order (transient errors only)
input int                 RetryDelayMs                 = 400;              // Delay between attempts (ms)
input bool                UseOrderCheckBeforeSend      = true;             // OrderCheck() before every OrderSend()
input int                 FillVerificationRetries      = 3;                // How often to re-scan positions for the fill
input int                 FillVerificationDelayMs      = 200;              // Delay between fill verification scans
input bool                BlockTradingIfNotConnected   = true;             // No new trades without a server connection
input bool                AllowNettingAccounts         = true;             // Allow netting accounts (see docs)
input bool                AllowStateAdoptionOnNetting  = false;            // Adopt an unknown netting basket as 1 layer
input bool                AllowNettingLayerReconstruction = true;          // Rebuild netting layer count from volume

input group                "=== DEBUG / TESTING ==="
input ENUM_XAU_LOGLEVEL   LogLevel                     = XAU_LOG_INFO;     // Log verbosity
input bool                LogToFile                     = false;           // Mirror the log into MQL5\Files
input int                 LogThrottleSeconds           = 60;               // Suppression window for repeated lines
input bool                EnableDebugTickLog           = false;            // Log every pipeline decision (noisy)
input bool                RunSelfTestsOnInit           = false;            // Run the built-in logic self tests
input bool                HaltAfterSelfTests           = false;            // Stay in SELFTEST_DONE after the tests
input int                 StateSaveIntervalSeconds     = 10;               // Maximum age of the state file

input group                "=== DAILY REPORT ==="
input int                 DailyReportTelegramHour      = 23;               // Auto-send the daily report at this server hour (-1 = off)
input bool                EnableCsvDailyReport         = false;            // Append the daily report to a CSV in MQL5\Files

//==================================================================//
// SECTION 2 - GLOBAL OBJECTS                                       |
//==================================================================//
CConfig        g_cfg;
CSymbolSpec    g_spec;
CLogger        g_log;
CStateStore    g_state;
CCycleManager  g_cycle;
CExecution     g_exec;
CEntryEngine   g_entry;
CAveragingEngine g_avg;
CLotManager    g_lots;
CMarketFilters g_filters;
CNewsFilter    g_news;
CBasketManager g_basket;
CStateMachine  g_sm;
CRiskManager   g_risk;
CStatistics    g_stats;
CDashboard     g_dash;
CTelegramBot   g_tg;
CSelfTest      g_tests;
SRt            g_rt;

bool  g_config_errors = false;      // hard input problems disable trading
bool  g_closing_basket = false;     // pipeline level close guard
int   g_pipeline_runs = 0;
string g_last_block_reason = "";
ENUM_XAU_BLOCK g_last_block_code = XAU_BLK_NONE;
datetime g_last_block_logged = 0;
int    g_heartbeat_seconds = 0;

// cycle-close bookkeeping (exactly one OnCycleFinished per finished cycle)
bool     g_prev_cycle_active = false;
bool     g_close_notice_set = false;
int      g_close_notice_code = 0;
double   g_close_notice_net = 0.0;
string   g_close_notice_reason = "";
int      g_close_notice_layers = 0;
double   g_close_notice_volume = 0.0;
double   g_close_notice_avg = 0.0;

//------------------------------------------------------------------//
// Forward declarations of the orchestration functions in this file |
//------------------------------------------------------------------//
void   LoadInputs(void);
string SafeComment(const string text);
void   ValidateConfig(string &errors);
void   SaveOverrides(void);
void   LoadPersistedFlags(void);
int    BitCount(const int value);
void   TrySaveState(const bool force);
void   UpdateMarketData(void);
bool   EnvironmentAllowsTrading(string &why);
void   Notify(const string text);
void   OnCycleFinished(const int exit_code, const string reason, const double net_pl);
bool   CloseBasket(const int exit_code, const string reason);
void   TryOpenCycle(const bool is_buy);
void   TryAverage(void);
void   LogBlock(const string tag, const ENUM_XAU_INTENT intent, const SVerdict &v);
void   RunPipeline(void);
int    DayEntriesCount(void);
int    DayClosedCount(void);
void   HandleCommand(const string name, const string args);
string OverrideSummary(void);
string StatusReport(void);
void   BuildDashboard(void);
void   CheckEmergencyAutoReset(void);
string DeinitReasonText(const int reason);

/// Copy every input into the mutable runtime configuration.
void LoadInputs(void)
  {
   g_cfg.EANameLabel = EANameLabel;
   g_cfg.MagicNumber = MagicNumber;
   g_cfg.ManageCurrentSymbolOnly = ManageCurrentSymbolOnly;
   g_cfg.TradingDirection = TradingDirection;
   g_cfg.BuyEnabled = BuyEnabled;
   g_cfg.SellEnabled = SellEnabled;
   g_cfg.AllowNewCycles = AllowNewCycles;
   g_cfg.MaxQuoteAgeSeconds = MaxQuoteAgeSeconds;
   g_cfg.EnableEMAEntry = EnableEMAEntry;
   g_cfg.FastEMAPeriod = FastEMAPeriod;
   g_cfg.SlowEMAPeriod = SlowEMAPeriod;
   g_cfg.EMATimeframe = EMATimeframe;
   g_cfg.EntryConfirmation = EntryConfirmation;
   g_cfg.EntryCandleFilter = EntryCandleFilter;
   g_cfg.MinimumBarRangePoints = MinimumBarRangePoints;
   g_cfg.OneEntryPerBar = OneEntryPerBar;
   g_cfg.MaximumEntriesPerDay = MaximumEntriesPerDay;
   g_cfg.RequireNewSignalAfterCycleClose = RequireNewSignalAfterCycleClose;
   g_cfg.CooldownAfterBasketTPMinutes = CooldownAfterBasketTPMinutes;
   g_cfg.CooldownAfterCutLossMinutes = CooldownAfterCutLossMinutes;
   g_cfg.EnableAveraging = EnableAveraging;
   g_cfg.AveragingDistanceMode = AveragingDistanceMode;
   g_cfg.AveragingDistancePoints = AveragingDistancePoints;
   g_cfg.AveragingReference = AveragingReference;
   g_cfg.ATRPeriod = ATRPeriod;
   g_cfg.ATRTimeframe = ATRTimeframe;
   g_cfg.ATRMultiplier = ATRMultiplier;
   g_cfg.MinimumAveragingDistancePoints = MinimumAveragingDistancePoints;
   g_cfg.MaximumAveragingDistancePoints = MaximumAveragingDistancePoints;
   g_cfg.MinimumDistanceSpreadMultiple = MinimumDistanceSpreadMultiple;
   g_cfg.AllowIntraBarATRRefresh = AllowIntraBarATRRefresh;
   g_cfg.MinimumSecondsBetweenAveraging = MinimumSecondsBetweenAveraging;
   g_cfg.OneLayerPerBar = OneLayerPerBar;
   g_cfg.AllowMultipleLayersPerTick = AllowMultipleLayersPerTick;
   g_cfg.MaximumLayer = MaximumLayer;
   g_cfg.EntryComment = EntryComment;
   g_cfg.AveragingComment = AveragingComment;
   g_cfg.LotMode = LotMode;
   g_cfg.InitialLot = InitialLot;
   g_cfg.LotMultiplier = LotMultiplier;
   g_cfg.MaximumLotPerOrder = MaximumLotPerOrder;
   g_cfg.RiskPercent = RiskPercent;
   g_cfg.AutoLotEquityBasis = AutoLotEquityBasis;
   g_cfg.AutoLotCalculationMode = AutoLotCalculationMode;
   g_cfg.InitialStopDistancePoints = InitialStopDistancePoints;
   g_cfg.AutoLotMaxMarginUsagePercent = AutoLotMaxMarginUsagePercent;
   g_cfg.AutoLotAllowMinLotFallback = AutoLotAllowMinLotFallback;
   g_cfg.ApplyMultiplierToAutoLot = ApplyMultiplierToAutoLot;
   g_cfg.BasketTPMode = BasketTPMode;
   g_cfg.BasketTakeProfitMoney = BasketTakeProfitMoney;
   g_cfg.BasketTakeProfitPoints = BasketTakeProfitPoints;
   g_cfg.BasketTakeProfitPercent = BasketTakeProfitPercent;
   g_cfg.BasketTakeProfitPrice = BasketTakeProfitPrice;
   g_cfg.AccountForSpreadInTP = AccountForSpreadInTP;
   g_cfg.AccountForSwapInTP = AccountForSwapInTP;
   g_cfg.EstimatedCommissionPerLot = EstimatedCommissionPerLot;
   g_cfg.RequireMinimumProfitMoney = RequireMinimumProfitMoney;
   g_cfg.BasketTPSafetyBufferPoints = BasketTPSafetyBufferPoints;
   g_cfg.EnableBasketCutLoss = EnableBasketCutLoss;
   g_cfg.CutLossMode = CutLossMode;
   g_cfg.BasketCutLossMoney = BasketCutLossMoney;
   g_cfg.BasketCutLossPercentOfBalance = BasketCutLossPercentOfBalance;
   g_cfg.BasketCutLossPoints = BasketCutLossPoints;
   g_cfg.CutLossCloseOrder = CutLossCloseOrder;
   g_cfg.MaximumTotalLot = MaximumTotalLot;
   g_cfg.TruncateLotToExposureHeadroom = TruncateLotToExposureHeadroom;
   g_cfg.MinimumFreeMarginPercent = MinimumFreeMarginPercent;
   g_cfg.MinimumFreeMarginMoney = MinimumFreeMarginMoney;
   g_cfg.MaximumAccountDrawdownPercent = MaximumAccountDrawdownPercent;
   g_cfg.DrawdownReference = DrawdownReference;
   g_cfg.MaximumCycleDrawdownPercent = MaximumCycleDrawdownPercent;
   g_cfg.MaximumFloatingLossMoney = MaximumFloatingLossMoney;
   g_cfg.MaximumDailyLossMoney = MaximumDailyLossMoney;
   g_cfg.MaximumDailyLossPercent = MaximumDailyLossPercent;
   g_cfg.DailyLossBasis = DailyLossBasis;
   g_cfg.ActionOnAccountDD = ActionOnAccountDD;
   g_cfg.ActionOnCycleDD = ActionOnCycleDD;
   g_cfg.ActionOnDailyLoss = ActionOnDailyLoss;
   g_cfg.ActionOnFloatingLoss = ActionOnFloatingLoss;
   g_cfg.AutoResetRiskBlock = AutoResetRiskBlock;
   g_cfg.RiskBlockResetHysteresisPercent = RiskBlockResetHysteresisPercent;
   g_cfg.EmergencyResetMode = EmergencyResetMode;
   g_cfg.EnableSpreadFilter = EnableSpreadFilter;
   g_cfg.MaximumSpreadPoints = MaximumSpreadPoints;
   g_cfg.SpreadFilterBlocksAveraging = SpreadFilterBlocksAveraging;
   g_cfg.EnableVolatilityFilter = EnableVolatilityFilter;
   g_cfg.VolatilityTimeframe = VolatilityTimeframe;
   g_cfg.VolatilityATRPeriod = VolatilityATRPeriod;
   g_cfg.MinimumATRPoints = MinimumATRPoints;
   g_cfg.MaximumATRPoints = MaximumATRPoints;
   g_cfg.VolatilityFilterBlocksAveraging = VolatilityFilterBlocksAveraging;
   g_cfg.EnableGapFilter = EnableGapFilter;
   g_cfg.MaximumGapPoints = MaximumGapPoints;
   g_cfg.GapLookbackBars = GapLookbackBars;
   g_cfg.GapBlockDurationMinutes = GapBlockDurationMinutes;
   g_cfg.GapBlocksAveraging = GapBlocksAveraging;
   g_cfg.EnableSessionFilter = EnableSessionFilter;
   g_cfg.SessionStartHour = SessionStartHour;
   g_cfg.SessionStartMinute = SessionStartMinute;
   g_cfg.SessionEndHour = SessionEndHour;
   g_cfg.SessionEndMinute = SessionEndMinute;
   g_cfg.SessionBlocksAveraging = SessionBlocksAveraging;
   g_cfg.EnableWeekendProtection = EnableWeekendProtection;
   g_cfg.FridayStopHour = FridayStopHour;
   g_cfg.FridayStopMinute = FridayStopMinute;
   g_cfg.MondayResumeHour = MondayResumeHour;
   g_cfg.MondayResumeMinute = MondayResumeMinute;
   g_cfg.WeekendBlocksAveraging = WeekendBlocksAveraging;
   g_cfg.CloseBasketBeforeFridayStop = CloseBasketBeforeFridayStop;
   g_cfg.EnableOpenMarketProtection = EnableOpenMarketProtection;
   g_cfg.OpenMarketReference = OpenMarketReference;
   g_cfg.ProtectionMinutes = ProtectionMinutes;
   g_cfg.EnableNewsFilter = EnableNewsFilter;
   g_cfg.NewsCurrency = NewsCurrency;
   g_cfg.NewsCountryCode = NewsCountryCode;
   g_cfg.MinimumNewsImportance = MinimumNewsImportance;
   g_cfg.MinutesBeforeNews = MinutesBeforeNews;
   g_cfg.MinutesAfterNews = MinutesAfterNews;
   g_cfg.NewsBlocksAveraging = NewsBlocksAveraging;
   g_cfg.NewsFailSafePolicy = NewsFailSafePolicy;
   g_cfg.NewsRefreshSeconds = NewsRefreshSeconds;
   g_cfg.EnableDashboard = EnableDashboard;
   g_cfg.DashboardCorner = DashboardCorner;
   g_cfg.DashboardXOffset = DashboardXOffset;
   g_cfg.DashboardYOffset = DashboardYOffset;
   g_cfg.DashboardUpdateIntervalMs = DashboardUpdateIntervalMs;
   g_cfg.DashboardFontName = DashboardFontName;
   g_cfg.DashboardFontSize = DashboardFontSize;
   g_cfg.DashboardShowFilters = DashboardShowFilters;
   g_cfg.EnableDashboardButton = EnableDashboardButton;
   g_cfg.RemoveDashboardOnDetach = RemoveDashboardOnDetach;
   g_cfg.ColorHeader = ColorHeader;
   g_cfg.ColorNormal = ColorNormal;
   g_cfg.ColorWarning = ColorWarning;
   g_cfg.ColorDanger = ColorDanger;
   g_cfg.EnableTelegram = EnableTelegram;
   g_cfg.TelegramBotToken = TelegramBotToken;
   g_cfg.TelegramChatID = TelegramChatID;
   g_cfg.TelegramPollingIntervalSeconds = TelegramPollingIntervalSeconds;
   g_cfg.TelegramRequestTimeoutMs = TelegramRequestTimeoutMs;
   g_cfg.RequireConfirmationForDestructive = RequireConfirmationForDestructive;
   g_cfg.TelegramEnableOverrides = TelegramEnableOverrides;
   g_cfg.TelegramMaxMessagesPerMinute = TelegramMaxMessagesPerMinute;
   g_cfg.TelegramNotifyOnEvents = TelegramNotifyOnEvents;
   g_cfg.TelegramStatusIntervalMinutes = TelegramStatusIntervalMinutes;
   g_cfg.PersistTelegramOverrides = PersistTelegramOverrides;
   g_cfg.MaximumDeviationPoints = MaximumDeviationPoints;
   g_cfg.MaxOrderRetries = MaxOrderRetries;
   g_cfg.RetryDelayMs = RetryDelayMs;
   g_cfg.UseOrderCheckBeforeSend = UseOrderCheckBeforeSend;
   g_cfg.FillVerificationRetries = FillVerificationRetries;
   g_cfg.FillVerificationDelayMs = FillVerificationDelayMs;
   g_cfg.BlockTradingIfNotConnected = BlockTradingIfNotConnected;
   g_cfg.AllowNettingAccounts = AllowNettingAccounts;
   g_cfg.AllowStateAdoptionOnNetting = AllowStateAdoptionOnNetting;
   g_cfg.AllowNettingLayerReconstruction = AllowNettingLayerReconstruction;
   g_cfg.LogLevel = LogLevel;
   g_cfg.LogToFile = LogToFile;
   g_cfg.LogThrottleSeconds = LogThrottleSeconds;
   g_cfg.EnableDebugTickLog = EnableDebugTickLog;
   g_cfg.RunSelfTestsOnInit = RunSelfTestsOnInit;
   g_cfg.HaltAfterSelfTests = HaltAfterSelfTests;
   g_cfg.StateSaveIntervalSeconds = StateSaveIntervalSeconds;
   g_cfg.DailyReportTelegramHour = DailyReportTelegramHour;
   g_cfg.EnableCsvDailyReport = EnableCsvDailyReport;
   // operator flags are not inputs: they always start clean and are then
   // restored from the state file if one exists
   g_cfg.emergency_stop = false;
   g_cfg.user_paused    = false;
   g_cfg.override_flags = 0;
  }

/// Order comments are truncated to 28 characters and stripped to printable
/// ASCII: several brokers reject longer comments or non ASCII bytes, and a
/// rejected order is a much worse outcome than a shorter label.
string SafeComment(const string text)
  {
   string out = "";
   int len = StringLen(text);
   for(int i = 0; i < len && StringLen(out) < 28; i++)
     {
      ushort c = StringGetCharacter(text, i);
      if(c < 32 || c > 126)
         c = ' ';
      out += ShortToString(c);
     }
   StringTrimRight(out);
   return(out);
  }

//==================================================================//
// SECTION 3 - CONFIGURATION VALIDATION                             |
//==================================================================//
/// All limits are checked here, once. Anything that would make the
/// behaviour unpredictable or unsafe is a HARD error: the EA then runs
/// in state ERROR, keeps the dashboard alive and refuses to trade.
void ValidateConfig(string &errors)
  {
   string e = "";
   // --- identity ---
   if(g_cfg.MagicNumber <= 0)
      e += "MagicNumber must be a positive number.\n";
   if(StringLen(g_cfg.EntryComment) == 0)
      g_cfg.EntryComment = "XAUAVG";
   if(StringLen(g_cfg.AveragingComment) == 0)
      g_cfg.AveragingComment = g_cfg.EntryComment + "-avg";
   g_cfg.EntryComment     = SafeComment(g_cfg.EntryComment);
   g_cfg.AveragingComment = SafeComment(g_cfg.AveragingComment);

   // --- entry ---
   if(g_cfg.EnableEMAEntry)
     {
      if(g_cfg.FastEMAPeriod < 2 || g_cfg.SlowEMAPeriod < 3)
         e += "FastEMAPeriod/SlowEMAPeriod must be >= 2/3.\n";
      if(g_cfg.FastEMAPeriod >= g_cfg.SlowEMAPeriod)
         g_log.Warn(XAU_T_CFG, StringFormat("FastEMA(%d) >= SlowEMA(%d): the crossover logic still works but the usual convention is reversed",
                                            g_cfg.FastEMAPeriod, g_cfg.SlowEMAPeriod));
      if(g_cfg.MaximumEntriesPerDay < 0)
         g_cfg.MaximumEntriesPerDay = 0;
     }

   // --- averaging ---
   g_cfg.MaximumLayer = (int)XauClampI(g_cfg.MaximumLayer, 1, XAU_MAX_LAYERS_HARD);
   if(g_cfg.EnableAveraging && g_cfg.MaximumLayer < 1)
      e += "MaximumLayer must be >= 1 when averaging is enabled.\n";
   if(g_cfg.AveragingDistanceMode == XAU_AVG_FIXED)
     {
      if(g_cfg.AveragingDistancePoints < 10)
         e += StringFormat("AveragingDistancePoints=%d is too small (minimum 10 pts) - XAUUSD would average on spread noise",
                           g_cfg.AveragingDistancePoints);
     }
   else
     {
      if(g_cfg.ATRPeriod < 2)
         e += "ATRPeriod must be >= 2 in ATR distance mode.";
      if(g_cfg.ATRMultiplier <= 0.0)
         e += "ATRMultiplier must be > 0 in ATR distance mode.";
      if(g_cfg.MinimumAveragingDistancePoints < 10)
        {
         g_log.Warn(XAU_T_CFG, "MinimumAveragingDistancePoints raised to 10 pts");
         g_cfg.MinimumAveragingDistancePoints = 10;
        }
      if(g_cfg.MaximumAveragingDistancePoints < g_cfg.MinimumAveragingDistancePoints)
        {
         g_log.Warn(XAU_T_CFG, "MaximumAveragingDistancePoints < minimum - set to the minimum value");
         g_cfg.MaximumAveragingDistancePoints = g_cfg.MinimumAveragingDistancePoints;
        }
     }
   if(g_cfg.MinimumDistanceSpreadMultiple < 1.0)
     {
      g_log.Warn(XAU_T_CFG, "MinimumDistanceSpreadMultiple < 1.0 raised to 1.0");
      g_cfg.MinimumDistanceSpreadMultiple = 1.0;
     }
   if(g_cfg.MinimumSecondsBetweenAveraging < 0)
      g_cfg.MinimumSecondsBetweenAveraging = 0;

   // --- lots ---
   double vmin = g_spec.VolumeMin();
   double vstep = g_spec.VolumeStep();
   if(g_cfg.InitialLot < vmin - 1.0e-9)
     {
      e += StringFormat("InitialLot %.2f is below the broker minimum %.2f", g_cfg.InitialLot, vmin);
      g_cfg.InitialLot = vmin;
     }
   else
     {
      double snapped = g_spec.NormalizeVolume(g_cfg.InitialLot, true);
      if(snapped > 0.0 && MathAbs(snapped - g_cfg.InitialLot) > 1.0e-9)
        {
         g_log.Warn(XAU_T_CFG, StringFormat("InitialLot %.4f is not a multiple of the volume step %.2f - using %.2f",
                                            g_cfg.InitialLot, vstep, snapped));
         g_cfg.InitialLot = snapped;
        }
     }
   if(g_cfg.LotMultiplier < 1.0)
     {
      g_log.Warn(XAU_T_CFG, StringFormat("LotMultiplier %.2f < 1.0 is not supported (de-escalating baskets are not modelled) - using 1.0",
                                         g_cfg.LotMultiplier));
      g_cfg.LotMultiplier = 1.0;
     }
   if(g_cfg.LotMultiplier > 3.0)
      g_log.Warn(XAU_T_CFG, StringFormat("LotMultiplier %.2f grows exposure geometrically: with MaximumLayer %d the last layer is x%.1f the base lot",
                                         g_cfg.LotMultiplier, g_cfg.MaximumLayer, MathPow(g_cfg.LotMultiplier, g_cfg.MaximumLayer - 1)));
   if(g_cfg.MaximumLotPerOrder < vmin)
     {
      e += StringFormat("MaximumLotPerOrder %.2f is below the broker minimum %.2f", g_cfg.MaximumLotPerOrder, vmin);
      g_cfg.MaximumLotPerOrder = vmin;
     }
   if(g_cfg.MaximumLotPerOrder > g_spec.VolumeMax())
     {
      g_log.Warn(XAU_T_CFG, StringFormat("MaximumLotPerOrder %.2f exceeds the broker maximum %.2f - clamped",
                                         g_cfg.MaximumLotPerOrder, g_spec.VolumeMax()));
      g_cfg.MaximumLotPerOrder = g_spec.VolumeMax();
     }
   if(g_cfg.MaximumTotalLot > 0.0 && g_cfg.MaximumTotalLot < g_cfg.InitialLot)
      e += StringFormat("MaximumTotalLot %.2f is smaller than InitialLot %.2f - no trade could ever be opened",
                        g_cfg.MaximumTotalLot, g_cfg.InitialLot);
   if(g_cfg.LotMode == XAU_LOT_AUTO)
     {
      if(g_cfg.RiskPercent <= 0.0 || g_cfg.RiskPercent > 5.0)
        {
         e += StringFormat("RiskPercent %.2f is outside the supported range 0.01..5.00 for AUTO LOT", g_cfg.RiskPercent);
         g_cfg.RiskPercent = XauClamp(g_cfg.RiskPercent, 0.01, 5.0);
        }
      if(g_cfg.InitialStopDistancePoints < 10)
         g_log.Warn(XAU_T_CFG, "AUTO LOT with InitialStopDistancePoints < 10 pts sizes the position on an unrealistically small stop");
     }

   // --- basket TP ---
   switch(g_cfg.BasketTPMode)
     {
      case XAU_TP_MONEY:
         if(g_cfg.BasketTakeProfitMoney <= 0.0)
           {
            g_log.Warn(XAU_T_CFG, "BasketTPMode=MONEY but BasketTakeProfitMoney<=0 - basket TP disabled");
            g_cfg.BasketTPMode = XAU_TP_NONE;
           }
         break;
      case XAU_TP_POINTS:
         if(g_cfg.BasketTakeProfitPoints < 1)
           {
            g_log.Warn(XAU_T_CFG, "BasketTPMode=POINTS but BasketTakeProfitPoints<1 - basket TP disabled");
            g_cfg.BasketTPMode = XAU_TP_NONE;
           }
         break;
      case XAU_TP_PERCENT:
         if(g_cfg.BasketTakeProfitPercent <= 0.0)
           {
            g_log.Warn(XAU_T_CFG, "BasketTPMode=PERCENT but BasketTakeProfitPercent<=0 - basket TP disabled");
            g_cfg.BasketTPMode = XAU_TP_NONE;
           }
         break;
      case XAU_TP_PRICE:
         if(g_cfg.BasketTakeProfitPrice <= 0.0)
           {
            g_log.Warn(XAU_T_CFG, "BasketTPMode=PRICE but BasketTakeProfitPrice<=0 - basket TP disabled");
            g_cfg.BasketTPMode = XAU_TP_NONE;
           }
         break;
     }
   if(g_cfg.BasketTPSafetyBufferPoints < 0)
      g_cfg.BasketTPSafetyBufferPoints = 0;
   if(g_cfg.EstimatedCommissionPerLot < 0.0)
     {
      g_log.Warn(XAU_T_CFG, "EstimatedCommissionPerLot was negative - using the absolute value");
      g_cfg.EstimatedCommissionPerLot = MathAbs(g_cfg.EstimatedCommissionPerLot);
     }

   // --- cut loss ---
   if(g_cfg.EnableBasketCutLoss)
     {
      bool any = (g_cfg.BasketCutLossMoney > 0.0 || g_cfg.BasketCutLossPercentOfBalance > 0.0 || g_cfg.BasketCutLossPoints > 0);
      if(!any)
        {
         e += "EnableBasketCutLoss=true but no cut loss threshold is positive - a basket could never be cut. Disabling cut loss.";
         g_cfg.EnableBasketCutLoss = false;
        }
      if(g_cfg.BasketCutLossPercentOfBalance > 50.0)
         g_log.Warn(XAU_T_CFG, "BasketCutLossPercentOfBalance above 50% is not a stop, it is an accept-loss plan");
     }

   // --- risk limits ---
   if(g_cfg.MaximumAccountDrawdownPercent < 0.0)
      g_cfg.MaximumAccountDrawdownPercent = 0.0;
   if(g_cfg.MaximumAccountDrawdownPercent > 90.0)
      e += "MaximumAccountDrawdownPercent above 90% provides no protection before a stop out.";
   if(g_cfg.MaximumCycleDrawdownPercent > 90.0)
      e += "MaximumCycleDrawdownPercent above 90% provides no protection before a stop out.";
   if(g_cfg.MinimumFreeMarginPercent > 0.0 && g_cfg.MinimumFreeMarginPercent < 100.0)
      e += StringFormat("MinimumFreeMarginPercent %.1f is below 100%% - the account would already be out of margin", g_cfg.MinimumFreeMarginPercent);
   if(g_cfg.RiskBlockResetHysteresisPercent < 10.0 || g_cfg.RiskBlockResetHysteresisPercent > 100.0)
     {
      g_log.Warn(XAU_T_CFG, "RiskBlockResetHysteresisPercent clamped into 10..100");
      g_cfg.RiskBlockResetHysteresisPercent = XauClamp(g_cfg.RiskBlockResetHysteresisPercent, 10.0, 100.0);
     }

   // --- filters ---
   if(g_cfg.MaximumSpreadPoints < 1)
      e += "MaximumSpreadPoints must be >= 1 when the spread filter is on.";
   if(g_cfg.EnableVolatilityFilter && g_cfg.MaximumATRPoints < g_cfg.MinimumATRPoints)
      g_log.Warn(XAU_T_CFG, "volatility filter: MaximumATRPoints <= MinimumATRPoints, only the lower bound is enforced");
   if(g_cfg.GapLookbackBars < 1 || g_cfg.GapLookbackBars > 50)
     {
      g_log.Warn(XAU_T_CFG, "GapLookbackBars clamped into 1..50");
      g_cfg.GapLookbackBars = (int)XauClampI(g_cfg.GapLookbackBars, 1, 50);
     }

   // --- session ---
   g_cfg.SessionStartHour   = (int)XauClampI(g_cfg.SessionStartHour, 0, 23);
   g_cfg.SessionStartMinute = (int)XauClampI(g_cfg.SessionStartMinute, 0, 59);
   g_cfg.SessionEndHour     = (int)XauClampI(g_cfg.SessionEndHour, 0, 23);
   g_cfg.SessionEndMinute   = (int)XauClampI(g_cfg.SessionEndMinute, 0, 59);
   g_cfg.FridayStopHour     = (int)XauClampI(g_cfg.FridayStopHour, 0, 23);
   g_cfg.FridayStopMinute   = (int)XauClampI(g_cfg.FridayStopMinute, 0, 59);
   g_cfg.MondayResumeHour   = (int)XauClampI(g_cfg.MondayResumeHour, 0, 23);
   g_cfg.MondayResumeMinute = (int)XauClampI(g_cfg.MondayResumeMinute, 0, 59);
   if(g_cfg.ProtectionMinutes < 0)
      g_cfg.ProtectionMinutes = 0;

   // --- news ---
   if(g_cfg.EnableNewsFilter)
     {
      if(StringLen(g_cfg.NewsCurrency) != 3 && StringLen(g_cfg.NewsCountryCode) < 2)
         e += "EnableNewsFilter needs NewsCurrency (3 letters) or NewsCountryCode (2 letters).";
      if(g_cfg.MinutesBeforeNews < 0 || g_cfg.MinutesAfterNews < 0)
         e += "MinutesBeforeNews / MinutesAfterNews cannot be negative.";
      if(g_cfg.NewsFailSafePolicy == XAU_FAILSAFE_ALLOW || g_cfg.NewsFailSafePolicy == XAU_FAILSAFE_WARN)
         g_log.Warn(XAU_T_CFG, "news fail-safe is ALLOW/WARN: the EA will trade while it cannot see the calendar");
     }

   // --- execution / account type ---
   if(!g_spec.IsHedgingAccount())
     {
      if(!g_cfg.AllowNettingAccounts)
         e += "This account is not a hedging account and AllowNettingAccounts=false - the averaging architecture cannot be modelled reliably.";
      else
         g_log.Warn(XAU_T_CFG, "NETTING account detected: layers are merged by the broker, so the layer history comes from the state cache; MaximumLayer is enforced from that history and averaging is blocked when the cache cannot be trusted");
     }
   if(g_cfg.MaximumDeviationPoints < 0)
      g_cfg.MaximumDeviationPoints = 0;
   g_cfg.MaxOrderRetries          = (int)XauClampI(g_cfg.MaxOrderRetries, 1, 10);
   g_cfg.FillVerificationRetries  = (int)XauClampI(g_cfg.FillVerificationRetries, 0, 10);
   g_cfg.MaxQuoteAgeSeconds       = (int)XauClampI(g_cfg.MaxQuoteAgeSeconds, 1, 86400);
   g_cfg.StateSaveIntervalSeconds = (int)XauClampI(g_cfg.StateSaveIntervalSeconds, 1, 3600);

   // --- dashboard / telegram ---
   g_cfg.DashboardFontSize        = (int)XauClampI(g_cfg.DashboardFontSize, 6, 20);
   g_cfg.DashboardUpdateIntervalMs= (int)XauClampI(g_cfg.DashboardUpdateIntervalMs, 100, 60000);
   if(g_cfg.EnableTelegram && (bool)MQLInfoInteger(MQL_TESTER))
      g_log.Warn(XAU_T_CFG, "Telegram is force-disabled in the Strategy Tester (no WebRequest)");
   if(g_cfg.TelegramMaxMessagesPerMinute < 1)
      g_cfg.TelegramMaxMessagesPerMinute = 1;
   //--- indicator timeframes: a handle on a meaningless period returns no
   //    data, so snap it to the chart period and say so instead of going quiet
   if(!XauIsRealTimeframe((int)g_cfg.EMATimeframe))
     {
      g_log.Warn(XAU_T_CFG, StringFormat("EMATimeframe=%d is not a real timeframe, using PERIOD_CURRENT",
                                         (int)g_cfg.EMATimeframe));
      g_cfg.EMATimeframe = PERIOD_CURRENT;
     }
   if(!XauIsRealTimeframe((int)g_cfg.ATRTimeframe))
     {
      g_log.Warn(XAU_T_CFG, StringFormat("ATRTimeframe=%d is not a real timeframe, using PERIOD_CURRENT",
                                         (int)g_cfg.ATRTimeframe));
      g_cfg.ATRTimeframe = PERIOD_CURRENT;
     }
   if(!XauIsRealTimeframe((int)g_cfg.VolatilityTimeframe))
     {
      g_log.Warn(XAU_T_CFG, StringFormat("VolatilityTimeframe=%d is not a real timeframe, using PERIOD_CURRENT",
                                         (int)g_cfg.VolatilityTimeframe));
      g_cfg.VolatilityTimeframe = PERIOD_CURRENT;
     }
   if(g_cfg.DailyReportTelegramHour < -1 || g_cfg.DailyReportTelegramHour > 23)
     {
      g_log.Warn(XAU_T_CFG, StringFormat("DailyReportTelegramHour=%d is outside -1..23, using -1 (off)",
                                         g_cfg.DailyReportTelegramHour));
      g_cfg.DailyReportTelegramHour = -1;
     }
   errors = e;
  }

string CConfig::Describe(void) const
  {
   return(StringFormat("dir=%s ema=%d/%d avg=%s dist=%d pts maxlayer=%d lot=%s/%s mult=%.2f maxord=%.2f maxtot=%.2f tp=%s/%s cut=%s/%s dd=%.1f/%.1f daily=%.1f%%/%s margin>=%.0f%%",
                       EnumToString(TradingDirection), FastEMAPeriod, SlowEMAPeriod,
                       EnumToString(AveragingDistanceMode), AveragingDistancePoints, MaximumLayer,
                       EnumToString(LotMode), DoubleToString(InitialLot, 2), DoubleToString(LotMultiplier, 2),
                       DoubleToString(MaximumLotPerOrder, 2), DoubleToString(MaximumTotalLot, 2),
                       EnumToString(BasketTPMode),
                       DoubleToString(BasketTakeProfitMoney, 2),
                       EnumToString(CutLossMode), DoubleToString(BasketCutLossMoney, 2),
                       MaximumAccountDrawdownPercent, MaximumCycleDrawdownPercent,
                       MaximumDailyLossPercent, EnumToString(DailyLossBasis),
                       MinimumFreeMarginPercent));
  }

//==================================================================//
// SECTION 4 - PERSISTENCE                                          |
//==================================================================//
void SaveOverrides(void)
  {
   if(!g_state.Enabled())
      return;
   g_state.SetInt("ovr_flags", g_cfg.override_flags);
   g_state.SetDbl("peak_equity", g_rt.peak_equity);
   g_state.SetInt("emg_day", (g_cfg.emergency_stop ? (long)XauServerDayStart(XauNow()) : 0));
   if((g_cfg.override_flags & XAU_OVR_LOT) != 0)        g_state.SetDbl("ovr_lot", g_cfg.InitialLot);
   if((g_cfg.override_flags & XAU_OVR_MULTIPLIER) != 0) g_state.SetDbl("ovr_mult", g_cfg.LotMultiplier);
   if((g_cfg.override_flags & XAU_OVR_DISTANCE) != 0)   g_state.SetInt("ovr_dist", g_cfg.AveragingDistancePoints);
   if((g_cfg.override_flags & XAU_OVR_TP) != 0)
     {
      g_state.SetInt("ovr_tp_mode", g_cfg.BasketTPMode);
      g_state.SetDbl("ovr_tp_value", g_cfg.BasketTakeProfitMoney);
      g_state.SetInt("ovr_tp_points", g_cfg.BasketTakeProfitPoints);
     }
   if((g_cfg.override_flags & XAU_OVR_CUTLOSS) != 0)    g_state.SetDbl("ovr_cut", g_cfg.BasketCutLossMoney);
   if((g_cfg.override_flags & XAU_OVR_DIRECTION) != 0)  g_state.SetInt("ovr_dir", g_cfg.TradingDirection);
   if((g_cfg.override_flags & XAU_OVR_MAXLAYER) != 0)   g_state.SetInt("ovr_maxlayer", g_cfg.MaximumLayer);
   if((g_cfg.override_flags & XAU_OVR_MAXLOT) != 0)     g_state.SetDbl("ovr_maxlot", g_cfg.MaximumTotalLot);
   g_state.SetBool("ovr_paused", g_cfg.user_paused);
   g_state.SetBool("ovr_emergency", g_cfg.emergency_stop);
  }

/// Restore operator flags + Telegram overrides. Called before
/// ValidateConfig so that a persisted override is validated like an input.
void LoadPersistedFlags(void)
  {
   if(!g_state.Enabled())
     {
      if(g_cfg.EnableTelegram)
         g_log.Warn(XAU_T_TG, "state persistence unavailable (tester) - overrides and emergency flag will not survive this run");
      return;
     }
   g_cfg.emergency_stop = g_state.GetBoolOr("ovr_emergency", false);
   g_rt.peak_equity = g_state.GetDblOr("peak_equity", 0.0);
   g_rt.worst_equity = AccountInfoDouble(ACCOUNT_EQUITY);
   g_cfg.user_paused    = g_state.GetBoolOr("ovr_paused", false);
   int flags = (int)g_state.GetIntOr("ovr_flags", 0);
   if(flags == 0)
      return;
   if(!g_cfg.PersistTelegramOverrides)
     {
      g_log.Warn(XAU_T_TG, "stored Telegram overrides ignored because PersistTelegramOverrides=false");
      return;
     }
   g_cfg.override_flags = (int)flags;
   if((flags & XAU_OVR_LOT) != 0)        g_cfg.InitialLot = g_state.GetDblOr("ovr_lot", g_cfg.InitialLot);
   if((flags & XAU_OVR_MULTIPLIER) != 0) g_cfg.LotMultiplier = g_state.GetDblOr("ovr_mult", g_cfg.LotMultiplier);
   if((flags & XAU_OVR_DISTANCE) != 0)   g_cfg.AveragingDistancePoints = (int)g_state.GetIntOr("ovr_dist", g_cfg.AveragingDistancePoints);
   if((flags & XAU_OVR_TP) != 0)
     {
      g_cfg.BasketTPMode = (ENUM_XAU_TP_MODE)g_state.GetIntOr("ovr_tp_mode", g_cfg.BasketTPMode);
      g_cfg.BasketTakeProfitMoney = g_state.GetDblOr("ovr_tp_value", g_cfg.BasketTakeProfitMoney);
      g_cfg.BasketTakeProfitPoints = (int)g_state.GetIntOr("ovr_tp_points", g_cfg.BasketTakeProfitPoints);
     }
   if((flags & XAU_OVR_CUTLOSS) != 0)    g_cfg.BasketCutLossMoney = g_state.GetDblOr("ovr_cut", g_cfg.BasketCutLossMoney);
   if((flags & XAU_OVR_DIRECTION) != 0)  g_cfg.TradingDirection = (ENUM_XAU_DIRECTION)g_state.GetIntOr("ovr_dir", g_cfg.TradingDirection);
   if((flags & XAU_OVR_MAXLAYER) != 0)   g_cfg.MaximumLayer = (int)g_state.GetIntOr("ovr_maxlayer", g_cfg.MaximumLayer);
   if((flags & XAU_OVR_MAXLOT) != 0)     g_cfg.MaximumTotalLot = g_state.GetDblOr("ovr_maxlot", g_cfg.MaximumTotalLot);
   g_log.Info(XAU_T_TG, StringFormat("restored %d persisted override group(s), flags=0x%s",
                                      BitCount(flags), IntegerToString(flags)));
  }

int BitCount(const int value)
  {
   int bits = 0;
   for(int i = 0; i < 16; i++)
      if((value & (1 << i)) != 0)
         bits++;
   return(bits);
  }

void TrySaveState(const bool force)
  {
   if(!g_state.Enabled())
      return;
   if(!force && g_rt.state_saved_at > 0 && (int)(XauNow() - g_rt.state_saved_at) < g_cfg.StateSaveIntervalSeconds
      && !g_state.Dirty())
      return;
   if(g_state.Save())
      g_rt.state_saved_at = XauNow();
   else
      g_log.Throttled(1, XAU_T_STATE, "save", StringFormat("state file could not be written (%s) - recovery after restart will use positions only",
                                                            g_state.FileName()), 300);
  }

//==================================================================//
// SECTION 5 - MARKET DATA / NEW BAR                                |
//==================================================================//
void UpdateMarketData(void)
  {
   // Refresh the cached broker quote on every market tick. Without this,
   // CSymbolSpec keeps the initialization tick forever, so QuoteAgeSeconds()
   // grows for the entire tester run and Risk blocks every entry/averaging.
   g_spec.UpdateQuote();
   g_rt.bid = g_spec.Bid();
   g_rt.ask = g_spec.Ask();
   g_rt.spread_points = g_spec.SpreadPoints();
   g_rt.ticks++;
   g_rt.tick_fresh = (g_spec.QuoteOk() && g_spec.QuoteAgeSeconds() <= (double)g_cfg.MaxQuoteAgeSeconds);
   datetime bt = iTime(_Symbol, PERIOD_CURRENT, 0);
   g_rt.new_bar = (bt != g_rt.bar_time);
   g_rt.last_bar_time = g_rt.bar_time;
   if(g_rt.new_bar)
      g_rt.bar_time = bt;
  }

/// Account / terminal level preconditions that must be re-checked on every
/// attempt (AutoTrading button, connection, investor password, ...).
bool EnvironmentAllowsTrading(string &why)
  {
   if((bool)MQLInfoInteger(MQL_TESTER))
     {
      why = "";
      return(true);
     }
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
     {
      why = "AutoTrading is off in the terminal toolbar";
      return(false);
     }
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
     {
      why = "this EA is not allowed to trade (check the EA properties dialog)";
      return(false);
     }
   if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))
     {
      why = "account forbids trading (investor login or broker restriction)";
      return(false);
     }
   why = "";
   return(true);
  }

//==================================================================//
// SECTION 6 - TRADING PIPELINE                                     |
//==================================================================//
void Notify(const string text)
  {
   if(g_cfg.EnableTelegram && g_tg.Enabled())
      g_tg.Notify(text + "\n[" + g_spec.Symbol() + " mg" + IntegerToString(g_cfg.MagicNumber) + "]");
  }

/// Cooldown bookkeeping + engine side reaction after a finished cycle.
void OnCycleFinished(const int exit_code, const string reason, const double net_pl)
  {
   // Capture the close snapshot BEFORE clearing the notice flag. Reconcile()
   // retires the live cycle to zero positions before this callback runs.
   bool   had_close_notice = g_close_notice_set;
   int    closed_layers    = (had_close_notice ? g_close_notice_layers : g_cycle.LayerCount());
   double closed_volume    = (had_close_notice ? g_close_notice_volume : g_cycle.TotalVolume());
   double closed_avg       = (had_close_notice ? g_close_notice_avg : g_cycle.AvgPrice());
   g_close_notice_set = false;
   int minutes = 0;
   if(exit_code == 1)
      minutes = g_cfg.CooldownAfterBasketTPMinutes;
   else
      if(exit_code == 2)
         minutes = g_cfg.CooldownAfterCutLossMinutes;
   if(minutes > 0)
      g_rt.next_entry_allowed_at = XauNow() + (datetime)(minutes * 60);
   if(g_cfg.RequireNewSignalAfterCycleClose)
      g_entry.ResetState(true);
   g_stats.RegisterCycleEnd(g_cycle.CycleId(), exit_code, net_pl);
   g_closing_basket = false;
   g_sm.SetClosing(false);
   TrySaveState(true);
   string txt = StringFormat("cycle #%d CLOSED | reason=%s exit=%d | net=%s layers=%d vol=%s avg=%s | worst DD %.2f (%.2f%%) | today: realized %s, %d cycle(s)",
                             g_cycle.CycleId(), reason, exit_code, XauMoney(net_pl),
                             closed_layers,
                             DoubleToString(closed_volume, g_spec.VolumeDigits()),
                             XauPrice(closed_avg), g_cycle.MaxDDMoney(), g_cycle.MaxDDPercent(),
                             XauMoney(g_stats.RealizedToday()), DayClosedCount());
   g_log.Info(exit_code == 2 ? XAU_T_CUT : (exit_code == 1 ? XAU_T_TP : XAU_T_STATE), txt);
   if(exit_code == 1)
      Notify("Basket TP reached for cycle #" + IntegerToString(g_cycle.CycleId()) + "\nNet: " + XauMoney(net_pl));
   else
      if(exit_code == 2)
         Notify("CUT LOSS for cycle #" + IntegerToString(g_cycle.CycleId()) + "\nNet: " + XauMoney(net_pl) +
                "\nCooldown " + IntegerToString(g_cfg.CooldownAfterCutLossMinutes) + " min");
   else
      Notify("Cycle #" + IntegerToString(g_cycle.CycleId()) + " closed (" + reason + ")\nNet: " + XauMoney(net_pl));
  }

/// Close the whole EA basket for a given reason.
/// @return true when everything is flat afterwards
bool CloseBasket(const int exit_code, const string reason)
  {
   if(!g_cycle.IsActive())
      return(true);
   g_closing_basket = true;
   g_sm.SetClosing(true);
   double net_before = g_basket.NetPL();
   // Capture the basket snapshot BEFORE CloseAllLayers(). A direct/instant
   // close can call CCycleManager::MarkClosed(), which resets live layer
   // totals to zero before OnCycleFinished() gets control.
   if(!g_close_notice_set)
     {
      g_close_notice_set    = true;
      g_close_notice_code   = exit_code;
      g_close_notice_net    = net_before;
      g_close_notice_reason = reason;
      g_close_notice_layers = g_cycle.LayerCount();
      g_close_notice_volume = g_cycle.TotalVolume();
      g_close_notice_avg    = g_cycle.AvgPrice();
     }
   int left = g_basket.CloseAllLayers(exit_code, reason);
   g_sm.SetClosing(false);
   g_closing_basket = false;
   if(left == 0)
     {
      // OnTick() observes the open->flat transition and calls
      // OnCycleFinished() exactly once, so nothing is counted twice.
      return(true);
     }
   g_log.Error(XAU_T_EXEC, StringFormat("basket not fully closed, %d position(s) left - retrying on the next tick (state stays CLOSING/IN_CYCLE)", left));
   return(false);
  }

/// Open the initial position of a new cycle.
void TryOpenCycle(const bool is_buy)
  {
   // first gate is the state machine table (cheap, and it counts illegal
   // attempts so a wiring bug becomes visible instead of silent); the detailed
   // reason comes from CRiskManager right after it
   if(!g_sm.Allows(XAU_INT_ENTRY))
     {
      g_log.Throttled(1, XAU_T_ENTRY, "gate",
                      StringFormat("state %s refuses a new entry (illegal attempts=%d)",
                                   g_sm.StateName(g_sm.State()), g_sm.IllegalAttempts()), 60);
      return;
     }
   string env_why = "";
   if(!EnvironmentAllowsTrading(env_why))
     {
      g_log.Throttled(1, XAU_T_EXEC, "env", "environment refuses trading: " + env_why, 120);
      return;
     }
   double price = (is_buy ? g_spec.Ask() : g_spec.Bid());
   double lot   = 0.0;
   SVerdict v;
   g_risk.CheckEntry(is_buy, price, lot, g_rt, v);
   if(!v.allowed)
     {
      LogBlock(XAU_T_RISK, XAU_INT_ENTRY, v);
      return;
     }
   SExecResult r;
   g_exec.Open(is_buy, lot, g_cfg.EntryComment, r);
   if(r.unverified)
     {
      g_sm.SetError("accepted order could not be verified: " + r.text);
      Notify("EXECUTION ANOMALY: " + r.text + "\nThe EA stopped trading. Verify the account manually.");
      g_log.Error(XAU_T_EXEC, r.text);
      TrySaveState(true);
      return;
     }
   if(!r.ok)
     {
      g_rt.open_failures_streak++;
      g_rt.last_open_attempt = XauNow();
      g_log.Error(XAU_T_EXEC, StringFormat("entry rejected retcode=%d | %s | lot=%.2f price=%s", r.retcode, r.text, lot, XauPrice(price)));
      if(XauRetcodeMarketBlocked(r.retcode))
         g_log.Info(XAU_T_EXEC, "market/trading unavailable right now - entry skipped, no state change");
      if(r.retcode == XAU_RC_NO_MONEY)
        {
         g_sm.SetRiskBlock(XAU_BLK_MARGIN, "broker reported insufficient margin", 0);
         Notify("MARGIN REJECTION on entry (" + r.text + "). New trading blocked by the risk engine.");
        }
      return;
     }
   g_rt.open_failures_streak = 0;
   datetime when = (r.time > 0 ? r.time : XauNow());
   g_cycle.BeginCycle((is_buy ? POSITION_TYPE_BUY : POSITION_TYPE_SELL), r.volume > 0.0 ? r.volume : lot,
                      r.price > 0.0 ? r.price : price, r.ticket, when);
   g_cycle.SetDistancePoints(g_avg.DistancePoints());
   g_stats.RegisterEntry();
   // baseline the averaging gates: the entry itself occupies this bar and
   // starts the minimum-seconds window, so a layer cannot follow instantly
   g_avg.NoteLayerOpened(0.0, g_rt.bar_time, g_rt);
   // one signal, one cycle: the signal is always consumed, OneEntryPerBar
   // additionally prevents a second signal on the same bar
   g_entry.Consume();
   g_log.Info(XAU_T_ENTRY, StringFormat("OPEN %s ticket=%s lot=%.2f price=%s | %s | cycle #%d | dd_now=%.2f%%",
                                        (is_buy ? "BUY" : "SELL"), IntegerToString(r.ticket), lot,
                                        XauPrice(r.price > 0 ? r.price : price), v.reason, g_cycle.CycleId(),
                                        g_risk.AccountDDPercent()));
   Notify(StringFormat("ENTRY %s cycle#%d\nlot %.2f @ %s\nspread %.0f pts | DD %.2f%%",
                       (is_buy ? "BUY" : "SELL"), g_cycle.CycleId(), lot, XauPrice(r.price > 0 ? r.price : price),
                       g_rt.spread_points, g_risk.AccountDDPercent()));
   TrySaveState(true);
  }

/// Averaging attempt for one candidate layer.
void TryAverage(void)
  {
   SAvgPlan plan;
   g_avg.BuildPlan(plan);
   g_cycle.SetNextLevel(plan.level);
   g_cycle.SetDistancePoints(plan.distance_points);
   if(!plan.basket_active || !plan.enabled)
      return;
   if(!plan.reached)
      return;
   // Test V of the test protocol: by default a single pipeline pass can add a
   // single layer. The escape hatch is deliberate and compound - the operator
   // must explicitly allow several layers per pass AND relax the per-bar and
   // interval gates - so that "many layers at once" can never be the default
   // behaviour of a mis-typed input.
   int max_this_pass = (g_cfg.AllowMultipleLayersPerTick ? 3 : 1);
   for(int pass = 0; pass < max_this_pass; pass++)
     {
      if(pass > 0)
        {
         // Re-derive the plan from the basket as it is now: the level of the
         // next layer is computed after the previous fill, not from a stale
         // pre-fill snapshot. Only the two "sequence" gates are relaxed, and
         // only because the operator asked for exactly that.
         g_avg.BuildPlan(plan);
         g_cycle.SetNextLevel(plan.level);
         g_cycle.SetDistancePoints(plan.distance_points);
         if(!plan.reached || !plan.enabled || !plan.basket_active)
            return;
         if(g_cfg.OneLayerPerBar || g_cfg.MinimumSecondsBetweenAveraging > 0)
           {
            g_log.Throttled(1, XAU_T_AVG, "multi",
                            "multiple layers per pass also needs OneLayerPerBar=false and MinimumSecondsBetweenAveraging=0",
                            300);
            return;
           }
         g_rt.last_avg_level_used = 0.0;
         g_rt.last_avg_open_bar   = 0;
        }
      double lot = 0.0;
      SVerdict v;
      g_risk.CheckAveraging(plan, lot, g_rt, g_rt.bar_time, v);
      if(!v.allowed)
        {
         if(v.code != XAU_BLK_LEVEL_NOT_REACHED)
            LogBlock(XAU_T_RISK, XAU_INT_AVERAGING, v);
         return;
        }
      if(!g_sm.Allows(XAU_INT_AVERAGING))
        {
         g_log.Throttled(1, XAU_T_AVG, "gate",
                         StringFormat("state %s refuses averaging (illegal attempts=%d)",
                                      g_sm.StateName(g_sm.State()), g_sm.IllegalAttempts()), 60);
         return;
        }
      string env_why = "";
      if(!EnvironmentAllowsTrading(env_why))
        {
         g_log.Throttled(1, XAU_T_EXEC, "env", "environment refuses trading: " + env_why, 120);
         return;
        }
      bool is_buy = g_cycle.IsBuyBasket();
      double price = (is_buy ? g_spec.Ask() : g_spec.Bid());
      SExecResult r;
      g_exec.Open(is_buy, lot, g_cfg.AveragingComment, r);
      if(r.unverified)
        {
         g_sm.SetError("averaging order accepted but not verified: " + r.text);
         Notify("EXECUTION ANOMALY during averaging: " + r.text + "\nTrading stopped, verify the account manually.");
         return;
        }
      if(!r.ok)
        {
         g_log.Error(XAU_T_AVG, StringFormat("layer L%d rejected retcode=%d | %s", plan.next_layer, r.retcode, r.text));
         if(r.retcode == XAU_RC_NO_MONEY)
            g_sm.SetRiskBlock(XAU_BLK_MARGIN, "broker reported insufficient margin on averaging", 0);
         return;
        }
      datetime when = (r.time > 0 ? r.time : XauNow());
      g_cycle.NoteFill(r.ticket, r.volume > 0.0 ? r.volume : lot,
                       r.price > 0.0 ? r.price : price, when);
      g_stats.RegisterAveraging();
      // Record the ACTUAL verified fill price, not the requested level.\n      // Slippage/fill differences can otherwise make the next level look\n      // like a duplicate even though the broker filled at a different price.\n      double opened_level = (r.price > 0.0 ? r.price : price);\n      g_avg.NoteLayerOpened(opened_level, g_rt.bar_time, g_rt);
      g_log.Info(XAU_T_AVG, StringFormat("LAYER %d opened | ticket=%s lot=%.2f price=%s level=%s dist=%.0f pts | basket: vol=%s avg=%s | float=%s | cycle #%d",
                                         g_cycle.LayerCount(), IntegerToString(r.ticket), lot,
                                         XauPrice(r.price > 0 ? r.price : price), XauPrice(plan.level),
                                         plan.distance_points,
                                         DoubleToString(g_cycle.TotalVolume(), g_spec.VolumeDigits()),
                                         XauPrice(g_cycle.AvgPrice()), XauMoney(g_basket.NetPL()), g_cycle.CycleId()));
      Notify(StringFormat("AVERAGING L%d lot %.2f @ %s\nBasket: %s lots avg %s | float %s",
                          g_cycle.LayerCount(), lot, XauPrice(r.price > 0 ? r.price : price),
                          DoubleToString(g_cycle.TotalVolume(), 2), XauPrice(g_cycle.AvgPrice()),
                          XauMoney(g_basket.NetPL())));
      TrySaveState(true);
      // recompute the geometry for a possible next level; risk has the
      // final word again on the next iteration
      g_cycle.Reconcile();
      g_basket.Recompute();
      g_avg.BuildPlan(plan);
      if(!plan.reached)
         return;
      if(g_cycle.LayerCount() >= g_cfg.MaximumLayer)
        {
         g_log.Info(XAU_T_MAXLAYER, StringFormat("MaximumLayer %d reached - no further averaging this pass", g_cfg.MaximumLayer));
         return;
        }
     }
  }

/// Blocked decisions are logged once per condition, not once per tick.
void LogBlock(const string tag, const ENUM_XAU_INTENT intent, const SVerdict &v)
  {
   bool changed = (v.code != g_last_block_code || g_last_block_reason != v.reason);
   g_last_block_reason = v.reason;
   g_last_block_code   = v.code;
   // the counter only moves when the *reason* changes, so a condition
   // that stays true for an hour is one blocked event, not 3600
   if(changed)
      g_stats.RegisterBlocked();
   string key = g_sm.BlockName(v.code) + "|" + IntegerToString((int)intent);
   if(g_cfg.EnableDebugTickLog)
      g_log.Raw(tag, StringFormat("[%s] %s | %s", g_sm.BlockName(v.code), v.reason, g_cycle.Describe()));
   else
      g_log.Throttled(2, tag, key, StringFormat("%s | %s | %s", g_sm.BlockName(v.code), v.reason, g_cycle.Describe()),
                      g_cfg.LogThrottleSeconds);
  }

/// The deterministic pipeline. Identical in the tester and live.
void RunPipeline(void)
  {
   g_pipeline_runs++;
   // 1 - market snapshot and indicator refresh (new bar only)
   UpdateMarketData();
   if(g_rt.new_bar)
     {
      g_entry.Update(g_rt.bar_time, true);
      g_avg.Refresh(g_rt.bar_time, true);
      g_filters.Update(g_rt.bar_time, true, g_rt);
     }
   else
     {
      g_entry.Update(g_rt.bar_time, false);
      if(g_cfg.AllowIntraBarATRRefresh)
         g_avg.Refresh(g_rt.bar_time, false);
     }

   // 2 - rebuild the basket from the account, then basket maths
   g_cycle.Reconcile();
   g_basket.Recompute();
   // A close request may have executed, while the cycle manager only observes
   // the flat account on the following reconciliation. Do not allow the entry
   // engine to open a replacement cycle before the pending close is recorded.
   if(g_close_notice_set && !g_cycle.IsActive())
      return;
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   if(g_rt.worst_equity <= 0.0 || equity < g_rt.worst_equity)
      g_rt.worst_equity = equity;
   if(g_rt.peak_equity < equity)
     {
      g_rt.peak_equity = equity;
      g_risk.SetPeakEquity(g_rt.peak_equity);
     }
   if(g_cycle.IsActive())
     {
      double pct = (g_cycle.BalanceAtStart() > 0.0 ? g_basket.NetPL() / g_cycle.BalanceAtStart() * 100.0 : 0.0);
      g_cycle.UpdateDrawdown(balance);
      g_stats.Observe(g_cycle.LayerCount(), g_cycle.TotalVolume(), g_basket.NetPL(), pct);
     }
   bool level_reached = false;
   if(g_cycle.IsActive() && g_cfg.EnableAveraging)
     {
      SAvgPlan plan;
      g_avg.BuildPlan(plan);
      level_reached = plan.reached;
      g_cycle.SetNextLevel(plan.level);
      g_cycle.SetDistancePoints(plan.distance_points);
     }
   else
     {
      g_cycle.SetNextLevel(0.0);
     }

   // 3 - state machine
   g_sm.Derive(g_cycle.IsActive(), level_reached);

   // 4 - hard limits (they may request closing, and always come first)
   SActionReq act;
   act.need_close_basket = false;
   act.need_close_all    = false;
   act.need_emergency    = false;
   act.need_pause        = false;
   act.exit_code         = 0;
   act.reason            = "";
   g_risk.EvaluateLimits(act);
   g_risk.SetTodayEntries(DayEntriesCount());
   if(g_sm.RiskBlocked())
      g_risk.ResetCheck(g_rt);
   if(act.need_emergency)
     {
      g_sm.SetEmergency(true, act.reason);
      SaveOverrides();
      TrySaveState(true);
     }
   if(act.need_close_basket || act.need_close_all)
     {
      g_log.Error(XAU_T_RISK, "risk action requests closing: " + act.reason);
      Notify("RISK ACTION: " + act.reason + "\nClosing the EA positions now.");
      if(g_cycle.IsActive())
         CloseBasket(act.exit_code > 0 ? act.exit_code : 3, "risk action");
      else
         if(act.need_close_all)
           {
            // CLOSE_ALL is stronger than CLOSE_BASKET: it sweeps every
            // position carrying this EA's magic number on this symbol even
            // when no cycle is tracked (e.g. an uncertain netting basket that
            // was deliberately not adopted). Foreign positions are never
            // touched - that is a hard rule of this EA, not a preference.
            int n = g_basket.CloseEverything();
            g_log.Warn(XAU_T_RISK, IntegerToString(n) + " EA position(s) closed by the risk sweep");
            TrySaveState(true);
           }
      if(g_cfg.emergency_stop)
         g_log.Error(XAU_T_STATE, "EMERGENCY STOP active - no new entries or averaging until it is cleared");
      // a hard limit is active: no averaging and no entry on this pass
      return;
     }
   if(act.need_emergency && !g_cycle.IsActive())
      return;

   // 5 - exit management first: TP, then cut loss
   if(g_cycle.IsActive())
     {
      g_basket.UpdateTakeProfit();
      if(g_filters.ShouldFlattenBeforeWeekend())
        {
         g_log.Info(XAU_T_SESSION, "Friday stop reached - flattening the basket (CloseBasketBeforeFridayStop)");
         if(CloseBasket(6, "weekend flatten"))
            return;
        }
      if(g_basket.TakeProfitReached())
        {
         g_log.Info(XAU_T_TP, StringFormat("basket TP hit | tp=%s close_ref=%s net=%s target=%s | %s",
                                           XauPrice(g_basket.TPPrice()), XauPrice(g_spec.Bid()),
                                           XauMoney(g_basket.NetPL()), XauMoney(g_basket.TargetMoney()),
                                           g_basket.TPNote()));
         CloseBasket(1, "basket TP");
         return;
        }
      SVerdict cv;
      g_basket.CheckCutLoss(cv);
      if(!cv.allowed)
        {
         g_log.Error(XAU_T_CUT, cv.reason);
         CloseBasket(2, "basket cut loss");
         return;
        }
      // 6 - averaging (only when nothing needed to be closed)
      TryAverage();
      return;
     }

   // 7 - entry management
   if(!g_cfg.AllowNewCycles || g_sm.Emergency() || g_sm.Paused())
      return;
   int sig = g_entry.Signal();
   if(sig == 0)
      return;
   TryOpenCycle(sig > 0);
  }

int DayEntriesCount(void)
  {
   SDayStats d;
   g_stats.Get(d);
   return(d.entries);
  }
int DayClosedCount(void)
  {
   SDayStats d;
   g_stats.Get(d);
   return(d.closed_cycles);
  }
/// Emergency stop that is configured to release on the next server day.
void CheckEmergencyAutoReset(void)
  {
   if(!g_cfg.emergency_stop || g_cfg.EmergencyResetMode != XAU_EMR_NEXT_DAY)
      return;
   long armed_day = (long)g_state.GetIntOr("emg_day", 0);
   if(armed_day <= 0)
      return;
   if(XauServerDayStart(XauNow()) > (datetime)armed_day)
     {
      g_sm.SetEmergency(false, "auto release at the next server day");
      g_sm.ClearRiskBlock("emergency auto released (next server day)");
      g_state.SetInt("emg_day", 0);
      SaveOverrides();
      TrySaveState(true);
      Notify("EMERGENCY STOP released automatically (EmergencyResetMode=NEXT_DAY).");
     }
  }

//==================================================================//
// SECTION 7 - TELEGRAM COMMAND HANDLING                            |
//==================================================================//
bool ParseNum(const string args, double &num)
  {
   string first = args;
   int sp = StringFind(first, " ");
   if(sp > 0)
      first = StringSubstr(first, 0, sp);
   if(StringLen(first) == 0)
      return(false);
   for(int i = 0; i < StringLen(first); i++)
     {
      ushort c = StringGetCharacter(first, i);
      bool okc = (c >= '0' && c <= '9') || c == '.' || c == '-' || c == '+';
      if(!okc)
         return(false);
     }
   num = StringToDouble(first);
   return(MathIsValidNumber(num));
  }
bool ParseFirstToken(const string args, string &tok)
  {
   string s = args;
   StringTrimLeft(s);
   int sp = StringFind(s, " ");
   tok = (sp > 0 ? StringSubstr(s, 0, sp) : s);
   StringToLower(tok);
   return(StringLen(tok) > 0);
  }
double SecondNumber(const string args, double &num)
  {
   string s = args;
   StringTrimLeft(s);
   int sp = StringFind(s, " ");
   if(sp < 0)
      return(0.0);
   string rest = StringSubstr(s, sp + 1);
   StringTrimLeft(rest);
   if(!ParseNum(rest, num))
      return(0.0);
   return(1.0);
  }

/// Human readable summary of the active Telegram overrides. Kept next to the
/// setter so a status line and a log line can never disagree about it.
string OverrideSummary(void)
  {
   if(g_cfg.override_flags == 0)
      return("none");
   string out = "";
   if((g_cfg.override_flags & XAU_OVR_LOT) != 0)
      out += "InitialLot=" + DoubleToString(g_cfg.InitialLot, g_spec.VolumeDigits()) + " ";
   if((g_cfg.override_flags & XAU_OVR_MULTIPLIER) != 0)
      out += "LotMultiplier=" + DoubleToString(g_cfg.LotMultiplier, 2) + " ";
   if((g_cfg.override_flags & XAU_OVR_DISTANCE) != 0)
      out += "AveragingDistancePoints=" + IntegerToString(g_cfg.AveragingDistancePoints) + " ";
   if((g_cfg.override_flags & XAU_OVR_TP) != 0)
      out += "BasketTP=" + EnumToString(g_cfg.BasketTPMode) + " ";
   if((g_cfg.override_flags & XAU_OVR_CUTLOSS) != 0)
      out += "CutLoss=" + (g_cfg.EnableBasketCutLoss ? "on" : "off") + " ";
   if((g_cfg.override_flags & XAU_OVR_DIRECTION) != 0)
      out += "Direction=" + EnumToString(g_cfg.TradingDirection) + " ";
   if((g_cfg.override_flags & XAU_OVR_MAXLAYER) != 0)
      out += "MaximumLayer=" + IntegerToString(g_cfg.MaximumLayer) + " ";
   if((g_cfg.override_flags & XAU_OVR_MAXLOT) != 0)
      out += "MaximumTotalLot=" + DoubleToString(g_cfg.MaximumTotalLot, 2) + " ";
   StringTrimRight(out);
   return(out);
  }

void SetOverrideFlag(const int bit)
  {
   g_cfg.override_flags |= bit;
   SaveOverrides();
   TrySaveState(true);
  }

/// Execute one queued command. Every parameter path validates the range,
/// applies it to g_cfg only, confirms, logs and notifies (spec section 20).
void HandleCommand(const string name, const string args)
  {
   string reply = "";
   double num = 0.0;
   string tok = "";
   g_log.Info(XAU_T_TG, StringFormat("command /%s args='%s'", name, args));

   if(name == "help")
     {
      g_tg.Reply("/status /stats /report /version /ping\n"
                 "/start /stop /pause /resume /emergency /emergency_clear\n"
                 "/closeall /closebuy /closesell (each needs /confirm_<cmd>)\n"
                 "/setlot 0.02 | /setmultiplier 1.5 | /setdistance 400\n"
                 "/settp money|points|percent|price|off <value> | /setcutloss money|percent|points|off <value>\n"
                 "/setdirection buy|sell|both | /setmaxlayer 6 | /setmaxlot 0.5 | /resetparams\n"
                 "Only these commands exist. Magic " + IntegerToString(g_cfg.MagicNumber));
      return;
     }
   if(name == "version")
     {
      g_tg.Reply(XAU_EA_NAME + " v" + XAU_EA_VERSION +
                 "\nsymbol " + g_spec.Symbol() + " | magic " + IntegerToString(g_cfg.MagicNumber));
      return;
     }
   if(name == "ping")
     {
      g_tg.Reply(StringFormat("pong | state %s | last poll %s | sent %d recv %d",
                              g_sm.StateName(g_sm.State()), TimeToString(g_tg.LastPollOk(), TIME_SECONDS),
                              g_tg.SentCount(), g_tg.RecvCount()));
      return;
     }
   if(name == "status")
     {
      g_tg.Reply(StatusReport());
      return;
     }
   if(name == "stats" || name == "report")
     {
      g_tg.Reply(g_stats.DailyReport());
      return;
     }

   //--- confirm flow for destructive actions ------------------------
   if(StringFind(name, "confirm_") == 0)
     {
      string want = StringSubstr(name, 8);
      if(!g_tg.HasPendingConfirm())
        {
         g_tg.Reply("Nothing to confirm (the request expired after 90 s or was never made).");
         return;
        }
      if(g_tg.PendingAction() != want)
        {
         g_tg.Reply("Confirmation mismatch: pending action is /" + g_tg.PendingAction());
         return;
        }
      string action = g_tg.PendingAction();
      g_tg.DisarmConfirmation();
      int n = 0;
      if(action == "closeall")
         n = g_basket.CloseEverything();
      else
         if(action == "closebuy")
            n = g_basket.CloseDirection(POSITION_TYPE_BUY);
         else
            if(action == "closesell")
               n = g_basket.CloseDirection(POSITION_TYPE_SELL);
      g_log.Warn(XAU_T_TG, StringFormat("destructive command /%s executed by Telegram: %d position(s) closed", action, n));
      g_cycle.Reconcile();
      g_basket.Recompute();
      TrySaveState(true);
      g_tg.Reply("Executed /" + action + ": " + IntegerToString(n) + " position(s) closed by the operator.");
      return;
     }
   if(name == "cancel")
     {
      g_tg.DisarmConfirmation();
      g_tg.ClearQueue();
      g_tg.Reply("Pending confirmation cleared, command queue dropped.");
      return;
     }
   if(name == "closeall" || name == "closebuy" || name == "closesell")
     {
      if(g_cfg.RequireConfirmationForDestructive)
        {
         g_tg.ArmConfirmation(name);
         string upper_name = name;
         StringToUpper(upper_name);
         g_tg.Reply("CONFIRM " + upper_name + ":\nReply with /confirm_" + name + " within 90 seconds.\nNothing has been executed.");
         return;
        }
      int n = (name == "closeall" ? g_basket.CloseEverything()
              : (name == "closebuy" ? g_basket.CloseDirection(POSITION_TYPE_BUY) : g_basket.CloseDirection(POSITION_TYPE_SELL)));
      g_log.Warn(XAU_T_TG, StringFormat("/%s executed without confirmation: %d position(s) closed", name, n));
      g_tg.Reply("Executed /" + name + ": " + IntegerToString(n) + " position(s) closed.");
      g_cycle.Reconcile();
      TrySaveState(true);
      return;
     }

   //--- soft controls ------------------------------------------------
   if(name == "start")
     {
      g_cfg.AllowNewCycles = true;
      g_sm.SetPaused(false, "Telegram /start");
      SetOverrideFlag(0);
      reply = "New cycles ENABLED (basket, if any, is kept). " + g_cfg.Describe();
     }
   else
      if(name == "stop")
        {
         g_cfg.AllowNewCycles = false;
         reply = "New cycles DISABLED. Existing positions are NOT closed - use /closeall for that.";
        }
      else
         if(name == "pause")
           {
            g_sm.SetPaused(true, "Telegram /pause");
            SetOverrideFlag(0);
            reply = "PAUSED: no entries, no averaging. Basket TP / cut loss / risk closing stay active.";
           }
         else
            if(name == "resume")
              {
               g_sm.SetPaused(false, "Telegram /resume");
               SetOverrideFlag(0);
               reply = "RESUMED.";
              }
            else
               if(name == "emergency")
                 {
                  g_sm.SetEmergency(true, "Telegram /emergency");
                  g_sm.SetRiskBlock(XAU_BLK_EMERGENCY, "manual emergency stop from Telegram", 0);
                  SetOverrideFlag(0);
                  g_log.Error(XAU_T_TG, "EMERGENCY STOP activated from Telegram - flattening and blocking");
                  if(g_cycle.IsActive())
                     CloseBasket(4, "manual emergency stop");
                  reply = StringFormat("EMERGENCY STOP active. %s",
                                       (g_cfg.EmergencyResetMode == XAU_EMR_MANUAL
                                        ? "Release it with /emergency_clear."
                                        : "It releases automatically on the next server day."));
                 }
               else
                  if(name == "emergency_clear")
                    {
                     if(g_cfg.EmergencyResetMode == XAU_EMR_MANUAL)
                       {
                        g_sm.SetEmergency(false, "Telegram /emergency_clear");
                        g_sm.ClearRiskBlock("Telegram /emergency_clear");
                        SetOverrideFlag(0);
                        g_log.Warn(XAU_T_TG, "EMERGENCY STOP cleared by Telegram");
                        reply = "Emergency cleared. Risk limits are re-evaluated on the next tick; no position is opened before every limit passes again.";
                       }
                     else
                       {
                        reply = StringFormat("EmergencyResetMode=NEXT_DAY: the stop releases automatically on the next server day (armed %s). /emergency_clear is rejected by design.",
                                             TimeToString((datetime)g_state.GetIntOr("emg_day", 0), TIME_DATE|TIME_MINUTES));
                        g_log.Warn(XAU_T_TG, "/emergency_clear rejected: reset mode is NEXT_DAY");
                       }
                    }
                  else
                     if(name == "resetparams")
                       {
                        g_state.ErasePrefix("ovr_");
                        TrySaveState(true);
                        reply = "Overrides erased. Reload the chart (or restart the EA) to go back to the input values.";
                       }
                     else
                        if(!g_cfg.TelegramEnableOverrides)
                           reply = "Parameter overrides are disabled (TelegramEnableOverrides=false). Use /status, /stats, /report, /start, /stop, /pause, /resume.";
                        else
                          {
                           //--- parameter commands, all range validated
                           if(name == "setlot")
                             {
                              if(!ParseNum(args, num))
                                 reply = "Usage: /setlot <lot>  (number only)";
                              else
                                 if(num < g_spec.VolumeMin() - 1.0e-9)
                                    reply = StringFormat("Rejected: %.4f is below the broker minimum %.2f", num, g_spec.VolumeMin());
                                 else
                                    if(num > g_cfg.MaximumLotPerOrder + 1.0e-9)
                                       reply = StringFormat("Rejected: %.4f is above MaximumLotPerOrder %.2f", num, g_cfg.MaximumLotPerOrder);
                                    else
                                      {
                                       double snapped = g_spec.NormalizeVolume(num, true);
                                       if(snapped <= 0.0)
                                          reply = "Rejected: value cannot be normalised to the broker volume step";
                                       else
                                         {
                                          g_cfg.InitialLot = snapped;
                                          SetOverrideFlag(XAU_OVR_LOT);
                                          reply = StringFormat("InitialLot = %.2f (was %.2f). MaximumLotPerOrder still caps every layer.",
                                                                snapped, InitialLot);
                                          g_log.Warn(XAU_T_CFG, "InitialLot changed by Telegram to " + DoubleToString(snapped, 2));
                                         }
                                      }
                             }
                           else
                              if(name == "setmultiplier")
                                {
                                 if(!ParseNum(args, num))
                                    reply = "Usage: /setmultiplier <1.0..3.0>";
                                 else
                                    if(num < 1.0 || num > 3.0)
                                       reply = StringFormat("Rejected: multiplier %.2f outside 1.00..3.00", num);
                                    else
                                      {
                                       g_cfg.LotMultiplier = num;
                                       SetOverrideFlag(XAU_OVR_MULTIPLIER);
                                       reply = StringFormat("LotMultiplier = %.2f -> last layer is x%.2f of the base lot",
                                                             num, MathPow(num, MathMax(0, g_cfg.MaximumLayer - 1)));
                                      }
                                }
                              else
                                 if(name == "setdistance")
                                   {
                                    if(!ParseNum(args, num))
                                       reply = "Usage: /setdistance <points> (10..20000)";
                                    else
                                       if(num < 10 || num > 20000)
                                          reply = StringFormat("Rejected: %.0f pts outside 10..20000", num);
                                       else
                                         {
                                          g_cfg.AveragingDistancePoints = (int)MathRound(num);
                                          if(g_cfg.AveragingDistanceMode != XAU_AVG_FIXED)
                                            {
                                             g_cfg.AveragingDistanceMode = XAU_AVG_FIXED;
                                             g_log.Warn(XAU_T_CFG, "AveragingDistanceMode switched to FIXED because /setdistance only applies to FIXED mode");
                                            }
                                          SetOverrideFlag(XAU_OVR_DISTANCE);
                                          reply = StringFormat("Averaging distance = %d pts (%s price). Mode switched to FIXED if it was ATR.",
                                                               g_cfg.AveragingDistancePoints,
                                                               DoubleToString(g_cfg.AveragingDistancePoints * g_spec.Point(), g_spec.Digits()));
                                         }
                                   }
                                 else
                                    if(name == "settp")
                                      {
                                       if(!ParseFirstToken(args, tok))
                                          reply = "Usage: /settp money|points|percent|price|off [value]";
                                       else
                                         {
                                          SecondNumber(args, num);
                                          if(tok == "off")
                                            {
                                             g_cfg.BasketTPMode = XAU_TP_NONE;
                                             SetOverrideFlag(XAU_OVR_TP);
                                             reply = "Basket TP disabled.";
                                            }
                                          else
                                             if(tok == "money" && num > 0.0 && num <= 1000000.0)
                                               {
                                                g_cfg.BasketTPMode = XAU_TP_MONEY;
                                                g_cfg.BasketTakeProfitMoney = num;
                                                SetOverrideFlag(XAU_OVR_TP);
                                                reply = StringFormat("Basket TP = %s (money).", XauMoney(num));
                                               }
                                             else
                                                if(tok == "points" && num >= 1.0 && num <= 100000.0)
                                                  {
                                                   g_cfg.BasketTPMode = XAU_TP_POINTS;
                                                   g_cfg.BasketTakeProfitPoints = (int)MathRound(num);
                                                   SetOverrideFlag(XAU_OVR_TP);
                                                   reply = StringFormat("Basket TP = %d points from the average price.", g_cfg.BasketTakeProfitPoints);
                                                  }
                                                else
                                                   if(tok == "percent" && num > 0.0 && num <= 25.0)
                                                     {
                                                      g_cfg.BasketTPMode = XAU_TP_PERCENT;
                                                      g_cfg.BasketTakeProfitPercent = num;
                                                      SetOverrideFlag(XAU_OVR_TP);
                                                      reply = StringFormat("Basket TP = %.2f%% of the basket cost basis.", num);
                                                     }
                                                   else
                                                      if(tok == "price" && num > 0.0 && num <= 10000.0)
                                                        {
                                                         g_cfg.BasketTPMode = XAU_TP_PRICE;
                                                         g_cfg.BasketTakeProfitPrice = num;
                                                         SetOverrideFlag(XAU_OVR_TP);
                                                         reply = StringFormat("Basket TP = %.2f price units from the average.", num);
                                                        }
                                                      else
                                                         reply = "Rejected: /settp needs a valid mode and value (money 0..1e6, points 1..1e5, percent 0..25, price 0..1e4)";
                                         }
                                      }
                                    else
                                       if(name == "setcutloss")
                                         {
                                          if(!ParseFirstToken(args, tok))
                                             reply = "Usage: /setcutloss money|percent|points|off [value]";
                                          else
                                            {
                                             SecondNumber(args, num);
                                             if(tok == "off")
                                               {
                                                g_cfg.EnableBasketCutLoss = false;
                                                SetOverrideFlag(XAU_OVR_CUTLOSS);
                                                reply = "Basket cut loss DISABLED - the basket can then only be closed by a risk limit.";
                                               }
                                             else
                                                if(tok == "money" && num > 0.0 && num <= 1000000.0)
                                                  {
                                                   g_cfg.EnableBasketCutLoss = true;
                                                   g_cfg.BasketCutLossMoney = num;
                                                   SetOverrideFlag(XAU_OVR_CUTLOSS);
                                                   reply = StringFormat("Basket cut loss = %s money.", XauMoney(-num));
                                                  }
                                                else
                                                   if(tok == "percent" && num > 0.0 && num <= 50.0)
                                                     {
                                                      g_cfg.EnableBasketCutLoss = true;
                                                      g_cfg.BasketCutLossPercentOfBalance = num;
                                                      SetOverrideFlag(XAU_OVR_CUTLOSS);
                                                      reply = StringFormat("Basket cut loss = %.2f%% of balance.", num);
                                                     }
                                                   else
                                                      if(tok == "points" && num >= 10.0 && num <= 100000.0)
                                                        {
                                                         g_cfg.EnableBasketCutLoss = true;
                                                         g_cfg.BasketCutLossPoints = (int)MathRound(num);
                                                         SetOverrideFlag(XAU_OVR_CUTLOSS);
                                                         reply = StringFormat("Basket cut loss = %d points against the average.", (int)MathRound(num));
                                                        }
                                                      else
                                                         reply = "Rejected: /setcutloss needs a valid mode and value";
                                            }
                                         }
                                       else
                                          if(name == "setdirection")
                                            {
                                             if(!ParseFirstToken(args, tok))
                                                reply = "Usage: /setdirection buy|sell|both";
                                             else
                                               {
                                                if(tok == "buy")
                                                   g_cfg.TradingDirection = XAU_DIR_BUY_ONLY;
                                                else
                                                   if(tok == "sell")
                                                      g_cfg.TradingDirection = XAU_DIR_SELL_ONLY;
                                                  else
                                                     if(tok == "both")
                                                        g_cfg.TradingDirection = XAU_DIR_BOTH;
                                                     else
                                                      {
                                                       reply = "Rejected: use buy, sell or both";
                                                       return;
                                                      }
                                                SetOverrideFlag(XAU_OVR_DIRECTION);
                                                reply = "TradingDirection = " + EnumToString(g_cfg.TradingDirection);
                                               }
                                            }
                                          else
                                             if(name == "setmaxlayer")
                                               {
                                                if(!ParseNum(args, num))
                                                   reply = "Usage: /setmaxlayer <1..20>";
                                                else
                                                   if(num < 1 || num > 20)
                                                      reply = StringFormat("Rejected: %.0f outside 1..20", num);
                                                    else
                                                     {
                                                      int lowering = (int)MathRound(num);
                                                      if(lowering <= g_cycle.LayerCount() && g_cycle.IsActive())
                                                         g_log.Warn(XAU_T_MAXLAYER, StringFormat("MaximumLayer lowered to %d while the basket already holds %d layers - no further averaging will be added",
                                                                                                 lowering, g_cycle.LayerCount()));
                                                      g_cfg.MaximumLayer = lowering;
                                                      SetOverrideFlag(XAU_OVR_MAXLAYER);
                                                      reply = StringFormat("MaximumLayer = %d (lowering it never closes an existing basket).", g_cfg.MaximumLayer);
                                                     }
                                               }
                                             else
                                                if(name == "setmaxlot")
                                                  {
                                                   if(!ParseNum(args, num))
                                                      reply = "Usage: /setmaxlot <lots> (>= InitialLot, <= broker max)";
                                                   else
                                                      if(num < g_cfg.InitialLot || num > g_spec.VolumeMax())
                                                         reply = StringFormat("Rejected: %.2f outside %.2f..%.2f", num, g_cfg.InitialLot, g_spec.VolumeMax());
                                                      else
                                                        {
                                                         if(g_cycle.IsActive() && num < g_cycle.TotalExposure())
                                                            g_log.Warn(XAU_T_MAXLOT, StringFormat("MaximumTotalLot %.2f is below the current basket exposure %.2f - existing positions are kept, no averaging is possible",
                                                                                                    num, g_cycle.TotalExposure()));
                                                         g_cfg.MaximumTotalLot = num;
                                                         SetOverrideFlag(XAU_OVR_MAXLOT);
                                                         reply = StringFormat("MaximumTotalLot = %.2f lots. Existing exposure is never increased by this change.", num);
                                                        }
                                                  }
                                                else
                                                   reply = "Unknown parameter command. /help lists everything.";
                          }
   if(StringLen(reply) > 0)
     {
      g_tg.Reply(reply);
      g_log.Info(XAU_T_TG, "reply: " + reply);
     }
  }

/// 12 rows of live status for the Telegram /status command.
string StatusReport(void)
  {
   string nl = "\n";
   SDayStats d;
   g_stats.Get(d);
   string s = "";
   s += XAU_EA_NAME + " v" + XAU_EA_VERSION + " | " + g_cfg.EANameLabel + nl;
   s += "Symbol    : " + g_spec.Symbol() + " (" + (g_spec.IsHedgingAccount() ? "hedging" : "netting") + ")  magic " + IntegerToString(g_cfg.MagicNumber) + nl;
   s += "State     : " + g_sm.StateName(g_sm.State()) + (StringLen(g_sm.DescribeCondition()) > 6 ? " - " + g_sm.DescribeCondition() : "") + nl;
   s += StringFormat("Transitions : %d   rejected-by-state %d   state since %s%s", g_sm.Transitions(), g_sm.IllegalAttempts(),
                     TimeToString(g_sm.Since(), TIME_MINUTES),
                     (g_sm.SelfTestHalt() ? "   SELFTEST HALT" : "")) + nl;
   s += "Direction : " + EnumToString(g_cfg.TradingDirection) + "  buy=" + (g_cfg.BuyEnabled ? "on" : "off") +
        " sell=" + (g_cfg.SellEnabled ? "on" : "off") + " new_cycles=" + (g_cfg.AllowNewCycles ? "on" : "off") + nl;
   if(g_cycle.IsActive())
     {
      s += "Cycle     : #" + IntegerToString(g_cycle.CycleId()) + " " + (g_cycle.IsBuyBasket() ? "BUY" : "SELL") +
           " since " + TimeToString(g_cycle.StartTime(), TIME_DATE | TIME_MINUTES) + nl;
      s += "Layer     : " + IntegerToString(g_cycle.LayerCount()) + "/" + IntegerToString(g_cfg.MaximumLayer) + nl;
      s += "Total lot : " + DoubleToString(g_cycle.TotalVolume(), g_spec.VolumeDigits()) + " / " + DoubleToString(g_cfg.MaximumTotalLot, 2) + nl;
      s += "Average   : " + XauPrice(g_cycle.AvgPrice()) + "  (break-even " + XauPrice(g_basket.BreakEvenPrice()) + ")" + nl;
      s += "Next avg  : " + XauPrice(g_cycle.NextLevel()) + " (" + DoubleToString(g_cycle.DistancePoints(), 0) + " pts)" + nl;
      s += "Basket TP : " + XauPrice(g_basket.TPPrice()) + " (" + DoubleToString(g_basket.TPPoints(), 1) + " pts, target " + XauMoney(g_basket.TargetMoney()) + ")" + nl;
      s += "Floating  : " + XauMoney(g_basket.NetPL()) + " (gross " + XauMoney(g_basket.GrossPL()) + ", swap " +
           DoubleToString(g_basket.SwapTotal(), 2) + ", comm est " + DoubleToString(g_basket.CommissionEstimate(), 2) + ")" + nl;
      s += "Worst DD  : " + DoubleToString(g_cycle.MaxDDMoney(), 2) + " (" + DoubleToString(g_cycle.MaxDDPercent(), 2) + "%)" + nl;
      s += "Layers    : " + g_cycle.LayerList() + nl;
     }
   else
      s += "Cycle     : none open" + nl;
   s += "Daily     : realized " + XauMoney(g_stats.RealizedToday()) + ", entries " + IntegerToString(d.entries) +
        ", avg " + IntegerToString(d.avg_orders) + ", TP " + IntegerToString(d.basket_tp_events) +
        ", CL " + IntegerToString(d.cut_loss_events) + nl;
   s += "Account   : balance " + XauMoney(AccountInfoDouble(ACCOUNT_BALANCE)) + "  equity " + XauMoney(AccountInfoDouble(ACCOUNT_EQUITY)) + nl;
   s += "Risk      : " + g_risk.DescribeLimits() + nl;
   s += "Filters   : " + g_filters.Describe() + nl;
   s += "News      : " + g_news.Describe() + nl;
   s += "Entry     : " + g_entry.Describe() + " | " + g_entry.Reason() + nl;
   s += "Averaging : " + g_avg.Describe() + nl;
   s += "Exec      : " + g_exec.Describe() + " (ok " + IntegerToString(g_exec.OkCount()) + ", failed " +
        IntegerToString(g_exec.FailedCount()) + ", unverified " + IntegerToString(g_exec.UnverifiedCount()) + ")" + nl;
   s += "Telegram  : " + g_tg.Describe() + nl;
   s += "Overrides : " + OverrideSummary() + nl;
   return(s);
  }

//==================================================================//
// SECTION 8 - DASHBOARD COMPOSITION                                |
//==================================================================//
void BuildDashboard(void)
  {
   if(!g_dash.Active())
      return;
   SDayStats d;
   g_stats.Get(d);
   g_dash.Begin();
   g_dash.Add("EA", g_cfg.EANameLabel + " v" + XAU_EA_VERSION, g_cfg.ColorHeader);
   color st_col = g_cfg.ColorNormal;
   if(g_sm.Emergency() || g_sm.ErrorFlag())
      st_col = g_cfg.ColorDanger;
   else
      if(g_sm.Paused() || g_sm.RiskBlocked())
         st_col = g_cfg.ColorWarning;
   g_dash.Add("STATUS", g_sm.StateName(g_sm.State()), st_col);
   g_dash.Add("SYMBOL", g_spec.Symbol() + " " + (g_spec.IsHedgingAccount() ? "(hedging)" : "(netting)"), g_cfg.ColorNormal);
   g_dash.Add("DIRECTION", EnumToString(g_cfg.TradingDirection) + (g_cfg.AllowNewCycles ? "" : " [no new cycles]"), g_cfg.ColorNormal);
   if(g_cycle.IsActive())
     {
      g_dash.Add("CYCLE", "#" + IntegerToString(g_cycle.CycleId()) + (g_cycle.IsUncertain() ? " [STATE UNCERTAIN]" : ""),
                 (g_cycle.IsUncertain() ? g_cfg.ColorDanger : g_cfg.ColorHeader));
      g_dash.Add("CYCLE START", TimeToString(g_cycle.StartTime(), TIME_DATE | TIME_MINUTES), g_cfg.ColorNormal);
      g_dash.Add("LAYER", IntegerToString(g_cycle.LayerCount()) + " / " + IntegerToString(g_cfg.MaximumLayer),
                 (g_cycle.LayerCount() >= g_cfg.MaximumLayer ? g_cfg.ColorWarning : g_cfg.ColorNormal));
      g_dash.Add("TOTAL LOT", DoubleToString(g_cycle.TotalVolume(), g_spec.VolumeDigits()) + " / " +
                 DoubleToString(g_cfg.MaximumTotalLot, 2),
                 (g_cycle.TotalVolume() >= g_cfg.MaximumTotalLot - 1.0e-9 ? g_cfg.ColorWarning : g_cfg.ColorNormal));
      g_dash.Add("AVG PRICE", XauPrice(g_cycle.AvgPrice()) + "  (BE " + XauPrice(g_basket.BreakEvenPrice()) + ")", g_cfg.ColorNormal);
      g_dash.Add("NEXT AVG", XauPrice(g_cycle.NextLevel()) + "  (" + DoubleToString(g_cycle.DistancePoints(), 0) + " pts)", g_cfg.ColorNormal);
      g_dash.Add("BASKET TP", XauPrice(g_basket.TPPrice()) + "  (" + DoubleToString(g_basket.TPPoints(), 1) + " pts)", g_cfg.ColorNormal);
      color pl_col = (g_basket.NetPL() >= 0.0 ? g_cfg.ColorNormal : g_cfg.ColorDanger);
      g_dash.Add("FLOATING P/L", XauMoney(g_basket.NetPL()) + " (gross " + DoubleToString(g_basket.GrossPL(), 2) +
                 ", swap " + DoubleToString(g_basket.SwapTotal(), 2) + ")", pl_col);
      g_dash.Add("COSTS", StringFormat("comm est %s  swap %s", XauMoney(-g_basket.CommissionEstimate()),
                                       XauMoney(g_basket.SwapTotal())), g_cfg.ColorNormal);
      g_dash.Add("CYCLE DD", DoubleToString(g_cycle.MaxDDMoney(), 2) + " (" + DoubleToString(g_cycle.MaxDDPercent(), 2) + "%)",
                 (g_risk.CycleDDPercent() >= g_cfg.MaximumCycleDrawdownPercent ? g_cfg.ColorDanger : g_cfg.ColorNormal));
      g_dash.Add("LAYERS", g_cycle.LayerList(), g_cfg.ColorNormal);
     }
   else
     {
      g_dash.Add("CYCLE", "none open", g_cfg.ColorNormal);
      g_dash.Add("SIGNAL", g_entry.Reason(), g_cfg.ColorNormal);
     }
   g_dash.Add("DAILY P/L", XauMoney(g_stats.RealizedToday()) + (d.closed_cycles > 0 ? StringFormat("  (%d cyc W%d/L%d)", d.closed_cycles, d.win_cycles, d.loss_cycles) : ""),
              (g_stats.RealizedToday() < 0.0 ? g_cfg.ColorWarning : g_cfg.ColorNormal));
   g_dash.Add("BALANCE", XauMoney(AccountInfoDouble(ACCOUNT_BALANCE)), g_cfg.ColorNormal);
   g_dash.Add("EQUITY", XauMoney(AccountInfoDouble(ACCOUNT_EQUITY)), g_cfg.ColorNormal);
   g_dash.Add("DRAWDOWN", StringFormat("%.2f%% (limit %.2f%%)", g_risk.AccountDDPercent(), g_cfg.MaximumAccountDrawdownPercent),
              (g_risk.AccountDDPercent() >= g_cfg.MaximumAccountDrawdownPercent ? g_cfg.ColorDanger : g_cfg.ColorNormal));
   g_dash.Add("DAILY LOSS", StringFormat("%.2f (limit %.2f)", g_risk.DailyLoss(), g_cfg.MaximumDailyLossMoney),
              (g_risk.DailyLoss() >= g_cfg.MaximumDailyLossMoney ? g_cfg.ColorDanger : g_cfg.ColorNormal));
   g_dash.Add("MARGIN LEVEL", StringFormat("%.0f%% (min %.0f%%)", g_spec.MarginLevel(), g_cfg.MinimumFreeMarginPercent),
              (g_spec.MarginLevel() > 0.0 && g_spec.MarginLevel() < g_cfg.MinimumFreeMarginPercent ? g_cfg.ColorDanger : g_cfg.ColorNormal));
   g_dash.Add("SPREAD", StringFormat("%.0f pts (max %d)", g_rt.spread_points, g_cfg.MaximumSpreadPoints),
              (g_cfg.EnableSpreadFilter && g_rt.spread_points > g_cfg.MaximumSpreadPoints ? g_cfg.ColorWarning : g_cfg.ColorNormal));
   g_dash.Add("ATR", g_filters.ATRAvailable() ? StringFormat("%.0f pts", g_filters.ATRPointsValue()) : "n/a", g_cfg.ColorNormal);
   MqlDateTime nowst;
   TimeToStruct(XauNow(), nowst);
   g_dash.Add("SESSION", StringFormat("%s-%s srv  now %s", XauHHMM(g_cfg.SessionStartHour, g_cfg.SessionStartMinute),
                                      XauHHMM(g_cfg.SessionEndHour, g_cfg.SessionEndMinute),
                                      XauHHMM(nowst.hour, nowst.min)), g_cfg.ColorNormal);
   if(StringLen(g_last_block_reason) > 0)
      g_dash.Add("LAST BLOCK", StringFormat("%s: %s", g_sm.BlockName(g_last_block_code), g_last_block_reason),
                 g_cfg.ColorWarning);
   if(g_cfg.DashboardShowFilters)
     {
      g_dash.Add("FILTERS", g_filters.Describe(),
                 (g_sm.RiskBlocked() && g_sm.RiskCode() >= XAU_BLK_SPREAD ? g_cfg.ColorWarning : g_cfg.ColorNormal));
      g_dash.Add("NEWS", g_news.Describe(), g_cfg.ColorNormal);
      g_dash.Add("RISK", g_risk.DescribeLimits(), (g_sm.RiskBlocked() ? g_cfg.ColorWarning : g_cfg.ColorNormal));
     }
   if(g_tg.Enabled())
      g_dash.Add("TELEGRAM", StringFormat("connected | sent %d recv %d dropped %d",
                                          g_tg.SentCount(), g_tg.RecvCount(), g_tg.DroppedCount()),
                 g_cfg.ColorNormal);
   else
      g_dash.Add("TELEGRAM", g_tg.Describe(),
                 (g_cfg.EnableTelegram ? g_cfg.ColorWarning : g_cfg.ColorNormal));
   if(StringLen(g_sm.ErrorText()) > 0)
      g_dash.Add("ERROR", g_sm.ErrorText(), g_cfg.ColorDanger);
   if(g_config_errors)
      g_dash.Add("CONFIG", "hard errors - trading disabled, see Experts log", g_cfg.ColorDanger);
   g_dash.End();
  }

//==================================================================//
// SECTION 9 - EVENT HANDLERS                                       |
//==================================================================//
int OnInit(void)
  {
   ZeroMemory(g_rt);
   g_rt.started_at = TimeCurrent();
   g_rt.peak_equity = AccountInfoDouble(ACCOUNT_EQUITY);
   g_rt.day_stamp   = XauServerDayStart(XauNow());
   LoadInputs();
   g_log.Init((int)g_cfg.LogLevel, g_cfg.LogToFile, g_cfg.LogThrottleSeconds, _Symbol, g_cfg.MagicNumber);
   g_log.Raw(XAU_T_INIT, StringFormat("%s v%s starting on %s (%s chart)", XAU_EA_NAME, XAU_EA_VERSION, _Symbol, EnumToString(_Period)));

   // --- symbol / account specification (never assumed, always read) ---
   if(!g_spec.Refresh(_Symbol))
     {
      // one retry after a short wait: right after a terminal start the
      // symbol properties may not be synchronised yet
      if((bool)MQLInfoInteger(MQL_TESTER) || !g_spec.UpdateQuote())
        {
         g_log.Error(XAU_T_INIT, StringFormat("symbol specification invalid: %s", g_spec.ErrorText()));
         g_log.Error(XAU_T_INIT, "the EA refuses to start instead of trading on assumed broker values");
         return(INIT_PARAMETERS_INCORRECT);
        }
      Sleep(500);
      if(!g_spec.Refresh(_Symbol))
        {
         g_log.Error(XAU_T_INIT, StringFormat("symbol specification invalid after retry: %s", g_spec.ErrorText()));
         return(INIT_PARAMETERS_INCORRECT);
        }
     }
   g_log.Raw(XAU_T_INIT, "spec: " + g_spec.Describe());
   g_log.Raw(XAU_T_INIT, "tick value: " + DoubleToString(g_spec.MoneyPerPointPerLot(), 6) + " per point per lot, account currency " + g_spec.AccountCurrency());

   // --- state and configuration ---
   g_state.Init(_Symbol, g_cfg.MagicNumber, true);
   LoadPersistedFlags();
   string errs = "";
   ValidateConfig(errs);
   if(StringLen(errs) > 0)
     {
      g_config_errors = true;
      // one log line per problem, so every line is searchable in the
      // Experts journal and copy-pasteable into an issue report
      string rest = errs;
      while(StringLen(rest) > 0)
        {
         int p = StringFind(rest, "\n");
         string l = (p < 0 ? rest : StringSubstr(rest, 0, p));
         rest = (p < 0 ? "" : StringSubstr(rest, p + 1));
         StringTrimLeft(rest);
         if(StringLen(l) > 0)
            g_log.Error(XAU_T_CFG, "invalid configuration: " + l);
        }
     }
   g_log.Raw(XAU_T_CFG, "config: " + g_cfg.Describe());

   g_sm.Init(GetPointer(g_cfg), GetPointer(g_log));
   g_cycle.Init(GetPointer(g_cfg), GetPointer(g_spec), GetPointer(g_log), GetPointer(g_state));
   g_exec.Init(GetPointer(g_cfg), GetPointer(g_spec), GetPointer(g_log));
   if(!g_entry.Init(GetPointer(g_cfg), GetPointer(g_spec), GetPointer(g_log)))
      g_log.Error(XAU_T_ENTRY, "entry engine unavailable - no new cycles will be opened");
   if(!g_avg.Init(GetPointer(g_cfg), GetPointer(g_spec), GetPointer(g_log), GetPointer(g_cycle)))
      g_log.Error(XAU_T_AVG, "ATR distance not available - averaging will be blocked until data arrives");
   g_lots.Init(GetPointer(g_cfg), GetPointer(g_spec), GetPointer(g_log));
   if(!g_filters.Init(GetPointer(g_cfg), GetPointer(g_spec), GetPointer(g_log)))
      g_log.Error(XAU_T_FILTER, "market filters partially unavailable - see log");
   g_news.Init(GetPointer(g_cfg), GetPointer(g_log));
   g_basket.Init(GetPointer(g_cfg), GetPointer(g_spec), GetPointer(g_log), GetPointer(g_cycle), GetPointer(g_exec));
   g_stats.Init(GetPointer(g_cfg), GetPointer(g_spec), GetPointer(g_log), GetPointer(g_state));
   g_risk.Init(GetPointer(g_cfg), GetPointer(g_spec), GetPointer(g_log), GetPointer(g_cycle), GetPointer(g_basket),
               GetPointer(g_filters), GetPointer(g_news), GetPointer(g_sm), GetPointer(g_lots), GetPointer(g_avg));
   g_dash.Init(GetPointer(g_cfg), GetPointer(g_spec), GetPointer(g_log));
   g_tg.Init(GetPointer(g_cfg), GetPointer(g_log), GetPointer(g_state));
   g_tests.Init(GetPointer(g_cfg), GetPointer(g_spec), GetPointer(g_log), GetPointer(g_cycle), GetPointer(g_lots),
                GetPointer(g_sm), GetPointer(g_tg), GetPointer(g_avg));

   // --- state machine start conditions ---
   if(g_config_errors)
      g_sm.SetError("configuration contains hard errors");
   if(!g_spec.IsHedgingAccount() && !g_cfg.AllowNettingAccounts)
      g_sm.SetError("netting account with AllowNettingAccounts=false");
   // the CSV daily row is written by CStatistics when the server day rolls;
   // writing one at start would only add a row per restart

   // --- recover from the account, not from RAM ---
   g_cycle.Reconcile();
   g_basket.Recompute();
   double eq0 = AccountInfoDouble(ACCOUNT_EQUITY);
   if(g_rt.peak_equity < eq0)
      g_rt.peak_equity = eq0;
   g_risk.SetPeakEquity(g_rt.peak_equity);
   SDayStats d0;
   g_stats.Get(d0);
   g_risk.SetDaySnapshot(d0.start_balance, d0.realized_pl);
   g_risk.SetTodayEntries(DayEntriesCount());
   g_sm.Derive(g_cycle.IsActive(), false);
   g_prev_cycle_active = g_cycle.IsActive();
   if(g_cfg.emergency_stop)
      g_log.Error(XAU_T_STATE, "EMERGENCY STOP was restored from the state file - trading stays blocked until /emergency_clear");

   if(g_cfg.RunSelfTestsOnInit)
     {
      bool all_ok = true;
      string summary = "";
      g_tests.Run(all_ok, summary);
      g_log.Raw(XAU_T_TEST, summary);
      if(g_cfg.EnableTelegram)
         g_tg.Reply("SELF TEST\n" + summary);
      if(g_cfg.HaltAfterSelfTests)
         g_sm.SetSelfTestHalt(true);
     }
   ChartRedraw();
   EventSetTimer(1);
   g_log.Raw(XAU_T_INIT, StringFormat("ready | state=%s | %s", g_sm.StateName(g_sm.State()),
                                      (g_cfg.EnableTelegram ? "telegram on" : "telegram off")));
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
   string why = StringFormat("deinit reason=%d (%s)", reason, DeinitReasonText(reason));
   g_log.Raw(XAU_T_INIT, why);
   g_cycle.Reconcile();
   if(g_cycle.IsActive())
      g_log.Warn(XAU_T_STATE, StringFormat("EA detached with cycle #%d still OPEN (%s). Positions are left untouched by design; re-attach to resume management.",
                                           g_cycle.CycleId(), g_cycle.Describe()));
   TrySaveState(true);
   g_dash.Destroy(g_cfg.RemoveDashboardOnDetach);
   g_tg.Deinit(why);
   g_entry.Deinit();
   g_avg.Deinit();
   g_filters.Deinit();
   g_log.Deinit();
  }

string DeinitReasonText(const int reason)
  {
   switch(reason)
     {
      case REASON_PROGRAM:     return("EA called ExpertRemove()");
      case REASON_REMOVE:      return("removed from chart");
      case REASON_RECOMPILE:   return("recompiled");
      case REASON_CHARTCHANGE: return("symbol/period changed");
      case REASON_CHARTCLOSE:  return("chart closed");
      case REASON_PARAMETERS:  return("inputs changed");
      case REASON_ACCOUNT:     return("account changed");
      case REASON_TEMPLATE:    return("template applied");
      case REASON_INITFAILED:  return("OnInit failed");
      case REASON_CLOSE:       return("terminal closed");
     }
   return("other");
  }

void OnTick(void)
  {
   if(g_rt.locked)
      return;
   g_rt.locked = true;
   // The open -> flat transition is detected here, once, so that a
   // basket closed by the EA and a basket closed by the broker follow the
   // same code path (cooldowns, statistics, notifications).
   bool was_active = g_prev_cycle_active;
   RunPipeline();
   if(was_active && !g_cycle.IsActive())
     {
      int    code   = (g_close_notice_set ? g_close_notice_code : (g_cycle.ExitCode() > 0 ? g_cycle.ExitCode() : 5));
      string reason = (g_close_notice_set ? g_close_notice_reason : "external close");
      double net    = (g_close_notice_set ? g_close_notice_net : 0.0);
      g_prev_cycle_active = false;
      OnCycleFinished(code, reason, net);
      g_close_notice_set    = false;
      g_close_notice_code   = 0;
      g_close_notice_net    = 0.0;
      g_close_notice_reason = "";
      g_close_notice_layers = 0;
      g_close_notice_volume = 0.0;
      g_close_notice_avg    = 0.0;
     }
   else
      g_prev_cycle_active = g_cycle.IsActive();
   BuildDashboard();
   g_rt.locked = false;
  }

void OnTimer(void)
  {
   // Telegram polling, news refresh, statistics and housekeeping are all
   // deliberately kept out of OnTick.
   if(g_tg.Enabled())
     {
      g_tg.Poll();
      while(g_tg.PendingCommands() > 0)
        {
         string name = "";
         string args = "";
         if(!g_tg.PopCommand(name, args))
            break;
         HandleCommand(name, args);
        }
      if(g_cfg.TelegramStatusIntervalMinutes > 0)
         g_tg.Heartbeat(StatusReport());
     }
   g_news.Refresh();
   g_stats.Tick();
   // day start balance and realized P/L come from the statistics module
   // (history based), which keeps percent limits and the daily report on
   // exactly the same numbers
   SDayStats d;
   g_stats.Get(d);
   g_risk.SetDaySnapshot(d.start_balance, d.realized_pl);
   g_risk.SetTodayEntries(d.entries);
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq > g_rt.peak_equity)
     {
      g_rt.peak_equity = eq;
      g_risk.SetPeakEquity(g_rt.peak_equity);
     }
   if(g_sm.RiskBlocked())
      g_risk.ResetCheck(g_rt);
   CheckEmergencyAutoReset();
   // scheduled daily report: exactly once per server day, and the day stamp
   // is persisted so a restart on the same day cannot re-send it
   if(g_cfg.DailyReportTelegramHour >= 0)
     {
      MqlDateTime dt;
      TimeToStruct(XauNow(), dt);
      datetime today = XauServerDayStart(XauNow());
      if(dt.hour == g_cfg.DailyReportTelegramHour && (long)g_state.GetIntOr("report_day", 0) != (long)today)
        {
         g_state.SetInt("report_day", (long)today);
         Notify("DAILY REPORT\n" + g_stats.DailyReport());
         if(g_cfg.EnableCsvDailyReport)
            g_stats.WriteCsv();
         TrySaveState(true);
        }
     }
   TrySaveState(false);
   g_heartbeat_seconds++;
   if(g_cfg.EnableDebugTickLog && g_heartbeat_seconds >= 10)
     {
      g_heartbeat_seconds = 0;
      g_log.Debug(XAU_T_INIT, StringFormat("heartbeat ticks=%d pipelines=%d state=%s spread=%.0f",
                                           g_rt.ticks, g_pipeline_runs, g_sm.StateName(g_sm.State()),
                                           g_rt.spread_points));
     }
   BuildDashboard();
  }

/// Deal level notifications: the fastest correct way to notice that a
/// position appeared or disappeared, so the state is refreshed instantly
/// instead of waiting for the next tick.
void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result)
  {
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD || trans.deal == 0)
      return;
   // MqlTradeTransaction has no magic field and no time field at all - the reference
   // structure is deal, order, symbol, type, order_type, order_state, deal_type, time_type,
   // time_expiration, price, price_trigger, price_sl, price_tp, volume, position,
   // position_by - so the deal record is the only authoritative source of the magic number.
   // HistoryDealSelect() copies a deal only if it lies inside the interval requested by the
   // last HistorySelect() call, hence the window; it ends in the future because every
   // transaction the terminal delivers has just been executed on the server.
   datetime now = TimeCurrent();
   if(!HistorySelect(now - 86400, now + 60))
      return;                        // history unreachable: the next tick reconciles anyway
   if(!HistoryDealSelect(trans.deal))
      return;                        // deal not in the window yet: the next tick reconciles
   if(HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != g_cfg.MagicNumber)
      return;                       // another EA or a manual trade: never ours to react to
   g_cycle.Reconcile();
   g_basket.Recompute();
   g_sm.Derive(g_cycle.IsActive(), false);
   TrySaveState(true);
   if(g_cfg.LogLevel >= (int)XAU_LOG_DEBUG)
      g_log.Debug(XAU_T_EXEC, StringFormat("deal %s entry=%I64d type=%I64d volume=%s price=%s",
                                            IntegerToString((long)trans.deal),
                                            HistoryDealGetInteger(trans.deal, DEAL_ENTRY),
                                            HistoryDealGetInteger(trans.deal, DEAL_TYPE),
                                            DoubleToString(HistoryDealGetDouble(trans.deal, DEAL_VOLUME), 2),
                                            DoubleToString(HistoryDealGetDouble(trans.deal, DEAL_PRICE), g_spec.Digits())));
  }

void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
  {
   if(id != CHARTEVENT_OBJECT_CLICK)
      return;
   bool toggle = false;
   if(!g_dash.OnChartEventClick(sparam, toggle))
      return;
   if(toggle)
     {
      g_sm.SetPaused(!g_cfg.user_paused, "chart button");
      SaveOverrides();
      TrySaveState(true);
      g_log.Info(XAU_T_DASH, StringFormat("chart button toggled pause=%s", (g_cfg.user_paused ? "true" : "false")));
      ObjectSetInteger(0, g_dash.ButtonObject(), OBJPROP_STATE, false);
      BuildDashboard();
     }
  }
//+------------------------------------------------------------------+