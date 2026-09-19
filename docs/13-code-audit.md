# 13 - Final Code Audit

Scope: every file in `MQL5/Experts` and `MQL5/Include/XAU_AVG_PRO`, against the
acceptance rules of the specification. The audit was performed in this repository
with the tools in `tools/` plus a manual read of every decision path. What this
audit **cannot** do is stated in 13.5 - read that first if you intend to
reproduce it.

## 13.1 Automated checks (all green at the time of writing)

```
$ bash tools/run_all_qa.sh                -> ALL QA STEPS PASSED (runs everything below)
$ python3 tools/qa_static_check.py         -> all static checks passed
$ python3 tools/qa_mql_symbol_check.py     -> no signature or member mismatches
$ python3 tools/gen_input_docs.py --check  -> docs/02 is up to date (165 inputs)
$ python3 tools/qa_preset_check.py         -> all presets valid
$ python3 tools/qa_doc_claims.py           -> documentation matches the source
$ python3 tools/stress_model.py --json     -> model runs clean
```

Families enforced by those commands, and the acceptance rule each one backs:

| Check | Rule it proves |
|---|---|
| 13 check families, listed below in the order they run; forbidden-marker scan (`TODO`, `FIXME`, `PLACEHOLDER`, `XXX`, `pseudo-code`, `not implemented`, `stub`) | §38/§41: no placeholder logic in a "complete" build |
| brace/paren balance outside strings and comments | the file is syntactically whole |
| all `#include` targets exist, every module includes `Types.mqh`, guards unique | §44: compile-in- one-step install |
| every input assigned exactly once in `LoadInputs()`, every `CConfig` field populated (168 fields = 165 inputs + 3 operator flags), no orphan assignment | no silently ignored parameter |
| every `g_cfg.X` / `m_cfg.X` exists; all 1 051 cross-module calls resolve by name, **arity and argument type shape**, and 1 552 member-field accesses resolve against the declaring type | the wiring between the 18 modules is real, not aspirational |
| every `XAU_*` identifier used is declared | no typo'd enum member, no half-renamed constant |
| no struct returned by value | MQL5 portability convention of this codebase |
| all 209 format strings (`StringFormat`/`PrintFormat` with a literal first argument): specifier count == argument count, and zero `%n` | MQL5 has no `%n`; a mismatch is a runtime corruption source |
| no token-shaped literal, `TelegramBotToken` default is `""` | §41: no hard-coded credentials |
| `docs/02` regeneration equals the committed file | the input documentation cannot drift |
| division-safety family: every division by a symbol-derived denominator is guarded locally, clamped where it is read, or backstopped by `MathIsValidNumber` | a zero denominator becomes `inf`/`NaN` and then silently becomes a lot size |
| every enum member is referenced outside its own declaration | no dead flag that reads as a live feature |
| presets: 165 keys each, type-legal, numeric-only, `; overrides:` manifest accurate, no secret shapes | a shipped default must actually be loadable, and its intent must be readable |
| every count quoted in `README`/`CHANGELOG`/these pages is recomputed from the tree | a stale number is how a correct document starts lying |
| every file name and class name mentioned in the docs exists (stdlib references excepted) | the specification cannot describe a module that was never written |
| every whitelisted Telegram command appears in `docs/07` | an undocumented command is an untested one |

### 13.1.1 Shape of the audited tree

**165** inputs in **15** groups, **19** source files, **9 607** lines, **168**
`CConfig` fields, **34** block reasons (plus `NONE`), **10** states, **28** Telegram
commands, **34** dashboard rows, **209** format strings, **14** documentation pages.

Those numbers are recomputed from the tree by `python3 tools/qa_doc_claims.py`, which
also fails if this page, the README or the CHANGELOG quotes a value the source no longer
produces. That is the only reason any count in these documents should be believed.

## 13.2 Manual audit of the risky paths

Each line is a property that was read in the source, with the file it lives in.

**Execution (`Execution.mqh`).**
* `OrderSend` return value is *not* treated as success; success requires
  `10008/10009/10010` **and** a located position (hedging: a new ticket; netting:
  a changed volume) - `docs/06.7`.
* An accepted-but-unverifiable fill sets `r.unverified`, the engine raises
  `XAU_ST_ERROR`, notifies and **never re-sends** (a double send is worse than an
  unknown state).
* Retries are limited to the transient retcode set (`10004, 10012, 10020, 10021,
  10024, 10028, 10029, 10031`) and bounded by `MaxOrderRetries`; hard errors
  (`10014/10016/10019/10033/10040/10045/10046` …) return immediately with the
  retcode name in the message.
