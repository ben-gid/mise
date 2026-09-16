# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
flutter test                              # full suite
flutter test test/recipe_store_test.dart  # one file
flutter test --plain-name "corrupt file"  # one test by name
flutter analyze                           # must stay clean
dart run build_runner build               # after ANY change to recipe_models.dart
flutter run                               # a phone/tablet device or emulator — the real target
flutter run -d linux                      # desktop, only to eyeball a change quickly
flutter run --dart-define-from-file=env.json   # with stock photos; see env.example.json
```

`--delete-conflicting-outputs` was removed in this build_runner version and is ignored — drop it.

Widget tests compile the whole app on first run and can take several minutes; pass
`--timeout 45s` so a hang fails fast instead of sitting for the default 10 minutes.

## Architecture

A Flutter app that stores LLM-generated recipes as validated JSON. Everything lives under
[lib/recipe/](lib/recipe/); `main.dart` only wires it together.

**Mobile and tablet first.** Phones and tablets are what this ships on — a recipe is read
one-handed at a counter. Linux desktop and web builds exist only so a change can be looked
at quickly without an emulator; they are a test harness, not a supported target. So: touch
targets stay finger-sized, nothing depends on hover or a right-click, layouts must survive a
phone-width window and a tablet's extra room, and desktop-only polish isn't worth a line of
code. When a platform API is needed, reach for the plugin with the real mobile
implementation (`share_plus`, `path_provider`) rather than a desktop-shaped workaround.

**The pipeline is validate-then-parse, and the order is load-bearing.** Raw JSON is checked
against [assets/schemas/recipe_schema.json](assets/schemas/recipe_schema.json) (Draft-7, via
the `json_schema` package) *before* any Dart parsing happens. `RecipeParser.parse` throws
`RecipeValidationException` carrying a list of every failure, so callers can show all of them
at once; it never crashes on bad input. Don't add a code path that calls `Recipe.fromJson`
directly on untrusted JSON — that's what the exception type exists to prevent.

**The schema is the source of truth, in three places at once.** Changing the recipe shape
means editing the schema, the models, and `test/fixtures/valid_recipe.json` together, then
re-running build_runner. The import screen's "Copy prompt" button embeds
`RecipeParser.schemaJson` verbatim so the LLM prompt can never drift from what the validator
enforces — keep it reading from the live schema string, not a hardcoded copy.

**One prose field, written last and printed first.** `notes` is the headnote, the way a
cookbook sets one: where the dish comes from, when to make it, what can be substituted. It
sits after `steps` in the schema because models emit an object in the order its properties
are declared, so the LLM writes it with the whole recipe already in front of it — and it
renders at the *top* of the detail screen, above the servings stepper, because a note under
the last step is a footnote nobody reads. It replaced a separate `description`: two fields
meant two half-filled boxes in the editor and two rows in the version diff.

A real headnote is several lines, so `_Headnote` cuts it to four with a More button —
otherwise it pushes the stepper and the first ingredients off a phone screen. The button
appears only when the text is genuinely clipped at the width it got, measured with a
`TextPainter`, not guessed from the string's length.

Recipes saved before that carry `description`, and `Recipe.fromJson` folds it into `notes`.
That is the chokepoint because `RecipeStore._read` goes straight through it without passing
the validator — which is also why the schema could drop `description` outright where a
*required* field would have bricked every recipe on disk: `toJson` never writes one, so the
validator never sees one. The fold is deletable once every recipe has been saved once.

**Ingredient ids are a live-scaling mechanism, not decoration.** Step content references
ingredients as `{0001}` and never repeats the amount in prose. `recipe_scaling.dart`
substitutes them at render time with amounts scaled by the servings stepper. JSON Schema
can't express cross-references, so `RecipeParser` adds a post-validation pass rejecting
`{id}` refs that don't resolve — a dangling ref would silently break scaling.

**Nobody types `{0001}`, so the editor round-trips ids through names — and that
round-trip has to be lossless.** `toDisplayRefs` renders a step as
`Whisk [bread flour]` on open and `toIdRefs` converts back on save. Both key off
`_labels` in [lib/recipe/recipe_refs.dart](lib/recipe/recipe_refs.dart), which is
the bare name where it is unique and `name #id` where it is not, because a recipe
split by component names one thing twice on purpose — sugar for the sponge, sugar
for the buttercream. Keyed by bare name the two functions stopped being inverses:
a Dart map literal keeps the *last* duplicate key, so opening and saving with no
edit at all repointed the first step at the second sugar's amount and left the
first orphaned. The editor used to refuse the save outright to dodge that; the
labels are what let it go through. Adding a second way to write a reference would
put that back, so a bracket's spelling comes from `_labels` or it comes from
nowhere. The id rather than an ordinal: `#0005` survives deleting the row above
it, `(2)` slides onto its neighbour and drags the step text along.

