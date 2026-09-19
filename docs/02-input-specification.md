# 02 - Complete Input Specification

This document is **generated** from the source by `tools/gen_input_docs.py`;
it is the authoritative list of every input of XAU_AVG_PRO v1.0.0 and it is
guaranteed to match `MQL5/Experts/XAU_AVG_PRO.mq5` exactly.

* Every input is read once in `OnInit()` and copied into the `CConfig`
  struct. No module ever reads an `input` variable directly, which is what
  makes the Telegram overrides and the unit self tests possible.
* Defaults are the **conservative** values intended for a first live run on
  a cent or demo account (see `docs/09-known-risks-and-limitations.md`).
* `ValidateConfig()` (in the `.mq5`) clamps or rejects the values listed in
  the *Validation* column. A hard error keeps the EA running in a trading-
  disabled state so that the dashboard and the log stay readable.

**165 inputs / 168 CConfig fields** (3 fields are operator state, not inputs: `emergency_stop`, `user_paused`, `override_flags`).

## GENERAL

| Input | Type | Default | Meaning | Validation |
|---|---|---|---|---|
| `EANameLabel` | `string` | `"XAU_AVG_PRO"` | Display name on chart / Telegram | length/character rules in ValidateConfig() |
| `MagicNumber` | `long` | `20260919` | Unique magic number (do not reuse) | see ValidateConfig() |
| `ManageCurrentSymbolOnly` | `bool` | `true` | Only manage the chart symbol | no validation needed |
| `TradingDirection` | `ENUM_XAU_DIRECTION` | `XAU_DIR_BOTH` | BUY_ONLY / SELL_ONLY / BOTH | one of the declared ENUM_XAU_DIRECTION values (compiler enforced) |
| `BuyEnabled` | `bool` | `true` | Allow BUY entries | no validation needed |
| `SellEnabled` | `bool` | `true` | Allow SELL entries | no validation needed |
| `AllowNewCycles` | `bool` | `true` | Allow opening new cycles (Telegram /stop turns this off) | no validation needed |
| `MaxQuoteAgeSeconds` | `int` | `30` | Block trading if the quote is older (s) | ValidateConfig() clamps the value into its documented range |

## ENTRY

| Input | Type | Default | Meaning | Validation |
|---|---|---|---|---|
| `EnableEMAEntry` | `bool` | `true` | Use the EMA crossover entry engine | no validation needed |
| `FastEMAPeriod` | `int` | `13` | Fast EMA period | ValidateConfig() clamps the value into its documented range |
| `SlowEMAPeriod` | `int` | `48` | Slow EMA period | ValidateConfig() clamps the value into its documented range |
| `EMATimeframe` | `ENUM_TIMEFRAMES` | `PERIOD_CURRENT` | EMA timeframe | one of the declared ENUM_TIMEFRAMES values (compiler enforced) |
| `EntryConfirmation` | `ENUM_XAU_ENTRY_CONFIRM` | `XAU_CONFIRM_CLOSE_BAR` | Signal evaluation bar | one of the declared ENUM_XAU_ENTRY_CONFIRM values (compiler enforced) |
| `EntryCandleFilter` | `ENUM_XAU_CANDLE_FILTER` | `XAU_CANDLE_NONE` | Optional candle quality filter | one of the declared ENUM_XAU_CANDLE_FILTER values (compiler enforced) |
| `MinimumBarRangePoints` | `int` | `0` | Minimum signal bar range (pts, 0=off) | ValidateConfig() clamps the value into its documented range |
| `OneEntryPerBar` | `bool` | `true` | At most one entry signal per bar | no validation needed |
| `MaximumEntriesPerDay` | `int` | `5` | Max initial entries per server day (0=unlimited) | ValidateConfig() clamps the value into its documented range |
| `RequireNewSignalAfterCycleClose` | `bool` | `true` | Require a fresh cross after a cycle closes | no validation needed |
| `CooldownAfterBasketTPMinutes` | `int` | `15` | Cooldown after a basket TP (minutes) | ValidateConfig() clamps the value into its documented range |
| `CooldownAfterCutLossMinutes` | `int` | `60` | Cooldown after a cut loss (minutes) | ValidateConfig() clamps the value into its documented range |