* A fresh quote is taken *inside* every attempt; a stale feed aborts the attempt
  instead of sending a remembered price.
* `10030 INVALID_FILL` walks the symbol's allowed filling modes (one retry per
  mode) and then fails with an explicit reason.
* `deviation` is set from `MaximumDeviationPoints`, `type_time=GTC`,
  `magic`/`comment` from the validated config, and the comment is
  sanitised/truncated to 28 printable ASCII characters before it is ever used.

**Risk precedence (`Risk.mqh`, `State.mqh`, pipeline order in the EA).**
* `Strongest(a, b)` is `(int)a >= (int)b ? a : b` over `ENUM_XAU_ACTION` declared in
  severity order (`BLOCK_ONLY < CLOSE_BASKET < CLOSE_ALL < EMERGENCY`), and
  `EvaluateLimits()` *accumulates* with it. An emergency therefore cannot be diluted by
  a milder limit evaluated later; the account-drawdown emergency is additionally
  force-merged (`Risk.mqh:242-244`).
* Entry and averaging are both gated twice: `g_sm.Allows(XAU_INT_ENTRY)` /
  `g_sm.Allows(XAU_INT_AVERAGING)` first (an illegal attempt increments a visible
  counter instead of failing silently), then `g_risk.CheckEntry` / `g_risk.CheckAveraging`.
  Because the risk manager is what puts the machine into `RISK_BLOCKED`/`EMERGENCY_STOP`,
  a profit opportunity can never outrun a limit: the limit is what removes the permission.
* Order of the pipeline is `Reconcile -> basket recompute -> Derive -> EvaluateLimits ->
  exits -> averaging -> entry`. Exits are evaluated before entries; there is no path from
  a signal to `OrderSend` that does not pass through both gates above.

**Risk (`Risk.mqh`, `Basket.mqh`).**
* No `OrderSend` in the risk module; the engine executes the request struct
  (`docs/04`).
* `XAU_INT_CLOSE` bypasses every block, in `CStateMachine` and in the pipeline
  (`docs/03.3`) - verified by a self test, not only by reading.
* Hard-limit evaluation is done before the entry/averaging section of the
  pipeline, and a fired limit makes `CheckEntry`/`CheckAveraging` refuse
  (`docs/04.2`) - "risk limit beats profit opportunity" is a code order, not a
  comment.
* `Basket.Recompute()` sums each **unique ticket once** (netting repeats tickets;
  summing per layer would have multiplied the basket P/L by the layer count).
* Basket TPs are anchored on one reference price and `m_target_money` is not
  overwritten by the trigger test (an earlier draft did, which would have made the
  money target drift after the first partial close).
* `CloseAllLayers` marks the cycle closed only when `PositionCount() == 0`;
  `SetClosing(false)` runs after the sweep, so a partial close retries.

**State / recovery (`StateStore.mqh`, `Statistics.mqh`, `Cycle.mqh`).**
* the state file is written atomically (`.tmp` + `FileMove(FILE_REWRITE)`), keyed
  by `symbol + magic`, so two charts do not fight over one file;
* `peak_equity`, `emg_day`, cooldown deadlines and the override mask are persisted
  (a restart must not reset the drawdown reference or forget an emergency stop);
* daily realized P/L is computed from `HistorySelect(dayStart .. +86400)` filtered
  by `DEAL_MAGIC` (and `DEAL_SYMBOL` when `ManageCurrentSymbolOnly`), counting
  `PROFIT + SWAP + COMMISSION` on `OUT/INOUT/OUT_BY` deals only - it is exact
  across restarts because it does not depend on memory;
* cycle *counters* fall back to a `NOTE: cycle counters are partial` line when the
  cache was unavailable (`docs/09.6`) rather than reporting a clean history.

**Numbers / time (`BrokerSpec.mqh`, `Types.mqh`).**
* Every denominator that can reach a lot size is non-zero by construction, and that is
  now enforced mechanically (static QA family 13) rather than by inspection:
  `m_point` starts at `0.01` in the constructor and is clamped after the symbol read
  (`BrokerSpec.mqh:77`), `m_vol_step` is clamped (`:84`), `m_vol_min` is raised to the
  step (`:86`); `risk_per_lot` and `margin_per_lot` in `Lots.mqh:97/106` return an
  explicit block (`SPEC_INVALID` / `MARGIN`) instead of dividing, and the result is
  re-checked with `MathIsValidNumber` before it can reach the broker.
* `m_contract` is deliberately *not* clamped (a zero contract size means the symbol is
  unusable, not that it is 100), so it never appears as a denominator; the check would
  flag it if it did.
