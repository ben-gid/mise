import 'recipe_models.dart';
import 'recipe_units.dart';

// Re-exported so the display helpers all arrive with one import, the way they
// did before units moved into their own file.
export 'recipe_units.dart'
    show
        MeasureBy,
        canConvert,
        formatAmount,
        isDerived,
        measureBy,
        unitConverts,
        unitLabel;

/// Scales ingredient amounts by servings (or loaves) and renders `{0001}` references in
/// step content. No widgets, so they test directly — though the display units
/// come from the notifiers in recipe_units.dart, which a test can set.

/// "750 g", "¾ cup + 1½ tbsp", or bare "6" for countable items whose
/// counting noun already lives in [Ingredient.name].
///
/// Scale first, convert second: the rounding is display-only, so tripling a
/// recipe can't compound a rounded cup into a wrong one.
String amountLabel(Ingredient ingredient, double factor, {bool flip = false}) {
  final amount = ingredient.amount * factor;
  final unit = ingredient.unit;
  return unit == null
      ? formatAmount(amount)
      : formatMeasure(
          amount,
          unit,
          density: ingredient.densityGPerMl,
          flip: flip,
        );
}

/// What the servings stepper counts from: the pieces a recipe makes when it
/// makes any — you double bread by the loaf — and the servings otherwise.
int baseCount(Recipe recipe) => recipe.makes?.amount ?? recipe.baseServings;

double scaleFactor(Recipe recipe, int count) => count / baseCount(recipe);

/// "2 loaves", or "4 servings" for a recipe that makes no pieces.
String countLabel(Recipe recipe, int count) => switch (recipe.makes) {
  final makes? => '$count ${makes.noun(count)}',
  null => '$count ${count == 1 ? 'serving' : 'servings'}',
};

/// How many [count] feeds, rounded — or null under one person, which is
/// what a single one of 24 cookies works out to.
int? servesAt(Recipe recipe, int count) {
  final serves = (recipe.baseServings * scaleFactor(recipe, count)).round();
  return serves < 1 ? null : serves;
}

/// "Serves 4", or "Makes 2 loaves · serves 12".
String yieldLine(Recipe recipe, int count) {
  if (recipe.makes == null) return 'Serves $count';
  final serves = servesAt(recipe, count);
  return 'Makes ${countLabel(recipe, count)}'
      '${serves == null ? '' : ' · serves $serves'}';
}

final _refPattern = RegExp(r'\{(\w+)\}');

/// A step's words cut at each `{0001}`: prose runs with a null [amount], and
/// each reference as its scaled amount and the ingredient's name, so the
/// screen can set the two apart from the prose around them. Unknown ids are
/// left as written — import already rejects those, this covers edited files.
List<({String? amount, String text})> contentParts(
  RecipeStep step,
  Recipe recipe,
  double factor, {
  Set<String> flipped = const {},
}) {
  final parts = <({String? amount, String text})>[];
  var at = 0;
  for (final match in _refPattern.allMatches(step.content)) {
    final ingredient = recipe.ingredientById(match[1]!);
    if (ingredient == null) continue;
    parts.add((amount: null, text: step.content.substring(at, match.start)));
    parts.add((
      amount: amountLabel(
        ingredient,
        factor,
        flip: flipped.contains(ingredient.id),
      ),
      text: ingredient.name,
    ));
    at = match.end;
  }
  parts.add((amount: null, text: step.content.substring(at)));
  return parts;
}

/// Replaces each `{0001}` with the scaled "750 g bread flour".
String renderContent(
  RecipeStep step,
  Recipe recipe,
  double factor, {
  Set<String> flipped = const {},
}) => [
  for (final part in contentParts(step, recipe, factor, flipped: flipped))
    part.amount == null ? part.text : '${part.amount} ${part.text}',
].join();

/// Plain text for sharing, scaled to [count] — same numbers the screen is
/// showing. Ingredient refs are already resolved by [renderContent], so the
/// text reads as prose with no `{0001}` left in it.
String formatForSharing(
  Recipe recipe,
  int count, {
  Set<String> flipped = const {},
}) {
  final factor = scaleFactor(recipe, count);
  return [
    recipe.title,
    if (recipe.notes case final notes? when notes.isNotEmpty) '\n$notes',
    '\n${yieldLine(recipe, count)}',
    '\nIngredients',
    for (final ingredient in recipe.ingredients)
      '- ${amountLabel(ingredient, factor, flip: flipped.contains(ingredient.id))}'
          ' ${ingredient.name}',
    '\nSteps',
    for (final (index, step) in recipe.steps.indexed)
      '${index + 1}. ${step.title}'
          '${step.timerSeconds == null ? '' : ' (${formatDuration(step.timerSeconds!)})'}\n'
          '   ${renderContent(step, recipe, factor, flipped: flipped)}',
    '\nSource: ${recipe.source}',
  ].join('\n');
}

/// "25 min", "1 h 30 min", "45 s".
String formatDuration(int seconds) {
  final hours = seconds ~/ 3600;
  final minutes = (seconds % 3600) ~/ 60;
  if (hours > 0) return minutes > 0 ? '$hours h $minutes min' : '$hours h';
  if (minutes > 0) return '$minutes min';
  return '$seconds s';
}
