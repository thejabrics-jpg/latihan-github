# 11 - Backtest and Optimisation Protocol

The purpose of backtesting this EA is **not** to find the settings that made the
most money in the past. For an averaging basket the useful questions are: does the
risk machinery fire when it must, how big does the basket actually get, and how
much does the tail cost. Everything below is ordered by that purpose.

## 11.1 Tester configuration (fixed, for every run)

| Setting | Value | Reason |
|---|---|---|
| Symbol | your gold symbol (with suffix) | the EA reads everything from the symbol, `docs/09.7` |
| Period | `M15` for the shipped EMA entry; also run `H1` | the entry timeframe is an input (`EMATimeframe`), keep it explicit |
| Modeling | **Every tick based on real ticks** | spread and intra-bar ordering decide averaging triggers |
| Spread | current / fixed at your broker's typical value | the spread filter and `MinimumDistanceSpreadMultiple` are spread-sensitive |
| Commission | model it (and set `EstimatedCommissionPerLot` to match) | the basket TP is cost aware (`docs/06.5`) |
| Swap | on | overnight gold carry moves a waiting basket |
| Optimization | **none** for the first 3 runs | see 11.4 |

Also: `LogLevel=DEBUG`, `EnableDebugTickLog=true`, `LogToFile=true` when hunting a
behaviour question; `EnableTelegram=false` is forced anyway (self-disabled in the
tester, `docs/09.4`) and `EnableNewsFilter` is inert there (`docs/09.3`) - never
count a tester run as a news-filter test.

## 11.2 The five runs every release gets

| # | Run | What must be true |
|---|---|---|
| 1 | 3 months, `M15`, real ticks, defaults | entries appear only on new bar / close bar per `EntryConfirmation`; **one layer per pass**; every basket ends in TP, cut loss, risk close or weekend flatten - never "still open at the end" without explanation |
| 2 | same period with `MaximumLayer=2` and `MaximumTotalLot=0.10` | the caps bind: log lines with `MAX_LAYER`/`MAX_TOTAL_LOT`, and total volume never exceeds them |
| 3 | worst month you can find (news week / gap open / trend) | the daily and account DD limits fire *before* the equity curve breaks; EMERGENCY (if configured) closes and blocks; no negative-equity nonsense |
| 4 | 3 years, out-of-sample split (see 11.4) | the tail is stable: the worst cycle loss across years is within `docs/12`-style arithmetic of the caps you configured |
| 5 | forward, demo, >= 2 weeks | same behaviour as the tester for the same inputs, including Telegram and the news filter (which only work here) |

## 11.3 Reading the results

Use the journal, not only the graph. The lines that matter:

* `[STATE] A -> B | reason` - a state machine that oscillates every few ticks is
  a configuration or filter problem (`docs/03.2`);
* `[AVG] LAYER n opened … level=… dist=…` and every *blocked* variant
  (`ONE_PER_BAR`, `TOO_SOON`, `DUPLICATE_LEVEL`, `DISTANCE_TOO_SMALL`) - the
  guards should appear in a rough market, and never be the only thing that saves
  you in a calm one;
* `[RISK]`/`[MAXDD]` with `action=` - which limit fired, and whether the action
  you configured actually ran;
* `[EXEC]` lines with retcodes - a clean backtest should show essentially no
  retries; `10019/10025/10030` mean the settings do not fit that broker.
* the `[STATS]` day-close line and the CSV: wins/losses by exit code, max layer
  reached, max floating. `docs/06.6` explains why "closed on TP" is counted by the
  *net* sign, not by the mode.

Report these per run, always, even when they are ugly:

```
cycles, wins by TP / by cut loss / by risk close / external
max total lot reached, max layers reached
max floating loss, max cycle drawdown %, max account drawdown %
average basket duration, longest basket duration
orders sent / retried / failed / unverified
sum of swap and commission inside the reported P/L
```

## 11.4 Optimisation rules (they exist to prevent the classic self-deception)

1. **Never optimise the money target or the lot.** `InitialLot`, `RiskPercent`,
   `BasketTakeProfitMoney` and `LotMultiplier` are risk knobs: optimising them
   finds the account size the past could survive. If a "best" setting needs more
   volume than `docs/10.5` arithmetic supports for your account, it is wrong, not
   ambitious.
2. Optimise only these, and only in the given ranges (all of them are the
   documented inputs):
   `AveragingDistancePoints` 200..1200, `ATRMultiplier` 1.0..2.5,
   `MinimumSecondsBetweenAveraging` 0..900, `MaximumLayer` 2..8,
   `MaximumAveragingDistancePoints` 400..3000, `BasketTakeProfitPoints` 100..1500,
   `MaximumSpreadPoints` 200..1200, `MinimumATRPoints` 0..200.
3. Objective = **maximise the worst case**, not the profit: rank by
   (recovery factor / max drawdown) then reject any candidate whose
   `max cycle loss > 2 x the configured cut loss` (which means the cap was blown
   through by a gap or by your own settings), and reject any candidate that needs
   more than 30 % margin utilisation at the 99th percentile.
4. Walk-forward: optimise 6 months, test the next 3, roll. A parameter set that
   only wins in its own window is noise. Keep the *neighbourhood*, not the peak:
   if the neighbours of the chosen point are much worse, the point is a spike.
5. Then re-run the chosen set over all years **with** the stress scenarios of
   `tools/stress_model.py` (a 5-6 layer adverse sequence is a *design* condition,
   not a tail you hope the backtest hides).

## 11.5 Known tester blind spots for this EA (each one is a "test on demo")

* news filter (`CalendarValueHistory` unavailable) - `docs/09.3`;
* Telegram (`WebRequest` unavailable) - `docs/09.4`;
* real requotes, partial fills, broker-side close-order handling
  (`10036/10039`) - `docs/09.8`;
* spread variation between sessions (unless real ticks + real spread are used);
* weekend gaps, if the data set does not contain one;
* swap/commission surprises at month end (the "3-day swap" Wed/Thu convention) -
  the cost-aware basket TP is only as good as the numbers you gave it.

## 11.6 What a good result looks like

A good backtest for this EA is *boring*: shallow equity steps, cut losses that all
land near the configured cap, no cycle that ever exceeds `MaximumLayer` or
`MaximumTotalLot`, no `ERROR` state entries, no `unverified` execution events, and
a max account drawdown comfortably below `MaximumAccountDrawdownPercent` so the
limit never actually had to save you. A backtest with a beautiful profit curve and
`XAU_ST_ERROR` lines in the log is a broken build, not a good system.

---
Prev: [10 - Installation](10-installation-and-configuration.md) |
Next: [12 - Stress test report](12-stress-test-report.md)