* digits, point, tick size/value, contract size, lot bounds, stops/freeze levels,
  filling mask, leverage and account mode are all read from the symbol; nothing in
  the tree hard-codes `0.01`, `100`, `5` digits, a symbol name or a suffix;
* volume normalisation floors toward zero and returns `0` below `VolumeMin`
  (self-tested), so a sub-minimum lot can never be sent "rounded up" silently;
* `XauNow()` (trade-server time) drives trading logic, `XauStampTime()`
  (`TimeTradeServer()` with fallbacks) drives the journal, `XauServerDayStart()`
  drives "today" - no `TimeLocal()` anywhere in the decision path.

**News (`News.mqh`).**
* real `CalendarValueHistory` + `CalendarEventById`; severity comes from
  `MqlCalendarEvent.importance` (ordinals aligned 1:1 with
  `ENUM_XAU_IMPORTANCE`), **not** from `impact_type`, which is a direction;
* the query window is narrow (a few hours) to avoid the `5401` "range too wide"
  class of failures, `actual_value == LONG_MIN` marks a future row (used for
  "not yet published"), non-`DATETIME` time modes are skipped for blackout
  purposes, and `-1`/`4004`/`5401` route into `NewsFailSafePolicy`;
* no synthetic or hard-coded event data exists anywhere in the tree (checked by
  the same grep that enforces the placeholder rule).

**Telegram (`Telegram.mqh`, `HandleCommand` in the EA).**
* token masked by `MaskToken()` on every log line; no reply, log or CSV contains
  it; `Describe()` reports counters and the disable reason only;
* whitelist of 28 commands with `[a-z0-9_]{1,64}` names, `@botname` stripped,
  arguments length-limited, multi-line input truncated before parsing, everything
  else rejected with a counter;
* the authorised chat id is taken from `"chat":{"id":`, not from the first `"id":`
  in the payload (which is `from.id`, i.e. the user - a real authorisation trap in
  group forwarding);
* destructive commands require the second, matching, in-window confirmation;
  confirmation arming is not persisted across restarts;
* all parameter commands are range-validated on the *engine* side and re-validated
  on the next `OnInit` after restoration (`docs/07.5`).

## 13.3 Defects found and fixed during this audit

Worth listing, because "it compiles" is not the interesting part:

| # | Defect | Fix |
|---|---|---|
| 1 | `OnCycleFinished()` could run twice for one closed basket (once in `CloseBasket`, once in the tick transition detector) - double-counted statistics and a doubled cooldown | close bookkeeping moved entirely to the single open -> flat transition in `OnTick`, with an explicit notice struct carrying code/reason/net |
| 2 | `LogBlock()` incremented the blocked-event counter on every tick a condition stayed true (throttled logging, unthrottled counting) and wrote to a dashboard frame that was not open | counter moves only when the reason changes; the block row is rendered from `g_last_block_*` inside the single `Begin/End` render window |
| 3 | `SafeComment()` replaced the tail of the string from the wrong offset, so control characters survived | rebuilt character-by-character with truncation to 28 |
| 4 | the dashboard printed the server hour as `(TimeCurrent()/3600) % 24`, which is epoch-relative, not broker-local | `TimeToStruct()` on the trading clock |
| 5 | `peak_equity` and the emergency day were not persisted, so `DrawdownReference=PEAK_EQUITY` silently reset to the current equity after a restart (defeating the account-DD limit) and `EmergencyResetMode=NEXT_DAY` could not auto-release | both persisted in the state file and restored before `Derive()` |
| 6 | an invented `g_exec.SetPositionSnapshot(g_exec_snapshot)` call and a wrong-arity `WriteCsv(...)` call, i.e. main-file/module drift | removed; `CloseEverything` derives its own pre-close expectation; the module symbol checker was written *because* of this class of bug and now blocks it |
| 7 | `%n` used inside `StringFormat` for newlines (MQL5 has no `%n`, so it printed a literal) | replaced by real `\n` escapes everywhere; the checker now rejects `%n` |
| 8 | a redundant `WriteCsv()` in `OnInit` added a CSV row per restart | removed - the row is written when the server day rolls |
| 9 | `/emergency_clear` wrote its log line and persisted flags in both branches, and its NEXT_DAY reply contradicted the actual behaviour | handlers rewritten: MANUAL clears, NEXT_DAY is rejected with the armed timestamp, and `CheckEmergencyAutoReset()` performs the automatic release |
| 10 | `XAU_CLOSE_LARGEST_FIRST` was offered but not documented in the docs (and `ALL_AT_ONCE` was documented but not implemented) | doc corrected to the three real modes; no phantom option remains in the docs |
| 11 | `AllowMultipleLayersPerTick` was effectively dead (the duplicate-level and per-bar gates always stopped the second layer) | the multi-pass branch now re-derives the plan and requires the compound relaxation, logging why it refused - and it is asserted by test V |
| 12 | `ActionOnDailyLoss`'s block could be auto-released the moment price recovered | `ResetCheck()` keeps a `DAILY_LOSS` block until the server day rolls (`docs/04.6`) |

