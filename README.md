# RectanglePendingEA

Compiled with `D:\Trading\MetaEditor64.exe`, the compiler supplied with your running `D:\Trading\terminal64.exe` installation. The compiled EA is `RectanglePendingEA.ex5` in this folder.

## Usage

1. In MetaTrader 5, refresh Navigator > Expert Advisors.
2. Attach PendingAssistance > RectanglePendingEA to a chart and enable Algo Trading and EA trading permissions.
3. Set `RiskMoney` (default `10.0`) in the account's deposit currency. A USD account uses dollars. Configure RR and partial profit using the inputs below.
4. Draw a standard Rectangle on the main price chart, or use an existing rectangle. Select the rectangle to display Buy, Sell and Close inside it; deselect it to hide the buttons.
5. Click Buy or Sell once to submit a pending order. Buttons are hidden while that rectangle has a linked pending order or open position. After cancellation, expiry or full position closure, selecting the rectangle shows Buy, Sell and Close again. Deselecting always hides its buttons. A partial close does not restore buttons while a remainder is still open.

Rectangle-to-order links are saved across ordinary EA/terminal restarts, keyed by account, symbol and rectangle name. An executed order is followed through its position identifier, including netting accounts. New orders have a rectangle-specific comment. Existing orders from earlier EA versions are recovered from their original entry/SL prices when these still match the rectangle; moved/renamed older rectangles cannot be reliably associated retroactively. A submission with an uncertain outcome keeps its controls hidden until an active matching trade is recovered; inspect Trade/History before retrying. The rectangle remains until you delete it.

The controls appear only inside selected rectangles and disappear when a rectangle is deselected. During a selected rectangle's drag, mouse events update the button positions, with timer updates as a fallback. Controls leave an 8-pixel inset for selection handles. The visible selected rectangle must be at least about 106 × 32 pixels to fit the controls; enlarge it or zoom in if no buttons appear. Rectangles in indicator subwindows are not used for orders.

## Order rules

Rectangle anchors may be drawn in either direction. Prices are rounded to the symbol's tradable tick size.

| Button | Entry | TP | SL | Pending order type |
| --- | --- | --- | --- | --- |
| Buy Stop | Bottom | Bottom plus height × RR | Bottom minus height | Rectangle above Ask |
| Buy Limit | Top | Top plus height × RR | Bottom | Rectangle below Ask |
| Buy Limit, Ask inside rectangle | Bottom | Bottom plus height × RR | Bottom minus height | Bottom < Ask <= Top |
| Sell Stop | Top | Top minus height × RR | Top plus height | Rectangle below Bid |
| Sell Limit | Bottom | Bottom minus height × RR | Top | Rectangle above Bid |
| Sell Limit, Bid inside rectangle | Top | Top minus height × RR | Top plus height | Bottom <= Bid < Top |

Entry equal to the applicable current quote is rejected, because neither pending-order condition applies. SL remains one rectangle height from entry. At RR = 2, TP is two rectangle heights from entry, beyond the opposite rectangle edge. Tradable tick rounding can slightly change the actual RR.

When Ask is inside the rectangle, Buy Limit uses the bottom as entry and SL one height below the bottom. When Bid is inside the rectangle, Sell Limit uses the top as entry and SL one height above the top. If the rectangle is entirely below Ask, Buy Limit uses the top with SL at bottom; if entirely above Bid, Sell Limit uses the bottom with SL at top. Buy at Ask equal to the bottom, or Sell at Bid equal to the top, is rejected because entry equals the current quote. Broker minimum stop-distance checks still apply.

## RR and partial-profit inputs

| Input | Default | Meaning |
| --- | --- | --- |
| `RR` | `2.0` | TP distance divided by SL distance for new orders |
| `IsPartialProfit` | `true` | Enable automatic partial closing of open positions |
| `PartialLevelRR` | `1.0` | Trigger at this multiple of the initial entry-to-SL distance |
| `PartialPercentage` | `50.0` | Percent of tracked starting volume to close; accepted range 50–80 |
| `IsBEAfterPartial` | `true` | Move the remaining position's SL to entry after a partial close |

For example, a Buy Stop rectangle from 100 to 110 creates entry 100, SL 90 and TP 120 at RR = 2. At 1R (Bid 110), the EA requests a 50% partial close. With `IsBEAfterPartial = true`, it moves the remaining position's SL to entry 100 and keeps TP at 120. A Sell uses the mirrored calculation, with Ask as its exit quote.

The manager runs on ticks and the timer, for this EA's magic number on the attached chart symbol only. It includes trades already open when the updated EA starts. It preserves TP and only changes SL for the enabled break-even action after a partial. R uses the original entry SL from trade history, falling back to the SL present when tracking begins; that distance and entry are then saved. A position with no usable initial SL is skipped. The percentage uses volume present when tracking begins, so an existing manually reduced position uses its remaining volume as the starting volume.