One keystroke can move two labels — renaming an ingredient onto a name another
already has makes *both* duplicates — so `_applyRenames` recomputes every label
each time rather than diffing the one field that changed. Its single pass is safe
only because a new label either has a different base name from every old one or
carries a `#id` no bare old label can match; check that before changing how a
label is spelled. A bare `[sugar]` typed by hand where two exist resolves to
neither and is reported at save, which is what makes the insert chips (they write
labels) the path that always works.

**Units are display-only, and every amount goes through one function.** The stored recipe is
never rewritten: `weightSystem`, `volumeSystem` and `measureBy` in
[lib/recipe/recipe_units.dart](lib/recipe/recipe_units.dart) are `ValueNotifier`s — the same
global pattern as `themeMode`, not constructor-passed — that change only how an amount
*reads*. `amountLabel` is the single chokepoint: ingredient rows, inline `{0001}` refs, the
share text and the version diff all route through it, so a second formatting path would
drift immediately. Scale first, convert second — the rounding never goes back to disk, or
tripling a recipe would compound a rounded cup into a wrong one.

**Any unit with a fixed factor converts; `density_g_per_ml` is what crosses between
dimensions.** `_gramsPer` and `_mlPer` canonicalise g/kg/oz/lb and ml/l/tsp/tbsp/cup/fl_oz
into grams or millilitres *before* rendering, so a recipe hand-written in cups is readable
in millilitres and back again. Adding a unit to the schema enum means adding it to one of
those maps — a unit in neither renders as written and silently ignores the setting, which
is exactly what shipped the first time. `pinch` is the one deliberate exception: it has no
fixed factor.

The stored unit only decides which dimension an amount *starts* in. An optional
`density_g_per_ml` divides grams into millilitres or multiplies back, so 500 g of flour
reads as cups and a cups-written recipe becomes weighable. It is optional because required
would break saving — every save re-validates through `RecipeParser.parse`, so a required
field makes every recipe already on disk unsaveable — and because eggs and pinches have no
meaningful density. `canConvert` answers whether a row can switch at all — only those get the `swap_horiz`
icon, though every row taps and answers with a SnackBar. `isDerived` answers whether the
amount on screen was *computed* through a density rather than read as stored, and a
highlight band behind the row is the only thing that says so. Both live in
`recipe_units.dart` and resolve the dimension through the same `_dimensions` helper
`formatMeasure` uses — a second copy of that decision would drift the band away from the
number it describes. The band tracks approximation, not interaction: tapping a derived row
back onto its stored unit clears it, and a settings change lights a whole recipe at once.
Nothing marks approximation in the share text or the version diff, which are plain
strings with nowhere to put a highlight.

Per-ingredient flips are deliberately **not** persisted — a `Set<String>` in the detail
screen's state, gone when you leave. `measureBy` is the persisted half, appended as a third
value to the `units.meta` line. If per-recipe persistence is ever added it needs carrying
forward in `saveVersion`: a recipe's id derives from `createdAt`, which every edit
restamps, which is why ratings silently reset on edit today.

