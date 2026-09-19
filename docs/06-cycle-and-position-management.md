# 06 - Cycle and Position Management

A **cycle** is one basket: the initial entry plus every averaging layer, from
the first verified fill to the moment the EA's positions on this symbol are
gone. `CCycleManager` (`Cycle.mqh`, 667 lines) owns its identity and history;
`CBasketManager` (`Basket.mqh`, 501 lines) owns the arithmetic on top of it.

## 6.1 Truth comes from the account, never from memory

`Reconcile()` is called at the start of every pipeline pass, after every
executed order, from `OnTradeTransaction`, and from `OnInit`. It enumerates
`PositionsTotal()`, keeps only positions whose `POSITION_SYMBOL == the chart
symbol (as resolved by CSymbolSpec)` **and** `POSITION_MAGIC == MagicNumber`,
sorts them by open time and rebuilds the layer list. Consequences:

* **Restart / reconnect / recompile:** the EA resumes an existing basket because
  it re-derives it from the positions, not because it remembered them. Layer
  count, volumes, prices and open times come from the broker.
* **Manual intervention:** if you close one layer by hand, the next reconcile
  simply has one layer fewer. The cycle id is preserved, the average and TP move
  accordingly, and the log records the disappearance of the ticket.
* **Broker stop-out / full external close:** the open -> flat transition is seen
  in `OnTick`, `OnCycleFinished(5, "external close", ...)` runs once, the
  cooldown starts and the daily statistics are updated.
* **Foreign positions are invisible on purpose.** There is no configuration
  that makes this EA manage a trade it did not open (`ManageCurrentSymbolOnly`
  plus the magic filter). This protects you from another EA's or your own manual
  positions being averaged into the basket.

## 6.2 Cycle identity and persisted state

`BeginCycle()` assigns `cycle_id` (monotonic, persisted), direction, start
balance (for the cycle-drawdown reference), start time and the first ticket.
`MarkClosed(exit_code, realized_pl)` finalises the record and is the only place
`exit_code` is written. Persisted keys in the state file (`.tmp` + atomic
`FileMove`) include the cycle id, start balance/time, next level, distance, exit
code, max cycle drawdown, plus the operator flags (`emergency_stop`,
`user_paused`, override bit mask, `peak_equity`, `emg_day`).

If the state file is missing or older than the terminal's session, the EA
continues from the account and logs that the *cycle counters* (not the P/L) are
reconstructed - `docs/09` quantifies what that costs: a cycle started long ago
may be re-adopted with `BalanceAtStart()` equal to the *current* balance, which
makes `MaximumCycleDrawdownPercent` read the loss of this session rather than the
whole cycle.

## 6.3 Adoption rules for an untracked basket

| Situation | Behaviour |
|---|---|
| hedging account, positions with our magic, no state file | adopt as a cycle; layers = the real positions (this is exact, so no uncertainty) |
| netting account, `LotMode=FIX`, `AllowNettingLayerReconstruction=true` | reconstruct the layer count from the aggregate volume divided by `InitialLot` |
| netting account, otherwise | **adopt as 1 uncertain layer**: TP/cut loss/risk closing all work; averaging is blocked (`XAU_BLK_NETTING_UNCERTAIN`) |
| netting account, `AllowStateAdoptionOnNetting=false` | refuse management, log an explicit instruction (it is a config decision, not a bug) |
| BUY **and** SELL for our magic on a netting account | `XAU_ST_ERROR`, trading refused, positions left alone |

Uncertainty is only ever a reason to *stop adding risk*. It is never a reason to
stop managing the exit, because leaving a basket unmanaged is strictly worse than
managing it with conservative assumptions.

## 6.4 Basket arithmetic

```
total_volume  = SUM(layer volume)                      (unique tickets only)
avg_price     = SUM(price x volume) / SUM(volume)      (weighted, direction aware)
gross_pl      = SUM(POSITION_PROFIT)  per unique ticket
swap          = SUM(POSITION_SWAP)    per unique ticket
commission    = 2 x EstimatedCommissionPerLot x total_volume     (round turn)
net_pl        = gross_pl + (AccountForSwapInTP ? swap : 0) - commission
money_per_point = SYMBOL_TRADE_TICK_VALUE / SYMBOL_TRADE_TICK_SIZE x point x total_volume
break_even    = avg_price pushed by the cost of closing          (BreakEvenPrice)
```

`Recompute()` dedupes tickets deliberately: on a netting account several layer
records share one ticket, and summing `POSITION_PROFIT` once per record would
multiply the P/L by the number of layers - a wrong basket P/L is the fastest way
to a wrong TP.

## 6.5 Take profit

| Mode | Level | Notes |
|---|---|---|
| `XAU_TP_POINTS` | `avg ± BasketTakeProfitPoints x point` | measured from the average, not from the entry |
| `XAU_TP_PRICE` | `avg ± BasketTakeProfitPrice` (price units) | the "I want $3.50 above my average" form |
| `XAU_TP_MONEY` | cost-aware: `close_ref + (target - net_pl)/money_per_point x point` | the TP moves as the basket accrues swap/commission so that the *net* figure hits the target |
| `XAU_TP_PERCENT` | same formula with `target = BasketTakeProfitPercent% of cost basis` | cost basis = avg x contract x volume |
| `XAU_TP_NONE` | no basket TP | the daily/account limits are then the only exits - `ValidateConfig()` warns loudly |

Trigger test uses the correct side (`Bid >= tp` for BUY, `Ask <= tp` for SELL), so
the spread cannot "hit" a TP that is not actually reachable. Three further rules
apply:

