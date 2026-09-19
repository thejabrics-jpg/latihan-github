# XAU_AVG_PRO v1.0.0 - averaging Expert Advisor for XAUUSD (MQL5)

Production-oriented MetaTrader 5 Expert Advisor for gold (XAUUSD and its
suffix variants) built around one idea: **an averaging basket is only as safe as
the arithmetic that bounds it.** Entry logic is replaceable; the risk layer is
not.

* **9 607 lines** of MQL5 in 19 files: the EA plus 18 modules (`MQL5/Experts`, `MQL5/Include/XAU_AVG_PRO`)
* **165 inputs**, all validated at start, all documented by a generated reference
* 34 named block reasons (plus `NONE`), 10 derived states, exactly one module that can send an order
* Telegram control (28 whitelisted commands, confirmation for destructive ones),
  chart dashboard (34 rows), daily report to chart / Telegram / CSV
* built-in deterministic self tests (75 assertions) and Python static QA that
  resolves every cross-module call by name, arity and argument type

> **No profitability is claimed anywhere in this repository.** Read
> [`docs/14-risk-disclaimer.md`](docs/14-risk-disclaimer.md) before touching a
> live account, and note that this build has **not been compiled** in the
> authoring environment ([`docs/13.5`](docs/13-code-audit.md)).

## Where to start

| I want to… | Go to |
|---|---|
| understand the design | [docs/01-architecture.md](docs/01-architecture.md) |
| see every parameter | [docs/02-input-specification.md](docs/02-input-specification.md) (generated from the source) |
| know what stops a trade | [docs/03-state-machine.md](docs/03-state-machine.md) |
| understand the limits | [docs/04-risk-model.md](docs/04-risk-model.md) |
| understand the averaging rules | [docs/05-averaging-algorithm.md](docs/05-averaging-algorithm.md) |
| know how a basket is tracked across restarts | [docs/06-cycle-and-position-management.md](docs/06-cycle-and-position-management.md) |
| drive it from a phone | [docs/07-telegram-command-spec.md](docs/07-telegram-command-spec.md) |
| verify it before using it | [docs/08-testing-strategy.md](docs/08-testing-strategy.md) |
| know what it cannot do | [docs/09-known-risks-and-limitations.md](docs/09-known-risks-and-limitations.md) |
| install it | [docs/10-installation-and-configuration.md](docs/10-installation-and-configuration.md) |
| backtest / optimise honestly | [docs/11-backtest-protocol.md](docs/11-backtest-protocol.md) |
| see what the tail costs | [docs/12-stress-test-report.md](docs/12-stress-test-report.md) |
| audit the code | [docs/13-code-audit.md](docs/13-code-audit.md) |

The "answer these before writing code" sections are answered by docs 01-09 in
order: architecture (01), complete input specification (02), state machine (03),
risk model (04), averaging algorithm (05), cycle / position management (06),
Telegram command specification (07), testing strategy (08), known risks and
limitations (09). Installation (10), backtest protocol (11), adverse-market
stress report (12), final code audit (13) and the risk disclaimer (14) follow.

## Behaviour in one paragraph

On a new bar (or bar close, configurable) an EMA cross produces a signal. The
first layer is sized by `LotMode` (`FIX` / `AUTO` risk-% / `MULTIPLIER`) and is
sent with `OrderCheck` first and a **verified fill** after: a retcode alone is
never treated as success. If price moves against the basket by the configured
distance (`FIXED` points, or `ATR x multiplier` clamped between a floor and a
ceiling and never below the spread x `MinimumDistanceSpreadMultiple`), one more
layer is added - at most one per bar, never the same level twice, never faster
than `MinimumSecondsBetweenAveraging`, never beyond `MaximumLayer`,
`MaximumLotPerOrder` or `MaximumTotalLot`. The whole basket then exits on its own
target (`MONEY` / `POINTS` / `PERCENT` / `PRICE`, cost aware: spread, commission
and swap included) or on its cut loss, after which a cooldown blocks the next
cycle. Account, cycle, floating and daily drawdown limits are evaluated on every
pass, **before** any entry or averaging decision, and can block, close, or raise
`EMERGENCY_STOP`; a risk limit always beats a profit opportunity.

## Repository layout

```
MQL5/Experts/XAU_AVG_PRO.mq5          inputs, wiring, event handlers, pipeline order
MQL5/Include/XAU_AVG_PRO/*.mqh        the 18 modules (see docs/01)
docs/01…14 + CHANGELOG.md             architecture → limits → tests → audit → disclaimer
presets/*.set                          conservative / cent-account / multiplier-demo
tools/*.py                             QA harness, doc generator, stress model
```

