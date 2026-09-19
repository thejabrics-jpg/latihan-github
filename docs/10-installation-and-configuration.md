# 10 - Installation and Configuration

## 10.1 Folder layout (exactly as in this repository)

```
<data folder>/MQL5/
   Experts/XAU_AVG_PRO.mq5
   Include/XAU_AVG_PRO/Types.mqh
   Include/XAU_AVG_PRO/Logger.mqh
   Include/XAU_AVG_PRO/BrokerSpec.mqh
   Include/XAU_AVG_PRO/StateStore.mqh
   Include/XAU_AVG_PRO/Cycle.mqh
   Include/XAU_AVG_PRO/Entry.mqh
   Include/XAU_AVG_PRO/Averaging.mqh
   Include/XAU_AVG_PRO/Lots.mqh
   Include/XAU_AVG_PRO/MarketFilters.mqh
   Include/XAU_AVG_PRO/News.mqh
   Include/XAU_AVG_PRO/Execution.mqh
   Include/XAU_AVG_PRO/Basket.mqh
   Include/XAU_AVG_PRO/State.mqh
   Include/XAU_AVG_PRO/Risk.mqh
   Include/XAU_AVG_PRO/Statistics.mqh
   Include/XAU_AVG_PRO/Dashboard.mqh
   Include/XAU_AVG_PRO/Telegram.mqh
   Include/XAU_AVG_PRO/SelfTest.mqh
```

Open the data folder with `Ctrl+Shift+D` in MetaTrader 5 (`File -> Open Data`).
The `MQL5/Include/XAU_AVG_PRO/…` subtree in this repository is already laid out
relative to `MQL5/`, so copying the `MQL5/` directory content is enough. The
`.mq5` includes its modules with a relative path
(`#include "Include\XAU_AVG_PRO\Types.mqh"`), so the EA does **not** depend on a
custom `MQL5/Include` subfolder name other than `XAU_AVG_PRO`.

## 10.2 Compile

1. `F7` in MetaEditor on `MQL5/Experts/XAU_AVG_PRO.mq5` (or
   `metaeditor64.exe /compile:"MQL5\Experts\XAU_AVG_PRO.mq5" /log`).
2. Expected result: **0 errors, 0 warnings**. Any warning is a defect: fix it, do
   not ignore it. No external library is required - the EA uses the MQL5 runtime
   only (`<Trade/…>` is deliberately not used, `docs/01.5`).
3. If the compiler reports a missing include, the folder layout is wrong (10.1) -
   not the code.
4. Refresh the Navigator (`Ctrl+D` right click -> Refresh).

## 10.3 Install a run

1. **Account**: a demo account first, on the broker you intend to use live
   (spread, freeze levels, swap and filling policy are broker properties).
2. **Symbol**: open an `M15` chart of your gold symbol (`XAUUSD`, `XAUUSDm`,
   `XAUUSD.a`, `GOLD`, `XAUUSDc`…). The EA resolves the symbol from the chart, so
   the suffix never has to be configured.
3. **Telegram (optional)**: `Tools -> Options -> Expert Advisors` -> tick *Allow
   WebRequest for the following URL list* and add `https://api.telegram.org`.
   Then set `EnableTelegram=true`, `TelegramBotToken`, `TelegramChatID`. Never put
   the token in a `.set` file you intend to share, and never in a screenshot.
4. **AutoTrading**: enable algorithmic trading in the toolbar; the EA checks
   `MQLInfoInteger(MQL_TRADE_ALLOWED)` and `TERMINAL_CONNECTED` every pass and
   refuses new risk (never exits) when either is off, with a logged reason.
5. Attach, then read the dashboard and the first lines of the Experts journal:
   `spec:`, `tick value:`, `config:` and `ready | state=… | telegram …`. A
   configuration problem shows as `CONFIG hard errors - trading disabled` on the
   panel and one `[CFG]` line per problem.

## 10.4 Configuration profiles

The **shipped defaults** are the conservative profile: `LotMode=FIX`,
`InitialLot=0.01`, `EnableAveraging=true` with `AveragingDistanceMode=FIXED`,
`AveragingDistancePoints=350`, `MaximumLayer=6`, `MaximumLotPerOrder=0.10`,
`MaximumTotalLot=0.50`, `BasketTPMode=MONEY` with `BasketTakeProfitMoney=5`,
`EnableBasketCutLoss=true` at `50` money, `ActionOnAccountDD=EMERGENCY`,
`MaximumAccountDrawdownPercent=20`, `MaximumDailyLossMoney=150`, filters on,
news filter off (it needs broker calendar data), Telegram off, dashboard on.