Break-even is the position's entry price, rounded to the tradable tick size; it does not include commissions or swaps. An SL already at break-even or further into profit is preserved. If stop/freeze rules or a broker rejection prevent the modification, the EA retries after 10 seconds. Completion is saved across ordinary restarts, including partials taken before this version was installed. Set `IsBEAfterPartial = false` to keep the existing SL after partials. Break-even management requires partial-profit management to remain enabled.

The enabled partial level must be positive and below the RR input; each new order also checks its rounded TP RR. Existing positions whose TP is at or before the partial level are skipped and logged. In particular, trades from version 1.00 with a 1R TP need a partial level below 1R, or a manually adjusted farther TP, to take a partial before TP.

Close volume is rounded down to the broker's lot step and capped to leave at least the minimum tradable volume open. This can result in less than the configured percentage. Positions too small for both a valid partial and remainder are skipped. The EA supports hedging and netting through ticket-specific opposite closing deals. A netting position containing entries from manual trades or another EA is skipped; it cannot distinguish individual trades inside that combined position. Positions scaled or whose entry price changes after tracking begins are skipped.

Each position takes a single partial-close event. Completion and original risk/volume are saved in terminal global variables across ordinary restarts; trade history provides an additional recovery check. A reversal on a netting account begins a new tracking lifetime. Changing the percentage or disabling/re-enabling partial profit does not reset a completed partial. An IOC broker may execute less than the requested partial volume; that execution still counts as the one partial event.

Rejected close requests retry after 10 seconds while the trigger still holds. Delayed or uncertain close outcomes stay locked against another request and are reconciled using trade history/volume reduction. Inspect Trade/History if an uncertain outcome is logged. Close requests use the symbol's supported filling mode and a 20-point deviation allowance. Partial profit requires the EA and terminal to remain running with trading enabled; it is not a broker-side order.

## Partial-profit chart markers

While partial profit is enabled, eligible pending orders and open positions from this EA on the chart symbol have an ash (`clrDarkGray`) horizontal line at the partial trigger. It uses dash-dot style (`STYLE_DASHDOT`, dash-dot-dash) and width 1. Its compact 7-point Arial label uses the same ash color as the line and aligns 7 pixels from the left edge immediately above the line, matching the inset of the reference TP/SL captions. The format is `PR 0.09 5.32`, with no separator symbol. Both the actual rounded partial-close lots and the estimated profit display two decimal places. Currency and ticket details appear in the tooltip only.

The label uses the same rounded partial-close volume as the manager. Money is estimated profit for that volume from entry to the trigger price in account currency, excluding commissions, swaps and fees. Pending markers use the order's entry, SL and remaining volume. Open markers use the manager's saved entry, original risk and starting volume when available. Label positioning follows chart zoom/scale changes; labels are hidden when the level is offscreen.

After a partial executes, its line and label are removed, even while the remaining position is open or the break-even modification is awaiting retry. The line and label are also removed when the pending order is cancelled/expires or the open position closes fully. The pending marker is replaced by an open-position marker when the order fills. Markers are refreshed on trade events, ticks and the timer, including for existing EA orders/positions on startup. Disabling partial profit removes its markers. Ineligible trades, such as positions too small to split or having TP before the partial level, have no marker. The thin dash-dot style repeats dash, dot, dash, dot along the line.

Volume uses `OrderCalcProfit` to estimate the loss between entry and SL in account currency and rounds down to the broker's volume step. If the minimum lot size would exceed the budget, no order is sent. The broker's maximum lot size may make estimated risk smaller than the input. Fees, swaps, slippage, gaps and subsequent currency conversion changes can make realized loss differ from the estimate.

Orders use the chart symbol, magic number `2026100601`, and GTC expiry. Broker checks validate permissions, prices, stops, volume and margin. Errors appear as alerts and in the Experts log; controls remain for retry. For an ambiguous server timeout, controls are removed to prevent a duplicate submission: inspect Trade and History before placing another order.

## Rectangle removal

Close deletes that rectangle and its buttons. It does not cancel orders or close positions. After submission, the rectangle can still be deleted with MetaTrader's normal object controls.

Deinitialization removes the EA's buttons and partial-profit markers and preserves all chart rectangles. Removing the EA, changing its inputs, changing chart symbol/timeframe, recompiling an attached EA or closing the terminal can trigger this cleanup. Submitted orders, positions and saved partial-profit state remain. Partial markers are recreated for eligible trades when the EA restarts.

## Validation

Compilation succeeded with **0 errors and 0 warnings**; see `RectanglePendingEA.compile.log`. Offline arithmetic regression checks cover RR levels, buy/sell exit quotes and volume rounding/remainder limits. Chart interaction, persistence across live restarts and broker order execution have not been tested in a running account.
