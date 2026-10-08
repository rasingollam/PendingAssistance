# RectanglePendingEA 2.02

Compiled with `D:\Trading\MetaEditor64.exe` from the `D:\Trading\terminal64.exe` installation. Refresh MT5 Navigator and attach `PendingAssistance > RectanglePendingEA` to a chart.

## Compact controls

Select a standard rectangle on the main price chart. A compact dark panel appears immediately to its right:

```text
Upper    Lower
Buy      Sell
```

Upper/Lower chooses the entry edge, highlighted in blue (initial default: Upper). Buy is green and Sell is red. Clicking either arms a cached waiting trade. There are no Stop/Limit or Close buttons. Use MT5's normal object controls to delete a rectangle.

The normal panel is 164 x 58 pixels and follows rectangle movement/zoom. It docks against the chart's right edge if there is insufficient space beside the rectangle. Deselecting hides unarmed controls. Controls are hidden while a linked broker order or position exists and return when selected after cancellation/full closure. A partial close keeps the rectangle linked until its remainder closes.

## Waiting status and Cancel

An armed trade shows BUY/SELL WAITING, the chosen edge and entry, SL, TP, estimated lots and estimated money risk. Cancel disarms it without deleting the rectangle. Waiting status and Cancel are visible only when the rectangle is selected; deselecting hides the panel while keeping the trade armed and its price lines visible. Entry is green; SL and TP are red. All three lines are dash-dot, width 1. White `SL` and `TP` captions share the PR label's Arial 7 font, left inset of 7 pixels and 1-pixel spacing above the line. The eligible partial level is also plotted.

Levels are saved when armed. Moving the rectangle afterward only moves the panel. Cancel and re-arm to change the trade. Deleting/renaming a rectangle cancels its still-waiting trade. Snapshots and edge selection survive ordinary EA/terminal restarts in terminal globals, keyed by account, symbol and rectangle name. The same symbol/name identifies the same cached trade across chart instances.

For rectangle bottom 100, top 110, RR 2:

| Choice | Entry | SL | Planned TP |
| --- | --- | --- | --- |
| Upper Buy | 110 | 100 | 130 |
| Lower Buy | 100 | 90 | 120 |
| Upper Sell | 110 | 120 | 90 |
| Lower Sell | 100 | 110 | 80 |

## Market execution

New trades are monitored in the EA; no new broker pending orders are submitted. Buy watches Ask, Sell watches Bid. The direction toward entry is inferred from the quote when armed, so no Stop/Limit selection is needed. Execution is evaluated on fresh chart ticks, including after restoring a saved plan.

At the trigger, absolute quote distance from entry must be no greater than the chart symbol's live spread (`Ask - Bid`). The spread is recalculated from the refreshed quote immediately before sending. A jump beyond that current spread cancels the plan and logs the reason in Experts. The EA does not chase the missed trade or wait for a later return to its entry. There is no fixed distance input, and spread is not cached when the trade is armed. Older cached plans also use this live-spread rule.

Lots are recalculated from the saved money budget and current quote-to-saved-SL distance, rounded down to the broker's volume step. SL stays fixed. TP is recalculated from that quote and SL to preserve the saved RR before submission. Actual lots/TP may therefore differ from the original cached preview. Broker fill slippage after submission can still alter actual risk/RR; this feature controls the EA's accepted quote, not a guaranteed final fill.

A rejected/invalid entry cancels its plan. A delayed/uncertain outcome shows CHECK TRADE / HISTORY and is never automatically resent. Cancel is available only while waiting, before a market request starts; it cannot undo a submitted market order. Active matching broker trades are used to reconcile uncertain outcomes.

The terminal, EA, connection and Algo Trading must remain active for execution. If an entry reaches its trigger while trading is disabled, it is cancelled when that tick is processed. Removing the EA pauses its saved waiting trades until reattachment. On netting accounts, a new plan cannot be armed/executed if a position already exists on the symbol, avoiding combined-position risk. Hedging accounts support separate trades per rectangle.

Older broker pending orders are preserved and continue to be managed; the update does not replace/cancel them.

## Inputs

| Input | Source default | Meaning |
| --- | --- | --- |
| `RiskMoney` | `20.0` | Maximum estimated SL loss in account currency |
| `RR` | `2.0` | Reward/risk for new plans |
| `IsPartialProfit` | `true` | Enable one-time partial profit |
| `PartialLevelRR` | `1.0` | Partial trigger in initial R multiples |
| `PartialPercentage` | `60.0` | Percentage to close, accepted range 50-80 |
| `IsBEAfterPartial` | `true` | Move remaining SL to entry after partial |

The entry tolerance is always one current spread in price units. For example, Ask 100.20 and Bid 100.00 allow a 0.20 entry distance; if the spread shrinks to 0.10 before submission, the refreshed check uses 0.10. A zero spread requires an exact quote. Requested execution deviation is the latest spread converted to whole symbol points. Money is in account deposit currency. Entry, SL, risk budget and RR are frozen when armed; changes affect new plans. Partial/BE inputs govern ongoing management. MT5 presets can override these source defaults.

## Partial profit and break-even

Only this EA's trades on the chart symbol are managed (magic `2026100601`). Initial R uses the entry SL from history, falling back to the SL at first tracking, and is saved along with entry and starting volume. Positions without a usable initial SL are skipped. Original R does not change after an SL modification.

Partial lots use the configured starting-volume percentage, round down to the broker's lot step, and leave at least the minimum tradable remainder. Too-small trades, TP at/before the partial level, mixed-ownership netting positions and positions scaled after tracking begins are skipped. IOC may execute less than requested; that still counts as the one partial event.

The partial line/text is ash (`clrDarkGray`), dash-dot, width 1. The small label aligns like the reference TP/SL captions and reads `PR 0.09 5.32`: calculated closing lots and estimated trigger profit, each shown to two decimals, excluding fees/swaps. Waiting estimates use planned entry/volume; open estimates use the actual saved entry/risk/volume.

After a partial executes, its line/label are removed. If enabled, remaining SL moves to actual entry rounded to tick size; TP is preserved and a more protective SL is never loosened. Break-even excludes fees/swaps. Rejected partials and temporarily blocked BE changes retry after 10 seconds. Uncertain partials are not blindly resent. Completion persists across ordinary restarts. Re-enabling partial profit does not reset an already completed partial; BE requires partial management enabled.

## Cleanup and validation

Deinitialization removes only EA panels/markings, keeping rectangles, broker trades and saved state. Waiting markers return on restart. Cancel affects cached waiting trades, not open positions or older broker pending orders.

Rectangle-to-broker links persist across ordinary restarts. Older untagged trades are recovered from original entry/SL geometry when it still matches; moved/renamed legacy rectangles cannot be reliably associated retroactively.

Compilation: **0 errors, 0 warnings** (`RectanglePendingEA.compile.log`). `python verify_math.py` covers actual source expressions for upper/lower buy/sell levels, trigger directions, live/shrinking/zero-spread boundaries, RR, partial/BE math, lot rounding and legacy geometry. Live rendering, restart persistence and broker execution remain untested in an account.
