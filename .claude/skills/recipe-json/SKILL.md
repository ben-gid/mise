---
name: recipe-json
description: Write a recipe as JSON that this app will accept. Use when asked to create, draft, or convert a recipe into mise JSON, or when a pasted recipe failed import validation.
---

# recipe-json

Read these two files first — they are the source of truth, do not work from memory:

- `assets/schemas/recipe_schema.json` — what the validator enforces.
- `_prompt` in `lib/recipe/ui/import_recipe_screen.dart` — the rules the schema can't express.

Then emit a single JSON object: no markdown fence, no commentary, nothing before or after it.

Two rules JSON Schema cannot check, so nothing will catch them but you:

- Every `{id}` in a step's `content` must match an ingredient `id`. A dangling ref
  breaks servings scaling silently.
- Amounts live only in `ingredients`. Steps say `{0001}`, never "2 cups flour".

To verify: paste it into the app's Import screen. It lists every failure at once.