**Weight reads in decimals, volume in fractions.** Not an inconsistency to tidy up: weight is
measured on a scale, which shows `1 lb 9.1 oz` and has no decimal-pound mode at all, so
`1.57 lb` is a number nobody can dial in. Volume is measured with cups and spoons, so it gets
`¾ cup + 1½ tbsp` — two terms, because snapping to one rung puts 200 ml 11% off. Imperial
weight below ~½ oz stays in grams, where a tenth of an ounce is 13% of 5 g.

**The model describes the photo; the app finds it.** `image_query` is the LLM's whole
half: two to four words for what the finished dish *looks like*, in the vocabulary of a
stock photo search ("creamy mushroom pasta", never "Nonna's Sunday gravy"). It sits
after `notes` in the schema for the same reason `notes` sits after `steps`. The app
searches Pexels with it, because the goal is a *beautiful* photo, and the model used to
be asked for urls instead — which, told to prefer stable sources, meant a Wikimedia
Commons photo nearly every time: the same plain picture the Wikipedia fallback finds
for free. The trade is accuracy: a Pexels photo is of something that looks like the
dish, not of this recipe, and `creditFor` says "Pexels" so a reader can tell.

`image_urls` is **app-owned**: the one photo the cook picked, or a `mise://<filename>`
copied in beside the recipes by `RecipeStore.addImage`. The prompt tells the model to
leave it out. It stays a list capped at three rather than becoming a string because
`saveVersion` carries it forward, the version diff sees it and the editor round-trips it.
The urls are relative on purpose where local: iOS hands the app container a new UUID on
every update, so an absolute path saved today is dead after the next release. `https`
only, never `http` — phones block cleartext.

The chain is own urls → `pexelsPhotos(image_query)` → `wikipediaImage(title)` → no
photo, as a queue of fallbacks in `ImageChain` that only shrinks — that is its whole
termination argument. Wikipedia is demoted, not deleted: it is a photo of *this* dish,
and the only link that works in a build with no key. `pexelsPhotos` memoises the whole
nine-result page per query for the run, so the hero takes the first and the picker sheet
shows all nine off one request. The key is compile-time (`PEXELS_KEY`, from a gitignored
`env.json`); an empty key returns no photos rather than failing, which is also what keeps
`flutter test` offline.

**A picture is not a version.** The first time the detail screen's chain lands on a
search result *that has actually loaded*, it writes that url into `image_urls` — so the
list and the next cold start show it without searching again. `winnerFromSearch` is the
gate, and it requires the decode, not just `winner`, which is optimistic: keeping a url
before it loads writes a dead link into the recipe for good. Only the detail screen
keeps a photo; fifty list rows doing it would be fifty concurrent writes. The
always-visible "Choose photo" action opens a bottom sheet (the app's only one — nine
photos on a phone, where a dialog is a letterbox) with the results plus "Use my own
photo". Both a kept result and a pick save through `RecipeStore.save`, **not**
`saveVersion` and **not** `_adopt`: the id is `<createdAtMillis>-<title-slug>` and
neither half moves, so the same file is rewritten, the rating stays attached and history
gets no entry. `_adopt` clears the stars, correctly, because every other caller minted a
new id. "Use my own photo" still goes through the editor's picker and `saveVersion` —
an asymmetry that is cheaper than a second `ImagePicker` path.

[lib/recipe/recipe_image.dart](lib/recipe/recipe_image.dart) is the chokepoint,
the way `amountLabel` is for amounts: `imageFor` turns a url into something
paintable, `creditFor` turns it into the host shown under the photo, and
`ImageChain` walks the list until one loads. `imageFor` hands back a `CachedNetworkImageProvider`, not a plain `NetworkImage`: `dart:io`'s HttpClient has no HTTP cache at all — it ignores `Cache-Control` and `ETag` — and Flutter's `ImageCache` dies with the process, so every cold start re-downloaded every photo, and a kitchen with no signal showed none. The `_pexels` and `_wikipedia` memos are still per-run; only the images survive a restart. The chain is **headless** — it
resolves through the image cache without painting — because the detail screen
*sizes its app bar* on the outcome, and a widget that rendered the chain and
reported upwards would loop: child says exhausted, parent shrinks, child
rebuilds, reports again. The detail screen, each list row and the editor preview
own one apiece, which is what stops the preview and the hero disagreeing about
which url wins.

