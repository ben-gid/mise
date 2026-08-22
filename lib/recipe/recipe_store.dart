import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:path_provider/path_provider.dart';

import 'recipe_models.dart';

/// A stored recipe and the id it was saved under. Recipes carry no id of their
/// own — the schema describes what an LLM emits, not how we file it — so the
/// filename is the id.
typedef SavedRecipe = (String id, Recipe recipe);

/// What the user thought of a recipe after cooking it. Kept out of [Recipe] on
/// purpose: the schema describes what an LLM emits, and a star rating from the
/// model would be meaningless.
typedef RecipeRating = ({int stars, String note});

/// Recipes as one JSON file each, in the app documents directory.
class RecipeStore {
  final Directory dir;

  RecipeStore(this.dir);

  static Future<RecipeStore> open() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/recipes');
    await dir.create(recursive: true);
    return RecipeStore(dir);
  }

  File _file(String id) => File('${dir.path}/$id.json');

  Future<String> save(Recipe recipe) async {
    final id = _idFor(recipe);
    await _file(id).writeAsString(jsonEncode(recipe.toJson()));
    return id;
  }

  /// Deletes the recipe and every earlier version of it. Deleting only the tip
  /// would promote its parent back into [loadAll], so a swipe-to-delete would
  /// leave the recipe on screen as its previous version.
  ///
  /// Leaves ratings behind: the list screen's Undo re-saves under the same id,
  /// and a stale entry costs a few bytes.
  // ponytail: Undo restores the recipe, not its lineage. Tombstone the chain if
  // that bites.
  Future<void> delete(String id) async {
    final parents = await _history();
    // `seen` only matters if the sidecar has been corrupted into a cycle;
    // saveVersion can't create one. Cheaper than a hung delete.
    final seen = <String>{};
    var unlinked = false;
    for (var current = id; seen.add(current);) {
      final file = _file(current);
      if (file.existsSync()) await file.delete();
      final parent = parents.remove(current);
      if (parent is! String) break;
      unlinked = true;
      current = parent;
    }
    // Deleting something with no history stays a no-op rather than writing a
    // sidecar that has nothing to say.
    if (unlinked) await _historyFile.writeAsString(jsonEncode(parents));
  }

  /// Which version each version was edited from, as `{childId: parentId}`.
  /// A sidecar and not a field on [Recipe]: the schema describes what an LLM
  /// emits, and an LLM never emits a parent pointer.
  File get _historyFile => File('${dir.path}/history.meta');

  Future<Map<String, dynamic>> _history() async {
    final file = _historyFile;
    if (!file.existsSync()) return {};
    try {
      return jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    } catch (e) {
      // Losing the links costs history, not recipes — every version then reads
      // as its own tip rather than disappearing from the list.
      debugPrint('Skipping unreadable history ${file.path}: $e');
      return {};
    }
  }

  /// Saves [recipe] as a new version of [parent], returning it under its new id.
  ///
  /// `createdAt` is stamped to now, which is what makes the id new — [_idFor]
  /// derives from it. Restoring an old version without this would regenerate
  /// that version's own id and overwrite it in place, and since it is still
  /// someone's parent, [loadAll] would then drop the whole recipe.
  Future<SavedRecipe> saveVersion(
    Recipe recipe, {
    required String parent,
  }) async {
    final versioned = Recipe.fromJson({
      ...recipe.toJson(),
      'created_at': DateTime.now().toIso8601String(),
    });
    final id = await save(versioned);
    final parents = await _history()
      ..[id] = parent;
    await _historyFile.writeAsString(jsonEncode(parents));
    return (id, versioned);
  }

  /// [id] first, then each version it was edited from, oldest last. A recipe
  /// that was never edited returns just itself.
  Future<List<SavedRecipe>> history(String id) async {
    final parents = await _history();
    final chain = <SavedRecipe>[];
    final seen = <String>{};
    for (String? current = id; current != null && seen.add(current);) {
      final recipe = await _read(_file(current));
      if (recipe != null) chain.add((current, recipe));
      final parent = parents[current];
      current = parent is String ? parent : null;
    }
    return chain;
  }

  /// Ratings live in one sidecar map rather than in the recipe files. The
  /// `.meta` extension keeps [loadAll] from trying to read it as a recipe.
  File get _ratingsFile => File('${dir.path}/ratings.meta');

  Future<Map<String, dynamic>> _ratings() async {
    final file = _ratingsFile;
    if (!file.existsSync()) return {};
    try {
      return jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('Skipping unreadable ratings ${file.path}: $e');
      return {};
    }
  }

  Future<RecipeRating?> rating(String id) async {
    final entry = (await _ratings())[id];
    if (entry is! Map) return null;
    return (stars: entry['stars'] as int, note: entry['note'] as String);
  }

  /// An empty rating removes the entry rather than storing a blank one.
  Future<void> setRating(String id, RecipeRating rating) async {
    final ratings = await _ratings();
    if (rating.stars == 0 && rating.note.isEmpty) {
      ratings.remove(id);
    } else {
      ratings[id] = {'stars': rating.stars, 'note': rating.note};
    }
    await _ratingsFile.writeAsString(jsonEncode(ratings));
  }

  /// The theme the user picked, as a [ThemeMode] name, or null for never
  /// chosen. Plain text in its own `.meta` sidecar: one setting doesn't earn a
  /// JSON map, and an unreadable one falls back rather than failing.
  File get _themeFile => File('${dir.path}/theme.meta');

  Future<String?> themeName() async =>
      _themeFile.existsSync() ? _themeFile.readAsString() : null;

  Future<void> setThemeName(String name) => _themeFile.writeAsString(name);

  /// The display unit systems, as `"<weight>,<volume>"` [UnitSystem] names, or
  /// null for never chosen. Same plain-text sidecar as the theme, and one file
  /// rather than two — the two settings are always written together.
  File get _unitsFile => File('${dir.path}/units.meta');

  Future<String?> unitSystems() async =>
      _unitsFile.existsSync() ? _unitsFile.readAsString() : null;

  Future<void> setUnitSystems(String names) => _unitsFile.writeAsString(names);

  /// One recipe file, or null if it won't decode — a corrupt file is skipped
  /// and logged rather than taking a whole listing down with it, and nothing is
  /// deleted, so it stays recoverable by hand.
  Future<Recipe?> _read(File file) async {
    if (!file.existsSync()) return null;
    try {
      final json = jsonDecode(await file.readAsString());
      return Recipe.fromJson(json as Map<String, dynamic>);
    } catch (e) {
      debugPrint('Skipping unreadable recipe ${file.path}: $e');
      return null;
    }
  }

  /// Current versions only, newest first. Earlier versions stay on disk but are
  /// reached through [history] — listing them here would show one row per edit.
  Future<List<SavedRecipe>> loadAll() async {
    if (!dir.existsSync()) return [];
    final files = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.json'))
        .toList();
    final ids = {
      for (final file in files)
        file.uri.pathSegments.last.replaceFirst('.json', ''): file,
    };
    // A tip is a version no *existing* file names as its parent. Reading the
    // links off surviving files means a deleted child can't strand its parent.
    final parents = await _history();
    final superseded = {
      for (final entry in parents.entries)
        if (ids.containsKey(entry.key)) entry.value,
    };

    final saved = <SavedRecipe>[];
    for (final MapEntry(key: id, value: file) in ids.entries) {
      if (superseded.contains(id)) continue;
      final recipe = await _read(file);
      if (recipe != null) saved.add((id, recipe));
    }
    saved.sort((a, b) => b.$2.createdAt.compareTo(a.$2.createdAt));
    return saved;
  }
}

/// Re-importing the same recipe overwrites it instead of duplicating.
String _idFor(Recipe recipe) {
  final slug = recipe.title
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-|-$'), '');
  return '${recipe.createdAt.millisecondsSinceEpoch}-$slug';
}
