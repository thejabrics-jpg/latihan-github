# 03 - State Machine

One object owns the answer to *"what is the EA allowed to do right now?"*:
`CStateMachine` (`MQL5/Include/XAU_AVG_PRO/State.mqh`, ~290 lines). No other
module sets a state; they only set **flags** (`SetEmergency`, `SetPaused`,
`SetRiskBlock`, `SetError`, `SetClosing`, `SetSelfTestHalt`) and the state is
**derived** from those flags plus the real positions on every pipeline pass.

That inversion is deliberate: a stored state can go stale, a derived state
cannot. Reconnecting after a weekend or restarting the terminal does not need
"state repair", because the state is recomputed from live facts each tick.

## 3.1 States

| # | State | Meaning |
|---|---|---|
| 0 | `XAU_ST_IDLE` | flat, no entry engine available (or `AllowNewCycles=false`) |
| 1 | `XAU_ST_WAITING_ENTRY` | flat, entry engine armed, waiting for a signal |
| 2 | `XAU_ST_IN_CYCLE` | basket open, level reached / being managed |
| 3 | `XAU_ST_WAITING_AVERAGING` | basket open, no level reached yet |
| 4 | `XAU_ST_RISK_BLOCKED` | a risk limit is active (blocking, not closing) |
| 5 | `XAU_ST_PAUSED` | operator pause (`/pause`, chart button, `StartPaused`) |
| 6 | `XAU_ST_EMERGENCY_STOP` | hard stop, only an explicit reset clears it |
| 7 | `XAU_ST_CLOSING` | a basket close is in progress |
| 8 | `XAU_ST_ERROR` | inconsistent state / bad config - trading refused |
| 9 | `XAU_ST_SELFTEST` | self tests ran with `HaltAfterSelfTests=true` |

## 3.2 Derivation priority

`Derive(basket_active, level_reached)` is evaluated top-down; the first true
row wins (`basket_active` comes from `CCycleManager::Reconcile()`, i.e. from
`PositionsTotal()` filtered by symbol + magic - never from a remembered flag):

```
EMERGENCY_STOP   <- cfg.emergency_stop            (restored from state file)
   ERROR         <- SetError(): hard config error, netting conflict,
                                   unverified fill, stale state after restart
   CLOSING       <- a close sequence is running
RISK_BLOCKED     <- CRiskManager wrote a block (SetRiskBlock)
   PAUSED        <- cfg.user_paused
SELFTEST         <- HaltAfterSelfTests
 IN_CYCLE / WAITING_AVERAGING  <- basket_active, split by level_reached
WAITING_ENTRY    <- flat && AllowNewCycles && EnableEMAEntry
   IDLE          <- flat, nothing to do
```

Every transition is logged once (`[STATE] RISK_BLOCKED -> PAUSED | ...`) with a
human-readable condition string from `DescribeCondition()`, plus transition and
rejected-attempt counters that `StatusReport()` exposes.

## 3.3 Gating table

`Allows(intent)` is the first gate on the two *opening* paths in the engine
(`TryOpenCycle`, `TryAverage`) - cheap, and it counts illegal attempts so a
wiring mistake becomes visible instead of silent:

| State | ENTRY | AVERAGING | CLOSE |
|---|---|---|---|
| IDLE | no | no | yes |
| WAITING_ENTRY | **yes** | no | yes |
| IN_CYCLE | no | **yes** | yes |
| WAITING_AVERAGING | no | **yes** | yes |
| RISK_BLOCKED | no | no | **yes** |
| PAUSED | no | no | **yes** |
| EMERGENCY_STOP | no | no | **yes** |
| CLOSING | no | no | **yes** |
| ERROR | no | no | **yes** |
| SELFTEST | no | no | **yes** |

**Closing is never blocked by any state.** That single rule is what makes the
EA safe under every failure mode in the specification: if the terminal, the
connection, Telegram, the calendar or a filter is broken, the EA may refuse to
open, but it must always be able to get out.

