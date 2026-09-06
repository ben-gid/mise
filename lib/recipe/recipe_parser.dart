import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:json_schema/json_schema.dart';

import 'recipe_models.dart';

const recipeSchemaAsset = 'assets/schemas/recipe_schema.json';

/// Thrown when incoming JSON is malformed or fails schema validation.
/// [errors] lists every failing field/constraint, not just the first.
class RecipeValidationException implements Exception {
  final List<String> errors;
  const RecipeValidationException(this.errors);

  @override
  String toString() =>
      'RecipeValidationException:\n${errors.map((e) => '  - $e').join('\n')}';
}

/// Validates raw JSON against the recipe JSON Schema, then parses it into a
/// typed [Recipe]. Nothing is parsed until validation passes.
class RecipeParser {
  /// Kept so callers can show the schema itself — see the "copy prompt"
  /// action on the import screen, which must never drift from the real rules.
  final String schemaJson;
  final JsonSchema _schema;

  RecipeParser(this.schemaJson) : _schema = JsonSchema.create(schemaJson);

  static Future<RecipeParser> fromAsset() async =>
      RecipeParser(await rootBundle.loadString(recipeSchemaAsset));

  /// Throws [RecipeValidationException] on bad input; never throws on a
  /// well-formed-but-invalid document.
  Recipe parse(String rawJson) {
    final Object? decoded;
    try {
      decoded = jsonDecode(_unfence(rawJson));
    } on FormatException catch (e) {
      throw RecipeValidationException(['Malformed JSON: ${e.message}']);
    }

    final result = _schema.validate(decoded);
    // Deduped: json_schema reports `required` failures at both the root and
    // the missing path.
    final errors = {
      ...result.errors.map(_readable),
      // Schema can't express cross-references; a dangling {0001} would break
      // live-scaling of amounts by servings later.
      if (result.isValid) ..._danglingRefs(decoded as Map<String, dynamic>),
    }.toList();
    if (errors.isNotEmpty) throw RecipeValidationException(errors);

    return Recipe.fromJson(decoded as Map<String, dynamic>);
  }
}

/// The prompt asks the LLM for a ```json code block, and text selected by
/// hand brings the fence along with it. Strip it rather than answering a
/// paste that is otherwise perfect with "Malformed JSON".
final _fence = RegExp(r'^\s*```[a-zA-Z]*\s*\n(.*?)\n?\s*```\s*$', dotAll: true);

String _unfence(String raw) => _fence.firstMatch(raw)?.group(1) ?? raw;

/// json_schema appends the offending instance to some messages, which for a
/// whole recipe is unreadable. Keep the path and the reason, drop the dump.
String _readable(ValidationError e) {
  final message = e.message.split(' from {').first.split(': {').first;
  return '${e.instancePath.isEmpty ? '#' : e.instancePath}: $message';
}

final _refPattern = RegExp(r'\{(\w+)\}');

Iterable<String> _danglingRefs(Map<String, dynamic> json) sync* {
  final ids = {for (final i in json['ingredients'] as List) i['id'] as String};
  for (final step in json['steps'] as List) {
    for (final m in _refPattern.allMatches(step['content'] as String)) {
      if (!ids.contains(m[1])) {
        yield 'steps[${step['id']}].content: references unknown ingredient id '
            '{${m[1]}}';
      }
    }
  }
}
