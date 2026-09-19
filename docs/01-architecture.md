# 01 - Architecture

XAU_AVG_PRO is a modular Expert Advisor. `OnTick()` is a scheduler: it calls the
modules in a fixed order and never contains trading logic. That is the single
structural decision everything else follows from.

## 1.1 File layout

```
MQL5/
  Experts/
    XAU_AVG_PRO.mq5              inputs, config loading/validation, module wiring,
                                 event handlers, Telegram command execution,
                                 pipeline order, dashboard assembly
  Include/
    XAU_AVG_PRO/
      Types.mqh      enums, structs, CConfig, number/time/price
                                      helpers, retcode table - no behaviour
      Logger.mqh  tagged, levelled, throttled journal + optional file
      BrokerSpec.mqh  live symbol facts, normalisation, margin/leverage
      StateStore.mqh  atomic key/value state file (restart recovery)
      Cycle.mqh  cycle identity, position reconciliation, layer model
      Entry.mqh  EMA cross engine (replaceable), confirmations
      Averaging.mqh  level geometry, distance policy, anti-runaway gates
      Lots.mqh  FIX / AUTO / MULTIPLIER sizing + margin pre-check
      MarketFilters.mqh  spread, ATR volatility, gap, session, weekend
      News.mqh  MqlCal economic calendar (fails safe)
      Execution.mqh  OrderSend/OrderCheck, retries, fill verification
      Basket.mqh  basket maths, TP, cut loss, closing
      State.mqh  the state machine (single source of truth for gating)
      Risk.mqh  every hard limit, in priority order
      Statistics.mqh  history-based daily stats + CSV report
      Dashboard.mqh  chart panel renderer (throttled)
      Telegram.mqh  long polling, whitelist, confirmations
      SelfTest.mqh  deterministic logic tests (no market needed)
tools/
  qa_static_check.py             structural + convention checks (12 families)
  qa_mql_symbol_check.py         arity / member / type-shape resolution
  gen_input_docs.py              generates docs/02 from the source (--check in CI)
  gen_preset.py                  builds .set presets from the real input names
  stress_model.py                generates the docs/12 stress tables (--json too)
  run_all_qa.sh                  the whole chain in one command
```

Total: 19 source files, 9,629 lines (recount with `wc -l MQL5/Experts/*.mq5 MQL5/Include/XAU_AVG_PRO/*.mqh`; it is the only metric in these documents that may change without a version bump). Every `.mqh` is standalone-compilable
(it includes `Types.mqh` itself) and is protected by an include guard.

## 1.2 Module responsibilities and ownership

| Module | Owns | Must never |
|---|---|---|
| `CSymbolSpec` | digits, point, tick size/value, contract size, lot min/max/step, stops/freeze level, filling policy, leverage, hedging/netting mode, quote age | assume a symbol or a suffix |
| `CLogger` | levels, tags, throttling, file mirror | log a secret, format trading decisions |
| `CStateStore` | the `.csv`-like key/value file, dirty flag, atomic save | decide anything about trading |
| `CCycleManager` | cycle id, layer records, magic/symbol filter, reconciliation from real positions | place orders |
| `CEntryEngine` | EMA handles, signal state, bar-close confirmation | size or place an order |
| `CAveragingEngine` | next level, distance policy, duplicate/one-per-bar/minimum-seconds gates | decide whether risk allows it |
| `CLotManager` | FIX/AUTO/MULTIPLIER sizing, broker legality, exposure headroom, margin projection | send orders |
| `CMarketFilters` | spread, volatility, gap, session, weekend, market-open guards | modify positions |
| `CNewsFilter` | calendar window, impact/importance, blackout windows | block a *close* |
| `CExecution` | request building, `OrderCheck`, retries, verified fills, error taxonomy | decide *whether* to trade |
| `CBasketManager` | totals, average price, TP (4 modes), cut loss, break-even, close loops | forget an unverified close |
| `CStateMachine` | the current state, block reason, gating queries | contain risk formulas |
| `CRiskManager` | all limits, priority order, actions, reset/hysteresis | place or close orders itself |
| `CStatistics` | today's realized P/L, counters, CSV | be the source of truth for positions |
| `CDashboard` | chart labels and the pause button | change state (the click is a request) |
| `CTelegramBot` | transport, whitelist, sanitising, rate limit, confirmation | execute anything itself |
| `CSelfTest` | deterministic logic assertions | trade or use the network |

