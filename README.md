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

- [x] Each version holds dated entries: servings, stars, note
- [x] "I made it" opens a new entry with today's date and the servings on screen
- [x] Headline stars are the newest entry that has stars
- [x] Old single ratings migrate as one entry
- [x] Picked photos shrink to 1600px before they're stored
- [x] Prompt: timers for timed stove work; common dish names allowed in `image_query`

### Phase 2 — Accounts

Supabase, anonymous by default: every install gets a user id with no sign-up screen.

- [x] Anonymous sign-in at launch, tolerant of being offline
- [x] Link Google in Settings, keeping the same user id (verified on Android)
- [x] Apple on iOS (verified on the simulator)
- [x] A second phone signing in with the same account switches to it
- [x] Sign out and Delete account, both keeping recipes on the phone
- [x] `profiles` table: `pro_until`, `free_tries_used`, created by trigger, owner-read only
- [x] Server verifies the Supabase token (`GET /me`, `DELETE /me`; `/photos` stays open)
- [x] No Supabase url at build time means no auth, so `flutter test` stays offline

### Phase 3 — Sync

Two-way, for signed-in users only, free. Local files stay the source of truth.

- [x] Tables for recipe versions (`parent_id`, `deleted_at`), cook entries and unit settings
- [x] `mise://` photos in Supabase Storage, one folder per user
- [x] Runs on launch, on resume and after every save; never blocks the screen
- [x] Deletes leave a `deleted_at` marker so they don't come back; Undo clears it
- [x] Two devices editing one version: the older edit moves into history, labelled
      "edited on another device"
- [x] First link uploads the whole library

### Phase 4 — Recipes from the server

One `POST /recipe` on the existing FastAPI service, on Claude Haiku 5.5.

- [x] Write from a sentence, adapt an existing recipe (saved as a new version, so the
      diff shows what changed), import from a URL or a cookbook photo — all one route
- [x] URLs read their schema.org Recipe data first, the page's text otherwise
- [x] Server built from the repo root, reading the live schema and one shared prompt file
      that both Copy buttons use too
- [x] `jsonschema` on the live schema plus the `{id}` reference check, at most two
      retries with the errors sent back; the phone still validates everything it receives
- [x] Shared valid/invalid fixtures that `flutter test` and `pytest` must agree on
- [x] Usage table recording each call's cost; five free tries per account, anonymous
      ones included, spent only by a recipe that passes
- [ ] Haiku checked against real URLs and cookbook photos (`server/eval/`) before
      `/import` ships

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
- [ ] Subscriptions in App Store Connect (`mise_pro_monthly`, `mise_pro_annual`, one
      group) and the Play Console (`mise_pro` with `monthly` and `annual` base plans)
- [ ] Store credentials in RevenueCat: the In-App Purchase key on iOS, a service
      account on Play
- [ ] RevenueCat's v1 secret key in `server/.env` as `REVENUECAT_SECRET_KEY`, then
      `scripts/deploy.sh`
- [ ] Terms and Privacy links on the paywall, which App Review requires for a subscription
- [ ] The app built and run on a phone with `purchases_flutter` in it
- [ ] A sandbox purchase, a Restore after reinstalling, and the 200 cap verified on
      both phones
