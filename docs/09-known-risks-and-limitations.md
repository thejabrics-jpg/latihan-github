# 09 - Known Risks and Limitations

Read this before the first live run. Everything here is a real property of this
build, not a disclaimer pasted for form: where a limitation exists, the section
says what the EA does about it and what it explicitly does **not** do.

## 9.1 The strategy risk is structural

Averaging (and lot multiplication) increases exposure **non-linearly** as the
market moves against you. That is not a bug to be tuned away; it is what the
mechanism is. Consequences that no parameter can remove:

* the deeper the basket, the larger the volume, so the same additional adverse
  move costs *more* money than the previous one did;
* the basket's break-even price keeps moving away from the market, so recovery
  requires a bigger reversal, not the same one;
* a basket that "always recovers" on the backtest is a statement about the sample,
  not about the distribution.

The numbers in `docs/12` are there so this is visible *before* you fund an account
with it. `docs/14` states the same in the language that must travel with the EA.

## 9.2 Exits live inside the EA

The EA places no broker-side stop loss or take profit on individual layers
(`docs/06.8` explains why per-layer stops are worse for this strategy). The
direct cost: **if the terminal is stopped, disconnected, or the EA is removed,
nothing manages the basket**. Mitigations, in order of value:

1. run it where it cannot silently stop (VPS or a machine that stays logged in);
2. keep `MaximumFloatingLossMoney` and `MaximumCycleDrawdownPercent` small enough
   that the worst move *between your reaction and the market* is survivable;
3. use `EnableWeekendProtection`, and `CloseBasketBeforeFridayStop=true` if your
   broker has gappy Monday opens;
4. accept that the EMERGENCY_STOP / risk-close path only works while the EA runs.

## 9.3 News filter depends on the broker's calendar

`EnableNewsFilter=true` uses the real MQL5 economic calendar
(`CalendarValueHistory` + `CalendarEventById`). Known limits:

* many brokers do not subscribe to (or do not enable) the calendar: `CalendarValueHistory`
  then returns `-1` / `4004` / `5401`. The EA **fails safe** according to
  `NewsFailSafePolicy` (default `XAU_FAILSAFE_BLOCK`: no new risk while the
  calendar is unavailable) and logs that it has no data. It never substitutes
  invented or hard-coded event data;
* event times are trade-server times, and `News.mqh` aligns its windows to
  `TimeTradeServer()`, so "30 minutes before NFP" means the same clock the
  positions are stamped with;
* events whose `time_mode` is not `DATETIME` (day-long, tentative) are skipped
  conservatively for *trading* purposes but the EA does not pretend to have seen
  them: they cannot create a blackout window;
* `importance` is what is compared (`MinimumNewsImportance`); `impact_type` in the
  API is a *direction* (positive/negative), not a severity, and is deliberately
  not used for blocking;
* the calendar is unavailable in the Strategy Tester, so any test that appears to
  "pass with the news filter on" in the tester is not testing the news filter
  (`docs/08.4`).

## 9.4 Telegram limits

* unavailable in the Strategy Tester (`WebRequest` is refused there) - the module
  self-disables and trading continues;
* requires `https://api.telegram.org` in the terminal's allowed-URL list; a wrong
  token disables Telegram with a reason, not the EA;
* inbound commands are only as timely as `TelegramPollingIntervalSeconds` and the
  1 s `OnTimer`; a command issued while the terminal is frozen executes after it
  unfreezes (the queue is bounded and `PendingCommands()` is reported);
* there is **no** authentication beyond "the update came from the configured chat
  id". Telegram accounts can be hijacked; treat the bot as a remote control for
  your money and use Telegram's own 2FA. `TelegramEnableOverrides=false` and
  `RequireConfirmationForDestructive=true` are the defaults for a reason;
* destructive commands are never executed without the in-window confirmation, and
  a pending confirmation does not survive a restart by design.

## 9.5 Netting accounts

On netting, "layers" are not first-class objects at the broker: one position per
symbol, averaged price, one ticket. The EA therefore:

* counts layers exactly only when `LotMode=FIX` **and**
  `AllowNettingLayerReconstruction=true` (volume divided by the fixed base lot is
  an unambiguous counter);
* otherwise adopts the basket as *uncertain*: exits are managed, averaging is
  refused (`XAU_BLK_NETTING_UNCERTAIN`);