**A recipe whose photos all fail is a recipe with no photo.** The hero eases
shut and the screen becomes the plain one, rather than sitting open on generated
art in a picture's place. That art is still the *list thumbnail* fallback, where
a 64px tile has nothing to collapse into — it shows through while the chain is
looking and stays put when it comes back with nothing. The list runs the full
chain too, in `_Cover`, query included, so a row shows the same photo the hero
settles on. Both memos are shared across rows and with the detail screen, so a
library costs one Pexels request per distinct query on first scroll against a
200/hour free tier. Both chain owners restart on a changed query as well as
changed urls — an edit that fixes a useless query leaves every url alone. Nothing
deletes a photo: a
deleted recipe leaves its file behind, because the list screen's Undo re-saves
the recipe and would otherwise find the picture gone.

**Storage is one JSON file per recipe** in the app documents dir, filename = id =
`<createdAtMillis>-<title-slug>.json`. Recipes carry no id field of their own (the schema
describes what an LLM emits, not how we file it), so `RecipeStore.loadAll` returns
`(id, recipe)` records. A file that won't decode is skipped and logged, never deleted.
`RecipeStore` takes a `Directory` so tests can point it at a temp dir. Everything that isn't
a recipe — version history, ratings, the theme, the unit systems — lives beside them in
plain-text `.meta` sidecars, and the extension is what keeps `loadAll` from trying to parse
them as recipes. A settings file written as `.json` would show up as a corrupt recipe.

**No state management package and none wanted** — three screens over one store, plain
`StatefulWidget` + `setState`, `Navigator.push` between them. The store and parser are
constructed once in `main()` and passed down by constructor.

## Gotchas that have already cost time here

- `testWidgets` runs in a fake-async zone, so real `dart:io` futures **never complete** inside
  it. Anything touching `RecipeStore` must be wrapped in `tester.runAsync`, or the test hangs
  until the 10-minute timeout. Plain `test()` files are unaffected.
- Inside `runAsync`, a fixed `Future.delayed` is a race, not a wait — it competes with the
  frame's own layout and paint. If the store read loses, `runAsync` exits and the future can
  never complete (see above), so the screen stays empty and the assertion fails. Pump until
  the screen has actually rendered its data, the way `widget_test.dart`'s `pumpUntil` does.
  Making the first frame more expensive is enough to turn this from green into ~1-in-5 flaky,
  so re-run the suite several times after any UI change rather than trusting one green run.
- Never leave an indefinite animation on screen in a default state (e.g. a
  `CircularProgressIndicator` while a Future resolves) — `pumpAndSettle` never returns.
- `setState(() => _field = someFuture)` silently asserts at runtime: the arrow body returns
  the assigned Future. Use a block body.
- The model class is `RecipeStep`, not `Step`, because `material.Step` exists.
- Photos resolve through `CachedNetworkImageProvider`, so anything that paints
  one drags in `flutter_cache_manager`, which asks `path_provider` for a cache
  dir. There is no plugin behind that channel under `flutter test`, and the
  `MissingPluginException` never reaches the `ImageStreamListener` — the stream
  just never completes and `ImageChain` hangs. `test/flutter_test_config.dart`
  mocks the channel to a temp dir for every test file; that is why no individual
  test opts in, and why deleting that file breaks tests that never mention
  images.
- A test that resolves an https url must let the request finish before it ends,
  inside `runAsync`, even when its assertion has already passed —
  `flutter_cache_manager` takes a lock per request and one abandoned mid-flight
  is never released, so the *next* test to resolve anything blocks forever. See
  `_drain` in `recipe_image_test.dart`. The symptom is a test that passes alone
  and fails in its own file.
- `image_picker` has no Linux implementation, so "Choose photo" throws
  `MissingPluginException` on the desktop harness and answers with a SnackBar.
  Expect that, the same way the share button degrades to `mailto:` there.
