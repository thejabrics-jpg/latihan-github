# 07 - Telegram Control Specification

`CTelegramBot` (`Telegram.mqh`, 603 lines) is a **transport and gatekeeper**, not
a command executor. It authenticates, sanitises, whitelists, rate-limits, queues
and replies. The engine (`HandleCommand` in `XAU_AVG_PRO.mq5`) validates ranges and
applies changes to `g_cfg`. That split means a Telegram failure can never become a
trading decision.

## 7.1 Transport

* Plain Bot API over `WebRequest` (`https://api.telegram.org/bot<token>/<method>`).
  The API host is a `#define` (`XAU_TG_API`), not a hard-coded URL scattered in the
  code.
* Inbound: `getUpdates` long-poll style with a persisted `update_id` offset (state
  key `tg_offset`), so a terminal restart cannot re-execute yesterday's commands.
* Outbound: `sendMessage`, throttled by `TelegramMaxMessagesPerMinute` (default 12).
* Polling happens in `OnTimer`, never in `OnTick`: one slow HTTP call must not
  delay a risk evaluation.
* **No HTML/Markdown parse mode**: replies are plain text, so a symbol in the
  status report cannot be interpreted as markup by the client.
* `TelegramRequestTimeoutMs` bounds every call; after 10 consecutive API errors
  the module backs the poll off for 600 s instead of hammering the endpoint, and
  `LastError()`/`ErrorCount()` show it in `/status`.

### Prerequisite the user must satisfy

`Tools -> Options -> Expert Advisors -> Allow WebRequest for the following list`
must contain `https://api.telegram.org`. If it does not, `WebRequest` fails with
error 4014 and the EA **self-disables Telegram** with an explicit reason
(`Init()` runs a `getMe` probe at start and disables itself if the probe fails),
leaving trading fully functional. The reason is logged once and shown on the
dashboard; nothing is retried silently forever.

## 7.2 Security model

| Threat | Countermeasure |
|---|---|
| token leakage | `MaskToken()` masks the token in every log line, in `Describe()`, in errors and in replies. `TelegramBotToken` defaults to `""` and the QA harness fails the build if a `bot\d+:AA...` pattern or a non-empty default appears anywhere. |
| unauthorised operator | only the configured `TelegramChatID` is served; the id is read from the update's `"chat":{"id":...}` object - **not** the first `"id":` in the payload, which is the *user* id, a real trap when a group forwards messages. A mismatch is dropped, counted (`RejectedCount()`) and logged without the token. |
| injection / shell-ish payloads | a command must match `[a-z0-9_]{1,64}` after `@botname` is stripped; any `;`, quote, backslash, bracket, space or uppercase letter in the *name* rejects the whole message. Arguments are limited to 40 characters, and multi-line messages are truncated before parsing. There is no path from a Telegram string to a file name, a symbol name or an executed expression. |
| unknown commands | rejected with a reply, never "tried anyway"; `RejectedCount()` and `DroppedCount()` are visible in `/status`. |
| accidental flatten | destructive commands require an explicit second message within `XAU_TG_CONFIRM_SECONDS = 90` (see 7.4) and `RequireConfirmationForDestructive` (default `true`). |
| spam / loop | per-minute outbound limit + the error backoff + `Ping` for liveness instead of polling `/status` in a loop. |
| group chat confusion | commands are only accepted from the authorised chat; `/cancel` clears both the pending confirmation and the queued commands. |

## 7.3 The whitelist (28 commands - nothing else exists)

