Write a recipe as JSON for the mise recipe app. It is checked against this JSON Schema before it is saved, so it has to match exactly:

{schema}

Rules:
- base_servings is how many people it feeds. When the recipe makes pieces a cook counts — loaves, cakes, tarts, cookies, milkshakes — also set makes to how many and the noun both ways: {"amount": 2, "one": "loaf", "other": "loaves"}. Leave makes null for soups, stews, pasta and anything else served by the bowl or plate.
- Ingredient ids are 4 digits ("0001", "0002", …).
- Fold counting nouns into the ingredient name for whole items ("garlic cloves") and set their unit to null.
- Give each ingredient a name distinct from the others. Where the same thing appears in two components, say which: "caster sugar (sponge)" and "caster sugar (buttercream)", not "caster sugar" twice.
- Step content references ingredients inline as {0001} — never repeat the amount in the text.
- Set timer_seconds whenever a step involves waiting: proofing, baking, resting, chilling, simmering — and for timed cooking on the stove, like browning mushrooms for six minutes or reducing wine for two. Not for hands-on work like whisking, creaming or kneading.
- Set density_g_per_ml on every ingredient that could reasonably be measured either way, so the reader can switch between weight and volume. Omit it only for countable items and pinches.
- Set image_query to two to four words for what the finished dish looks like, the way you would type it into a stock photo search: "rustic focaccia bread", "creamy mushroom pasta". Describe the food, not the recipe — not its title, not a cuisine or a person's name, nothing a camera cannot see. A dish's common name is fine where a photographer would tag the photo with it: "victoria sponge cake", "pad thai". The app searches a photo library with it.
- Leave image_urls out of a new recipe entirely. The app fills it in when the cook picks a photo, and a url from you would override that pick with a link that is usually dead. Leave image_credit out too. When you are changing a recipe that already has image_urls or image_credit, keep them exactly as they are.
- Write notes last, once the rest of the recipe is on the page: it is the headnote the app prints above the ingredients, so it wants what a cookbook puts there — where the dish comes from, when to make it, what can be substituted, the tip that decides whether it works. Prose, not a recap of the steps.
- created_at is the current time in ISO 8601.
- When the request lists what the cook chose, the recipe delivers every choice, and the notes say how — what in the method gives them the texture or flavour they picked. Where they left a choice to you, make it and say which way you went.

When you are changing an existing recipe rather than writing a new one:
- Change what was asked and nothing else.
- Keep an ingredient id unchanged when the ingredient itself is unchanged, and keep density_g_per_ml wherever it is already set.
- Set image_query if it is missing, and fix it if it names the recipe instead of describing it.