## AVERAGING

| Input | Type | Default | Meaning | Validation |
|---|---|---|---|---|
| `EnableAveraging` | `bool` | `true` | Enable controlled averaging | no validation needed |
| `AveragingDistanceMode` | `ENUM_XAU_AVG_MODE` | `XAU_AVG_FIXED` | FIXED points or ATR based | one of the declared ENUM_XAU_AVG_MODE values (compiler enforced) |
| `AveragingDistancePoints` | `int` | `350` | FIXED distance in points | ValidateConfig() clamps the value into its documented range |
| `AveragingReference` | `ENUM_XAU_AVG_REF` | `XAU_AVGREF_LAST_LAYER` | Distance measured from | one of the declared ENUM_XAU_AVG_REF values (compiler enforced) |
| `ATRPeriod` | `int` | `14` | ATR period (ATR mode) | ValidateConfig() clamps the value into its documented range |
| `ATRTimeframe` | `ENUM_TIMEFRAMES` | `PERIOD_CURRENT` | ATR timeframe (ATR mode) | one of the declared ENUM_TIMEFRAMES values (compiler enforced) |
| `ATRMultiplier` | `double` | `1.5` | ATR multiplier (ATR mode) | finite; range rules in ValidateConfig() |
| `MinimumAveragingDistancePoints` | `int` | `200` | Distance floor in points | ValidateConfig() clamps the value into its documented range |
| `MaximumAveragingDistancePoints` | `int` | `1500` | Distance ceiling in points | ValidateConfig() clamps the value into its documented range |
| `MinimumDistanceSpreadMultiple` | `double` | `2.0` | Distance must be >= spread x this | finite, >= 0; hard caps are additionally clamped to the broker limits |
| `AllowIntraBarATRRefresh` | `bool` | `false` | Recompute ATR distance every tick | no validation needed |
| `MinimumSecondsBetweenAveraging` | `int` | `60` | Minimum seconds between two layers | ValidateConfig() clamps the value into its documented range |
| `OneLayerPerBar` | `bool` | `true` | At most one layer per bar | no validation needed |
| `AllowMultipleLayersPerTick` | `bool` | `false` | Advanced: allow up to 3 layers in one tick pass | no validation needed |
| `MaximumLayer` | `int` | `6` | Maximum layer count (1 = no averaging) | ValidateConfig() clamps the value into its documented range |
| `EntryComment` | `string` | `"XAUAVG"` | Order comment for initial entries | sanitised to printable ASCII and truncated to 28 characters |
| `AveragingComment` | `string` | `"XAUAVG-avg"` | Order comment for averaging layers | sanitised to printable ASCII and truncated to 28 characters |

## LOT MANAGEMENT

| Input | Type | Default | Meaning | Validation |
|---|---|---|---|---|
| `LotMode` | `ENUM_XAU_LOT_MODE` | `XAU_LOT_FIXED` | FIX LOT / AUTO LOT / MULTIPLIER | one of the declared ENUM_XAU_LOT_MODE values (compiler enforced) |
| `InitialLot` | `double` | `0.01` | Base lot | finite; range rules in ValidateConfig() |
| `LotMultiplier` | `double` | `1.5` | Multiplier per layer (>=1.0) | finite; range rules in ValidateConfig() |
| `MaximumLotPerOrder` | `double` | `0.10` | Hard cap per single order | finite, >= 0; hard caps are additionally clamped to the broker limits |
| `RiskPercent` | `double` | `0.5` | AUTO LOT: risk % of balance/equity | finite; range rules in ValidateConfig() |
| `AutoLotEquityBasis` | `ENUM_XAU_LOT_BASIS` | `XAU_LOTBASIS_EQUITY` | AUTO LOT basis | one of the declared ENUM_XAU_LOT_BASIS values (compiler enforced) |
| `AutoLotCalculationMode` | `ENUM_XAU_AUTLOT_MODE` | `XAU_AUTLOT_RISK_DISTANCE` | AUTO LOT method | one of the declared ENUM_XAU_AUTLOT_MODE values (compiler enforced) |
| `InitialStopDistancePoints` | `int` | `400` | AUTO LOT: assumed stop distance (pts) | ValidateConfig() clamps the value into its documented range |
| `AutoLotMaxMarginUsagePercent` | `double` | `30.0` | AUTO LOT: max margin use of basis (%) | finite; range rules in ValidateConfig() |
| `AutoLotAllowMinLotFallback` | `bool` | `false` | AUTO LOT: allow rounding up to broker min lot | no validation needed |
| `ApplyMultiplierToAutoLot` | `bool` | `false` | Apply LotMultiplier on top of AUTO LOT | no validation needed |