## Build, check, run

```bash
# 1. everything that can be checked without a terminal - one command, nine steps
bash tools/run_all_qa.sh          # must end with: ALL QA STEPS PASSED

# 2. (individual steps, if you want to run one of them)
python3 tools/qa_static_check.py          # structure, wiring, format strings, markers
python3 tools/qa_mql_symbol_check.py       # call arity, member names, enum values
python3 tools/gen_input_docs.py --check    # docs/02 is current
python3 tools/qa_preset_check.py           # presets complete, type-legal, secret-free
python3 tools/qa_doc_claims.py             # every number in these docs is true
python3 tools/stress_model.py --emit-doc docs/12-stress-test-report.md

# 3. compile in MetaEditor (F7) -> 0 errors, 0 warnings, then attach to an M15
#    XAUUSD chart with RunSelfTestsOnInit=true once, on a DEMO account.
```

Full install steps, the WebRequest allowance for Telegram, and the
verification checklist: [docs/10](docs/10-installation-and-configuration.md).

## Defaults are conservative on purpose

`LotMode=FIX`, `InitialLot=0.01`, `AveragingDistancePoints=350`,
`MaximumLayer=6`, `MaximumLotPerOrder=0.10`, `MaximumTotalLot=0.50`,
`BasketTPMode=MONEY` at 5.0, cut loss 50.0, `ActionOnAccountDD=EMERGENCY` at
20 %, daily loss 150.0 / 5 %, spread and gap and session and weekend filters
armed, news filter and Telegram off (they need broker-side data you must opt
into). The multiplier is off by default because
[docs/12](docs/12-stress-test-report.md) shows what it does to a 6-layer sequence.

## Status of this repository

Phase-by-phase delivery was used (architecture → inputs → state machine → risk →
averaging → cycle management → Telegram → tests → risks → implementation → QA →
docs). The code passes every automated check listed above; it has **not** been
compiled or run against a broker from here. Version history:
[CHANGELOG.md](CHANGELOG.md).

## What is verified, what is implemented, what cannot be proven here

Three different claims, deliberately separated. Read the third column before you fund
anything; `docs/13.5` is the long version.

| Verified mechanically in this repository | Implemented, but only a terminal can prove it | Cannot be verified from here at all |
|---|---|---|
| Structure: braces/guards/includes, 1 051 cross-module calls by name, arity and type shape, 1 552 member accesses, every enum member used | MetaEditor reports **0 errors, 0 warnings** (the requirement in `docs/10.2`, not a result) | Real `OrderSend`/`OrderCheck` behaviour: requotes, partial fills, `10030` fallback in practice (tests A-V, `docs/08`) |
| Every one of the 165 inputs is copied into `CConfig` exactly once; no placeholder markers; no secret-shaped literal | The 75 self-test assertions actually pass at `OnInit` in a terminal | Broker-specific values: real swap, commission, freeze-level rejections, margin mode quirks |
| All 209 format strings: specifier count == argument count, zero `%n` (MQL5 has no `%n`) | News blocking on a real economic calendar (`CalendarValueHistory` is unavailable in the tester) | Whether *your* account is hedging or netting, or allows hedged closes at all |
| Risk precedence read in the source: severity-ordered `Strongest()`, state gate before risk gate on both entry and averaging | Restart recovery after a real terminal restart with an open basket (the state file logic is unit-tested, the disk + timing behaviour is not) | Live feed hazards: slippage, weekend gap sizes, spread blowouts between your ticks |
| Presets load: 165 keys, numeric only, `; overrides:` manifest accurate, token/chat-id left empty | Telegram actually reaching the Bot API (needs `WebRequest` allow-list + your own token) | **Profitability.** Nothing here predicts profit; averaging increases exposure non-linearly (`docs/14`) |
| `docs/02` regenerates identical; `docs/12` is byte-identical to `tools/stress_model.py`; every count quoted in these docs is recomputed by `tools/qa_doc_claims.py` | Dashboard and object layout on your chart (fonts, scaling, chart events) | Whether the strategy is suitable for your capital and jurisdiction |

## Licence / usage note

Provided for study and personal use with the documentation intact. Nothing here
is investment advice; trading leveraged gold CFDs can lose your entire deposit
([docs/14](docs/14-risk-disclaimer.md)).

---

## Catatan awal repositori / original repository note

This repository started as a place to learn GitHub from scratch:

> **# Latihan GitHub**
> Saya sedang belajar GitHub dari nol.

That purpose is preserved: `XAU_AVG_PRO` is the project used to practise branching,
commits, documentation and review. The original two-line README is kept verbatim
above so the history of the repository stays readable.
