# Price third-party models from models.dev and drop overrides

This partly supersedes [ADR 0001](0001-derive-cost-from-a-dated-price-book.md). Cost is still derived from stored tokens whenever usage is read, and the price book still prices Claude and OpenAI models. What changes is how other models get a price, and the user's overrides go away.

Codex and Claude Code are often pointed at other vendors' models, such as DeepSeek, GLM, Kimi, or MiMo. On one real database those models made up more than 1.3B tokens, and every one of them was unpriced. The book cannot keep up with that many vendors by hand, and overrides only helped users who typed the rates in themselves.

## Decision

- **Every cost is an estimate at API list prices.** No source is treated as authoritative. The book is not "exact" and models.dev is not "approximate"; they just cover different models.
- **The price book covers Claude and OpenAI models only, kept by hand.** A model the book lists is priced from the book on every day, even when models.dev also lists it. models.dev never prices a name that contains `claude` or `gpt-`, starts with `chatgpt-`, `codex-`, `o<digit>`, or a vendor prefix such as `openai-` or `us.anthropic.`, or whose `canonical_model_id` belongs to `openai` or `anthropic`. This holds even before the book lists a new model of theirs.
- **Every other model is priced from models.dev**, through a local cache in `~/Library/Application Support/QuotaBar/third-party-rates.json`:
  - The app downloads `models.dev/api.json` at most once a day, alongside a cost refresh, without holding the scan up. After a failed download it waits an hour before trying again, and the cache stays as it was.
  - models.dev lists a model under every provider that serves it. When the model's maker has its own listing, which `canonical_model_id` names, the maker's price is used. Otherwise the middle price of all listings is used, so one reseller's discount or markup does not set the estimate.
  - A model listed only at zero is left out, so its usage stays unpriced rather than costing nothing. Local and free models therefore stay unpriced.
  - Rates above 200K tokens (`context_over_200k`) become the Long-context tier. models.dev's other context tiers are not read. Because 200K is the only threshold models.dev describes, a third-party request is classified against it at scan time whether or not its rates have been downloaded; a model without long-context rates bills that tier at its base rates.
  - models.dev has no Fast tier, so Fast usage of a third-party model stays unpriced.
- **History comes from the cache.** models.dev publishes today's rates only. When a fetch sees a model's rates change, the cache opens a new period starting that day. The rates first seen cover every earlier day, and a model models.dev stops listing keeps its last rates. This is less precise than the book's periods, which is acceptable for an estimate.
- **The download can be turned off.** "Price other models with models.dev" in Settings → General is on by default. Turning it off makes third-party usage unpriced and stops the download. It keeps the cache.
- **Overrides are removed.** The pricing settings become a read-only table showing each model's rates and where they come from. On launch the app deletes the `pricing-overrides.json` an earlier version wrote.
- **Agent-reported cost is not read.** OpenCode and Pi Agent store a cost per message, but QuotaBar only records their OpenAI usage, which the book already prices, and that cost is zero under OAuth subscriptions. Reading third-party usage from those agents would need its own decision about which provider it counts toward.

## Why ADR 0001's objections no longer apply

- **The broken parser.** ADR 0001's catalog expected a `providers` key that `api.json` does not have. The new parser reads the top-level provider map and is tested against a fixture with the real shape.
- **Reseller prices.** Preferring the maker's own listing, and otherwise taking the middle price, keeps one reseller from setting the price.
- **The 200K vs 272K threshold.** That mistake came from letting models.dev price OpenAI models. It no longer prices any Claude or OpenAI model.
- **An unreviewed source rewriting history.** Costs are still derived at read time, but the cache only ever adds periods. A model's past days keep their rates even when today's fetch disagrees.

## Considered options

- **Keep overrides as a top layer.** Users would still have to find and type in every third-party rate. With models.dev covering those models, overrides mostly added a second way to be wrong. Removing them also removes the editor, its validation, and the quit-time save prompt.
- **Read agent-reported cost before models.dev.** Agent cost is a good source in principle, but under the current scope it never applies (see above).
- **Fetch models.dev without a local cache.** Every price change would then reprice all past usage, and the app would have nothing to fall back on offline.

## Consequences

- The app now makes one network request of its own, to `models.dev`, at most once a day while the setting is on.
- A third-party model's price can change without a release, and a past day keeps whatever rates this machine had seen for it on that day. Two machines can therefore disagree about the same day if they fetched at different times.
- A usage day before a machine's first fetch is priced at the first rates that machine saw.
- The Long-context tier of third-party usage is still decided at scan time, but against the fixed 200K threshold, so it does not depend on when rates were fetched. Usage scanned by an earlier version stays in the base tier.
