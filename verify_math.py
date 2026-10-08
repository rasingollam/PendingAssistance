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
entry_math = (ROOT / "VirtualEntryMath.mqh").read_text()


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
        "MathMin": min, "MathMax": max, "MathFloor": math.floor,
        "MathAbs": abs,
        "NormalizeDouble": round,
        "TickPrice": lambda price, tick: round(math.floor(price / tick + 0.5) * tick, 8),
        **values,
    })


def function_return(source, name):
    body = source.split(name + "(", 1)[1].split("{", 1)[1].split("}", 1)[0]
    return re.search(r"return ([^;]+);", body).group(1)


selected_expr = function_return(entry_math, "SelectedEntryPrice")
sl_expr = function_return(entry_math, "VirtualStopPrice")
tp_expr = function_return(entry_math, "VirtualTargetPrice")
reached_expr = function_return(entry_math, "VirtualEntryReached")
allowed_expr = function_return(entry_math, "VirtualEntryAllowed")
spread_expr = function_return(entry_math, "LiveEntrySpread")

# A missed crossing can return to the eligible side and execute once, for either direction.
for rising, quotes in [(True, [99.5, 100.5, 100.3, 99.9, 100.05]),
                        (False, [100.5, 99.5, 99.7, 100.1, 99.95])]:
    eligible = [run(reached_expr, rising=rising, current=quote, entry=100) and
                run(allowed_expr, current=quote, entry=100, spread=0.1, tolerance=1e-8)
                for quote in quotes]
    assert eligible == [False, False, False, False, True]

# Regression: neither pre-send distance guard may cancel the saved waiting plan.
virtual = (ROOT / "VirtualTrades.mqh").read_text()
distance_guards = re.findall(r"if\(!VirtualEntryAllowed\([^\n]+\)\)\s*([^\n]+)", virtual)
assert len(distance_guards) == 2
assert all(guard.strip().startswith("return;") for guard in distance_guards)
rejection = virtual.split("MarkRectangleUncertain(index,false);", 1)[1].split("void ProcessVirtualEntries", 1)[0]
assert "SetVirtualState(index,1);" in rejection
assert "ReportVirtualRetry(" in rejection
assert ".VRetry" not in virtual

for buy, upper, expected_entry, expected_sl, expected_tp in [
    (True, True, 110, 100, 130), (True, False, 100, 90, 120),
    (False, True, 110, 120, 90), (False, False, 100, 110, 80),
]:
    entry = run(selected_expr, upper=upper, bottom=100, top=110)
    sl = run(sl_expr, buy=buy, entry=entry, height=10)
    tp = run(tp_expr, buy=buy, entry=entry, risk=10, reward_rr=2)
    assert (entry, sl, tp) == (expected_entry, expected_sl, expected_tp)

for rising, quote, expected in [
    (True, 99.9, False), (True, 100, True), (True, 100.2, True),
    (False, 100.1, False), (False, 100, True), (False, 99.8, True),
]:
    assert run(reached_expr, rising=rising, current=quote, entry=100) == expected

# A live 0.20 spread allows +/-0.20 around entry, but rejects larger jumps.
live_spread = run(spread_expr, ask=100.20, bid=100.00)
for quote, expected in [(100, True), (100.05, True), (100.20, True), (99.80, True),
                        (100.21, False), (99.79, False), (100.30, False)]:
    assert run(allowed_expr, current=quote, entry=100, spread=live_spread, tolerance=1e-8) == expected
assert run(allowed_expr, current=100, entry=100, spread=0, tolerance=1e-8)
assert not run(allowed_expr, current=100.01, entry=100, spread=0, tolerance=1e-8)
# The same 0.15 entry distance becomes ineligible when the current spread shrinks to 0.10.
for ask, bid, expected in [(100.15, 99.95, True), (100.15, 100.05, False)]:
    spread = run(spread_expr, ask=ask, bid=bid)
    assert run(allowed_expr, current=ask, entry=100, spread=spread, tolerance=1e-8) == expected

# Execution TP uses the current quote and saved SL, retaining requested RR.
for buy, quote, sl in [(True, 100.05, 90), (False, 99.95, 110)]:
    risk = abs(quote - sl)
    for rr in (1, 2, 3):
        tp = run(tp_expr, buy=buy, entry=quote, risk=risk, reward_rr=rr)
        assert math.isclose(abs(tp - quote) / risk, rr)

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

print("Passed: upper/lower buy/sell levels, rising/falling triggers, live-spread and shrinking/zero-spread boundaries, execution RR, partial markers, break-even, exit quotes, lot steps/remainders and legacy matching.")