- A `Future` made in the fake-async zone never delivers inside `tester.runAsync`.
  `seedPexels` stores one, so call it *inside* `runAsync`; seeded above it, the chain
  waits on the seed until the test times out, with no error. `pumpPhotos` in
  `widget_test.dart` takes a `search:` map and seeds it in the right place. The memo
  also outlives a test, which is why that file's `tearDown` calls `forgetPexels`.
- `_draft()` in the editor builds a `Recipe` field by field. A field added to `Recipe`
  but not to `_draft()` is erased by the first form save, with no error — that is why
  it carries `imageQuery` next to `source` and `createdAt`.
- The picker awaits `pexelsPhotos` *before* opening the sheet, never inside it. A
  spinner in a modal is an indefinite animation, and `pumpAndSettle` never returns.
- The detail screen is a `CustomScrollView`, not a `ListView`, and passes
  `appBar: null` — a `SliverAppBar` is not a `PreferredSizeWidget`, so it cannot
  go in `GlassScaffold.appBar`. Its frost is driven off `SliverLayoutBuilder`
  constraints rather than a `ScrollController`, so it stays a function of layout
  with nothing for `pumpAndSettle` to wait on. A recipe with no photo gets
  `expandedHeight: null` and looks exactly like every other screen.
- Anything put inside the detail screen's `flexibleSpace` sits **under**
  `frostPane`'s `BackdropFilter` and gets blurred away as the hero collapses.
  That is why the recipe's name is set in the page body — centred, wrapping,
  `headlineMedium` — rather than in the bar, which could only ever give it
  `kToolbarHeight`. A widget test asserting `findsWidgets` on it passes while it
  is invisible; assert it is *not* a descendant of `FlexibleSpaceBar` instead.
- That title block pushes the ingredient rows past a default 600px test surface,
  where a `SliverList` has not built them yet. Tests about how an amount reads
  call `tallSurface` rather than tuning scroll offsets; only tests genuinely
  about scrolling use `scrollTo`.
- A `SliverAppBar`'s height cannot be animated with `TweenAnimationBuilder` —
  that is a box widget and the target is a sliver. The detail screen uses an
  `AnimationController` with an `AnimatedBuilder` around the whole
  `CustomScrollView` instead. Its frost divides by `expanded - collapsed`, which
  reaches zero at the end of that animation; unguarded it puts a NaN straight
  into the opacity.
- `SharePlus.instance.share` needs a `sharePositionOrigin` rect or it throws on iPad, where
  the sheet is a popover that must be anchored. On Linux it degrades to a `mailto:` link —
  expect that when testing the share button on desktop, it isn't a bug.
- Adding an asset requires listing it under `flutter: assets:` in pubspec.yaml or
  `rootBundle.loadString` fails at runtime while tests (which read from disk) still pass.
- A `ListView` only builds what's near the viewport; widget tests asserting on content
  further down need `tester.scrollUntilVisible` rather than assuming it's in the tree.
- A widget test asserting on an amount has to know which unit settings are live: at the
  metric default `1 tsp` of yeast renders as `5 ml`, so `find.text('1 tsp')` only works in
  a test that set `volumeSystem` to imperial first.
- `TextOverflow.ellipsis` with `maxLines: null` limits a paragraph to a **single line**.
  The two go together or neither does — see `_Headnote`, where leaving the ellipsis set
  while expanded showed one line of a nine-line note.
- The headnote leads the editor form, so on a default 600px surface the first ingredient
  row is below the fold and unbuilt. `openEditor` in `widget_test.dart` calls `tallSurface`
  for that reason; a test needing more than that sets its own size *after* the open, or the
  helper overrides it.
- A route already pushed on the Navigator does **not** repaint when the unit notifiers
  change. Rebuilding `MaterialApp` rebuilds the Navigator but not the element subtrees of
  live routes, and unlike `Theme` there is no InheritedWidget carrying the dependency across
  the boundary. It doesn't bite today only because Settings is reachable from the list
  screen alone, which shows no amounts, so every recipe screen is built fresh on the way
  back. Putting a Settings entry point on the detail screen means wrapping that screen's
  build in an `AnimatedBuilder` over `weightSystem` and `volumeSystem`.