* reports a `XAU_ST_ERROR` if it sees contradictory directions for its own magic.

Anything fancier (reconstructing layers from deal history when the base lot
varies, or when AUTO LOT changes size per layer) would be a guess about which
deal belonged to which level, and a guess here is how a controlled basket becomes
an uncontrolled one. It is a documented gap, not a hidden one.

## 9.6 Statistics that cannot be perfectly reconstructed

Realized P/L, entry counts and closed-deal counts come from **deal history** and
are exact for the current server day. Cycle counters (wins/losses by exit type,
max layer, max DD per cycle) live in the EA's state file: if the state file is
lost, the counters restart from zero while the P/L stays right - the daily report
then prints `NOTE: cycle counters are partial`, by design, rather than silently
reporting a clean history.

## 9.7 Broker-environment differences that are *not* smoothed away

The EA reads everything dynamically (`CSymbolSpec`): digits, point, tick size and
value, contract size, lot min/max/step, stops and freeze levels, filling policy,
leverage, hedging vs netting, swap/commission presence. Two consequences:

* a backtest on broker A and a live account on broker B can behave differently -
  spread, freeze levels and swap/commission structure are broker properties;
* `EstimatedCommissionPerLot` is an *estimate* used for cost-aware basket TP and
  statistics: if you leave it at 0 while your broker charges 3.0 per lot per side,
  the basket TP will be reached a little later than the panel suggests. The
  dashboard's `COSTS` row shows the commission estimate and the accrued swap of
  the open basket, so the assumption is visible while it matters.

## 9.8 Filling, slippage and the "accepted but invisible" case

`10009 DONE` is not treated as success: the position must be found. If a broker
reports a fill that the EA cannot locate, the EA raises `XAU_ST_ERROR`, notifies
and **refuses to re-send** (a re-send could double the exposure). Recovery is
manual by design: check the terminal's position list, then either fix the state or
`/resetparams` + reload. `10030 INVALID_FILL` falls back across the symbol's
allowed filling modes (one retry per mode) before failing with an explicit reason.

## 9.9 Time semantics

Trading decisions use `XauNow()` = `TimeCurrent()` (the trade-server time of the
last tick) so that a backtest is reproducible; log stamps use `XauStampTime()`
(`TimeTradeServer()` with fallbacks) so a quiet feed cannot freeze the journal;
`XauServerDayStart()` anchors "today" for daily limits and reports. If your broker
names server midnight differently, all "day" boundaries move with it - that is the
broker's clock, and the EA does not pretend to know your local timezone.

## 9.10 What this EA never claims

* it does not claim profitability, a win rate, or that any account size is "safe
  for everyone" - the account figures in `docs/10`/`docs/12` are arithmetic about
  the loss a *given* configuration can produce, not advice;
* it does not recover a blown account, and there is no setting that makes the loss
  of one cycle irrelevant;
* it does not manage other EAs' or your manual trades (deliberate isolation);
* it does not "protect" you from a stop-out the broker executes first - a margin
  call is a race the EA tries to avoid *before* sending, which is why the margin
  gate and `OrderCheck` run ahead of every request.

## 9.11 Smaller things worth knowing

* `AllowIntraBarATRRefresh=true` makes the next level move while the current bar
  is still forming. It is off by default: determinism beats smoothness here.
* `MaximumLayer=1` is not "no averaging" in spirit - it is "one entry only";
  prefer `EnableAveraging=false`, which also stops the level bookkeeping and says
  so on the dashboard.
* In the Strategy Tester `Sleep()` is ignored; the fill-verification loop still
  runs, which is why verification works there, but timing-sensitive behaviours
  (retry spacing, cooldown seconds vs. wall clock) are compressed. Test them on
  demo.
* `DailyReportTelegramHour` fires when `TimeCurrent()`'s hour equals it; a market
  closed at that hour (weekend) means the report goes out on the next tick, and
  the `report_day` state key guarantees it goes out at most once per server day.
* Chart objects use the `XAAP_` prefix and are deleted on detach only when
  `RemoveDashboardOnDetach=true`, so a template that you want to keep can survive.

---
Prev: [08 - Testing strategy](08-testing-strategy.md) |
Next: [10 - Installation & configuration](10-installation-and-configuration.md)
