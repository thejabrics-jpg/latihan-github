# 04 - Risk Model

`CRiskManager` (`MQL5/Include/XAU_AVG_PRO/Risk.mqh`, 589 lines) is the only
module that measures capital risk, and it contains **no `OrderSend` call at
all**: it fills an `SActionReq` and the engine executes it. That separation is
what makes the risk section auditable - one file, no side effects, pure
arithmetic over account data.

Order of precedence is fixed and is *not* configurable:

> **capital protection → deterministic behaviour → correct execution →
> observability → performance → optimisation.**
> A risk limit always beats a profit opportunity. There is no parameter that
> inverts this, by design.

## 4.1 Reference values (fed in from the engine)

| Value | Source | Why it is not read ad hoc |
|---|---|---|
| balance, equity | `AccountInfoDouble` each pass | - |
| `m_peak_equity` | persisted in the state file (`peak_equity`) | a restart must not "forget" the high-water mark, otherwise peak-referenced drawdown silently resets to 0 % |
| `m_day_start_balance`, `m_day_realized` | `CStatistics`, computed from **deal history** since server midnight | restart-proof by construction |
| cycle start balance | `CCycleManager::BalanceAtStart()`, persisted in the cycle snapshot | cycle drawdown must survive a restart too |

## 4.2 The four hard limits (evaluated in this order)

```
ref      = (DrawdownReference == PEAK_EQUITY) ? peak_equity : day_start_balance
account% = (ref - equity) / ref * 100                      >= MaximumAccountDrawdownPercent
daily    = max(0, -(realized_today [+ EA floating]))      >= MaximumDailyLossMoney
                                                          or day_start * MaximumDailyLossPercent/100
floating = -basket.NetPL()                                 >= MaximumFloatingLossMoney
cycle%   = -basket.NetPL() / cycle_start_balance * 100     >= MaximumCycleDrawdownPercent
```

Notes that matter in practice:

* **First hit wins as the reported reason**, but the *action* is the strongest
  of the hits (`CRiskManager::Strongest()`), and an `EMERGENCY` request is never downgraded by
  a milder limit that happened to be evaluated first.
* `DailyLossBasis`: `REALIZED` counts closed deals only;
  `REALIZED_PLUS_EA` also counts the EA's open basket, so a 5 % daily stop cannot
  be bypassed by holding a losing basket open across midnight.
* The daily block carries `until = next server midnight` and is *not* released
  early even if the loss is recouped (`ResetCheck` re-arms only on day roll).
* `MaximumDailyLossPercent` is measured against the **day start balance**, not
  current equity, so it does not shrink as you lose (which would be a martingale
  of limits rather than a cap).

## 4.3 Actions

| `ENUM_XAU_ACTION` | Effect in `Act()` | Basket closed? | New entries | Averaging |
|---|---|---|---|---|
| `XAU_ACT_BLOCK_ONLY` | risk block + reason + counters | no | blocked | blocked |
| `XAU_ACT_CLOSE_BASKET` | `need_close_basket` + block | yes, exit code 3 | blocked | blocked |
| `XAU_ACT_CLOSE_ALL` | `need_close_all` + block | yes + sweep of any EA position not tracked as a cycle | blocked | blocked |
| `XAU_ACT_EMERGENCY` | `need_emergency` + `need_close_all` | yes, then EMERGENCY_STOP | blocked until reset | blocked |

`CloseAll` never reaches beyond `symbol + MagicNumber`: positions opened
manually or by another EA are not managed by this EA under any circumstance
(spec §16, "ManageCurrentSymbolOnly"). `docs/09` states the consequence honestly:
if you *want* a global account flatten you must do it yourself or run a second
instance - the EA will not do it for you.

## 4.4 Gate chain for an opening intent

`CheckEntry` / `CheckAveraging` share `CommonGates` and then apply their own
structure checks. The first failing check is returned with its code, a
human-readable reason, an optional `block_until` and the offending `value` - all
of which surface on the dashboard, in `/status` and in the throttled log.

```
CommonGates:  EMERGENCY -> STATE_ERROR -> PAUSED -> risk block -> spec valid
              -> quote age <= MaxQuoteAgeSeconds -> connected (optional)
              -> symbol+account allow trading (terminal, market, algo allowed)
CheckEntry:   AllowNewCycles -> no basket already open -> no reconciliation
              conflict -> BuyEnabled/SellEnabled -> TradingDirection
              -> cooldown -> MaximumEntriesPerDay -> hard-limit hits
              -> lot sizing (CLotManager) -> margin projection (CLotManager)
              -> market filters -> news blackout
CheckAveraging: EnableAveraging -> basket active -> basket not uncertain
              -> MaximumLayer -> hard-limit hits -> averaging timing gates
              (level reached, duplicate level, one-per-bar, min seconds)
              -> lot sizing -> margin projection -> filters -> news
```