| Command | Effect | Preconditions / notes |
|---|---|---|
| `/status` | full state report (state, cycle, layers, volumes, limits, filters, news, Telegram counters) | read-only, always available |
| `/stats`, `/report` | daily report (same text as the scheduled one) | read-only |
| `/help` | the command list | read-only |
| `/version` | EA name/version, `__DATE__ __TIME__`, symbol, magic | read-only - proves which build is live |
| `/ping` | liveness + last successful poll + sent/received counters | read-only |
| `/start` | resume: `user_paused=false`, clears a soft risk block if `AutoResetRiskBlock` allows | does **not** clear EMERGENCY_STOP or a daily-loss block |
| `/stop` | `AllowNewCycles=false` - no new cycles | never closes anything (the reply says so explicitly) |
| `/pause` | pause: no entries, no averaging; exits stay armed | state machine keeps managing the basket |
| `/resume` | clears the pause | |
| `/emergency` | EMERGENCY_STOP: block everything and flatten the EA basket (exit code 4) | released only per `EmergencyResetMode` |
| `/emergency_clear` | clears EMERGENCY_STOP | **rejected by design** when `EmergencyResetMode=NEXT_DAY`; the reply shows the armed timestamp instead |
| `/closeall` | close every position with this EA's magic (honouring `ManageCurrentSymbolOnly`) | needs `/confirm_closeall` |
| `/closebuy` | close BUY positions of this EA | needs `/confirm_closebuy` |
| `/closesell` | close SELL positions of this EA | needs `/confirm_closesell` |
| `/confirm_closeall` `/confirm_closebuy` `/confirm_closesell` | execute the armed action | must match the pending action exactly, within 90 s |
| `/cancel` | disarm the confirmation, drop the queued commands | |
| `/setlot <lot>` | `InitialLot` | >= broker min, <= `MaximumLotPerOrder`, must snap onto the broker volume step; the reply shows before -> after |
| `/setmultiplier <1.0..3.0>` | `LotMultiplier` | the reply also prints the resulting worst-layer multiple, so the effect is visible |
| `/setdistance <10..20000>` | `AveragingDistancePoints`, and switches `AveragingDistanceMode` to FIXED | the mode switch is announced in the reply |
| `/settp money\|points\|percent\|price\|off <v>` | basket TP mode + value | money 0..1e6, points 1..1e5, percent 0..25, price 0..1e4; `off` sets `XAU_TP_NONE` and the reply warns that only risk limits remain |
| `/setcutloss money\|percent\|points\|off <v>` | basket cut loss | money 0..1e6, percent 0..50, points 10..1e5; `off` warns explicitly that the basket can then only be closed by a risk limit |
| `/setdirection buy\|sell\|both` | `TradingDirection` | invalid token rejected, nothing changed |
| `/setmaxlayer <1..20>` | `MaximumLayer` | lowering it never closes an existing basket (the reply says so) |
| `/setmaxlot <lots>` | `MaximumTotalLot` (the total exposure cap) | must be >= `InitialLot`, <= broker `VolumeMax`, and cannot be set below the exposure the basket already has |
| `/resetparams` | erase all stored overrides (`ovr_*` keys) | the reply states that a chart reload/restart reverts to the input values |

All parameter commands are refused with a clear reply when
`TelegramEnableOverrides=false`; `/status`, `/stats`, `/report`, `/start`,
`/stop`, `/pause`, `/resume` keep working in that mode.

## 7.4 Confirmation flow for destructive actions

```
operator:  /closeall
EA:        arm(action="closeall", until=now+90s)
           "CONFIRM CLOSEALL:
            Reply with /confirm_closeall within 90 seconds.
            Nothing has been executed."
operator:  /confirm_closeall            (or 90 s pass, or /cancel)
EA:        action == pending -> execute -> report the closed count
           expired          -> "Nothing to confirm (the request expired after 90 s
                                or was never made)." - and nothing was executed
```

Three properties are deliberate: the arming is *single-slot* (a second
`/closebuy` replaces the pending action instead of queueing two), the confirmation
must name the action it confirms (a stale `/confirm_closeall` cannot authorise a
later `/closebuy`), and the expiry is checked at execution time, not at reply
time, so a queued command cannot be executed after its window.

## 7.5 Overrides are configuration, validated like configuration

Every change is applied to `g_cfg` only, then:

1. the same validators that `ValidateConfig()` uses are re-run on the touched
   field (there is no "Telegram path" that skips validation);
2. the corresponding `XAU_OVR_*` bit is set in `override_flags` and the value is
   persisted in the state file (`ovr_*` keys) when
   `PersistTelegramOverrides=true`;
3. `[CFG] WARN` is logged with before/after and the operator's chat id, so a
   parameter change is auditable in the journal and in `/status` (which prints the
   active override mask);
4. on the next `OnInit` the stored overrides are restored **before**
   `ValidateConfig()` runs, so an override that has become invalid (for example a
   lot above a new broker limit) is rejected by the same rules as an input, and
   the EA refuses to trade rather than trading with a broken cap.

## 7.6 Failure modes, each with a stated behaviour

| Failure | Behaviour |
|---|---|
| `EnableTelegram=false` (default) | module never initialised; no network at all |
| running in the Strategy Tester | self-disabled at `Init()` (no `WebRequest` there), trading unaffected |
| token or chat id empty | self-disabled with the reason in the log; no probe is attempted |
| `getMe` fails (bad token, 4014, no permission) | self-disabled, reason logged **masked**, dashboard shows `TG: off (reason)`, trading unaffected |
| network/API error during polling | error counter + `LastError()`; 10 consecutive errors -> 600 s backoff; state never changes because of a Telegram error |
| rate limit exceeded by the operator | messages beyond `TelegramMaxMessagesPerMinute` are dropped and counted, not queued forever |
| terminal closed with a pending confirmation | the arming is not persisted: after a restart there is nothing to confirm (a destructive action never survives its own window silently) |

---
Prev: [06 - Cycle & position management](06-cycle-and-position-management.md) |
Next: [08 - Testing strategy](08-testing-strategy.md)
