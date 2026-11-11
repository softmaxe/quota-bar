# Maintaining the price book

Claude and OpenAI models that are on their makers' current price lists and still supported are priced from [`price-book.json`](../Sources/QuotaBarCore/Resources/Pricing/price-book.json), kept by hand. Every other model, retired Claude and OpenAI models included, is priced from models.dev through a local cache (see [Models outside the book](#models-outside-the-book)). Cost is computed from stored tokens each time it is read, so editing the book reprices recorded usage as soon as the new build runs. Rates, aliases, and supported per-request long-context tiers are resolved again; rows without a saved request context retain their stored tier. See [Historical thresholds](#historical-thresholds).

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

Providers are `codex` (OpenAI models, including OpenCode and Pi Agent usage) and `claude`. Do not add other vendors' models or retired models here: models.dev prices them, and a model the book lists is never priced from models.dev.

A model has these keys:

- `id` is the name scanners store: lowercase, with no date suffix or vendor prefix. `RateCard.modelID(for:provider:)` must return it unchanged.
- `aliases` lists other names for the same model. Usage is stored under the name the log reported; aliases resolve to `id` when it is read, so an alias added later still prices earlier usage.
- `showInSettings` lists the model in the pricing settings before it appears in local logs.
- `source`, `checkedAt` and `note` are optional. Use them when a model's price comes from a different page than the provider's, or when the numbers need explaining.

A period has these keys:

- `from` is the first Gregorian day in the local time zone (`yyyy-MM-dd`) the rates apply to, regardless of the system calendar. Recording and query bounds use the same day keys. The first period has no `from` and covers every earlier day. Later periods need one, in ascending order.
- `rates` are USD per million tokens. `input` and `output` are required. `cacheWrite` is the five-minute rate. Leave `cacheWrite1h` out when it is 2x input, which is Anthropic's published ratio. Rates ending in `Above` need `thresholdTokens`. The third-party rates cache uses the same keys and rules.
- `fastMultiplier` prices Fast usage as that multiple of every rate in the period, cache rates included. It covers Codex's priority tier and Claude's Fast mode (`usage.speed: "fast"` in Claude Code transcripts). Leave it out and Fast usage of the model stays unpriced. Use `1` for a model that accepts Fast requests but bills them at Standard rates, such as Claude Opus 4.6.

## Common changes

**New model.** Add an entry with one period and no `from`. Add `showInSettings` if it should appear in settings before anyone uses it.

**Price change.** Add a period whose `from` is the day the new price took effect. Leave the old period alone, so usage before that day keeps the old price.

**Promotion with an end date.** Add the period that follows it as soon as the end date is confirmed. Usage after that date then gets the regular price without another release.

**Wrong rate.** Fix it in place. Every recorded day it covered is repriced.

**Model is retired.** Delete its entry. All of its recorded usage is then priced from models.dev, whose rates cover no Fast tier, and stays unpriced if models.dev does not list it.

After any edit, update `checkedAt` for the provider or model you compared, then run:

```bash
make test
```

`PriceBookTests` loads the bundled book and fails on unknown keys, missing rates, unordered periods, duplicate names, or a listed model with no price today. It pins historical rates on 2026-09-25, the additions checked on 2026-11-11, and the GPT-5.6 Sol promotion ending on 2026-11-30, including Fast and long-context rates. Editing an old period fails; adding a new period does not. It prints a note when a provider was last checked more than 45 days ago.

## Models outside the book