## 13.4 Spec compliance table

| Requirement | Where | Status |
|---|---|---|
| EMA cross entry, new-bar/close-bar, BUY/SELL/BOTH, replaceable module | `Entry.mqh`, `docs/02 ENTRY`, `docs/01.2` | met |
| controlled averaging, FIXED or ATR-clamped distance, no duplicates, one per bar, min seconds, gap protection | `Averaging.mqh`, `docs/05` | met |
| FIX / AUTO / MULTIPLIER lots, capped by `MaximumLotPerOrder` | `Lots.mqh`, self-tested | met |
| `MaximumTotalLot`, `MaximumLayer`, margin/free-margin safety | `Lots.mqh` + `Risk.mqh` | met |
| account / cycle / floating / daily DD protection with block-or-close, EMERGENCY_STOP | `Risk.mqh`, `docs/04` | met |
| basket TP in MONEY/POINTS/PERCENT/PRICE incl. spread/commission/swap | `Basket.mqh`, `docs/06.5` | met |
| basket cut loss + cooldown | `docs/06.6` | met |
| spread / ATR / gap / session (incl. crossing midnight) / weekend / open-market filters | `MarketFilters.mqh` | met |
| real MQL5 economic-calendar news filter that fails safe | `News.mqh`, `docs/09.3` | met |
| chart dashboard with 18+ fields | `Dashboard.mqh` (30 rows available) | met |
| >= 20 whitelisted Telegram commands, confirmation, no token in logs | `Telegram.mqh` (28), `docs/07` | met |
| daily report to chart/Telegram/CSV, restart-recoverable | `Statistics.mqh`, `DailyReportTelegramHour` | met |
| structured tagged logs, verified `OrderSend` | `Logger.mqh`, `docs/13.2` | met |
| hedging vs netting explicit | `docs/06.3`, `docs/09.5` | met |
| Strategy Tester compatibility | `docs/01.6`, `docs/11` | met |
| no hard-coded digits/point/contract/lot limits/suffix | symbol checks in `SelfTest`, `CSymbolSpec` | met |
| state reconstructed from real positions/history | `docs/06.1` | met |
| risk limit beats profit opportunity | `docs/04`, `docs/03.3` | met |
| fail-safe on every listed failure | `docs/09`, `docs/08.3` | met |
| no guaranteed-profit claim anywhere | `docs/14`, grep of `docs/` and sources | met |

## 13.5 What this audit could not verify (do not skip this)

* **The code has never been compiled.** This workspace has no MetaEditor (MQL5 is
  Windows-only), so "0 errors 0 warnings" is a *requirement in `docs/10.2`*, not a
  result. The static harness covers structure, wiring, arity, type shape,
  format strings and conventions - it does not cover MQL5 type checking, overload
  resolution or the runtime semantics of the standard API. Expect `docs/08` test A
  to be the first real compiler pass, and treat any compile error as a defect to
  report back rather than a puzzle to improvise around.
* No live or tester order was ever sent here, so `docs/08.3` (tests A-V) is
  **unexecuted** by design; the self tests in `SelfTest.mqh` are the only executed
  verification available in this environment, and they cover logic, not broker
  behaviour.
* Broker-specific behaviour (freeze levels on closes, `10039` handling, netting
  partial-close semantics, calendar availability, real swap/commission) can only
  be confirmed on the target broker - `docs/09.7`.

## 13.6 Review checklist for a future change

1. change an input? update `ValidateConfig()` **and** run
   `python3 tools/gen_input_docs.py`, then `--check` in CI;
2. add a module? it must include `Types.mqh`, take its dependencies in `Init()`,
   never call `OrderSend`, never read an `input` variable, and be listed in
   `docs/01.2`;
3. add a block reason? extend `ENUM_XAU_BLOCK`, name it in `BlockName()` and the
   self test that requires every code to have a name will keep the docs honest;
4. touch the execution or risk path? run `docs/08.2` self tests plus `docs/08.3`
   tests L, M, T, V before anything else;
5. never resolve a "self test failure" by deleting the assertion - the assertion
   is the cheaper of the two problems.

---
Prev: [12 - Stress test report](12-stress-test-report.md) |
Next: [14 - Risk disclaimer](14-risk-disclaimer.md)