Two things the defaults deliberately do **not** include: a multiplier (the model
in `docs/12` shows what it costs) and an unbounded basket (`BasketTPMode=NONE` or
`EnableBasketCutLoss=false` are supported but they are *not* defaults).

| Preset | For | Notable differences from the shipped defaults |
|---|---|---|
| `presets/XAU_AVG_PRO_conservative.set` | first demo run, then the smallest live account | `MaximumLayer=4`, `MaximumLotPerOrder=0.05`, `MaximumTotalLot=0.20`, distance 400 pts, TP $5, cut loss $40, account DD 10 % with `ActionOnAccountDD=EMERGENCY`, daily $50 / 3 %, floating $60, file log on |
| `presets/XAU_AVG_PRO_cent_account.set` | cent accounts, where the money numbers are cents | `InitialLot=0.10` (a cent account), `MaximumTotalLot=1.50`, TP 50, cut loss 400, daily 500 / 5 %, floating 600, account DD 15 % |
| `presets/XAU_AVG_PRO_multiplier_demo.set` | **demo only**: observing a multiplier in the tail | `LotMode=MULTIPLIER`, `LotMultiplier=1.5`, ATR distance mode with a 350..1500 pts clamp, `MaximumTotalLot=0.30` |

They are plain text, one `name=value` per line under `[input]` (enum inputs are
numeric values, booleans are `0/1`), loadable from the EA properties dialog ->
`Load`. They contain **no token and no chat id** - those two inputs are deliberately
left empty in every preset, because a preset file gets copied and `docs/09.4`.

Regenerate after any input change (the tool reads the input names from the source
and refuses to write an unknown name):

```bash
python3 tools/gen_preset.py --name conservative --out presets/XAU_AVG_PRO_conservative.set \
       --set MaximumLayer=3 --set MaximumTotalLot=0.10 --set BasketCutLossMoney=25.0
```

## 10.5 Account size: arithmetic, not advice

These are modelled worst cases for a **complete 6-layer sequence that then does
not recover**, with the cut-loss cap plus a two-distance gap through it
(`tools/stress_model.py` reproduces them in one command). They are *not* safety
guarantees and *not* a claim about your broker's real spread, slippage or margin
call level.

| Profile | Total volume at layer 6 | Modelled worst loss | Equity for that loss to be <= 20 % |
|---|---|---|---|
| defaults (`FIX 0.01`, cut loss $50) | 0.06 | ~$92 | ~$460 |
| `MULTIPLIER 1.5`, base 0.01, cap 0.10 | 0.19 | ~$184 | ~$920 |
| `MULTIPLIER 2.0`, base 0.02, cap 0.10, cut loss $200 | 0.44 | ~$511 | ~$2 560 |

Two rules of thumb that follow from the arithmetic rather than from courage:

1. size the account so that **the worst modelled case is a fraction of equity** -
   not the average case;
2. if the resulting volume is too small to be interesting, that is the correct
   answer for that account size: increase the account, not the multiplier.

## 10.6 Verification checklist after attaching

- [ ] `spec:` line shows your real digits/point/lot step and `fill=` list;
- [ ] `SYMBOL` row shows `(hedging)` or `(netting)` and matches the account;
- [ ] `RISK` row shows the limits you think are active;
- [ ] `FILTERS`/`NEWS` rows show what is armed (and `NEWS: off - no calendar data`
      if the broker has none - that is `NewsFailSafePolicy` talking, see `docs/09.3`);
- [ ] `TELEGRAM` row: `connected` or `off: <reason>` (a reason, never silence);
- [ ] `RunSelfTestsOnInit=true` once on a live chart -> `[TEST]` lines, all `PASS`
      (`HaltAfterSelfTests=true` if you want to read them without trading);
- [ ] one deliberate `pause` + `resume` via the chart button and via Telegram;
- [ ] one restart with an open basket: same cycle id, same layer count
      (`docs/08` test M).

## 10.7 Uninstall / stop cleanly

`/stop` (no new cycles) or `/pause` (no new risk at all), wait for the basket to
close (or `/closeall` + `/confirm_closeall`), then remove the EA. Positions are
never force-closed by detaching - `OnDeinit` logs `EA detached with cycle #N still
OPEN` so the event is explicit. Chart objects disappear with
`RemoveDashboardOnDetach=true` (default).

---
Prev: [09 - Known risks and limitations](09-known-risks-and-limitations.md) |
Next: [11 - Backtest protocol](11-backtest-protocol.md)