## BASKET TP

| Input | Type | Default | Meaning | Validation |
|---|---|---|---|---|
| `BasketTPMode` | `ENUM_XAU_TP_MODE` | `XAU_TP_MONEY` | MONEY/POINTS/PERCENT/PRICE/NONE | one of the declared ENUM_XAU_TP_MODE values (compiler enforced) |
| `BasketTakeProfitMoney` | `double` | `5.0` | Target money for the whole basket | finite; range rules in ValidateConfig() |
| `BasketTakeProfitPoints` | `int` | `350` | Target points above/below average | ValidateConfig() clamps the value into its documented range |
| `BasketTakeProfitPercent` | `double` | `0.05` | Target % of basket cost basis | finite; range rules in ValidateConfig() |
| `BasketTakeProfitPrice` | `double` | `3.50` | Target price units above/below average | finite; range rules in ValidateConfig() |
| `AccountForSpreadInTP` | `bool` | `true` | Anchor the TP on the real close price | no validation needed |
| `AccountForSwapInTP` | `bool` | `true` | Include swap in basket P/L | no validation needed |
| `EstimatedCommissionPerLot` | `double` | `0.0` | Commission per lot PER SIDE (0 if unknown) | finite; range rules in ValidateConfig() |
| `RequireMinimumProfitMoney` | `double` | `0.0` | Never close a basket below this profit | finite; range rules in ValidateConfig() |
| `BasketTPSafetyBufferPoints` | `int` | `0` | Extra distance before the TP triggers | ValidateConfig() clamps the value into its documented range |

## CUT LOSS

| Input | Type | Default | Meaning | Validation |
|---|---|---|---|---|
| `EnableBasketCutLoss` | `bool` | `true` | Enable basket cut loss | no validation needed |
| `CutLossMode` | `ENUM_XAU_CUT_MODE` | `XAU_CUT_ANY` | Which threshold may trigger | one of the declared ENUM_XAU_CUT_MODE values (compiler enforced) |
| `BasketCutLossMoney` | `double` | `50.0` | Cut loss in money | finite; range rules in ValidateConfig() |
| `BasketCutLossPercentOfBalance` | `double` | `5.0` | Cut loss % of balance | finite; range rules in ValidateConfig() |
| `BasketCutLossPoints` | `int` | `2000` | Cut loss in points from average | ValidateConfig() clamps the value into its documented range |
| `CutLossCloseOrder` | `ENUM_XAU_CLOSE_ORDER` | `XAU_CLOSE_YOUNGEST_FIRST` | Which layer to close first | one of the declared ENUM_XAU_CLOSE_ORDER values (compiler enforced) |

## RISK MANAGEMENT

