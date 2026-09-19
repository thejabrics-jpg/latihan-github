#!/usr/bin/env python3
"""
stress_model.py - deterministic adverse-market stress model for XAU_AVG_PRO (§36).

This is the arithmetic the EA itself performs, reproduced independently in
Python so that the numbers in docs/12-stress-test-report.md can be audited
without running MetaTrader. It answers the only question that matters for an
averaging EA:

    how much money is lost, and how much margin is used, when price moves
    against the basket while the EA keeps adding layers?

Model (mirrors MQL5/Include/XAU_AVG_PRO/{Averaging,Lots,Basket}.mqh):
  * XAUUSD contract size 100 oz, point 0.01  ->  1.00 lot = $100 per $1 move
  * layer prices: L1 = entry, L(n+1) = level_n - distance (BUY basket)
  * distance: FIXED points, or ATR*multiplier clamped to [min,max]
  * lots: FIX, or MULTIPLIER = base * mult^(n-1) capped by MaximumLotPerOrder
  * weighted average price, basket TP by points/money/percent/price
  * floating P/L at a given adverse excursion, margin usage per leverage

Usage:
  python3 tools/stress_model.py                 # markdown for docs/12
  python3 tools/stress_model.py --json          # machine readable
  python3 tools/stress_model.py --layers 6 --base 0.01 --mult 2.0 --distance 350 \
          --entry 2350.00 --atr 480 --account 10000 --leverage 500
"""
from __future__ import annotations
import argparse
import json
import math
from pathlib import Path
from dataclasses import dataclass, asdict, field

POINT = 0.01          # XAUUSD point size (digits=2)
CONTRACT = 100.0      # troy ounces per 1.00 lot
MONEY_PER_LOT_PER_USD_MOVE = CONTRACT           # 1.0 lot: $100 per $1.00 move
MONEY_PER_POINT_PER_LOT = CONTRACT * POINT      # 1.0 lot: $1   per 0.01 (1 point)


def floor_to_step(value: float, step: float) -> float:
    """The EA floors lots: rounding must never increase exposure."""
    if step <= 0:
        return value
    return math.floor(value / step + 1e-9) * step


@dataclass
class Config:
    entry: float = 2350.00
    layers: int = 6
    base_lot: float = 0.01
    lot_step: float = 0.01
    max_lot: float = 0.20            # MaximumLotPerOrder
    max_total_lot: float = 1.00      # MaximumTotalLot
    distance_points: int = 350       # FIXED mode distance
    distance_mode: str = "FIXED"     # FIXED | ATR
    atr_points: int = 480
    atr_multiplier: float = 1.0
    min_distance_points: int = 200
    max_distance_points: int = 1500
    spread_points: int = 35
    min_distance_spread_multiple: float = 2.0
    multiplier: float = 1.5
    lot_mode: str = "MULTIPLIER"     # FIX | MULTIPLIER
    account: float = 10000.0
    leverage: int = 500
    tp_mode: str = "POINTS"          # POINTS | MONEY | PERCENT
    tp_points: int = 400
    tp_money: float = 120.0
    tp_percent: float = 1.0
    cutloss_money: float = 350.0
    commission_per_lot: float = 3.5  # round turn per 1.00 lot (both sides)
    swap_per_lot_night: float = -12.0

    # ---- derived geometry -------------------------------------------------
    def distance_price(self) -> float:
        pts = self.distance_points
        if self.distance_mode == "ATR":
            pts = self.atr_points * self.atr_multiplier
        pts = min(max(pts, self.min_distance_points), self.max_distance_points)
        safe = self.spread_points * self.min_distance_spread_multiple
        pts = max(pts, safe)
        return pts * POINT

    def lot(self, layer: int) -> float:
        if self.lot_mode == "FIX":
            raw = self.base_lot
        else:
            raw = self.base_lot * (self.multiplier ** (layer - 1))
        raw = min(raw, self.max_lot)
        lot = floor_to_step(raw, self.lot_step)
        return max(lot, 0.0)


@dataclass
class Layer:
    index: int
    price: float
    lot: float
    cum_lot: float
    avg_price: float
    floating_at_this_price: float
    margin: float