Models the book does not list, such as DeepSeek, GLM, or Kimi used through Codex or Claude Code and retired or not-yet-listed Claude and OpenAI models, are priced from [models.dev](https://models.dev). Nothing about them is maintained in this repository.

- The app downloads `https://models.dev/api.json` at most once a day, alongside a cost refresh, and folds it into `~/Library/Application Support/QuotaBar/third-party-rates.json`. A failed download is retried after an hour and leaves the cache alone.
- For each model it uses the maker's own listing when `canonical_model_id` names one, otherwise the middle price across every provider that lists it. A model listed only at zero stays unpriced.
- A model is matched by its name after the last `/`, ignoring case. A name models.dev does not list falls back to the same name without a trailing region tag (`-sg`, `-us`, `-eu`, `-cn`, `-global`, `@eu`, and so on; the list is in `ThirdPartyRates.regionSuffix`), so `deepseek-v4.1-flash-sg` is priced as `deepseek-v4.1-flash`. A listing under the regional name wins. Other suffixes, such as `-fast`, `-flex`, or `:thinking`, name different offers and do not fall back.
- The vendor part of `canonical_model_id` is cached beside the rates as the model's maker, and **Settings → Pricing** groups the model under it. A model with no canonical ID is grouped by the start of its name; the list is in `PricingVendor`, and anything else goes under **Other**.
- `context_over_200k` becomes a 200K long-context tier. Requests for models outside the book use the 200K threshold even before their rates are downloaded. Keyed rows with saved request context are classified again when read; aggregate-only rows keep their scan-time tier. There is no Fast tier.
- A model whose rates changed since the last fetch gets a new period starting that day, so earlier days keep their rates.
- A new Claude or OpenAI model is priced from models.dev until the book lists it. The book's rates replace models.dev for all of its usage from then on.
- The **models.dev** switch in **Settings → Pricing** turns this off. Usage of models outside the book is then unpriced and nothing is downloaded.

`ThirdPartyRatesTests` covers the parsing, the choice between listings, and the dated cache.

## Historical thresholds

Claude messages, OpenCode parts, and Pi messages now save a nullable `context_input INTEGER`: the individual request's `input + cacheRead + cacheWrite`. Output does not set this tier, and `cacheWrite1h` is already a subset of `cacheWrite`, so it is not added again. The stored `long_context` flag remains available as a fallback.

When the menu or usage report reads rows with `context_input`, it classifies them using the current rate card, resolved model or alias, recorded day, and Fast flag. A request is long-context only when its context input strictly exceeds that day's threshold. For example, a 250K request recorded while its model was unlisted initially uses the default 200K threshold; a later alias to a model with a 272K threshold makes that request base-tier when read. The stored day and tokens do not change. A listed model with no applicable threshold has no long-context tier; unlisted Standard models retain the models.dev 200K rule, and unlisted Fast models have no applicable threshold.

The reader keeps aggregation in SQL. It groups context input by the finite threshold boundaries used by the provider's current price book plus the models.dev threshold, with separate buckets for legacy base and long-context rows. It does not group by every distinct input count or load every request into Swift. Each bucket's lower bound suffices for the model's dated tier decision; pricing then merges aliases and buckets into one row per day/source/model/tier/Fast combination. Existing day indexes still bound the scan. See [Performance validation](performance.md#read-time-context-tiers).

Opening an older database adds the column to `claude_message`, `opencode_part`, and `pi_message` without backfilling it or resetting scan cursors. All existing rows start with NULL and keep using their stored tier, even if their token columns could suggest another one. Unchanged request replays do not fill the new column. An ordinary content update accepted by the existing merge rule saves a new context measurement with that updated usage; it is not a historical rescan. There is no automatic log backfill, and pricing never rewrites stored rows.

Codex is the aggregate-only exception. Its per-path/day/model/tier/Fast rows do not retain individual request sizes, so both old and newly recorded Codex rows keep their stored tier. A daily input sum must never be classified as one request. The change adds no Codex request identity or context column. Its time-zone rewrite and backup replacement behavior is documented in [Historical time zones](usage-report.md#historical-time-zones).

Backup export and import preserve the nullable context values. An old backup is upgraded in a staging copy before merging, leaving its request context NULL and its stored tiers intact; the selected backup file is untouched. An older app can reject a backup containing this new column as `UsageBackupError.newerVersion` through `requireKnownSchema()`, which is the existing compatibility rule.
