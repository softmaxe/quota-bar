# Maintaining the price book

Claude and OpenAI models are priced from [`price-book.json`](../Sources/QuotaBarCore/Resources/Pricing/price-book.json), kept by hand. Every other model is priced from models.dev through a local cache (see [Third-party models](#third-party-models)). Cost is computed from stored tokens each time it is read, so editing the book reprices recorded usage as soon as the new build runs.

## Layout

```json
{
  "schemaVersion": 1,
  "providers": {
    "codex": {
      "source": "https://developers.openai.com/api/docs/pricing",
      "checkedAt": "2026-08-26",
      "models": [
        {
          "id": "gpt-5.6-sol",
          "aliases": ["gpt-5.6"],
          "showInSettings": true,
          "note": "Why the numbers look the way they do.",
          "periods": [
            {
              "rates": { "input": 4, "output": 20, "cacheWrite": 5, "cacheRead": 0.4,
                         "thresholdTokens": 272000, "inputAbove": 8, "outputAbove": 30 },
              "fastMultiplier": 2
            },
            { "from": "2026-11-22", "rates": { "input": 5, "output": 30 } }
          ]
        }
      ]
    }
  }
}
```

Providers are `codex` (OpenAI models, including OpenCode and Pi Agent usage) and `claude`. Do not add other vendors' models here: models.dev prices them, and a model the book lists is never priced from models.dev.

A model has these keys:

- `id` is the name scanners store: lowercase, with no date suffix or vendor prefix. `RateCard.modelID(for:provider:)` must return it unchanged.
- `aliases` lists other names for the same model. They resolve to `id` before usage is stored.
- `showInSettings` lists the model in the pricing settings before it appears in local logs.
- `retired` marks a model that is no longer on the provider's price list. Keep retired models so older usage stays priced.
- `source`, `checkedAt` and `note` are optional. Use them when a model's price comes from a different page than the provider's, or when the numbers need explaining.

A period has these keys:

- `from` is the first local day (`yyyy-MM-dd`) the rates apply to. The first period has no `from` and covers every earlier day. Later periods need one, in ascending order.
- `rates` are USD per million tokens. `input` and `output` are required. `cacheWrite` is the five-minute rate. Leave `cacheWrite1h` out when it is 2x input, which is Anthropic's published ratio. Rates ending in `Above` need `thresholdTokens`. The third-party rates cache uses the same keys and rules.
- `fastMultiplier` prices Fast usage as that multiple of every rate in the period, cache rates included. It covers Codex's priority tier and Claude's Fast mode (`usage.speed: "fast"` in Claude Code transcripts). Leave it out and Fast usage of the model stays unpriced. Use `1` for a model that accepts Fast requests but bills them at Standard rates, such as Claude Opus 4.6.

## Common changes

**New model.** Add an entry with one period and no `from`. Add `showInSettings` if it should appear in settings before anyone uses it.

**Price change.** Add a period whose `from` is the day the new price took effect. Leave the old period alone, so usage before that day keeps the old price.

**Promotion with an end date.** Add the period that follows it as soon as the end date is confirmed. Usage after that date then gets the regular price without another release.

**Wrong rate.** Fix it in place. Every recorded day it covered is repriced.

**Model leaves the price list.** Set `retired` and remove `showInSettings`. Do not delete the entry.

After any edit, update `checkedAt` for the provider or model you compared, then run:

```bash
make test
```

`PriceBookTests` loads the bundled book and fails on unknown keys, missing rates, unordered periods, duplicate names, or a listed model with no price today. It also pins the published rates of the current models on 2026-09-25, so editing an old period fails; a new period does not. It prints a note when a provider was last checked more than 45 days ago.

## Third-party models

Models the book does not list, such as DeepSeek, GLM, or Kimi used through Codex or Claude Code, are priced from [models.dev](https://models.dev). Nothing about them is maintained in this repository.

- The app downloads `https://models.dev/api.json` at most once a day, alongside a cost refresh, and folds it into `~/Library/Application Support/QuotaBar/third-party-rates.json`. A failed download is retried after an hour and leaves the cache alone.
- For each model it uses the maker's own listing when `canonical_model_id` names one, otherwise the middle price across every provider that lists it. A model listed only at zero stays unpriced.
- A model is matched by its name after the last `/`, ignoring case. A name models.dev does not list falls back to the same name without a trailing region tag (`-sg`, `-us`, `-eu`, `-cn`, `-global`, `@eu`, and so on; the list is in `ThirdPartyRates.regionSuffix`), so `deepseek-v4.1-flash-sg` is priced as `deepseek-v4.1-flash`. A listing under the regional name wins. Other suffixes, such as `-fast`, `-flex`, or `:thinking`, name different offers and do not fall back.
- The vendor part of `canonical_model_id` is cached beside the rates as the model's maker, and **Settings → Pricing** groups the model under it. A model with no canonical ID is grouped by the start of its name; the list is in `PricingVendor`, and anything else goes under **Other**.
- `context_over_200k` becomes a 200K long-context tier. Third-party requests are classified against 200K at scan time even before their rates are downloaded. There is no Fast tier.
- A model whose rates changed since the last fetch gets a new period starting that day, so earlier days keep their rates.
- Names containing `claude` or `gpt-`, starting with `chatgpt-`, `codex-`, `o<digit>`, or a vendor prefix such as `openai-` or `us.anthropic.`, and models whose maker is OpenAI or Anthropic, are never priced from models.dev. A new Claude or OpenAI model stays unpriced until the book lists it.
- The **models.dev** switch under **Settings → General → Price sources** turns this off. Third-party usage is then unpriced and nothing is downloaded.

`ThirdPartyRatesTests` covers the parsing, the choice between listings, and the dated cache.
