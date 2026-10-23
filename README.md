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
`test/fixtures/valid_recipe.json` together, then `dart run build_runner build`.
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
- [ ] Apple on iOS — written, not yet run (needs a Mac)
- [x] A second phone signing in with the same account switches to it
- [x] Sign out and Delete account, both keeping recipes on the phone
- [x] `profiles` table: `pro_until`, `free_tries_used`, created by trigger, owner-read only
- [x] Server verifies the Supabase token (`GET /me`, `DELETE /me`; `/photos` stays open)
- [x] No Supabase url at build time means no auth, so `flutter test` stays offline

### Phase 3 — Sync

Two-way, for signed-in users only, free. Local files stay the source of truth.

- [ ] Tables for recipe versions (`parent_id`, `deleted_at`), cook entries and unit settings
- [ ] `mise://` photos in Supabase Storage, one folder per user
- [ ] Runs on launch, on resume and after every save; never blocks the screen
- [ ] Deletes leave a `deleted_at` marker so they don't come back; Undo clears it
- [ ] Two devices editing one version: the older edit moves into history, labelled
      "edited on another device"
- [ ] First link uploads the whole library

### Phase 4 — Recipes from the server

Three routes on the existing FastAPI service, all on Claude Haiku 5.5.

- [ ] `/generate` from a sentence, `/adapt` an existing recipe (saved as a new version, so
      the diff shows what changed), `/import` from a URL or a cookbook photo
- [ ] Server built from the repo root, reading the live schema and one shared prompt file
- [ ] Pydantic validation plus the `{id}` reference check, at most two retries with the
      errors sent back; the phone still validates everything it receives
- [ ] Shared valid/invalid fixtures that `flutter test` and `pytest` must agree on
- [ ] Usage table recording each call's cost; three free tries per account
- [ ] Haiku checked against real URLs and cookbook photos before `/import` ships

### Phase 5 — Payments

- [ ] RevenueCat subscription with the Supabase user id as its app user id
- [ ] Webhook sets `pro_until`
- [ ] Paywall when the free tries run out; Restore purchases
- [ ] Monthly cost cap per user at about 80% of net proceeds (after the store's cut)