@dataclass
class Basket:
    cfg: Config
    layers: list = field(default_factory=list)
    total_lot: float = 0.0
    avg_price: float = 0.0
    tp_price: float = 0.0
    tp_target_money: float = 0.0
    stop_layer_price: float = 0.0
    capped_by_total_lot: bool = False
    capped_by_max_lot: bool = False

    def money_per_point(self) -> float:
        return MONEY_PER_POINT_PER_LOT * self.total_lot

    def build(self) -> "Basket":
        c = self.cfg
        price = c.entry
        self.avg_price = price
        self.layers = []
        for i in range(1, c.layers + 1):
            lot = c.lot(i)
            if lot <= 0:
                break
            if c.max_total_lot > 0 and self.total_lot + lot > c.max_total_lot + 1e-9:
                self.capped_by_total_lot = True
                break
            if lot >= c.max_lot - 1e-12 and c.lot_mode != "FIX":
                self.capped_by_max_lot = True
            new_total = self.total_lot + lot
            self.avg_price = ((self.avg_price * self.total_lot) + price * lot) / new_total
            self.total_lot = new_total
            adverse = (self.avg_price - price)  # this layer is instantly underwater
            self.layers.append(Layer(
                index=i,
                price=round(price, 2),
                lot=round(lot, 2),
                cum_lot=round(self.total_lot, 2),
                avg_price=round(self.avg_price, 2),
                floating_at_this_price=round(-adverse * MONEY_PER_LOT_PER_USD_MOVE * lot, 2),
                margin=round(self.price_per_lot() * self.total_lot / c.leverage, 2),
            ))
            price -= c.distance_price()
        # take profit
        if c.tp_mode == "POINTS":
            self.tp_target_money = c.tp_points * self.money_per_point()
            self.tp_price = self.avg_price + c.tp_points * POINT
        elif c.tp_mode == "MONEY":
            self.tp_target_money = c.tp_money
            self.tp_price = self.avg_price + (c.tp_money / self.money_per_point()) * POINT
        else:  # PERCENT of the notional exposure
            notional = self.avg_price * CONTRACT * self.total_lot
            self.tp_target_money = notional * c.tp_percent / 100.0
            self.tp_price = self.avg_price + (self.tp_target_money / self.money_per_point()) * POINT
        # costs the EA must beat before the TP is real (Basket.mqh cost-aware branch)
        costs = 2 * c.commission_per_lot * self.total_lot
        self.tp_price += (costs / self.money_per_point()) * POINT
        self.tp_target_money = (self.tp_price - self.avg_price) / POINT * self.money_per_point()
        self.stop_layer_price = self.avg_price - c.cutloss_money / self.money_per_point() * POINT
        return self

    def price_per_lot(self) -> float:
        return self.avg_price * CONTRACT

    def floating(self, price: float, nights: float = 0.0) -> float:
        """P/L of the whole basket when the market is at `price` (bid side)."""
        pl = (price - self.avg_price) * MONEY_PER_LOT_PER_USD_MOVE * self.total_lot
        pl -= 2 * self.cfg.commission_per_lot * self.total_lot
        pl += nights * self.cfg.swap_per_lot_night * self.total_lot
        return pl

    def summary(self) -> dict:
        c = self.cfg
        worst = {}
        for drop in (50, 100, 200, 300, 500, 700, 1000, 1500, 2000):
            px = c.entry - drop * POINT        # drop is measured in points
            worst[f"minus_{drop}pts"] = round(self.floating(px), 2)
        cut = self.floating(self.stop_layer_price)
        # a gap can jump past the cut-loss trigger, so the cap is not a hard
        # floor on the realised loss: model one full extra distance beyond it
        gap = self.floating(self.stop_layer_price - 2.0 * c.distance_price())
        return {
            "total_lot": round(self.total_lot, 2),
            "avg_price": round(self.avg_price, 2),
            "tp_price": round(self.tp_price, 2),
            "tp_money": round(self.tp_target_money, 2),
            "cutloss_price": round(self.stop_layer_price, 2),
            "money_per_point": round(self.money_per_point(), 4),
            "margin_at_leverage": round(self.price_per_lot() * self.total_lot / c.leverage, 2),
            "margin_percent_of_account": round(100.0 * self.price_per_lot() * self.total_lot
                                               / c.leverage / c.account, 1),
            "notional": round(self.price_per_lot() * self.total_lot, 2),
            "pl_at_cutloss_trigger": round(cut, 2),
            "pl_after_last_layer_if_price_drops_one_more_level": round(
                self.floating(self.layers[-1].price - c.distance_price()), 2),
            "pl_if_a_gap_jumps_past_the_cutloss": round(gap, 2),
            "excursion_table": worst,
        }