| Input | Type | Default | Meaning | Validation |
|---|---|---|---|---|
| `MaximumTotalLot` | `double` | `0.50` | Maximum total EA exposure (lots) | finite, >= 0; hard caps are additionally clamped to the broker limits |
| `TruncateLotToExposureHeadroom` | `bool` | `false` | Shrink instead of rejecting when near the cap | no validation needed |
| `MinimumFreeMarginPercent` | `double` | `200.0` | Required projected margin level (%) | finite, >= 0; hard caps are additionally clamped to the broker limits |
| `MinimumFreeMarginMoney` | `double` | `0.0` | Required free margin after the order (money) | finite, >= 0; hard caps are additionally clamped to the broker limits |
| `MaximumAccountDrawdownPercent` | `double` | `20.0` | Account drawdown limit (%) | finite, >= 0; hard caps are additionally clamped to the broker limits |
| `DrawdownReference` | `ENUM_XAU_DD_REF` | `XAU_DD_PEAK_EQUITY` | Drawdown reference | one of the declared ENUM_XAU_DD_REF values (compiler enforced) |
| `MaximumCycleDrawdownPercent` | `double` | `10.0` | Cycle drawdown limit (% of cycle start balance) | finite, >= 0; hard caps are additionally clamped to the broker limits |
| `MaximumFloatingLossMoney` | `double` | `100.0` | Maximum basket floating loss (money) | finite, >= 0; hard caps are additionally clamped to the broker limits |
| `MaximumDailyLossMoney` | `double` | `150.0` | Maximum daily loss (money) | finite, >= 0; hard caps are additionally clamped to the broker limits |
| `MaximumDailyLossPercent` | `double` | `5.0` | Maximum daily loss (% of day start balance) | finite, >= 0; hard caps are additionally clamped to the broker limits |
| `DailyLossBasis` | `ENUM_XAU_DAILY_MODE` | `XAU_DAILY_REALIZED_PLUS_EA` | What counts as daily loss | one of the declared ENUM_XAU_DAILY_MODE values (compiler enforced) |
| `ActionOnAccountDD` | `ENUM_XAU_ACTION` | `XAU_ACT_EMERGENCY` | When the account DD limit is hit | one of the declared ENUM_XAU_ACTION values (compiler enforced) |
| `ActionOnCycleDD` | `ENUM_XAU_ACTION` | `XAU_ACT_CLOSE_BASKET` | When the cycle DD limit is hit | one of the declared ENUM_XAU_ACTION values (compiler enforced) |
| `ActionOnDailyLoss` | `ENUM_XAU_ACTION` | `XAU_ACT_BLOCK_ONLY` | When the daily loss limit is hit | one of the declared ENUM_XAU_ACTION values (compiler enforced) |
| `ActionOnFloatingLoss` | `ENUM_XAU_ACTION` | `XAU_ACT_BLOCK_ONLY` | When the floating loss limit is hit | one of the declared ENUM_XAU_ACTION values (compiler enforced) |
| `AutoResetRiskBlock` | `bool` | `true` | Release soft blocks when conditions clear | no validation needed |
| `RiskBlockResetHysteresisPercent` | `double` | `80.0` | Must recover to x% of the limit to clear | finite; range rules in ValidateConfig() |
| `EmergencyResetMode` | `ENUM_XAU_EMR_RESET` | `XAU_EMR_MANUAL` | How EMERGENCY STOP is released | one of the declared ENUM_XAU_EMR_RESET values (compiler enforced) |

## MARKET FILTERS

| Input | Type | Default | Meaning | Validation |
|---|---|---|---|---|
| `EnableSpreadFilter` | `bool` | `true` | Spread filter | no validation needed |
| `MaximumSpreadPoints` | `int` | `500` | Maximum spread (points) | ValidateConfig() clamps the value into its documented range |
| `SpreadFilterBlocksAveraging` | `bool` | `true` | Spread filter also blocks averaging | no validation needed |
| `EnableVolatilityFilter` | `bool` | `false` | ATR volatility filter | no validation needed |
| `VolatilityTimeframe` | `ENUM_TIMEFRAMES` | `PERIOD_CURRENT` | Volatility ATR timeframe | one of the declared ENUM_TIMEFRAMES values (compiler enforced) |
| `VolatilityATRPeriod` | `int` | `14` | Volatility ATR period | ValidateConfig() clamps the value into its documented range |
| `MinimumATRPoints` | `int` | `30` | Block below this ATR (points) | ValidateConfig() clamps the value into its documented range |
| `MaximumATRPoints` | `int` | `1500` | Block above this ATR (points, <=min=off) | ValidateConfig() clamps the value into its documented range |
| `VolatilityFilterBlocksAveraging` | `bool` | `false` | Volatility filter also blocks averaging | no validation needed |
| `EnableGapFilter` | `bool` | `true` | Gap filter | no validation needed |
| `MaximumGapPoints` | `int` | `1500` | Maximum bar-to-bar gap (points) | ValidateConfig() clamps the value into its documented range |
| `GapLookbackBars` | `int` | `2` | Bars scanned for gaps | ValidateConfig() clamps the value into its documented range |
| `GapBlockDurationMinutes` | `int` | `15` | Block duration after a gap | ValidateConfig() clamps the value into its documented range |
| `GapBlocksAveraging` | `bool` | `true` | Gap filter also blocks averaging | no validation needed |

