# Derive cost from a dated price book

QuotaBar stores only token counts and computes cost each time usage is read. The rates come from a bundled price book, `Sources/QuotaBarCore/Resources/Pricing/price-book.json`, where every model lists its rates in dated periods. User overrides sit on top and apply to every day.

Up to 1.0.7, each row's cost was computed at scan time and frozen in SQLite, and a models.dev catalog fetched at runtime sat between the overrides and a Swift rate table. Two problems made us drop both:

- Freezing made mistakes permanent. Usage of a model scanned before its price shipped stayed unpriced forever. On one real database that was 92M Claude Opus 5.5 tokens. A wrong rate could not be corrected either.
- The catalog never worked. Its parser expected a `providers` key that `models.dev/api.json` does not have, so every fetch was discarded. A fixed parser would still have mixed reseller prices into the table, and it read a 200K long-context threshold where OpenAI uses 272K.

## Considered options

- **Keep frozen costs and add a reprice step for unpriced rows.** This fixes the unpriced case only. Wrong rates stay wrong, and two code paths would disagree about how cost is computed.
- **Fix the models.dev parser and keep it as a fallback.** This keeps an unreviewed network source in the billing path. With costs derived at read time, a bad catalog entry would also rewrite every past day at once.

## Consequences

- A past day keeps its old price only if the book has a period for it. When a provider changes a price, add a period starting on the change date. Do not edit the old rates.
- Saving an override reprices all recorded usage of that model. The pricing settings say so.
- The long-context tier is still decided at scan time, because it depends on each request's size and rows are aggregated per day. A model scanned before the book knew its threshold stays at the base tier.
- The schema migration drops `cost_usd` and `unpriced_tokens`. An older release opening the migrated database cannot write OpenCode or Pi Agent rows until it is upgraded again.
