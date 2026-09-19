# 14 - Risk Disclaimer

Read this. It is short, it is not decoration, and it is part of the deliverable.

## 14.1 The mechanism you are about to enable

This Expert Advisor adds to a losing position on a schedule (controlled
averaging), optionally with growing volume (`LotMultiplier`). Both choices mean
the same thing expressed differently:

> **exposure grows when the market is wrong about you, and it grows
> non-linearly.**

That is the defining property of the class, not a flaw of this implementation. It
has three consequences that no parameter, filter or stop setting removes:

1. **A single cycle can cost many times the loss of its first trade.** A
   6-layer basket holds several times the volume of its entry, at an average price
   that keeps moving away from recovery. `docs/12` prints the exact arithmetic for
   the configurations shipped here.
2. **The loss distribution has a long left tail.** Most cycles end at the small
   basket target; a few end at the cut loss, and a few of *those* end beyond it,
   because a gap or a fast move can jump past the trigger. The "cut loss plus a
   two-distance gap" row in `docs/12` is the number to size the account against,
   not the average.
3. **Recovery requires a reversal, not a bounce.** The deeper the basket, the more
   the market has to come back for the basket to close in profit. In a trend that
   does not turn, the cap - not the market - decides the outcome, which is exactly
   why `MaximumLayer`, `MaximumTotalLot`, `MaximumLotPerOrder`, the cut loss and
   the account-drawdown limit are hard, non-optimisable, always-evaluated-first.

## 14.2 No promise is made anywhere in this project

* There is **no guaranteed profit**, no expected win rate, no "safe" account size,
  and no claim that any backtest result will repeat. Documentation, defaults, the
  stress model and the self tests describe *behaviour*, never *returns*.
* Any account-size figure in `docs/10.5` is arithmetic about what a given
  configuration can lose in a modelled sequence. It is **not** a claim that the
  configuration is safe on that size of account, and it is not suitable for anyone
  who has not verified it on their own broker, symbol, spread, leverage and
  account type.
* A backtest (even "every tick based on real ticks") is a simulation. Slippage,
  requotes, broker-side fills, swaps, commission changes, weekend gaps and
  liquidity are only partly represented, and are never favourable on average.

## 14.3 You can lose more than you intended, and in rare cases more than you hold

The worst realistic cases are outside the EA's control:

* a broker stop-out executed before the EA's own closing sweep;
* a gap through the cut-loss level (the model bounds it, the market does not);
* negative balance / a margin call during an illiquid open;
* the terminal or connection being down while a basket is open (this EA manages
  exits **inside the running program**, `docs/09.2` - if it is not running, nothing
  is);
* a symbol specification change (contract size, digits, lot step) that alters what
  "one lot" means while positions are open.

## 14.4 Practical minimums before any real money

1. run on **demo** with the exact broker, symbol, suffix and inputs (`docs/08`
   tests A-V);
2. fund a live account only with money whose total loss you can absorb without
   changing your life;
3. start with the shipped conservative defaults, single chart, `LotMode=FIX`,
   no multiplier, cut loss armed, `MaximumAccountDrawdownPercent` set so the
   *block* fires before the broker's margin call does;
4. keep `LogToFile=true` and read the journal weekly - a `FAIL` self-test line, an
   `ERROR` state, an `unverified` execution or a rising `blocked` counter are all
   reasons to stop and investigate, not to widen a limit;
5. never run two instances on the same symbol with the same magic, and never let
   another EA manage the same positions (`docs/06.1` isolation rule);
6. treat every Telegram command as moving real money: keep the chat id private,
   keep the token out of files and screenshots, and leave
   `RequireConfirmationForDestructive=true`.

## 14.5 Taxonomy of who is at risk of what

| Reader | The part that matters |
|---|---|
| evaluating the software | `docs/13.5` - this build has **not been compiled** in the authoring environment; treat `docs/10.2` as step one |
| sizing an account | `docs/12` and `docs/10.5` |
| tuning parameters | `docs/11.4` (and the rule that risk caps are not tunables) |
| deploying for others | `docs/09` in full, plus this page; a strategy that averages into losers must be explained to the person whose money it is, before it is explained to their broker |

## 14.6 One sentence version

This EA can lose money faster than it can make money, it is engineered so that
this happens in a bounded and visible way, and every safety mechanism in it exists
to make the *worst* case survivable rather than to make the *average* case
profitable.

---
Prev: [13 - Code audit](13-code-audit.md) | Back to [README](../README.md)
