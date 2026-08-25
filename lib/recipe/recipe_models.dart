import 'package:json_annotation/json_annotation.dart';

part 'recipe_models.g.dart';

/// Measurement units. `null` unit means a whole/countable item, where the
/// counting noun is folded into [Ingredient.name] (e.g. "garlic cloves").
enum Unit {
  g,
  kg,
  ml,
  l,
  tsp,
  tbsp,
  cup,
  @JsonValue('fl_oz')
  flOz,
  oz,
  lb,
  pinch,
}

@JsonSerializable(explicitToJson: true)
class Ingredient {
  /// 4-char id, e.g. '0001'. Referenced from [RecipeStep.content] as `{0001}`.
  final String id;
  final String name;
  final num amount;
  final Unit? unit;

  /// Grams per millilitre, when the ingredient is measurable both ways.
  /// Null is the norm for countable items and pinches, and means the amount
  /// can only ever read in the dimension it was written in.
  @JsonKey(name: 'density_g_per_ml')
  final num? densityGPerMl;

  const Ingredient({
    required this.id,
    required this.name,
    required this.amount,
    this.unit,
    this.densityGPerMl,
  });

  factory Ingredient.fromJson(Map<String, dynamic> json) =>
      _$IngredientFromJson(json);
  Map<String, dynamic> toJson() => _$IngredientToJson(this);
}

/// Named `RecipeStep` rather than `Step` to avoid colliding with
/// `material.Step` in widget files.
@JsonSerializable(fieldRename: FieldRename.snake, explicitToJson: true)
class RecipeStep {
  final String id;
  final String title;

  /// Ingredients are referenced inline as `{0001}` so amounts can be
  /// re-rendered when servings change.
  final String content;
  final int? timerSeconds;

  const RecipeStep({
    required this.id,
    required this.title,
    required this.content,
    this.timerSeconds,
  });

  factory RecipeStep.fromJson(Map<String, dynamic> json) =>
      _$RecipeStepFromJson(json);
  Map<String, dynamic> toJson() => _$RecipeStepToJson(this);
}

@JsonSerializable(fieldRename: FieldRename.snake, explicitToJson: true)
class Recipe {
  final String title;
  final String description;
  final int baseServings;
  final List<Ingredient> ingredients;
  final List<RecipeStep> steps;
  final String? notes;

  /// Photos of the finished dish, best first — `https` urls the LLM found, or a
  /// single `mise://<filename>` pointing at a picked photo copied in beside the
  /// recipes.
  ///
  /// A list because a guessed url is often dead: the app shows the first that
  /// loads and treats the rest as fallbacks. Empty is the norm, and a recipe
  /// whose urls all fail reads as one with no photo at all. See
  /// `recipe_image.dart` for how a url becomes a picture.
  @JsonKey(defaultValue: <String>[])
  final List<String> imageUrls;
  final List<String> tags;
  final String source;
  final DateTime createdAt;

  const Recipe({
    required this.title,
    required this.description,
    required this.baseServings,
    required this.ingredients,
    required this.steps,
    this.notes,
    this.imageUrls = const [],
    required this.tags,
    required this.source,
    required this.createdAt,
  });

  factory Recipe.fromJson(Map<String, dynamic> json) => _$RecipeFromJson(json);
  Map<String, dynamic> toJson() => _$RecipeToJson(this);

  Ingredient? ingredientById(String id) =>
      ingredients.where((i) => i.id == id).firstOrNull;
}
