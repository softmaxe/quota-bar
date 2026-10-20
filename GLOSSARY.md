# QuotaBar

A macOS menu bar app that shows Codex and Claude quota and estimates API cost from local session logs.

## Pricing

**Usage source**:
A local tool whose session logs QuotaBar reads token usage from: Codex, Claude Code, OpenCode, or Pi Agent. Each counts toward one provider's usage.
_Avoid_: scanner, log source, agent

**Recorded usage**:
Token usage saved from local sessions, attributed to its Usage source, model, and local-calendar day. The model is kept as the name the log reported, with vendor prefix and date suffix removed, and the Rate card resolves it to a model ID when read. Its Fast and Long-context tier attributes are retained, while cost is derived from the Rate card when read.
_Avoid_: stored cost, cached cost

**Price book**:
The list of Claude and OpenAI model rates that ships with the app, kept by hand, each model's rates split into dated periods.
_Avoid_: pricing table, catalog, built-in table

**Third-party rates**:
Rates for every model the price book does not cover, taken from models.dev and kept in a cache on this machine. A model's rates open a new period on the day a fetch first sees them change. Never used for a Claude or OpenAI model.
_Avoid_: catalog, fallback rates

**Period**:
A span of days, starting on a given day, during which one set of rates applies to a model.
_Avoid_: price version, tier

**Rate card**:
The price book with the third-party rates beside it: what every model costs on any given day, and the only place a rate is looked up. A model the price book lists is priced by the book alone. Every cost it gives is an estimate at API list prices.
_Avoid_: pricing overlay, effective pricing

**Priced usage**:
Recorded usage grouped under the model ID the Rate card resolves each recorded name to, with each row's cost at the rates in force on its day, or none when it is Unpriced usage. The menu and the usage report both total the same Priced usage.
_Avoid_: cost rows, aggregated cost

**Unpriced usage**:
Recorded tokens whose model has no rate on their day, including models that models.dev lists only for free and all third-party usage while models.dev pricing is off. They count toward token totals but not toward cost.
_Avoid_: unknown cost, free usage

**Long-context tier**:
The higher rates a model charges when one request's input and cache tokens exceed its threshold. Whether a request is in the tier is settled when it is scanned, against the rate card's threshold at that moment, and does not change when the threshold later does. A third-party model's threshold is always 200K tokens, the only tier models.dev describes, so its requests are classified even before its rates are downloaded.
_Avoid_: above-threshold pricing

**Fast**:
Codex's priority service tier or Claude's Fast mode, billed as a multiple of the period's Standard rates. Only the price book has Fast multipliers, so Fast usage of a third-party model is unpriced.
_Avoid_: priority tier

## Quota

**Refresh cooldown**:
The minute each provider waits after any refresh of its quota before the next one, whichever path asked: polling, opening the menu, switching providers, or the Refresh row. A server 429 holds every path until the server's retry date.
_Avoid_: throttle, debounce

**Credential recovery**:
One user-initiated repair of a provider credential the last refresh found expired or rejected. It may skip the Refresh cooldown, but never a server 429.
_Avoid_: force refresh, bypass
