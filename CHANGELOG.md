# Changelog

All notable changes to XAU_AVG_PRO. Versions follow `MAJOR.MINOR.PATCH`;
`XAU_EA_VERSION` in `MQL5/Include/XAU_AVG_PRO/Types.mqh` and `#property version`
in the `.mq5` are the authority for the build string.

## [1.0.0] - 2026-09-19

First complete release: a modular XAUUSD averaging EA with a risk layer that is
evaluated before every opening decision.

### Added

* **EA core** - `MQL5/Experts/XAU_AVG_PRO.mq5`: 165 inputs in 15 groups, one-time
  copy into `CConfig`, `ValidateConfig()` (hard errors keep the EA running but
  refuse trading so the dashboard and log stay readable), `OnInit`/`OnDeinit`/
  `OnTick`/`OnTimer`/`OnTradeTransaction`/`OnChartEvent`, the pipeline order, the
  Telegram command executor, the dashboard assembly and the cycle-finish
  bookkeeping (`OnCycleFinished`, exactly one per finished cycle).
* **18 modules** in `MQL5/Include/XAU_AVG_PRO/`: `Types` (enums, structs, number/
  price/time helpers, retcode taxonomy), `Logger` (tagged, levelled, throttled,
  optional file mirror, `MaskToken`-safe), `BrokerSpec` (everything read from the
  symbol: digits, point, tick size/value, contract, lot min/max/step, stops and
  freeze level, filling mask, leverage, account mode, quote age), `StateStore`
  (atomic key/value file, dirty tracking), `Cycle` (cycle identity, position
  reconciliation, layer model, netting handling), `Entry` (EMA cross, new-bar /
  close-bar confirmation, optional candle filter, replaceable), `Averaging`
  (level geometry, FIXED/ATR distance, four runaway guards), `Lots` (FIX / AUTO /
  MULTIPLIER, exposure headroom, margin projection), `MarketFilters` (spread, ATR
  volatility, gap, session crossing midnight, weekend, open-market protection),
  `News` (real MQL5 calendar, importance based, fails safe), `Execution` (the only
  `OrderSend` in the tree: `OrderCheck`, bounded transient retries, filling-mode
  fallback for 10030, verified fills, unverified -> `ERROR`), `Basket` (unique
  ticket sums, four TP modes cost aware, cut loss, break-even, closing sweeps),
  `State` (derived state machine, 10 states, 35 block codes, closes never
  blocked), `Risk` (all hard limits in priority order, actions, hysteresis
  reset), `Statistics` (history-based daily P/L, EA cycle counters, CSV),
  `Dashboard` (34 rows, throttled render, optional pause button), `Telegram`
  (28 whitelisted commands, sanitiser, per-minute rate limit, 90 s confirmation,
  backoff, masked token), `SelfTest` (75 deterministic assertions, no market,
  no network, no orders).
* **Documentation** `docs/01` … `docs/14` + this changelog: architecture, generated
  input reference, state machine, risk model, averaging algorithm, cycle
  management, Telegram specification, testing strategy, known risks and
  limitations, installation, backtest protocol, stress report, code audit, risk
  disclaimer.
* **QA tooling** `tools/`: `qa_static_check.py` (13 check families incl.
  forbidden-marker scan, input <-> `CConfig` mirroring, 209 format strings),
  `qa_mql_symbol_check.py` (1 051 call sites and 1 552 field accesses resolved against
  the declarations, by name, arity and type shape), `gen_input_docs.py` (docs/02
  cannot drift), `gen_preset.py`
  (`.set` presets built from the real input names), `stress_model.py` (the
  generated tables behind `docs/12`, `--json` for machines).
* **Presets**: `presets/XAU_AVG_PRO_conservative.set`,
  `XAU_AVG_PRO_cent_account.set`, `XAU_AVG_PRO_multiplier_demo.set` (demo only).

