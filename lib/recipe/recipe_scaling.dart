import 'recipe_models.dart';
import 'recipe_units.dart';

// Re-exported so the display helpers all arrive with one import, the way they
// did before units moved into their own file.
export 'recipe_units.dart' show formatAmount, unitLabel;

/// Scales ingredient amounts by servings and renders `{0001}` references in
/// step content. No widgets, so they test directly — though the display units
/// come from the notifiers in recipe_units.dart, which a test can set.

/// "750 g", "¾ cup + 1½ tbsp", or bare "6" for countable items whose
/// counting noun already lives in [Ingredient.name].
///
/// Scale first, convert second: the rounding is display-only, so tripling a
/// recipe can't compound a rounded cup into a wrong one.
String amountLabel(Ingredient ingredient, double factor) {
  final amount = ingredient.amount * factor;
  final unit = ingredient.unit;
  return unit == null ? formatAmount(amount) : formatMeasure(amount, unit);
}

double scaleFactor(Recipe recipe, int servings) =>
    servings / recipe.baseServings;

final _refPattern = RegExp(r'\{(\w+)\}');

/// Replaces each `{0001}` with the scaled "750 g bread flour". Unknown ids are
/// left as written — import already rejects those, this covers edited files.
String renderContent(RecipeStep step, Recipe recipe, double factor) {
  return step.content.replaceAllMapped(_refPattern, (match) {
    final ingredient = recipe.ingredientById(match[1]!);
    if (ingredient == null) return match[0]!;
    return '${amountLabel(ingredient, factor)} ${ingredient.name}';
  });
}

/// Plain text for sharing, scaled to [servings] — same numbers the screen is
/// showing. Ingredient refs are already resolved by [renderContent], so the
/// text reads as prose with no `{0001}` left in it.
String formatForSharing(Recipe recipe, int servings) {
  final factor = scaleFactor(recipe, servings);
  return [
    recipe.title,
    if (recipe.description.isNotEmpty) '\n${recipe.description}',
    '\nServes $servings',
    '\nIngredients',
    for (final ingredient in recipe.ingredients)
      '- ${amountLabel(ingredient, factor)} ${ingredient.name}',
    '\nSteps',
    for (final (index, step) in recipe.steps.indexed)
      '${index + 1}. ${step.title}'
          '${step.timerSeconds == null ? '' : ' (${formatDuration(step.timerSeconds!)})'}\n'
          '   ${renderContent(step, recipe, factor)}',
    if (recipe.notes case final notes? when notes.isNotEmpty) '\nNotes\n$notes',
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