* `AccountForSpreadInTP` anchors the level on the price the close would use.
* `BasketTPSafetyBufferPoints` only ever pushes the level **away** from the
  market (a buffer that helped you reach the TP faster would be a lie).
* `RequireMinimumProfitMoney` refuses a "profit" close that is smaller than the
  floor, so a basket that would net 0.40 after costs is not counted as a win.
* The TP is refreshed every pass because the average moves when a layer is added,
  and because swap accrues while you wait.

Basket TPs are realised by closing all layers (`CloseAllLayers`), not by placing
a broker `TP` on each position: with averaging, a per-position TP would take
profit on the old layers while the newest layer is still deeply underwater, which
is not the strategy the user configured. `CloseBasketOnTP` therefore always
closes the *basket*.

## 6.6 Cut loss

`CheckCutLoss(SVerdict &v)` fires on `BasketCutLossMoney`, `BasketCutLossPercentOfBalance`
or `BasketCutLossPoints` (from the average), combined by `CutLossMode`:

| `CutLossMode` | Meaning |
|---|---|
| `XAU_CUT_ANY` (default) | the first threshold reached fires |
| `XAU_CUT_MONEY_ONLY` / `PERCENT_ONLY` / `POINTS_ONLY` | only that metric can fire |

When it fires, `CloseAllLayers(2, "basket cut loss")` runs in the order set by
`CutLossCloseOrder` (`XAU_CLOSE_YOUNGEST_FIRST` default, `XAU_CLOSE_OLDEST_FIRST`,
`XAU_CLOSE_LARGEST_FIRST`).
Youngest-first is the useful default for an averaging basket: if the broker
rejects part of a close (limit prices, freeze levels, market micro-structure),
the loss-generating *recent* layers are gone first. After any cut loss:

* `CooldownAfterCutLossSeconds` blocks new entries *and* new cycles, and
  `g_rt.block_until` carries the deadline into the state file so a restart does
  not skip the cooldown;
* the day's realized P/L and the cut-loss counter move (statistics read
  the same history the broker shows);
* if the same event also breached a hard limit, `CRiskManager` still holds its
  own block - a cooldown never overrides a risk block.

## 6.7 Closing, and what "closed" means

`CloseAllLayers(exit_code, reason)` (`Basket.mqh`) owns the sweep:

1. `MarkClosing(exit_code)` puts the cycle into the closing phase (state
   `XAU_ST_CLOSING` via the engine), so nothing can open while we are getting out;
2. the layer order is decided by `CutLossCloseOrder`: youngest first (the
   default - reverse of the ascending-by-time list), oldest first, or largest
   volume first; the sort is an insertion sort over the layer index array so the
   layer records themselves are never reordered;
3. per layer: `m_exec.Close(ticket, r)` builds a close request for that exact
   ticket with the symbol's allowed filling policy; success requires an accepted
   retcode **and** the ticket no longer being present;
4. on a netting account there is one ticket for the whole basket, so the close is
   issued by volume (the loop closes the aggregate position and skips the
   remaining layer records) - the log line says `netting close`;
5. `m_close_failures` counts every rejected close; a rejection never aborts the
   sweep, the remaining tickets are still attempted;
6. `int left = m_cycle.PositionCount()` after the loop is the only thing that
   decides success. `left == 0` -> `MarkClosed(exit_code, net_pl)` and the cycle is
   finished. `left > 0` -> the function returns `left`, `XAU_ST_CLOSING` stays set,
   the engine logs it and retries on the next pass.

Two rules follow from that structure and are the reason it is written this way:

* **the EA never reports a flatten it has not observed** - a `10009 DONE` on the
  last order is not proof, the empty position list is;
* **a cycle is never marked finished on partial success**, so a partially closed
  basket cannot lose its cooldown, its drawdown record or its statistics entry.

`CloseDirection(type)` (Telegram `/closebuy`, `/closesell`) and `CloseEverything()`
(`/closeall`) are the operator variants: they filter strictly by `POSITION_MAGIC`
(and by symbol when `ManageCurrentSymbolOnly=true`), return the number of
positions closed, and are followed by `Reconcile() + Recompute()` so the state
file reflects the new reality immediately.

## 6.8 What the EA does not do to your positions

The EA never places a broker-side stop loss or take profit on an individual
layer, and there is no input that enables one. That is a deliberate design
decision with a stated cost, not an oversight:

* per-layer stops would be triggered by exactly the volatility that averaging is
  built to survive - the basket would be dismantled layer by layer at the worst
  prices, which is the failure mode of this class of strategy;
* the exits are therefore basket-level (`docs/05`, `docs/06.5/6.6`) and are
  evaluated inside the EA;
* the cost is that **if the terminal is off or disconnected, nothing is managing
  the basket** - there is no disaster stop resting at the broker. `docs/09` lists
  this as the most important operational limitation, together with the
  mitigations (run it where it cannot stop: VPS or a logged-in desktop; keep
  `MaximumCycleDrawdownPercent`/`MaximumFloatingLossMoney` small enough that the
  loss between "market moves" and "EA reacts" is survivable; use
  `EnableWeekendProtection` and `CloseBasketBeforeFridayStop` if you hold through
  low-liquidity hours).

`InitialStopDistancePoints` is *not* an order field: it is the assumed stop
distance used by AUTO LOT sizing to convert `RiskPercent` into a volume.

---
Prev: [05 - Averaging algorithm](05-averaging-algorithm.md) |
Next: [07 - Telegram control](07-telegram-command-spec.md)