### Behaviour decisions (deliberate, documented)

* `LotMode=FIX` and no multiplier are the shipped defaults; the multiplier must be
  opted into after reading `docs/12`.
* No broker-side SL/TP on individual layers: basket-level exits only, with the
  operational consequence stated in `docs/06.8` / `docs/09.2`.
* Foreign and manual positions are never touched (`symbol + MagicNumber`
  isolation), including under `ActionOnDailyLoss=XAU_ACT_CLOSE_ALL`.
* The news filter never invents event data; when the broker calendar is
  unavailable it fails according to `NewsFailSafePolicy` (default: block new risk)
  and says so in the log.
* A `10009 DONE` that cannot be verified becomes `XAU_ST_ERROR`, never a re-send.
* `DailyLossBasis=REALIZED_PLUS_EA` by default so a daily stop cannot be evaded
  by holding a losing basket across midnight.
* One averaging layer per pipeline pass; `AllowMultipleLayersPerTick` requires
  `OneLayerPerBar=false` **and** `MinimumSecondsBetweenAveraging=0` to do anything.

### Finalization & QA pass (documentation + tooling only, same build string)

No file under `MQL5/` changed in this pass, which is why `XAU_EA_VERSION` is still
`1.0.0`: a version bump that implies behaviour change would have been a lie. What
changed is how much of the tree can be *checked*:

* `tools/run_all_qa.sh` is now nine steps instead of five: preset validation, a
  documentation-claims gate, a secret/placeholder sweep, a stress-model
  reproducibility check, and an explicit `NOT AVAILABLE IN CURRENT ENVIRONMENT`
  line for compilation rather than a silent skip.
* New `tools/qa_preset_check.py`: every `.set` must be complete (165 keys), numeric-only,
  type-legal against the input type, free of secret shapes, and its `; overrides:`
  manifest must match the values that actually differ. Presets now carry that manifest.
* New `tools/qa_doc_claims.py`: recomputes every count quoted in the README, CHANGELOG
  and `docs/`, checks that every file and class the docs name exists, that every enum
  member is used, that every input reaches `CConfig`, and that every whitelisted
  Telegram command is documented.
* New `tools/mql_values.py`, shared by the generator and the checker, so the two cannot
  disagree about what `clrDodgerBlue`, `PERIOD_CURRENT` or `XAU_CORNER_LEFT_TOP` mean.
* `gen_preset.py` lost its private duplicate of those tables (they had begun to drift).
* Static QA grew family 13: division-safety on symbol-derived denominators (locally
  guarded, clamped where read, or backstopped by `MathIsValidNumber`).
* Stale numbers found by that gate and corrected: assertion count `76 -> 75` (the 76th
  `Check(` match was the helper's own declaration), input groups `17 -> 15`, format
  strings `199 -> 209`, block-reason phrasing aligned to the real enum prefix
  `XAU_BLK_`, symbol-checker counts stated exactly (`1 051` calls, `1 552` field
  accesses), `docs/02`/`docs/12` regenerated and verified byte-identical.
* `README.md` gained a "what is verified / what a terminal must prove / what cannot be
  proven here" table, so a reader never has to guess which claims are mechanical.

### Known limitations of this release

* The sources have **not been compiled** in the authoring environment (no MetaEditor
  on Linux); `docs/08` test A is the first real compiler pass, and `docs/13.5`
  states precisely what the static harness does and does not prove.
* Cycle *counters* (not P/L) are EA-maintained: without a state file they restart
  from zero and the daily report says `NOTE: cycle counters are partial`
  (`docs/09.6`).
* Layer reconstruction on netting accounts is exact only for `LotMode=FIX`
  (`docs/09.5`).

## Version policy

`PATCH` - fixes that cannot change a risk decision. `MINOR` - new inputs or new
exit/block reasons, defaults unchanged. `MAJOR` - anything that can change whether
a position is opened, averaged or closed.
