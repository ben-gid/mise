# mise

A Flutter app for saving LLM-generated recipes as validated JSON. Mobile and tablet first.

Paste a recipe JSON, it's checked against a JSON Schema before parsing, then stored as one
file per recipe on the device. Ingredients are referenced from steps by id (`{0001}`), so the
servings stepper rescales amounts live.

## Run

```bash
flutter run             # phone/tablet — the real target
flutter run -d linux    # desktop, only to eyeball a change
flutter test
flutter analyze
```

## Layout

- [lib/recipe/](lib/recipe/) — models, parser, store, scaling, UI. `main.dart` only wires it up.
- [assets/schemas/recipe_schema.json](assets/schemas/recipe_schema.json) — the recipe shape, source of truth.
- The import screen's "Copy prompt" button embeds that schema, so an LLM emits exactly what the validator accepts.

Changing the recipe shape means editing the schema, `recipe_models.dart`, and
`test/fixtures/valid/focaccia.json` together, then `dart run build_runner build`.
See [CLAUDE.md](CLAUDE.md) for the rest.

## Roadmap

Pro is a subscription that unlocks recipes written on the server. Everything that works
today — copy-prompt import, stock photos, scaling, units — stays free, and nobody is made
to sign up to use it. Each phase ships on its own.

### Phase 1 — Cook log

A version is cooked more than once, so it keeps a log rather than one rating.

- [X] Each version holds dated entries: servings, stars, note
- [X] "I made it" opens a new entry with today's date and the servings on screen
- [X] Headline stars are the newest entry that has stars
- [X] Old single ratings migrate as one entry
- [X] Picked photos shrink to 1600px before they're stored
- [X] Prompt: timers for timed stove work; common dish names allowed in `image_query`

### Phase 2 — Accounts

Supabase, anonymous by default: every install gets a user id with no sign-up screen.

- [X] Anonymous sign-in at launch, tolerant of being offline
- [X] Link Google in Settings, keeping the same user id (verified on Android)
- [X] Apple on iOS (verified on the simulator)
- [X] A second phone signing in with the same account switches to it
- [X] Sign out and Delete account, both keeping recipes on the phone
- [X] `profiles` table: `pro_until`, `free_tries_used`, created by trigger, owner-read only
- [X] Server verifies the Supabase token (`GET /me`, `DELETE /me`; `/photos` stays open)
- [X] No Supabase url at build time means no auth, so `flutter test` stays offline

### Phase 3 — Sync

Two-way, for signed-in users only, free. Local files stay the source of truth.

- [X] Tables for recipe versions (`parent_id`, `deleted_at`), cook entries and unit settings
- [X] `mise://` photos in Supabase Storage, one folder per user
- [X] Runs on launch, on resume and after every save; never blocks the screen
- [X] Deletes leave a `deleted_at` marker so they don't come back; Undo clears it
- [X] Two devices editing one version: the older edit moves into history, labelled
  "edited on another device"
- [X] First link uploads the whole library

### Phase 4 — Recipes from the server

One `POST /recipe` on the existing FastAPI service, on Claude Haiku 5.5.

- [X] Write from a sentence, adapt an existing recipe (saved as a new version, so the
  diff shows what changed), import from a URL or a cookbook photo — all one route
- [X] URLs read their schema.org Recipe data first, the page's text otherwise
- [X] Server built from the repo root, reading the live schema and one shared prompt file
  that both Copy buttons use too
- [X] `jsonschema` on the live schema plus the `{id}` reference check, at most two
  retries with the errors sent back; the phone still validates everything it receives
- [X] Shared valid/invalid fixtures that `flutter test` and `pytest` must agree on
- [X] Usage table recording each call's cost; five free tries per account, anonymous
  ones included, spent only by a recipe that passes
- [X] Haiku checked against real URLs and cookbook photos (`server/eval/`) before
  `/import` ships. URLs and text cases are in `server/eval/cases.json`; still to add
  are cookbook photos (`{"photo": "eval/photos/x.jpg"}`, relative to `server/`).
  Run where your key lives (real Haiku calls, a few cents):
  `cd server && ANTHROPIC_API_KEY=sk-ant-... uv run python -m eval.run`

### Phase 5 — Payments

Mise Pro: $4.99 a month or $49.99 a year, one `pro` entitlement in RevenueCat.

- [x] RevenueCat subscription with the Supabase user id as its app user id
- [x] The server asks RevenueCat when the free tries are gone and keeps the expiry in
      `pro_until`, rather than running a webhook
- [x] Paywall when the free tries run out, which retries the recipe after a purchase;
      Restore purchases; a Mise Pro panel in Settings
- [x] Pro is capped at 200 recipes a month, about $1 of model time
- [x] RevenueCat project `mise`: iOS and Android apps, `pro` entitlement, default
      offering with Monthly and Yearly packages
- [x] Subscriptions in App Store Connect (`mise_pro_monthly`, `mise_pro_annual`, one
      group)
- [ ] Subscriptions in the Play Console (`mise_pro` with `monthly` and `annual` base plans)
- [x] The In-App Purchase key in RevenueCat for iOS
- [ ] A Play service account in RevenueCat for Android
- [x] RevenueCat's v1 secret key in `server/.env` as `REVENUECAT_SECRET_KEY`, then
      `scripts/deploy.sh`
- [ ] Terms and Privacy links on the paywall, which App Review requires for a subscription
- [ ] The app built and run on a phone with `purchases_flutter` in it
- [ ] A sandbox purchase, a Restore after reinstalling, and the 200 cap verified on
  both phones

### Phase 6 — Ask me on a saved recipe

The Create page's question rounds, pointed at a recipe already in the library, to explore
a variation of it as a new version. Nothing decided yet.

- [ ] decide: where it starts, how many rounds, and what it costs