## SESSION

| Input | Type | Default | Meaning | Validation |
|---|---|---|---|---|
| `EnableSessionFilter` | `bool` | `true` | Trading session filter | no validation needed |
| `SessionStartHour` | `int` | `7` | Session start hour (server time) | ValidateConfig() clamps the value into its documented range |
| `SessionStartMinute` | `int` | `0` | Session start minute | ValidateConfig() clamps the value into its documented range |
| `SessionEndHour` | `int` | `20` | Session end hour (server time) | ValidateConfig() clamps the value into its documented range |
| `SessionEndMinute` | `int` | `30` | Session end minute | ValidateConfig() clamps the value into its documented range |
| `SessionBlocksAveraging` | `bool` | `false` | Session filter also blocks averaging | no validation needed |
| `EnableWeekendProtection` | `bool` | `true` | Weekend protection | no validation needed |
| `FridayStopHour` | `int` | `20` | Friday stop hour (server time) | ValidateConfig() clamps the value into its documented range |
| `FridayStopMinute` | `int` | `30` | Friday stop minute | ValidateConfig() clamps the value into its documented range |
| `MondayResumeHour` | `int` | `3` | Monday resume hour (server time) | ValidateConfig() clamps the value into its documented range |
| `MondayResumeMinute` | `int` | `0` | Monday resume minute | ValidateConfig() clamps the value into its documented range |
| `WeekendBlocksAveraging` | `bool` | `true` | Weekend protection also blocks averaging | no validation needed |
| `CloseBasketBeforeFridayStop` | `bool` | `false` | Flatten the basket at the Friday stop | no validation needed |
| `EnableOpenMarketProtection` | `bool` | `true` | Protection right after market open | no validation needed |
| `OpenMarketReference` | `ENUM_XAU_OPEN_REF` | `XAU_OPEN_SESSION_START` | What counts as "open" | one of the declared ENUM_XAU_OPEN_REF values (compiler enforced) |
| `ProtectionMinutes` | `int` | `15` | Protection length after open (minutes) | ValidateConfig() clamps the value into its documented range |

## NEWS

| Input | Type | Default | Meaning | Validation |
|---|---|---|---|---|
| `EnableNewsFilter` | `bool` | `false` | MT5 economic calendar filter | no validation needed |
| `NewsCurrency` | `string` | `"USD"` | Currency to watch | length/character rules in ValidateConfig() |
| `NewsCountryCode` | `string` | `""` | Optional ISO country code (e.g. US) | length/character rules in ValidateConfig() |
| `MinimumNewsImportance` | `ENUM_XAU_IMPORTANCE` | `XAU_IMP_HIGH` | Minimum importance to block on | one of the declared ENUM_XAU_IMPORTANCE values (compiler enforced) |
| `MinutesBeforeNews` | `int` | `30` | Block this many minutes before | ValidateConfig() clamps the value into its documented range |
| `MinutesAfterNews` | `int` | `30` | Block this many minutes after | ValidateConfig() clamps the value into its documented range |
| `NewsBlocksAveraging` | `bool` | `true` | News window also blocks averaging | no validation needed |
| `NewsFailSafePolicy` | `ENUM_XAU_FAILSAFE` | `XAU_FAILSAFE_BLOCK` | What to do when the calendar is unavailable | one of the declared ENUM_XAU_FAILSAFE values (compiler enforced) |
| `NewsRefreshSeconds` | `int` | `60` | Calendar refresh interval (s) | ValidateConfig() clamps the value into its documented range |

## DASHBOARD