## 3.4 Block reasons

`ENUM_XAU_BLOCK` (34 codes) is the reason attached to a refusal; it is what the
dashboard's `LAST BLOCK` row, the throttled `[RISK]/[MAXDD]/[FILTER]` log lines
and the Telegram `/status` report show. The full list, in the order the risk
engine tests them:

`EMERGENCY`, `PAUSED`, `NEWCYCLES_OFF`, `EA_DISABLED`, `STATE_ERROR`,
`BASKET_OPEN`, `ACCOUNT_DD`, `CYCLE_DD`, `DAILY_LOSS`, `FLOATING_LOSS`,
`MARGIN`, `MAX_LAYER`, `MAX_LOT_ORDER`, `MAX_TOTAL_LOT`, `SPREAD`,
`VOLATILITY`, `GAP`, `SESSION`, `WEEKEND`, `OPEN_PROTECT`, `NEWS`,
`DAILY_ENTRIES`, `COOLDOWN`, `DIRECTION`, `SPEC_INVALID`, `NO_SIGNAL`,
`LEVEL_NOT_REACHED`, `ONE_PER_BAR`, `TOO_SOON`, `DUPLICATE_LEVEL`,
`DISTANCE_TOO_SMALL`, `NETTING_UNCERTAIN`, `EXEC_FAILED`, `NOT_CONNECTED`.

`BlockName()` maps each code to a stable string used as the throttling key, so
two different reasons for refusal never suppress each other's log lines. The self
test asserts that no code falls back to `CODE_<n>` - a renamed or added enum
member that nobody documented fails the test.

## 3.5 Cycle exit codes

Recorded in the cycle snapshot, persisted, and used by the statistics and the
daily report:

| Code | Name | Set by |
|---|---|---|
| 0 | open | - |
| 1 | basket take profit | `RunPipeline` step 9 |
| 2 | basket cut loss | `RunPipeline` step 9 |
| 3 | risk close | account / floating / daily limit with an action that closes |
| 4 | manual | Telegram `/closeall`, chart close, `/emergency` |
| 5 | external close | broker stop-out, manual intervention, another chart - detected by the open -> flat transition in `OnTick` |
| 6 | weekend flatten | `CloseBasketBeforeFridayStop` |

`OnTick()` detects the open -> flat transition **once** and calls
`OnCycleFinished()` exactly once, whether the EA closed the basket (it leaves a
"notice" with the exit code, reason and net P/L) or somebody else did (the
cycle's recorded exit code, or `5`). Cooldowns, statistics, notifications and
the state file update all hang off that one function, so no path can double-count
a closed cycle and no path can forget the cooldown.

## 3.6 Reset semantics

| Block | How it clears |
|---|---|
| `EMERGENCY` | `EmergencyResetMode=MANUAL`: `/emergency_clear` (Telegram) only. `NEXT_DAY`: automatically at the next server midnight, and `/emergency_clear` is *rejected by design* with the armed timestamp in the reply. |
| `DAILY_LOSS` | persists until the next server day, even if the loss is recouped - a daily stop is a stop, not a suggestion |
| other risk blocks | `AutoResetRiskBlock=true` and the metric must return inside the limit minus `RiskBlockResetHysteresisPercent`; otherwise manual restart or `/start` |
| `STATE_ERROR` | `ClearError()` after the cause is fixed (bad config, netting conflict). A restart re-derives it from the account, so it cannot be papered over |
| `COOLDOWN` | time-based (`CooldownAfterCutLossSeconds`), no override |
| `PAUSED` | `/start`, `/resume`, chart button |

Hysteresis exists because "block at 5.0 %, resume at 5.0 %" oscillates on a
noisy equity curve and produces exactly the churn an averaging basket cannot
afford.

---
Prev: [02 - Inputs](02-input-specification.md) | Next: [04 - Risk model](04-risk-model.md)