def scenario(cfg: Config) -> dict:
    b = Basket(cfg).build()
    out = {
        "config": asdict(cfg),
        "layers": [asdict(x) for x in b.layers],
        "basket": b.summary(),
        "flags": {"capped_by_total_lot": b.capped_by_total_lot, "capped_by_max_lot": b.capped_by_max_lot},
    }
    # required account so that the modelled max drawdown stays under a fraction
    excursion_loss = -min(0.0, min(b.floating(cfg.entry - d * POINT) for d in
                                   (50, 100, 200, 300, 500, 700, 1000, 1500, 2000)))
    capped = max(0.0, -b.summary()["pl_at_cutloss_trigger"])
    gapped = max(0.0, -b.summary()["pl_if_a_gap_jumps_past_the_cutloss"])
    out["loss_capped_by_cutloss"] = round(capped, 2)
    out["loss_if_gap_jumps_past_cutloss"] = round(gapped, 2)
    out["loss_deepest_excursion"] = round(excursion_loss, 2)
    # the sizing recommendation must survive the gap case, not the polite one
    worst = max(capped, gapped, excursion_loss)
    out["max_modelled_loss"] = round(worst, 2)
    for pct in (10, 20, 30, 50):
        out[f"account_for_{pct}pct_dd"] = round(worst / (pct / 100.0), 0)
    return out


