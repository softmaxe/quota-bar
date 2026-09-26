# QuotaBar

A macOS menu bar app that shows Codex and Claude quota and estimates API cost from local session logs.

## Pricing

**Recorded usage**:
Token usage saved from local sessions, attributed to its producing tool, model, and local-calendar day. Its Fast and Long-context tier attributes are retained, while cost is derived from the Rate card when read.
_Avoid_: stored cost, cached cost

**Price book**:
The list of published model rates that ships with the app, each model's rates split into dated periods.
_Avoid_: pricing table, catalog, built-in table

**Period**:
A span of days, starting on a given day, during which one set of rates applies to a model.
_Avoid_: price version, tier

**Override**:
A rate the user sets for a model in the pricing settings. It replaces the price book's Standard rates on every day. An override that breaks the rules the price book's own rates must follow is ignored, and the price book's rates apply instead.
_Avoid_: custom price, user price

**Rate card**:
The price book with the user's overrides laid over it: what every model costs on any given day, and the only place a rate is looked up.
_Avoid_: pricing overlay, effective pricing

**Unpriced usage**:
Recorded tokens whose model has no rate on their day. They count toward token totals but not toward cost.
_Avoid_: unknown cost, free usage

**Long-context tier**:
The higher rates a model charges when one request's input and cache tokens exceed its threshold. Whether a request is in the tier is settled when it is scanned, against the rate card's threshold at that moment, and does not change when the threshold later does.
_Avoid_: above-threshold pricing

**Fast**:
Codex's priority service tier, billed as a multiple of the period's Standard rates.
_Avoid_: priority tier
