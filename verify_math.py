"""Offline regressions execute arithmetic expressions taken from the actual MQL source.

This checks math boundaries without connecting to an account or sending orders.
It does not emulate MetaTrader's order execution or terminal-global persistence.
"""
import math
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent
ea = (ROOT / "RectanglePendingEA.mq5").read_text()
partial = (ROOT / "PartialProfit.mqh").read_text()
markers = (ROOT / "PartialMarkers.mqh").read_text()
links = (ROOT / "RectangleTrades.mqh").read_text()


def expression(source, name):
    return re.search(r"(?:double|bool) " + name + r"=([^;]+);", source).group(1)


def run(expr, **values):
    expr = expr.strip()
    expr = expr.replace("&&", " and ").replace("||", " or ")
    if expr.startswith("TickPrice("):
        price, tick = expr[len("TickPrice("):-1].rsplit(",", 1)
        return round(math.floor(run(price, **values) / run(tick, **values) + 0.5) * run(tick, **values), 8)
    if "?" in expr:
        condition, rest = expr.split("?", 1)
        yes, no = rest.split(":", 1)
        expr = yes if run(condition, **values) else no
    return eval(expr, {"__builtins__": {}}, {
        "MathMin": min, "MathFloor": math.floor,
        "MathAbs": abs,
        "NormalizeDouble": round,
        "TickPrice": lambda price, tick: round(math.floor(price / tick + 0.5) * tick, 8),
        **values,
    })


# Pending-order branch and level expressions are read directly from the source.
def order_levels(buy, current, rr=2):
    inputs = dict(buy=buy, current=current, bottom=100, top=110, height=10, RR=rr, tick_size=0.01)
    for name in ("stop_entry", "is_limit", "within_rectangle", "inside_entry", "outside_limit_entry", "limit_entry", "entry", "valid_limit", "tp", "stop_sl", "outside_limit_sl", "limit_sl", "sl"):
        inputs[name] = run(expression(ea, name), **inputs)
    return inputs


for buy, current, limit, entry, sl, tp in [
    (True, 90, False, 100, 90, 120),   # Buy Stop
    (True, 120, True, 110, 100, 130),  # Buy Limit
    (False, 120, False, 110, 120, 90), # Sell Stop
    (False, 90, True, 100, 110, 80),   # Sell Limit
    (True, 105, True, 100, 90, 120),   # Buy Limit inside rectangle
    (False, 105, True, 110, 120, 90),  # Sell Limit inside rectangle
    (True, 110, True, 100, 90, 120),   # Ask at top: bottom remains a valid Buy Limit
    (False, 100, True, 110, 120, 90),  # Bid at bottom: top remains a valid Sell Limit
]:
    levels = order_levels(buy, current)
    assert (levels["is_limit"], levels["entry"], levels["sl"], levels["tp"]) == (limit, entry, sl, tp)
    if limit:
        assert levels["valid_limit"]

# Entry at the current quote still cannot produce a pending order.
for buy, current in [(True, 100), (False, 110)]:
    assert order_levels(buy, current)["stop_entry"] == current

for rr in (1, 2, 3):
    for buy, current in [(True, 90), (True, 120), (False, 120), (False, 90), (True, 105), (False, 105)]:
        levels = order_levels(buy, current, rr)
        assert abs(levels["tp"] - levels["entry"]) / abs(levels["sl"] - levels["entry"]) == rr

# Verify executable exit-side prices: a Buy exits at Bid and a Sell exits at Ask.
marker_level_expr = re.search(r"return (buy \? entry\+risk\*PartialLevelRR[^;]+);", markers).group(1)
for buy, entry, risk, partial_rr, expected in [
    (True, 100, 10, 1, 110),
    (False, 110, 10, 1, 100),
    (True, 100, 10, 0.5, 105),
    (False, 110, 10, 0.5, 105),
]:
    assert run(marker_level_expr, buy=buy, entry=entry, risk=risk, PartialLevelRR=partial_rr) == expected

# A break-even update must not loosen a stop already protecting entry or a profit.
be_expr = re.search(r"return (buy \? sl>=entry-tolerance[^;]+);", partial).group(1)
for buy, sl, expected in [(True, 90, False), (True, 100, True), (True, 105, True),
                           (False, 110, False), (False, 100, True), (False, 95, True)]:
    assert run(be_expr, buy=buy, sl=sl, entry=100, tolerance=1e-8) == expected

movement_expr = expression(partial, "movement").replace("quote.bid", "bid").replace("quote.ask", "ask")
for buy, entry, bid, ask, expected in [
    (True, 100, 109.9, 110.1, 9.9),
    (True, 100, 110, 110.2, 10),
    (False, 110, 99.8, 100, 10),
    (False, 110, 99.9, 100.1, 9.9),
]:
    assert math.isclose(run(movement_expr, buy=buy, entry=entry, bid=bid, ask=ask), expected)

helper = partial.split("double PartialCloseVolume(", 1)[1].split("// Read the original SL", 1)[0]
cap_expr = expression(helper, "cap")
volume_expr = expression(helper, "volume")
cases = [
    (0.10, 0.10, 50, 0.01, 100, 0.01, 0.05),
    (0.10, 0.10, 80, 0.01, 100, 0.01, 0.08),
    (0.03, 0.03, 50, 0.01, 100, 0.01, 0.01),
    (0.02, 0.02, 80, 0.01, 100, 0.01, 0.01),
    (0.10, 0.03, 80, 0.01, 100, 0.01, 0.02),
    (2.00, 2.00, 80, 0.01, 1.00, 0.01, 1.00),
    (0.50, 0.50, 50, 0.10, 100, 0.10, 0.20),
]
for original, current, percentage, minimum, maximum, step, expected in cases:
    inputs = dict(original=original, current=current, percentage=percentage,
                  minimum=minimum, maximum=maximum, step=step)
    cap = run(cap_expr, **inputs)
    volume = run(volume_expr, cap=cap, **inputs)
    assert math.isclose(volume, expected), (inputs, volume, expected)
    assert current - volume >= minimum - 1e-10
    assert math.isclose(volume / step, round(volume / step))

# Execute the actual guards for unsplittable positions.
guards = re.findall(r"if\((.*?)\) return 0;", helper)
for current in (0.01, 0.015):
    inputs = dict(original=current, current=current, percentage=50, minimum=0.01,
                  maximum=100, step=0.01, volume=0)
    guard = guards[0].replace("||", " or ")
    assert run(guard, **inputs)

# Legacy recovery must match the original entry AND SL, not just a nearby trade price.
legacy_expr = re.search(r"return (\(MathAbs\(entry-stop_entry\).*?);", links, re.S).group(1)
for buy, entry, sl, expected in [
    (True, 100, 90, True), (True, 110, 100, True),
    (False, 110, 120, True), (False, 100, 110, True),
    (True, 100, 95, False), (True, 105, 95, False),
    (False, 110, 115, False), (False, 105, 115, False),
]:
    values = dict(buy=buy, entry=entry, sl=sl, bottom=100, top=110, height=10, tolerance=0.001)
    for name in ("stop_entry", "stop_sl", "limit_entry", "limit_sl"):
        values[name] = run(expression(links, name), **values)
    assert run(legacy_expr.replace("\n", " "), **values) == expected

print("Passed: pending-order branches, RR examples, partial marker levels, break-even protection, exit-quote triggers, volume steps, percentage endpoints, minimum remainders, tiny-position guards and legacy rectangle matching.")