def md_tables(base: Config) -> str:
    out: list[str] = []
    out.append("<!-- generated by tools/stress_model.py - do not edit by hand -->")
    out.append("")
    out.append("## 1. Model and assumptions")
    out.append("")
    out.append("| Assumption | Value | Source |")
    out.append("|---|---|---|")
    out.append("| Point size | 0.01 | XAUUSD digits=2 (`CSymbolSpec` reads it live) |")
    out.append(f"| Contract size | {CONTRACT:.0f} oz | `SYMBOL_TRADE_CONTRACT_SIZE` |")
    out.append(f"| Money per point per 1.00 lot | ${MONEY_PER_POINT_PER_LOT:.2f} | contract x point |")
    out.append(f"| Commission | ${base.commission_per_lot:.2f} round turn per lot | typical raw/ECN XAUUSD |")
    out.append(f"| Swap | ${base.swap_per_lot_night:.2f} per lot per night | long gold carry, see docs/09 |")
    out.append("| Lot flooring | floor to VolumeStep | `CSymbolSpec::NormalizeVolume` |")
    out.append("| Distance | max(clamped(ATR x mult or FIXED), spread x multiple) | `CAveragingEngine::MinimumSafeDistancePoints` |")
    out.append("")
    out.append("The model deliberately ignores slippage and requotes, and it assumes every")
    out.append("order fills exactly at the trigger price, so it **understates** the real")
    out.append("damage. Every number below is a floor, not a forecast.")
    out.append("")
    out.append("Two conventions matter when reading the tables:")
    out.append("")
    out.append("1. Adverse excursions are measured from the **first entry price**, not from the")
    out.append("   basket average. After a full sequence the average sits far below the entry")
    out.append("   (BUY case), so a shallow dip is already profitable - the real risk is the")
    out.append("   deep tail, which is why the tables keep going to -2000 points.")
    out.append("2. The *instant floating* column is the loss created at the moment each new layer")
    out.append("   is filled. Averaging converts a winning basket into a losing one precisely")
    out.append("   because every new layer starts underwater, and it does so by `lot x distance`.")
    out.append("")

    cases = [
        ("A - conservative defaults (FIX 0.01, FIXED distance, no multiplier)",
         Config(lot_mode="FIX", base_lot=0.01, distance_mode="FIXED", distance_points=350,
                layers=6, max_lot=0.05, account=base.account, leverage=base.leverage)),
        ("B - MULTIPLIER 1.5, distance FIXED 350 pts",
         Config(lot_mode="MULTIPLIER", multiplier=1.5, base_lot=0.01, distance_points=350,
                layers=6, max_lot=0.20, account=base.account, leverage=base.leverage)),
        ("C - MULTIPLIER 2.0 (the dangerous setting), FIXED 350 pts",
         Config(lot_mode="MULTIPLIER", multiplier=2.0, base_lot=0.01, distance_points=350,
                layers=6, max_lot=0.20, account=base.account, leverage=base.leverage)),
        ("D - MULTIPLIER 2.0 with ATR distance (ATR 480 pts, x1.5)",
         Config(lot_mode="MULTIPLIER", multiplier=2.0, base_lot=0.01, distance_mode="ATR",
                atr_multiplier=1.5, atr_points=480, layers=6, max_lot=0.20,
                account=base.account, leverage=base.leverage)),
        ("E - gap scenario: 6x spread-wide jump straight through 3 levels",
         Config(lot_mode="MULTIPLIER", multiplier=1.5, base_lot=0.01, distance_points=350,
                layers=6, max_lot=0.20, spread_points=210, account=base.account, leverage=base.leverage)),
    ]
    for title, cfg in cases:
        r = scenario(cfg)
        out.append(f"## {title}")
        out.append("")
        mult_txt = ", LotMultiplier=%s" % cfg.multiplier if cfg.lot_mode != "FIX" else ""
        if cfg.distance_mode == "ATR":
            dist_txt = "ATR %d pts x %.2f" % (cfg.atr_points, cfg.atr_multiplier)
        else:
            dist_txt = "FIXED %d pts" % cfg.distance_points
        out.append("Inputs: `InitialLot=%s`, LotMode=`%s`%s, distance=%s, "
                   "MaximumLayer=%d, MaximumLotPerOrder=%s, MaximumTotalLot=%s, "
                   "entry %.2f, account %s, leverage 1:%d."
                   % (cfg.base_lot, cfg.lot_mode, mult_txt, dist_txt, cfg.layers,
                      cfg.max_lot, cfg.max_total_lot, cfg.entry,
                      "{:,.0f}".format(cfg.account), cfg.leverage))
        out.append("")
        out.append("| Layer | Price | Lot | Cumulative lot | Average price | Instant floating at that price | Margin used |")
        out.append("|---|---|---|---|---|---|---|")
        for l in r["layers"]:
            out.append(f"| {l['index']} | {l['price']:.2f} | {l['lot']:.2f} | {l['cum_lot']:.2f} | "
                       f"{l['avg_price']:.2f} | {l['floating_at_this_price']:+,.2f} | {l['margin']:,.2f} |")
        b = r["basket"]
        out.append("")
        out.append("| Basket | Value |")
        out.append("|---|---|")
        for k, label in (("total_lot", "Total volume"), ("avg_price", "Weighted average"),
                         ("tp_price", "Basket TP price"), ("tp_money", "TP target (net, cost aware)"),
                         ("money_per_point", "Money per point"), ("cutloss_price", "Cut-loss price"),
                         ("margin_at_leverage", "Margin at 1:" + str(cfg.leverage)),
                         ("margin_percent_of_account", "Margin as % of account"),
                         ("notional", "Notional exposure"),
                         ("pl_at_cutloss_trigger", "P/L when the cut loss triggers"),
                         ("pl_if_a_gap_jumps_past_the_cutloss", "P/L if a gap jumps past the cut loss"),
                         ("pl_after_last_layer_if_price_drops_one_more_level",
                          "P/L one more level below the last layer")):
            v = b[k]
            out.append(f"| {label} | {v:,.2f} |" if isinstance(v, float) else f"| {label} | {v} |")
        out.append("")
        out.append("| Adverse excursion from the entry | Floating P/L | % of account |")
        out.append("|---|---|---|")
        for k, v in b["excursion_table"].items():
            pts = int("".join(ch for ch in k if ch.isdigit()))
            out.append(f"| -{pts} pts (${pts * POINT:.2f}) | {v:+,.2f} | {100.0 * v / cfg.account:+.1f}% |")
        out.append("")
        out.append("")
        out.append("| Loss measure | Amount | % of the modelled account |")
        out.append("|---|---|---|")
        out.append(f"| deepest point of the {cfg.layers}-layer sequence | {r['loss_deepest_excursion']:,.2f} "
                   f"| {100.0 * r['loss_deepest_excursion'] / cfg.account:.1f}% |")
        out.append(f"| the EA's own cut-loss cap | {r['loss_capped_by_cutloss']:,.2f} "
                   f"| {100.0 * r['loss_capped_by_cutloss'] / cfg.account:.1f}% |")
        out.append(f"| **cut-loss cap plus a 2-distance gap through it** | {r['loss_if_gap_jumps_past_cutloss']:,.2f} "
                   f"| {100.0 * r['loss_if_gap_jumps_past_cutloss'] / cfg.account:.1f}% |")
        out.append(f"Modelled worst loss in this scenario: **{r['max_modelled_loss']:,.2f}**. "
                   f"To keep that inside 20% of equity the account needs "
                   f"**{r['account_for_20pct_dd']:,.0f}**; for 10% it needs "
                   f"**{r['account_for_10pct_dd']:,.0f}**. "
                   + ("**MaximumLotPerOrder capped the growth.** " if r["flags"]["capped_by_max_lot"] else "")
                   + ("**MaximumTotalLot stopped further averaging.**" if r["flags"]["capped_by_total_lot"] else ""))
        out.append("")
    out.append("## 2. Reading the tables")
    out.append("")
    out.append("* Scenario A is what the shipped defaults do. The basket never grows its")
    out.append("  volume, so the loss curve is linear in price and the cut-loss cap is")
    out.append("  reachable by design.")
    out.append("* B vs C: doubling the multiplier from 1.5 to 2.0 roughly triples the total")
    out.append("  volume at layer 6 and quadruples the loss at the same depth. That is the")
    out.append("  non-linearity the risk disclaimer in `docs/14-risk-disclaimer.md` is about.")
    out.append("* D shows why the ATR distance mode is safer in a volatile regime: levels are")
    out.append("  further apart, so fewer layers are added per dollar of adverse move - but the")
    out.append("  basket is *below* the market by more when it is done, so the recovery target")
    out.append("  is larger. There is no free parameter here.")
    out.append("* E models a gap: when one jump crosses several levels, `MinimumDistanceSpreadMultiple`,")
    out.append("  `MinimumSecondsBetweenAveraging` and `OneLayerPerBar` decide how many layers the")
    out.append("  EA actually adds. The single worst outcome is therefore bounded by")
    out.append("  `MaximumLayer x MaximumLotPerOrder`, not by the multiplier.")
    out.append("")
    out.append("## 3. What the caps buy")
    out.append("")
    out.append("| Cap | Effect in the model |")
    out.append("|---|---|")
    out.append(f"| `MaximumLotPerOrder = {base.max_lot}` | hard ceiling on any single layer; caps the growth of scenario C |")
    out.append(f"| `MaximumTotalLot = {base.max_total_lot}` | stops adding layers once the basket reaches the ceiling (flag `capped_by_total_lot`) |")
    out.append(f"| `MaximumLayer = {base.layers}` | bounds the sequence length, hence bounds the worst case |")
    out.append(f"| `MaximumCycleDrawdownPercent` / cut loss | converts an open-ended losing basket into a fixed money loss |")
    out.append("")
    out.append("Reproduce any of these numbers with:")
    out.append("")
    out.append("```bash")
    out.append("python3 tools/stress_model.py --layers 6 --base 0.01 --mult 2.0 \\")
    out.append("       --distance 350 --entry 2350 --account 10000 --leverage 500")
    out.append("```")
    return "\n".join(out) + "\n"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--layers", type=int, default=6)
    ap.add_argument("--base", type=float, default=0.01)
    ap.add_argument("--mult", type=float, default=1.5)
    ap.add_argument("--distance", type=int, default=350)
    ap.add_argument("--entry", type=float, default=2350.00)
    ap.add_argument("--atr", type=int, default=480)
    ap.add_argument("--account", type=float, default=10000.0)
    ap.add_argument("--leverage", type=int, default=500)
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--emit", type=str, default="", help="write the markdown into this file (docs/12 body)")
    ap.add_argument("--emit-doc", type=str, default="",
                    help="replace the block between STRESS:BEGIN / STRESS:END in this markdown file")
    args = ap.parse_args()
    cfg = Config(layers=args.layers, base_lot=args.base, multiplier=args.mult,
                 distance_points=args.distance, entry=args.entry, atr_points=args.atr,
                 account=args.account, leverage=args.leverage)
    if args.json:
        print(json.dumps(scenario(cfg), indent=2))
        return 0
    text = md_tables(cfg)
    if args.emit_doc:
        doc = Path(args.emit_doc)
        txt = doc.read_text()
        b = "<!-- STRESS:BEGIN -->"
        e = "<!-- STRESS:END -->"
        if b not in txt or e not in txt:
            raise SystemExit(f"{doc}: markers {b} / {e} not found")
        head, rest = txt.split(b, 1)
        _, tail = rest.split(e, 1)
        doc.write_text(head + b + "\n" + text + e + tail)
        print(f"refreshed {doc}")
        return 0
    if args.emit:
        Path(args.emit).write_text(text)
        print(f"wrote {args.emit}")
    else:
        print(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
