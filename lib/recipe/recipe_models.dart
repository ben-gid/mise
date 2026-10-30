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

/// A photographer, for the credit line under a stock photo.
@JsonSerializable()
class ImageCredit {
  final String name;

  /// Their profile, built by the server with Unsplash's referral parameters —
  /// the phone shows it and never assembles one.
  final String url;

  const ImageCredit({required this.name, required this.url});

  factory ImageCredit.fromJson(Map<String, dynamic> json) =>
      _$ImageCreditFromJson(json);
  Map<String, dynamic> toJson() => _$ImageCreditToJson(this);
}

/// What a recipe makes when it comes in pieces: 2 loaves, 24 cookies. Both
/// nouns are written out because English plurals don't follow a rule the app
/// could apply — loaf, loaves.
@JsonSerializable()
class Makes {
  final int amount;
  final String one;
  final String other;

  const Makes({required this.amount, required this.one, required this.other});

  String noun(int count) => count == 1 ? one : other;

  factory Makes.fromJson(Map<String, dynamic> json) => _$MakesFromJson(json);
  Map<String, dynamic> toJson() => _$MakesToJson(this);
}

@JsonSerializable(fieldRename: FieldRename.snake, explicitToJson: true)
class Recipe {
  final String title;

  /// How many it feeds. Always set, even where [makes] is what the stepper
  /// counts — it is what "serves 12" beside "2 loaves" is worked out from.
  final int baseServings;

  /// Pieces the recipe makes, null for soup and anything else served by the
  /// bowl. When set, the servings stepper counts these instead. Optional for
  /// the reason every later field is: required would brick recipes on disk.
  final Makes? makes;
  final List<Ingredient> ingredients;
  final List<RecipeStep> steps;

  /// The headnote, shown above the ingredients rather than under the steps —
  /// where the dish comes from, when to make it, what can be swapped. The LLM
  /// writes it last, once it has the whole recipe in front of it, which is why
  /// it sits after [steps] in the schema: models emit an object in the order
  /// its properties are declared.
  final String? notes;

  /// Two to four words for what the finished dish looks like, as typed into a
  /// stock photo search. The model's whole half of the picture: it never emits
  /// a url, it says what to go and find. See `stockPhotos` in
  /// `recipe_image.dart` for what does the finding.
  ///
  /// It sits after [notes] for the same reason [notes] sits after [steps] —
  /// models emit an object in the order its properties are declared, and
  /// describing how a dish looks wants the whole recipe already written.
  final String? imageQuery;

  /// The photo the cook settled on: one `https` url the app's search turned up,
  /// or a single `mise://<filename>` pointing at a picture copied in beside the
  /// recipes. **App-owned** — an LLM writes [imageQuery] and never this.
  ///
  /// Still a list, and still capped at three, because it is what `saveVersion`
  /// carries forward, what the version diff reads and what the editor
  /// round-trips — none of which a single string would have got for free. Empty
  /// is the norm: a recipe usually wears whatever the search found, and only a
  /// deliberate pick is written down. See `recipe_image.dart` for how a url
  /// becomes a picture.
  @JsonKey(defaultValue: <String>[])
  final List<String> imageUrls;

  /// Who took the photo in [imageUrls], when it came from the stock photo
  /// search — Unsplash's terms ask for the photographer by name, linked. Null
  /// for the cook's own photo, a Wikipedia stand-in, and every recipe saved
  /// before this existed. **App-owned**, like [imageUrls], and it travels with
  /// it: whatever sets or clears the photo sets or clears this.
  ///
  /// Optional in the schema, not required, for the reason every later field
  /// is: every save re-validates, and required would brick the recipes on disk.
  final ImageCredit? imageCredit;
  final List<String> tags;
  final String source;
  final DateTime createdAt;

  const Recipe({
    required this.title,
    required this.baseServings,
    this.makes,
    required this.ingredients,
    required this.steps,
    this.notes,
    this.imageQuery,
    this.imageUrls = const [],
    this.imageCredit,
    required this.tags,
    required this.source,
    required this.createdAt,
  });

  /// Recipes saved before the headnote replaced the separate `description`
  /// field carry both; fold the old one in rather than dropping it on the
  /// floor. This is the chokepoint for it because [RecipeStore] reads files
  /// straight through here without going past the validator — which is also
  /// why the schema could drop `description` outright: it never sees one.
  ///
  /// ponytail: delete once the recipes on this phone have each been saved.
  factory Recipe.fromJson(Map<String, dynamic> json) =>
      _$RecipeFromJson(_foldDescription(json));

  static Map<String, dynamic> _foldDescription(Map<String, dynamic> json) {
    final old = (json['description'] as String?)?.trim() ?? '';
    if (old.isEmpty) return json;
    final notes = (json['notes'] as String?)?.trim() ?? '';
    return {...json, 'notes': notes.isEmpty ? old : '$old\n\n$notes'};
  }

  Map<String, dynamic> toJson() => _$RecipeToJson(this);

  Ingredient? ingredientById(String id) =>
      ingredients.where((i) => i.id == id).firstOrNull;
}
