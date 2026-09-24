# Maintaining the price book

Every cost QuotaBar shows comes from [`price-book.json`](../Sources/QuotaBarCore/Resources/Pricing/price-book.json) plus whatever the user has overridden in **Settings → Pricing**. Cost is computed from stored tokens each time it is read, so editing the book reprices recorded usage as soon as the new build runs. [ADR 0001](adr/0001-derive-cost-from-a-dated-price-book.md) explains why.

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

Providers are `codex` (OpenAI models, including OpenCode and Pi Agent usage) and `claude`.

A model has these keys:

- `id` is the name scanners store: lowercase, with no date suffix or vendor prefix. `RateCard.modelID(for:provider:)` must return it unchanged.
- `aliases` lists other names for the same model. They resolve to `id` before usage is stored.
- `showInSettings` lists the model in the pricing settings before it appears in local logs.
- `retired` marks a model that is no longer on the provider's price list. Keep retired models so older usage stays priced.
- `source`, `checkedAt` and `note` are optional. Use them when a model's price comes from a different page than the provider's, or when the numbers need explaining.

A period has these keys:

- `from` is the first local day (`yyyy-MM-dd`) the rates apply to. The first period has no `from` and covers every earlier day. Later periods need one, in ascending order.
- `rates` are USD per million tokens and use the same keys as the user override file. `input` and `output` are required. `cacheWrite` is the five-minute rate. Leave `cacheWrite1h` out when it is 2x input, which is Anthropic's published ratio. Rates ending in `Above` need `thresholdTokens`. The override file follows the same rules, and an override entry that breaks one is ignored.
- `fastMultiplier` prices Codex Fast usage as that multiple of every rate in the period. Leave it out and Fast usage of the model stays unpriced.

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

`PriceBookTests` loads the bundled book and fails on unknown keys, missing rates, unordered periods, duplicate names, or a listed model with no price today. It prints a note when a provider was last checked more than 45 days ago.
