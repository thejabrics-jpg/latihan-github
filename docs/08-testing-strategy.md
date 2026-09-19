# 08 - Testing Strategy

Three layers, in this order. Do not skip layer 1 - it costs two minutes and it is
the only layer that can be run without a terminal.

| Layer | What it proves | How |
|---|---|---|
| 1. Static QA | the sources are structurally sound, the config plumbing is complete, no forbidden markers, no format-string bugs | `python3 tools/qa_static_check.py && python3 tools/qa_mql_symbol_check.py` |
| 2. Built-in self tests | the deterministic maths and gates (lot normalisation, points/money round trip, averaging guards, margin gate, state precedence, Telegram sanitiser) | `RunSelfTestsOnInit=true` in the terminal, or the Strategy Tester with any symbol |
| 3. MT5 protocol A-V | behaviour against a real market, a real broker and a real account | Strategy Tester + demo, checklists below |

## 8.1 Layer 1 - static QA (run in CI or before every release)

```
bash tools/run_all_qa.sh                  # the whole chain: 9 steps, ends "ALL QA STEPS PASSED"
```

which runs, in order:

```
python3 tools/qa_static_check.py           # 13 check families, exit code 0 = clean
python3 tools/qa_mql_symbol_check.py       # 1 051 call sites resolved against the declarations
python3 tools/gen_input_docs.py --check    # docs/02 still matches the source
python3 tools/qa_preset_check.py           # every preset: 165 keys, types, manifest, secrets
python3 tools/qa_doc_claims.py             # every count in README/CHANGELOG/docs is recomputed
python3 tools/stress_model.py --emit-doc /tmp/d12.md   # docs/12 must be byte-identical
```

Step 9 of that chain is **compilation**, and in a Linux sandbox it prints
`NOT AVAILABLE IN CURRENT ENVIRONMENT` instead of pretending: the pass line below does
not mean the code was compiled (`docs/13.5`).

What they enforce, and why each of those is a *release* check rather than a lint
nicety:

* brace/paren/bracket balance outside strings and comments;
* every `#include` resolves - a renamed module must not fail only in a customer's
  MetaEditor;
* **no `TODO` / `FIXME` / `PLACEHOLDER` / `XXX` / `pseudo-code` / `not implemented` /
  `stub`** anywhere in the shipped sources (hard acceptance rule);
* every `input` is assigned **exactly once** in `LoadInputs()`, and every
  `CConfig` field except the three operator flags is populated - a silently
  ignored parameter is worse than a missing one;
* every `m_cfg.<Field>` / `g_cfg.<Field>` exists in `CConfig`;
* method arity, member existence and argument *type shape* for all cross-module
  calls (this check already caught real integration bugs during development: a
  `WriteCsv` with the wrong argument count, a `ClearRiskBlock()` without its
  reason string, an invented `SetPositionSnapshot` call);
