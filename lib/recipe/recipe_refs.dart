import 'recipe_models.dart';

/// Translating ingredient references between what is stored and what a person
/// edits. Pure functions — no widgets, so they test directly.
///
/// Stored, a step says `Whisk {0001}` because ids survive renames and are what
/// live scaling resolves. Nobody should have to type that, so the editor works
/// in `Whisk [bread flour]` and converts back on save.
///
/// Brackets rather than the bare name: this recipe has both "fine sea salt"
/// and "flaky salt", and a bare word in prose would be indistinguishable from
/// a reference.

final _idRef = RegExp(r'\{(\w+)\}');

/// A bracketed ingredient reference as the editor writes it. Public so the
/// editor can paint these spans without re-deriving the syntax.
final nameRefPattern = RegExp(r'\[([^\[\]]+)\]');

/// What each ingredient is called in bracket syntax, by id.
///
/// The bare name where it is the only one — which is every ingredient in
/// almost every recipe. Where it is not, the id is appended, because an LLM
/// splitting a recipe by component writes "sugar" twice on purpose: once for
/// the sponge and once for the buttercream. Two brackets both reading
/// `[sugar]` could not say which was meant, and [toIdRefs] would quietly
/// resolve them both to whichever ingredient came last — pointing a step at
/// the wrong amount, which is the failure this whole mechanism exists to
/// prevent.
///
/// The id rather than an ordinal: `#0005` still names the same ingredient
/// after one above it is deleted, where `(2)` would slide onto its neighbour
/// and take the step text with it.
Map<String, String> _labels(List<Ingredient> ingredients) {
  final counts = <String, int>{};
  for (final i in ingredients) {
    counts.update(i.name.trim(), (n) => n + 1, ifAbsent: () => 1);
  }
  return {
    for (final i in ingredients)
      // An unnamed ingredient — only reachable as a half-typed editor draft,
      // the schema requires a name — has nothing to be referred to by.
      i.id: i.name.trim().isEmpty
          ? ''
          : counts[i.name.trim()] == 1
          ? i.name.trim()
          : '${i.name.trim()} #${i.id}',
  };
}

/// The labels of [ingredients], in order — what the editor offers to insert.
List<String> labelsFor(List<Ingredient> ingredients) {
  final labels = _labels(ingredients);
  return [for (final i in ingredients) labels[i.id]!];
}

/// `Whisk {0001}` -> `Whisk [bread flour]`.
///
/// An id with no ingredient is left as written, the way [renderContent] leaves
/// it: import already rejects those, and rewriting one would hide the problem.
String toDisplayRefs(String content, List<Ingredient> ingredients) {
  final labels = _labels(ingredients);
  return content.replaceAllMapped(_idRef, (match) {
    final label = labels[match[1]];
    return label == null ? match[0]! : '[$label]';
  });
}

/// `Whisk [bread flour]` -> `Whisk {0001}`. Labels are matched exactly, after
/// trimming — the insert chips write them verbatim, so anything that misses is
/// a typo worth reporting rather than guessing at.
///
/// Exactly the inverse of [toDisplayRefs]: both key off the same labels, so a
/// step opened in the editor and saved untouched comes back byte for byte.
String toIdRefs(String content, List<Ingredient> ingredients) {
  final ids = {for (final e in _labels(ingredients).entries) e.value: e.key};
  return content.replaceAllMapped(nameRefPattern, (match) {
    final id = ids[match[1]!.trim()];
    return id == null ? match[0]! : '{$id}';
  });
}

/// Bracketed labels in [content] that aren't ingredients, in the order written.
///
/// Without this a mistyped `[buter]` would save as literal prose and quietly
/// stop scaling, which is the failure the whole reference mechanism exists to
/// prevent. A bare `[sugar]` typed by hand where two sugars exist lands here
/// too — it names no single ingredient, so it is reported rather than guessed
/// at. Tapping the insert chip always writes the resolvable form.
List<String> unresolvedRefs(String content, List<Ingredient> ingredients) {
  final labels = _labels(ingredients).values.toSet();
  return [
    for (final match in nameRefPattern.allMatches(content))
      if (!labels.contains(match[1]!.trim())) match[1]!.trim(),
  ];
}

/// Ingredients no step mentions. They still take up a line and still scale with
/// the servings stepper, so they are almost always either a leftover from an
/// edit or a step that forgot to use them.
List<Ingredient> unusedIngredients(Recipe recipe) {
  final used = {
    for (final step in recipe.steps)
      for (final match in _idRef.allMatches(step.content)) match[1]!,
  };
  return [
    for (final ingredient in recipe.ingredients)
      if (!used.contains(ingredient.id)) ingredient,
  ];
}

/// The next free 4-digit ingredient id. The schema pins the format, so this
/// counts up rather than inventing one.
String nextIngredientId(Iterable<String> usedIds) {
  final used = usedIds.toSet();
  for (var n = 1; ; n++) {
    final id = n.toString().padLeft(4, '0');
    if (!used.contains(id)) return id;
  }
}

/// The next free step id. Step ids are free-form in the schema; these follow
/// the `s1`, `s2` shape imports already use.
String nextStepId(Iterable<String> usedIds) {
  final used = usedIds.toSet();
  for (var n = 1; ; n++) {
    if (!used.contains('s$n')) return 's$n';
  }
}
