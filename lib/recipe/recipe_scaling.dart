import 'recipe_models.dart';

/// Scales ingredient amounts by servings and renders `{0001}` references in
/// step content. Pure functions — no widgets, so they test directly.

/// `1.0` -> "1", `166.666` -> "166.67".
String formatAmount(num amount) {
  final rounded = (amount * 100).round() / 100;
  return rounded == rounded.roundToDouble()
      ? rounded.round().toString()
      : rounded.toString();
}

/// "750 g", or bare "6" for countable items whose counting noun already lives
/// in [Ingredient.name].
String amountLabel(Ingredient ingredient, double factor) {
  final amount = formatAmount(ingredient.amount * factor);
  final unit = ingredient.unit;
  return unit == null ? amount : '$amount ${unitLabel(unit)}';
}

String unitLabel(Unit unit) => switch (unit) {
  Unit.flOz => 'fl oz',
  _ => unit.name,
};

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
