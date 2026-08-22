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

**Ingredient ids are a live-scaling mechanism, not decoration.** Step content references
ingredients as `{0001}` and never repeats the amount in prose. `recipe_scaling.dart`
substitutes them at render time with amounts scaled by the servings stepper. JSON Schema
can't express cross-references, so `RecipeParser` adds a post-validation pass rejecting
`{id}` refs that don't resolve — a dangling ref would silently break scaling.

**Units are display-only, and every amount goes through one function.** The stored recipe is
never rewritten: `weightSystem` and `volumeSystem` in
[lib/recipe/recipe_units.dart](lib/recipe/recipe_units.dart) are `ValueNotifier`s — the same
global pattern as `themeMode`, not constructor-passed — that change only how an amount
*reads*. `amountLabel` is the single chokepoint: ingredient rows, inline `{0001}` refs, the
share text and the version diff all route through it, so a second formatting path would
drift immediately. Scale first, convert second — the rounding never goes back to disk, or
tripling a recipe would compound a rounded cup into a wrong one.

**Any unit with a fixed factor converts; the stored unit only picks the dimension.**
`_gramsPer` and `_mlPer` canonicalise g/kg/oz/lb and ml/l/tsp/tbsp/cup/fl_oz into grams or
millilitres *before* rendering, so a recipe hand-written in cups is readable in millilitres
and back again. Adding a unit to the schema enum means adding it to one of those maps — a
unit in neither renders as written and silently ignores the setting, which is exactly what
shipped the first time. `pinch` is the one deliberate exception: it has no fixed factor.

**Weight reads in decimals, volume in fractions.** Not an inconsistency to tidy up: weight is
measured on a scale, which shows `1 lb 9.1 oz` and has no decimal-pound mode at all, so
`1.57 lb` is a number nobody can dial in. Volume is measured with cups and spoons, so it gets
`¾ cup + 1½ tbsp` — two terms, because snapping to one rung puts 200 ml 11% off. Imperial
weight below ~½ oz stays in grams, where a tenth of an ounce is 13% of 5 g.

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
- `SharePlus.instance.share` needs a `sharePositionOrigin` rect or it throws on iPad, where
  the sheet is a popover that must be anchored. On Linux it degrades to a `mailto:` link —
  expect that when testing the share button on desktop, it isn't a bug.
- Adding an asset requires listing it under `flutter: assets:` in pubspec.yaml or
  `rootBundle.loadString` fails at runtime while tests (which read from disk) still pass.
- A `ListView` only builds what's near the viewport; widget tests asserting on content
  further down need `tester.scrollUntilVisible` rather than assuming it's in the tree.
- A route already pushed on the Navigator does **not** repaint when the unit notifiers
  change. Rebuilding `MaterialApp` rebuilds the Navigator but not the element subtrees of
  live routes, and unlike `Theme` there is no InheritedWidget carrying the dependency across
  the boundary. It doesn't bite today only because Settings is reachable from the list
  screen alone, which shows no amounts, so every recipe screen is built fresh on the way
  back. Putting a Settings entry point on the detail screen means wrapping that screen's
  build in an `AnimatedBuilder` over `weightSystem` and `volumeSystem`.