Averaging is deliberately **not** gated by the session filter in the same way an
entry is: if a basket is open and a level is reached, refusing to average while
the basket stays exposed would be the worst possible behaviour. Instead the
session/weekend filters drive `CloseBasketBeforeFridayStop`, and the news filter's
"no new averaging" window is applied *before* the layer is added, never after.
Both decisions are explained in `docs/09-known-risks-and-limitations.md`.

## 4.5 Structural caps (hard, never overridden)

| Cap | Enforced in | Behaviour |
|---|---|---|
| `MaximumLayer` | `CheckAveraging` | the basket stops growing, TP/cut loss still manage it |
| `MaximumLotPerOrder` | `CLotManager::Resolve` | clamps **every** lot mode, including FIX and a multiplier that would exceed it |
| `MaximumTotalLot` | `CLotManager::Resolve` | reject, or shrink to the headroom when `TruncateLotToExposureHeadroom=true` (never grows the request) |
| broker `VolumeMin/Max/Step` | `CSymbolSpec::NormalizeVolume` | floor to the step; below the minimum -> reject (with an optional logged fallback to the minimum lot, never a silent raise) |
| `MinimumFreeMarginPercent` / `Money` | `CLotManager::CheckMargin` via `OrderCheck`/`OrderCalcMargin` | projected free margin after the fill must stay above the limit |
| stops/freeze level | `CSymbolSpec` | any TP/SL distance below the broker minimum is widened and logged |
| `MaximumSpreadPoints` | `CMarketFilters` | refuse new risk; never force a close |
| `MinimumATRPoints` / `MaximumATRPoints` | `CMarketFilters` | volatility out of band -> refuse new risk |
| `MaximumGapPoints` (+`GapLookbackBars`) | `CMarketFilters` | a measured gap blocks for `GapBlockDurationMinutes` |
| `ProtectionMinutes` after `OpenMarketReference` | `CMarketFilters` | no new risk right after the market opens |

## 4.6 Reset and hysteresis

`ResetCheck()` runs from `OnTimer` while a block is active:

```
if block has an 'until' and now < until      -> keep
if code == DAILY_LOSS                        -> keep until the day rolls over
if not AutoResetRiskBlock                    -> keep (manual)
else measure again:  clear only when the metric is inside
                     limit * (1 - RiskBlockResetHysteresisPercent/100)
```

`RiskBlockResetHysteresisPercent` is a **recovery fraction**, not an offset
(default `80`): the block clears only when the metric is back inside
`limit x 0.80`, i.e. for `MaximumAccountDrawdownPercent = 20` the block releases
at 16 % or better, never at 19.9 %. The value is clamped to 10..100 in
`ValidateConfig()`; `100` means "only when the metric is fully back inside the
limit". Without such a band the EA alternates block/unblock on every tick around
the threshold and can start a fresh cycle straight into the same falling market.

## 4.7 Worked example (defaults, 10 000 account, 0.01 base lot)

| Step | Value |
|---|---|
| entry BUY 0.01 @ 2350.00 | risk basis: cycle start balance 10 000 |
| layers 2-6 at 350 pts, multiplier 1.5 | volumes 0.01/0.01/0.02/0.03/0.05 (floored), total 0.12 |
| average price | 2341.25 |
| basket at -1000 pts from entry | floating ≈ -236 (see `docs/12`) |
| `MaximumFloatingLossMoney = 350` | not yet hit; block/close per `ActionOnFloatingLoss` |
| basket at the cut-loss price 2318.87 | ≈ -351 → cut loss closes, exit code 2, cooldown starts |
| account drawdown at that point | ≈ 3.6 % of 10 000 → `MaximumAccountDrawdownPercent = 15` untouched |
| if the same depth happened at 0.20 base lot | loss × 20 → both the floating and account limits fire *before* the basket finishes growing |

Reproduce any variant with `python3 tools/stress_model.py` (§4.8) - the tables in
`docs/12-stress-test-report.md` are generated by exactly that tool.

## 4.8 What the model does *not* claim

* It does not model slippage, requotes, partial fills or spread widening during
  a fast move - all of which make a real loss larger than the modelled one.
* It does not predict the probability of hitting a limit. No number in this
  project is a profitability claim.
* It cannot protect against a broker-side event it cannot see (a stop-out
  executed by the server, a negative balance, a symbol rename). Fail-safe
  behaviour on those events is: stop opening, log, reconcile from the account.

---
Prev: [03 - State machine](03-state-machine.md) | Next: [05 - Averaging algorithm](05-averaging-algorithm.md)
