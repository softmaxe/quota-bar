# QuotaBar

A macOS menu bar app that shows Codex and Claude quota and estimates API cost from local session logs.

## Pricing

**Price book**:
The list of published model rates that ships with the app, each model's rates split into dated periods.
_Avoid_: pricing table, catalog, built-in table

**Period**:
A span of days, starting on a given day, during which one set of rates applies to a model.
_Avoid_: price version, tier

**Override**:
A rate the user sets for a model in the pricing settings. It replaces the price book's Standard rates on every day.
_Avoid_: custom price, user price

**Unpriced usage**:
Recorded tokens whose model has no rate on their day. They count toward token totals but not toward cost.
_Avoid_: unknown cost, free usage

**Long-context tier**:
The higher rates a model charges when one request's input and cache tokens exceed its threshold.
_Avoid_: above-threshold pricing

**Fast**:
Codex's priority service tier, billed as a multiple of the period's Standard rates.
_Avoid_: priority tier
