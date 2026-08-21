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
