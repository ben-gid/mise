// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'recipe_models.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

Ingredient _$IngredientFromJson(Map<String, dynamic> json) => Ingredient(
  id: json['id'] as String,
  name: json['name'] as String,
  amount: json['amount'] as num,
  unit: $enumDecodeNullable(_$UnitEnumMap, json['unit']),
  densityGPerMl: json['density_g_per_ml'] as num?,
);

Map<String, dynamic> _$IngredientToJson(Ingredient instance) =>
    <String, dynamic>{
      'id': instance.id,
      'name': instance.name,
      'amount': instance.amount,
      'unit': _$UnitEnumMap[instance.unit],
      'density_g_per_ml': instance.densityGPerMl,
    };

const _$UnitEnumMap = {
  Unit.g: 'g',
  Unit.kg: 'kg',
  Unit.ml: 'ml',
  Unit.l: 'l',
  Unit.tsp: 'tsp',
  Unit.tbsp: 'tbsp',
  Unit.cup: 'cup',
  Unit.flOz: 'fl_oz',
  Unit.oz: 'oz',
  Unit.lb: 'lb',
  Unit.pinch: 'pinch',
};

RecipeStep _$RecipeStepFromJson(Map<String, dynamic> json) => RecipeStep(
  id: json['id'] as String,
  title: json['title'] as String,
  content: json['content'] as String,
  timerSeconds: (json['timer_seconds'] as num?)?.toInt(),
);

Map<String, dynamic> _$RecipeStepToJson(RecipeStep instance) =>
    <String, dynamic>{
      'id': instance.id,
      'title': instance.title,
      'content': instance.content,
      'timer_seconds': instance.timerSeconds,
    };

Recipe _$RecipeFromJson(Map<String, dynamic> json) => Recipe(
  title: json['title'] as String,
  baseServings: (json['base_servings'] as num).toInt(),
  ingredients: (json['ingredients'] as List<dynamic>)
      .map((e) => Ingredient.fromJson(e as Map<String, dynamic>))
      .toList(),
  steps: (json['steps'] as List<dynamic>)
      .map((e) => RecipeStep.fromJson(e as Map<String, dynamic>))
      .toList(),
  notes: json['notes'] as String?,
  imageUrls:
      (json['image_urls'] as List<dynamic>?)
          ?.map((e) => e as String)
          .toList() ??
      [],
  tags: (json['tags'] as List<dynamic>).map((e) => e as String).toList(),
  source: json['source'] as String,
  createdAt: DateTime.parse(json['created_at'] as String),
);

Map<String, dynamic> _$RecipeToJson(Recipe instance) => <String, dynamic>{
  'title': instance.title,
  'base_servings': instance.baseServings,
  'ingredients': instance.ingredients.map((e) => e.toJson()).toList(),
  'steps': instance.steps.map((e) => e.toJson()).toList(),
  'notes': instance.notes,
  'image_urls': instance.imageUrls,
  'tags': instance.tags,
  'source': instance.source,
  'created_at': instance.createdAt.toIso8601String(),
};