| Input | Type | Default | Meaning | Validation |
|---|---|---|---|---|
| `EnableDashboard` | `bool` | `true` | Draw the chart panel | no validation needed |
| `DashboardCorner` | `ENUM_BASE_CORNER` | `CORNER_LEFT_UPPER` | Panel corner | one of the declared ENUM_BASE_CORNER values (compiler enforced) |
| `DashboardXOffset` | `int` | `8` | X offset (px) | ValidateConfig() clamps the value into its documented range |
| `DashboardYOffset` | `int` | `22` | Y offset (px) | ValidateConfig() clamps the value into its documented range |
| `DashboardUpdateIntervalMs` | `int` | `500` | Repaint interval (ms) | ValidateConfig() clamps the value into its documented range |
| `DashboardFontName` | `string` | `"Consolas"` | Font | length/character rules in ValidateConfig() |
| `DashboardFontSize` | `int` | `9` | Font size | ValidateConfig() clamps the value into its documented range |
| `DashboardShowFilters` | `bool` | `true` | Show filter detail rows | no validation needed |
| `EnableDashboardButton` | `bool` | `true` | Show PAUSE/RESUME button | no validation needed |
| `RemoveDashboardOnDetach` | `bool` | `true` | Delete chart objects on detach | no validation needed |
| `ColorHeader` | `color` | `clrDodgerBlue` | Header colour | see ValidateConfig() |
| `ColorNormal` | `color` | `clrGainsboro` | Normal text colour | see ValidateConfig() |
| `ColorWarning` | `color` | `clrOrange` | Warning colour | see ValidateConfig() |
| `ColorDanger` | `color` | `clrTomato` | Danger colour | see ValidateConfig() |

## TELEGRAM

| Input | Type | Default | Meaning | Validation |
|---|---|---|---|---|
| `EnableTelegram` | `bool` | `false` | Enable Telegram integration | no validation needed |
| `TelegramBotToken` | `string` | `""` | Bot token (never logged) | length/character rules in ValidateConfig() |
| `TelegramChatID` | `string` | `""` | Your chat id | length/character rules in ValidateConfig() |
| `TelegramPollingIntervalSeconds` | `int` | `5` | getUpdates polling interval (s) | ValidateConfig() clamps the value into its documented range |
| `TelegramRequestTimeoutMs` | `int` | `5000` | WebRequest timeout (ms) | ValidateConfig() clamps the value into its documented range |
| `RequireConfirmationForDestructive` | `bool` | `true` | closeall/closebuy/closesell need /confirm | no validation needed |
| `TelegramEnableOverrides` | `bool` | `true` | Allow parameter changing commands | no validation needed |
| `TelegramMaxMessagesPerMinute` | `int` | `12` | Outbound rate limit | ValidateConfig() clamps the value into its documented range |
| `TelegramNotifyOnEvents` | `bool` | `true` | Send event notifications | no validation needed |
| `TelegramStatusIntervalMinutes` | `int` | `0` | Periodic status (0 = off) | ValidateConfig() clamps the value into its documented range |
| `PersistTelegramOverrides` | `bool` | `true` | Keep overrides after restart | no validation needed |

## EXECUTION

| Input | Type | Default | Meaning | Validation |
|---|---|---|---|---|
| `MaximumDeviationPoints` | `int` | `30` | Maximum slippage (points) | ValidateConfig() clamps the value into its documented range |
| `MaxOrderRetries` | `int` | `3` | Attempts per order (transient errors only) | ValidateConfig() clamps the value into its documented range |
| `RetryDelayMs` | `int` | `400` | Delay between attempts (ms) | ValidateConfig() clamps the value into its documented range |
| `UseOrderCheckBeforeSend` | `bool` | `true` | OrderCheck() before every OrderSend() | no validation needed |
| `FillVerificationRetries` | `int` | `3` | How often to re-scan positions for the fill | ValidateConfig() clamps the value into its documented range |
| `FillVerificationDelayMs` | `int` | `200` | Delay between fill verification scans | ValidateConfig() clamps the value into its documented range |
| `BlockTradingIfNotConnected` | `bool` | `true` | No new trades without a server connection | no validation needed |
| `AllowNettingAccounts` | `bool` | `true` | Allow netting accounts (see docs) | no validation needed |
| `AllowStateAdoptionOnNetting` | `bool` | `false` | Adopt an unknown netting basket as 1 layer | no validation needed |
| `AllowNettingLayerReconstruction` | `bool` | `true` | Rebuild netting layer count from volume | no validation needed |

