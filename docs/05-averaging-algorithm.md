# 05 - Averaging Algorithm

`CAveragingEngine` (`Averaging.mqh`, 283 lines) answers exactly one question per
pipeline pass: *"may a further layer be added now, and at what price was it
supposed to trigger?"* It never decides whether the account can afford it
(`CRiskManager`) and never computes the volume (`CLotManager`).

## 5.1 Distance

```
FIXED  : distance_points = AveragingDistancePoints
ATR    : distance_points = clamp( ATR(ATRTimeframe, ATRPeriod) / point * ATRMultiplier,
                                  MinimumAveragingDistancePoints,
                                  MaximumAveragingDistancePoints )
then   : distance_points = max(distance_points, MinimumSafeDistancePoints())
```

`MinimumSafeDistancePoints()` is not a preference, it is arithmetic about what
the quote structure allows:

```
min_safe = max( spread_points * MinimumDistanceSpreadMultiple,   default multiple 2.0
                broker stops level in points )   and at least 1 point
```

Averaging into a level that is closer than the spread is a guaranteed loss per
layer, so a plan below `min_safe` is **refused** (`XAU_BLK_DISTANCE_TOO_SMALL`)
rather than silently widened. `Refresh()` recomputes ATR once per new bar;
`AllowIntraBarATRRefresh` allows an in-bar update (useful for very long bars, but it
makes the level of an in-progress bar move under the trader - it is off by
default and the reason is documented in `docs/09`).

## 5.2 Level geometry (direction aware, never hard-coded prices)

```
reference = AveragingReferencePrice()      LAST_LAYER (default) | AVERAGE | FIRST
level     = is_buy ? reference - distance*point : reference + distance*point
level     = NormalizePrice(level)
market    = is_buy ? Bid : Ask            (the price the close would happen at)
reached   = is_buy ? market <= level : market >= level
```

`AveragingReference` is a real behavioural choice, not cosmetics:

| Mode | Reference | Consequence |
|---|---|---|
| `LAST_LAYER` (default) | last filled layer's price | constant spacing, layers stay a fixed distance apart; the sequence is predictable in a backtest |
| `AVERAGE` | weighted average price | each new layer pulls the average toward the market, so spacing *shrinks* geometrically - more aggressive, easier to end at a small profit but with much bigger total volume |
| `FIRST` | first entry price | all layers pile at the same distance from the original entry - only sensible with `MaximumLayer` small |

## 5.3 The four runaway guards

Every one of them is tested in `CheckTiming()` **before** an order is sent, and
each is a separate block code so the log says which one stopped you:

| Guard | Code | Rule |
|---|---|---|
| distance too small | `DISTANCE_TOO_SMALL` | `distance < min_safe` (spread x multiple or the broker stop level) |
| one per bar | `ONE_PER_BAR` | `rt.last_avg_open_bar == bar_time` and `OneLayerPerBar=true` |
| minimum interval | `TOO_SOON` | `now < rt.next_avg_allowed_at` (`MinimumSecondsBetweenAveraging`) |
| duplicate level | `DUPLICATE_LEVEL` | the candidate level is within `0.9 x distance` of the level that already produced a fill |

The duplicate-level rule is what makes a *re-entrant* basket safe: price hovering
around a level must not turn one trigger into five fills. The window is relative
to the current distance instead of absolute points, so it behaves the same at
350 points and at 3500.

**Order of recording matters and is enforced in the engine**: `NoteLayerOpened()`
is called *only after a verified fill* (`SExecResult.verified`). A rejected or
timed-out order must not move the geometry, otherwise a failed send could
"consume" the level and leave the basket one layer short of what the trader
configured - or, worse, mark a bar as used while nothing was opened.

`NoteLayerOpened()` also baselines the entry itself: `TryOpenCycle()` calls it
with level `0.0` right after the opening fill, so the first averaging layer can
never land on the same bar as the entry and the minimum-interval clock starts at
the entry, not at the first level.

## 5.4 Gap protection

A gap (or a fast spike) can jump over several levels at once. Three rules bound
what the EA then does:

1. `OneLayerPerBar` (default `true`) - a single bar, however violent, adds at
   most one layer. This is the difference between "the EA averaged 1 time into a
   15-minute flash" and "the EA averaged 5 times into it".
2. `MinimumSecondsBetweenAveraging` (default 60 s) - even across bars.
3. `MaximumLayer` and `MaximumTotalLot` - the sequence is finite, so the worst
   case is bounded by arithmetic, not by luck (see `docs/12`).
4. one layer per pipeline pass. `AllowMultipleLayersPerTick=true` raises the
   cap to three per pass, but it is only honoured when `OneLayerPerBar=false`
   **and** `MinimumSecondsBetweenAveraging=0` as well; otherwise the engine logs
   the reason and stops at one. A mistyped single input cannot produce a
   multi-layer burst (test V in `docs/08-testing-strategy.md`).

`CMarketFilters` covers the other direction: the largest hole over
`GapLookbackBars` bars is measured, and a gap above `MaximumGapPoints` blocks new
entries for `GapBlockDurationMinutes` (and the next layer too when
`GapBlocksAveraging=true`, which is the default) because the averaging geometry
was computed against prices that no longer exist. Both directions are logged with
the measured gap in points.

## 5.5 Interaction with netting accounts

On a netting account the broker keeps one position per symbol, so "layers" are
not observable as separate positions. `CCycleManager` therefore:

* counts volume steps as layers when `AllowNettingLayerReconstruction=true` and
  `LotMode=FIX` (only then is volume an unambiguous layer counter);
* otherwise marks the basket **uncertain** (`IsUncertain()`), and
  `BuildPlan()` refuses to average (`NETTING_UNCERTAIN`) while still computing
  the basket TP - closing is never blocked, only adding is.
* if the broker reports both BUY and SELL positions for the EA's magic on a
  netting account (impossible state), the EA enters `XAU_ST_ERROR` instead of
  guessing.

This is stated as a limitation rather than faked (`docs/09`), because a wrong
layer count on a netting account is exactly the kind of silent error that turns a
controlled basket into an uncontrolled one.

## 5.6 What averaging never does

* never opens more than one layer per pipeline pass unless the operator explicitly
  configured the compound exception described above;
* never widens a distance to make a layer legal;
* never averages when the basket is uncertain, when a hard limit already fired,
  or during a news blackout (`MinutesBeforeNews` / `MinutesAfterNews`, with `NewsBlocksAveraging=true`);
* never uses `MinimumSecondsBetweenAveraging = 0` implicitly - `0` means "the
  operator asked for no interval", and `OneLayerPerBar` remains the backstop;
* never re-sends an unverified order (`SExecResult.unverified` -> `ERROR`).

---
Prev: [04 - Risk model](04-risk-model.md) | Next: [06 - Cycle & position management](06-cycle-and-position-management.md)
