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

/// `Whisk {0001}` -> `Whisk [bread flour]`.
///
/// An id with no ingredient is left as written, the way [renderContent] leaves
/// it: import already rejects those, and rewriting one would hide the problem.
String toDisplayRefs(String content, List<Ingredient> ingredients) {
  final names = {for (final i in ingredients) i.id: i.name};
  return content.replaceAllMapped(_idRef, (match) {
    final name = names[match[1]];
    return name == null ? match[0]! : '[$name]';
  });
}

/// `Whisk [bread flour]` -> `Whisk {0001}`. Names are matched exactly, after
/// trimming — the insert chips write them verbatim, so anything that misses is
/// a typo worth reporting rather than guessing at.
String toIdRefs(String content, List<Ingredient> ingredients) {
  final ids = {for (final i in ingredients) i.name.trim(): i.id};
  return content.replaceAllMapped(nameRefPattern, (match) {
    final id = ids[match[1]!.trim()];
    return id == null ? match[0]! : '{$id}';
  });
}

/// Bracketed names in [content] that aren't ingredients, in the order written.
///
/// Without this a mistyped `[buter]` would save as literal prose and quietly
/// stop scaling, which is the failure the whole reference mechanism exists to
/// prevent.
List<String> unresolvedRefs(String content, List<Ingredient> ingredients) {
  final names = {for (final i in ingredients) i.name.trim()};
  return [
    for (final match in nameRefPattern.allMatches(content))
      if (!names.contains(match[1]!.trim())) match[1]!.trim(),
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

/// Names shared by more than one ingredient, which the editor cannot allow:
/// `[butter]` would have no way to say which one it meant.
List<String> duplicateNames(List<Ingredient> ingredients) {
  final seen = <String>{};
  final duplicates = <String>{};
  for (final ingredient in ingredients) {
    final name = ingredient.name.trim();
    if (!seen.add(name)) duplicates.add(name);
  }
  return duplicates.toList();
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