## DEBUG / TESTING

| Input | Type | Default | Meaning | Validation |
|---|---|---|---|---|
| `LogLevel` | `ENUM_XAU_LOGLEVEL` | `XAU_LOG_INFO` | Log verbosity | one of the declared ENUM_XAU_LOGLEVEL values (compiler enforced) |
| `LogToFile` | `bool` | `false` | Mirror the log into MQL5\Files | no validation needed |
| `LogThrottleSeconds` | `int` | `60` | Suppression window for repeated lines | ValidateConfig() clamps the value into its documented range |
| `EnableDebugTickLog` | `bool` | `false` | Log every pipeline decision (noisy) | no validation needed |
| `RunSelfTestsOnInit` | `bool` | `false` | Run the built-in logic self tests | no validation needed |
| `HaltAfterSelfTests` | `bool` | `false` | Stay in SELFTEST_DONE after the tests | no validation needed |
| `StateSaveIntervalSeconds` | `int` | `10` | Maximum age of the state file | ValidateConfig() clamps the value into its documented range |

## DAILY REPORT

| Input | Type | Default | Meaning | Validation |
|---|---|---|---|---|
| `DailyReportTelegramHour` | `int` | `23` | Auto-send the daily report at this server hour (-1 = off) | ValidateConfig() clamps the value into its documented range |
| `EnableCsvDailyReport` | `bool` | `false` | Append the daily report to a CSV in MQL5\Files | no validation needed |

## Non-input `CConfig` fields (operator state)

| Field | Type | Purpose |
|---|---|---|
| `emergency_stop` | `bool` | persisted |
| `user_paused` | `bool` | persisted |
| `override_flags` | `int` | bit mask of active overrides |

## Enums used by the inputs

Every enum type below is declared in `MQL5/Include/XAU_AVG_PRO/Types.mqh`.
Because the values are declared as `input enum` with explicit member names,
MetaEditor shows readable names in the dialog instead of numbers.

`ENUM_BASE_CORNER` (`DashboardCorner`) is also an MQL5 standard enum:
`CORNER_LEFT_UPPER` 0, `CORNER_LEFT_LOWER` 1, `CORNER_RIGHT_LOWER` 2,
`CORNER_RIGHT_UPPER` 3 - the value stored in a `.set` file is that integer.

`ENUM_TIMEFRAMES` (`EMATimeframe`, `ATRTimeframe`, `VolatilityTimeframe`) is the
MQL5 standard enum, and `ValidateConfig()` checks each of them: `0`
(`PERIOD_CURRENT`) is accepted and resolved to the chart period by the indicator
call itself, while any *other* value must be one of the real periods
(`PERIOD_M1..PERIOD_MN1`); a value outside that set is snapped to
`PERIOD_CURRENT` and reported as a `[CFG]` warning, because a handle created on a
meaningless timeframe would silently return no data and freeze the entry logic.

### `ENUM_XAU_DIRECTION`

Used by: `TradingDirection`

| Value | Numeric | Meaning |
|---|---|---|
| `XAU_DIR_SELL_ONLY` | 2 | SELL_ONLY |

### `ENUM_XAU_ENTRY_CONFIRM`

Used by: `EntryConfirmation`

| Value | Numeric | Meaning |
|---|---|---|
| `XAU_CONFIRM_CURRENT_BAR` | 1 | current bar (repaints) |

### `ENUM_XAU_CANDLE_FILTER`

Used by: `EntryCandleFilter`

| Value | Numeric | Meaning |
|---|---|---|
| `XAU_CANDLE_CLOSE_STRONG` | 2 | close in upper/lower 1/3 of range |

### `ENUM_XAU_AVG_MODE`

Used by: `AveragingDistanceMode`

| Value | Numeric | Meaning |
|---|---|---|
| `XAU_AVG_ATR` | 1 | ATR based distance |