* every `XAU_*` identifier used is declared (no typo'd enum member);
* no struct is returned by value;
* every `StringFormat`/`PrintFormat` format string has exactly as many
  specifiers as arguments (209 strings checked at the time of writing) - and no `%n`, which MQL5 does not
  support;
* no token-shaped literal and no non-empty `TelegramBotToken` default;
* no duplicate method definitions across modules; each module includes `Types.mqh`
  and is therefore compilable standalone.

## 8.2 Layer 2 - the built-in self tests

`SelfTest.mqh` (510 lines, 75 assertions + 8 skips) runs from `OnInit` when
`RunSelfTestsOnInit=true`. It needs **no market data, no positions and no
network**, and it never sends an order. Each check prints `PASS/FAIL/SKIP` with
the measured value into the log (`[TEST]`) and into a single summary that is also
sent to Telegram when Telegram is on. `HaltAfterSelfTests=true` additionally
leaves the EA in `XAU_ST_SELFTEST` - management of an existing basket stays
armed, opening stays blocked - so you can read the result on a live chart without
risking a trade.

Coverage, by group:

| Group | Asserts |
|---|---|
| number helpers | `XauVolumeDigits` for steps 0.001/0.01/0.1/1.0; `XauClamp` on both bounds and inside them |
| retcode taxonomy | `10004/10012/10020/10021/10024/10028/10029/10031` retryable; `10014/10016/10019` hard-fail; `10018` classified as a market block; unknown retcodes fall back to `RET_<n>` instead of an assert |
| time helpers | server day start is exactly midnight; minutes-of-day range; `XauHHMM` zero padding; day-of-week range |
| verdict struct | pass/fail helpers fill `allowed`, `code`, `block_until`, `value`, `reason` |
| symbol spec | normalised price lands on the point grid; a volume below `VolumeMin` normalises to **0** (i.e. "refuse"); flooring never *increases* volume; `MoneyPerPointPerLot > 0`; points -> money -> points and points -> price -> points round trips; `OrderCalcMargin` returns a positive margin (or SKIP where unavailable) |
| lot manager | FIX lot returned untouched; `MaximumLotPerOrder` caps every mode including FIX; MULTIPLIER equals `floor(min(base*mult^(n-1), cap))` for layers 1-6 and is monotonic; the multiplier can never bypass the cap; `MaximumTotalLot` rejects the next layer **and returns lot 0** (no leak); `TruncateLotToExposureHeadroom` shrinks instead of rejecting; AUTO LOT scales linearly with `RiskPercent` (within 1 %) and `RiskPercent=0` is *rejected* rather than defaulted; the margin gate blocks with `XAU_BLK_MARGIN` for an unreachable `MinimumFreeMarginPercent` and for an absurd `MinimumFreeMarginMoney`, and opens when both are off; **the live configuration is fully restored afterwards** |
| averaging gates | clean plan passes; `TOO_SOON`, `ONE_PER_BAR`, `DUPLICATE_LEVEL`, `DISTANCE_TOO_SMALL` each fire on their own precondition and no other; BUY levels sit below and SELL levels above the reference; the two are symmetric |
| state machine | full precedence chain `EMERGENCY > ERROR > CLOSING > RISK_BLOCKED > PAUSED > SELFTEST > IN_CYCLE/WAITING_AVERAGING > WAITING_ENTRY/IDLE`; `XAU_INT_CLOSE` allowed in **every** state; entries/averaging refused under EMERGENCY; every one of the 34 block codes has a name (no `CODE_<n>` fallback) |
| Telegram sanitiser | `/status` queued; free text, shell metacharacters, non-whitelisted names and >64-character payloads rejected; argument tokenising; FIFO order; overlong argument rejected; confirmation arms, matches and disarms |

If any check fails, the log line says *"SELF TEST FAILURES: n of m checks failed -
do not trust this build"*, and the QA policy is: **a build that fails a self test
is not released**, whatever else it does.

## 8.3 Layer 3 - the MT5 protocol (tests A-V)

Setup that applies to all of them: a **demo** account, `XAUUSD` (or your broker's
suffix variant), `M1` chart, `RunSelfTestsOnInit=false`, `LogLevel=DEBUG`,
`EnableDebugTickLog=true`, `LogToFile=true`, and the log open next to the chart.
Every test has a *pass condition* that is observable in the log, the dashboard or
the state file - never "it looked fine".

| # | Test | How to run | Pass condition |
|---|---|---|---|
| A | Compile & install | fresh MetaEditor build of `XAU_AVG_PRO.mq5` | 0 errors, 0 warnings; `OnInit` logs `ready`, spec line and config line |
| B | Suffix tolerance | attach to `XAUUSDm`, `XAUUSD.a`, `GOLD`, `XAUUSDc` charts | the same symbol facts are read and printed; no hard-coded `XAUUSD` in the log; state/log file names differ per symbol+magic |
| C | Entry correctness | M15 tester, `EntryConfirmation=CLOSE_BAR` vs `NEW_BAR` | one signal -> one cycle; the cycle opens on the first tick of the next bar (CLOSE_BAR) or intra-bar (NEW_BAR); `TradingDirection=BUY_ONLY` never produces a SELL |
| D | Averaging geometry | `AveragingDistanceMode=FIXED`, `AveragingDistancePoints=350`, `MaximumLayer=6` | layers appear at 350/700/1050... points from `AveragingReference`; `AveragingReference=AVERAGE` behaves as documented in `docs/05` |
| E | Duplicate / runaway | force price to oscillate around one level (visual mode, or a tick-series replay) | exactly one fill per level; `DUPLICATE_LEVEL`, `ONE_PER_BAR`, `TOO_SOON` appear as the *reasons*, not a silent skip |
| F | Gap protection | replay a session containing an opening gap larger than `MaximumGapPoints` | entries blocked for `GapBlockDurationMinutes`, and the next layer too when `GapBlocksAveraging=true`; log shows the measured gap |
| G | Basket TP - money | `BasketTPMode=MONEY`, `EstimatedCommissionPerLot` set to the real value | the close happens at a *net* >= target; `RequireMinimumProfitMoney` respected; TP level moves when a layer is added |
| H | Basket TP - points / price / percent | switch modes with a basket open (or in separate runs) | POINTS/PRICE anchor on the average, MONEY/PERCENT are cost aware; `BasketTPSafetyBufferPoints` only pushes the level away |
| I | Cut loss + cooldown | `EnableBasketCutLoss=true`, small `BasketCutLossMoney` | close at the threshold (exit code 2), then no new cycle for `CooldownAfterCutLossSeconds`; a restart during the cooldown **keeps** it |
| J | Hard caps | `MaximumTotalLot=0.05` with a base lot of 0.03; `MaximumLayer=2` | no layer beyond the caps; `MAX_TOTAL_LOT` / `MAX_LAYER` are the logged reasons; with `TruncateLotToExposureHeadroom=true` the layer is shrunk instead |
| K | Margin safety | tiny balance (or `MinimumFreeMarginPercent=99`) | the EA refuses before sending (`OrderCheck`/`10019` never reached); `MARGIN` block, no retry storm |
| L | Account/cycle/floating/daily DD | set `MaximumAccountDrawdownPercent` so it triggers within minutes; try each `ActionOn*` | the configured action happens exactly once; `EMERGENCY` is never downgraded; the daily block lasts to the next server midnight; the *risk limit beats the entry signal* (a valid signal while blocked must not open) |
| M | Restart / reconnect recovery | open a basket, remove the EA, recompile, close the terminal, restart | after each event: same cycle id, same layer count, TP recomputed from the real positions; no duplicate open; `OnTradeTransaction` triggers an immediate reconcile |
| N | Netting account | run on a netting demo (or `AllowNettingAccounts` matrix) | behaviour per `docs/06.3`: reconstruction only in FIX mode, otherwise `NETTING_UNCERTAIN` with exits still armed; mixed BUY+SELL -> `XAU_ST_ERROR` |
| O | Manual / foreign trades | open a position manually on the same symbol, and run a second EA with another magic | the foreign position is never averaged, never closed, never counted; only `ManageCurrentSymbolOnly=false` extends closing to this EA's other symbols - never to foreign magics |
| P | Spread / volatility / session / weekend | widen `MaximumSpreadPoints` to below the live spread; set a 1-minute session; set the Friday stop before the current time | each filter blocks in turn with its own code; `CloseBasketBeforeFridayStop` flattens (exit 6); a full-day session window never blocks; `SessionBlocksAveraging` respected |
| Q | News filter | `EnableNewsFilter=true` around a scheduled high-impact USD event, and with no broker calendar data | entries (and averaging with `NewsBlocksAveraging`) blocked in the window; when the calendar is unavailable the `NewsFailSafePolicy` decides: `BLOCK` (default) refuses new risk, and it is logged - **no synthetic event data is ever invented** |
| R | Telegram round trip | `/status /start /stop /pause /resume /stats /report /help /version /ping`, then `/closeall` | every command replies; `/closeall` arms a confirmation and executes **only** after `/confirm_closeall` within 90 s; `/setlot 1e999`, `/shutdown_now`, `; rm -rf /` are all rejected; the token never appears in the log |
| S | Telegram overrides survive | `/settp money 50`, restart the chart | override restored, re-validated, `[CFG]` line present; `/resetparams` then reverts to the inputs after a reload |
| T | Execution failures | `MaxOrderRetries` with an off-hours market, a freeze-level TP and an unsupported filling type | transient retcodes retried within the limit; `10030 INVALID_FILL` triggers a fallback fill type; `10009` without a verifiable position -> `XAU_ST_ERROR`, never a re-send; `10036/10039` on close treated as already closed |
| U | Dashboard | `EnableDashboard=true`, then `false` | >= 18 rows including state, layers, volumes, average, TP, floating, daily P/L, limits, filters, news, Telegram; repaint throttled (no visible flicker at 1 s timer); objects are deleted on detach; nothing is drawn in a non-visual tester |
| V | **One layer per tick** | `AllowMultipleLayersPerTick=false` (default), a violent 3-level move in one tick/bar cluster | exactly one layer per pipeline pass. With the compound exception (`AllowMultipleLayersPerTick=true` **and** `OneLayerPerBar=false` **and** `MinimumSecondsBetweenAveraging=0`) up to 3; if the exception is only partly configured the engine logs the reason and stays at one |

## 8.4 Strategy Tester settings that make results meaningful

* `Every tick based on real ticks` for anything involving spread or gaps;
  `1 minute OHLC` is acceptable for entry logic only - it hides intra-bar
  spread/ordering effects that matter for averaging triggers.
* Model the commission (`EstimatedCommissionPerLot`) and enable swap, otherwise
  the cost-aware basket TP you are testing is not the one you will run.
* Never trust a tester run with `EnableTelegram`/`EnableNewsFilter` "passing":
  both self-disable there (`WebRequest`/calendar are unavailable) and the log says
  so. Test them on a demo chart.
* Run the same configuration across at least three volatility regimes (quiet
  range, trending, high-impact news week) - an averaging EA's tail risk lives in
  the third one.

## 8.5 Acceptance criteria mapping

| Requirement from the specification | Where it is proven |
|---|---|
| no TODO/FIXME/PLACEHOLDER, no pseudo-code | 8.1 (automated), `docs/13` |
| no hard-coded credentials, no token in logs | 8.1 pattern check, test R |
| state reconstructed from real positions/history | tests I, M, N, O + `docs/06.1` |
| verified `OrderSend` results | tests T, G + `docs/13.2` |
| hedging vs netting explicit | test N + `docs/06.3` |
| fail safe on restart/reconnect/errors/no margin/spread/gap/news/weekend/unavailable Telegram or calendar | tests F, I, K, L, M, P, Q, R, T |
| no several layers on one tick unless configured | test V + `docs/05.4` |
| risk limit beats profit opportunity | test L + `docs/04` preamble |
| Strategy Tester compatibility | 8.4 + `docs/11` |

---
Prev: [07 - Telegram control](07-telegram-command-spec.md) |
Next: [09 - Known risks and limitations](09-known-risks-and-limitations.md)