Two ownership rules are enforced mechanically by the QA harness:

* **Only `CExecution` calls `OrderSend`.** Nothing else in the tree is allowed to
  place, modify or close an order, so there is exactly one place to audit for
  execution risk (and exactly one place that knows what a "verified fill" means).
* **Only `CStateMachine` answers "may I act?"** Every open/average path asks
  `g_sm.Allows(intent)` after `CRiskManager` has spoken; `XAU_INT_CLOSE` is never
  denied by any state.

## 1.3 Data flow per tick

```
OnTick
  └─ RunPipeline
       1  UpdateMarketData()          quotes, bar detection, spread, age
       2  entry/avg/filters Update()  indicator refresh (new bar; ATR refresh optional in-bar)
       3  g_cycle.Reconcile()           rebuild from PositionsTotal/HistoryDeal  <-- truth
       4  g_basket.Recompute()          volumes, average price, notional
       5  g_cycle.UpdateDrawdown()      worst-case tracking for the cycle
       6  g_avg.BuildPlan()             next level + distance (also feeds the dashboard)
       7  g_sm.Derive()                 state = f(operator flags, risk, real positions)
       8  g_risk.EvaluateLimits()       hard limits -> maybe CLOSE / EMERGENCY  (returns first)
       9  basket exits: weekend flatten -> TP -> cut loss
      10  TryAverage()                  gated by everything above
      11  TryOpenCycle()                only when flat and every filter passes
      12  BuildDashboard()              one render pass, throttled inside CDashboard
```

Everything that is *not* tick-rate work lives in `OnTimer(1s)`: Telegram
polling and command draining, calendar refresh, statistics day-roll, peak
equity, emergency auto-reset, scheduled daily report, state flush, dashboard
refresh. `OnTradeTransaction` (deal add, own magic) triggers an immediate
reconcile + state save, so recovery does not depend on the next tick arriving.

## 1.4 Communication and shared data

MQL5 has no references to members and no function pointers, so the design uses
what the language actually offers:

* Modules hold **pointers** to the objects they need, injected by `Init()` in
  `OnInit`. There is no global singleton service and no hidden coupling: the
  dependency list of a module is exactly its `Init()` signature.
* All configuration lives in one `CConfig` value that `OnInit()` fills from the
  `input` variables **once**. Modules never read `input` directly - that is what
  makes runtime overrides (Telegram) and the self tests possible without
  touching the trader's dialog.
* Cross-module results are POD structs passed by reference (`SVerdict`,
  `SAvgPlan`, `SExecResult`, `SActionReq`). No function returns a struct by
  value: this codebase treats that as a portability hazard and the QA harness
  rejects it.
* `SRt` is the per-tick runtime snapshot (prices, bar time, spread, gates that
  need to survive a bar, counters). It is passed by reference into the modules
  that need it instead of being read from globals.

## 1.5 Deliberate deviations from "just use CTrade"

* **No `<Trade/Trade.mqh>`.** `CTrade` hides the request/result and its own
  success test (`retcode==10009`) is not enough on a market with requotes. The
  EA builds `MqlTradeRequest` itself, runs `OrderCheck` first, retries only on
  transient retcodes, and then *verifies the fill by looking for the position*.
  A `10009 DONE` that cannot be verified becomes `ERROR`, never a re-send.
* **`OnTimer` for I/O.** `WebRequest` (Telegram) and `CalendarValueHistory` are
  slow or blocking; putting them in `OnTick` would distort every decision and is
  impossible in the Strategy Tester anyway.
* **State file, not globals.** Everything that must survive a restart is either
  reconstructed from the account (positions, history) or persisted in a key/value
  file written atomically (`.tmp` + `FileMove(FILE_REWRITE)`).

## 1.6 Tester compatibility

`MQLInfoInteger(MQL_TESTER)` is checked wherever the environment differs: the
dashboard is not drawn in a non-visual tester, Telegram and the news filter
self-disable (no `WebRequest` in the tester), the CSV writer is skipped, and
`Sleep()` between fill-verification scans is ignored by the tester (harmless:
verification is a loop, not a wait). Backtests therefore exercise the real
decision path with only the external I/O stubbed out by policy - and the log
says so explicitly instead of silently pretending to be live.

---
Next: [02 - Complete input specification](02-input-specification.md)