### `ENUM_XAU_AVG_REF`

Used by: `AveragingReference`

| Value | Numeric | Meaning |
|---|---|---|
| `XAU_AVGREF_FIRST` | 2 | distance from first entry |

### `ENUM_XAU_LOT_MODE`

Used by: `LotMode`

| Value | Numeric | Meaning |
|---|---|---|
| `XAU_LOT_MULTIPLIER` | 2 | LOT MULTIPLIER |

### `ENUM_XAU_LOT_BASIS`

Used by: `AutoLotEquityBasis`

| Value | Numeric | Meaning |
|---|---|---|
| `XAU_LOTBASIS_EQUITY` | 1 | equity |

### `ENUM_XAU_AUTLOT_MODE`

Used by: `AutoLotCalculationMode`

| Value | Numeric | Meaning |
|---|---|---|
| `XAU_AUTLOT_MARGIN_CAP` | 1 | limit margin consumption per layer |

### `ENUM_XAU_TP_MODE`

Used by: `BasketTPMode`

| Value | Numeric | Meaning |
|---|---|---|
| `XAU_TP_PRICE` | 4 | price units above/below average |

### `ENUM_XAU_CUT_MODE`

Used by: `CutLossMode`

| Value | Numeric | Meaning |
|---|---|---|
| `XAU_CUT_POINTS` | 3 | points only |

### `ENUM_XAU_CLOSE_ORDER`

Used by: `CutLossCloseOrder`

| Value | Numeric | Meaning |
|---|---|---|
| `XAU_CLOSE_LARGEST_FIRST` | 2 | - |

### `ENUM_XAU_ACTION`

Used by: `ActionOnAccountDD`, `ActionOnCycleDD`, `ActionOnDailyLoss`, `ActionOnFloatingLoss`

| Value | Numeric | Meaning |
|---|---|---|
| `XAU_ACT_EMERGENCY` | 3 | close all + EMERGENCY_STOP |

### `ENUM_XAU_DD_REF`

Used by: `DrawdownReference`

| Value | Numeric | Meaning |
|---|---|---|
| `XAU_DD_DAY_BALANCE` | 1 | equity vs balance at day start |

### `ENUM_XAU_DAILY_MODE`

Used by: `DailyLossBasis`

| Value | Numeric | Meaning |
|---|---|---|
| `XAU_DAILY_REALIZED_PLUS_EA` | 1 | closed + EA floating P/L |

### `ENUM_XAU_EMR_RESET`

Used by: `EmergencyResetMode`

| Value | Numeric | Meaning |
|---|---|---|
| `XAU_EMR_NEXT_DAY` | 1 | auto reset at new server day |

### `ENUM_XAU_OPEN_REF`

Used by: `OpenMarketReference`

| Value | Numeric | Meaning |
|---|---|---|
| `XAU_OPEN_SESSION_START` | 1 | SessionStart input |

### `ENUM_XAU_FAILSAFE`

Used by: `NewsFailSafePolicy`

| Value | Numeric | Meaning |
|---|---|---|
| `XAU_FAILSAFE_WARN` | 2 | trade, log once per bar |

### `ENUM_XAU_IMPORTANCE`

Used by: `MinimumNewsImportance`

| Value | Numeric | Meaning |
|---|---|---|
| `XAU_IMP_HIGH` | 3 | high only |

### `ENUM_XAU_LOGLEVEL`

Used by: `LogLevel`

| Value | Numeric | Meaning |
|---|---|---|
| `XAU_LOG_DEBUG` | 3 | 3 = debug |

### `ENUM_XAU_STATE`

Used by: _internal state only_

| Value | Numeric | Meaning |
|---|---|---|
| `XAU_ST_SELFTEST` | 9 | self test finished, trading halted |

### `ENUM_XAU_BLOCK`

Used by: _internal state only_

| Value | Numeric | Meaning |
|---|---|---|

### `ENUM_XAU_INTENT`

Used by: _internal state only_

| Value | Numeric | Meaning |
|---|---|---|
| `XAU_INT_CLOSE` | 2 | - |

---

Next: [03 - State machine](03-state-machine.md)

