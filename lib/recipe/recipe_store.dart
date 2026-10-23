import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:path_provider/path_provider.dart';

import 'recipe_models.dart';

/// A stored recipe and the id it was saved under. Recipes carry no id of their
/// own — the schema describes what an LLM emits, not how we file it — so the
/// filename is the id.
typedef SavedRecipe = (String id, Recipe recipe);

/// One time a version was cooked, and how it went. Kept out of [Recipe] on
/// purpose: the schema describes what an LLM emits, and a star rating from the
/// model would be meaningless.
///
/// [stars] is 0 for a note-only entry. [servings] is null only on an entry
/// migrated from the single rating a version used to have, which never
/// recorded it.
typedef CookEntry = ({
  String id,
  DateTime date,
  int? servings,
  int stars,
  String note,
});

/// The stars a version shows: its newest cook that was rated, so a fix shows
/// up the next time it's made and a note-only entry doesn't reset the verdict.
/// [entries] newest first, as [RecipeStore.entries] returns them.
int headlineStars(List<CookEntry> entries) =>
    entries.map((e) => e.stars).firstWhere((s) => s > 0, orElse: () => 0);

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

  /// The cook log lives in one sidecar map, `{versionId: [entry, ...]}`,
  /// rather than in the recipe files. The `.meta` extension keeps [loadAll]
  /// from trying to read it as a recipe. Named for what it held before a
  /// version could be cooked more than once.
  File get _logFile => File('${dir.path}/ratings.meta');

  Future<Map<String, List<CookEntry>>> _log() async {
    final file = _logFile;
    if (!file.existsSync()) return {};
    try {
      final raw = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      return {
        for (final MapEntry(key: id, value: value) in raw.entries)
          id: switch (value) {
            List() => [for (final e in value) _decodeEntry(e as Map)],
            // A version's single rating from before the log. Dated from the
            // version itself — its id starts with its createdAt — since when
            // it was cooked was never recorded.
            Map() => [
              (
                id: 'legacy',
                date: DateTime.fromMillisecondsSinceEpoch(
                  int.tryParse(id.split('-').first) ?? 0,
                ),
                servings: null,
                stars: value['stars'] as int,
                note: value['note'] as String,
              ),
            ],
            _ => throw FormatException('Bad cook log for $id'),
          },
      };
    } catch (e) {
      // Losing the log costs notes, not recipes.
      debugPrint('Skipping unreadable cook log ${file.path}: $e');
      return {};
    }
  }

  Future<void> _writeLog(Map<String, List<CookEntry>> log) =>
      _logFile.writeAsString(
        jsonEncode({
          for (final MapEntry(key: id, value: entries) in log.entries)
            id: [
              for (final e in entries)
                {
                  'id': e.id,
                  // UTC on disk, so a cook keeps its moment when the phone
                  // changes timezone — or, once logs sync, changes phone.
                  'date': e.date.toUtc().toIso8601String(),
                  'servings': e.servings,
                  'stars': e.stars,
                  'note': e.note,
                },
            ],
        }),
      );

  /// Every time version [id] was cooked, newest first.
  Future<List<CookEntry>> entries(String id) async =>
      [...?(await _log())[id]]..sort((a, b) => b.date.compareTo(a.date));

  /// Adds [entry] to version [id]'s log, or replaces the one with its id.
  Future<void> saveEntry(String id, CookEntry entry) async {
    final log = await _log();
    log[id] = [
      for (final e in log[id] ?? const <CookEntry>[])
        if (e.id != entry.id) e,
      entry,
    ];
    await _writeLog(log);
  }

  /// Removes one entry. A version whose last entry goes loses its key rather
  /// than keeping an empty list.
  Future<void> deleteEntry(String id, String entryId) async {
    final log = await _log();
    final remaining = [
      for (final e in log[id] ?? const <CookEntry>[])
        if (e.id != entryId) e,
    ];
    if (remaining.isEmpty) {
      log.remove(id);
    } else {
      log[id] = remaining;
    }
    await _writeLog(log);
  }

  /// Copies a picked photo in beside the recipes, returning the url to store
  /// on the recipe as `image_url`.
  ///
  /// The url is relative on purpose. iOS hands the app container a new UUID on
  /// every update, so an absolute path saved today is a dead path after the
  /// next release — the recipe would keep pointing at a file that moved. The
  /// `mise://` scheme is what tells [imageFor] to resolve against [dir].
  ///
  /// Named by timestamp, the same way recipe ids are.
  // ponytail: a deleted or abandoned recipe leaves its photo behind. Deleting
  // them would break the list screen's Undo, which re-saves the recipe and
  // would find the photo gone. Sweep unreferenced files if storage matters.
  Future<String> addImage(String sourcePath) async {
    final dot = sourcePath.lastIndexOf('.');
    final ext = dot == -1 ? '.jpg' : sourcePath.substring(dot);
    final name = '${DateTime.now().millisecondsSinceEpoch}$ext';
    await File(sourcePath).copy('${dir.path}/$name');
    return 'mise://$name';
  }

  /// A picked photo by filename. Photos sit beside the recipes and are hidden
  /// from [loadAll] by its `.json` filter, the same way the `.meta` sidecars
  /// are — a photo saved as `.json` would show up as a corrupt recipe.
  File imageFile(String name) => File('${dir.path}/$name');

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

CookEntry _decodeEntry(Map e) => (
  id: e['id'] as String,
  date: DateTime.parse(e['date'] as String).toLocal(),
  servings: e['servings'] as int?,
  stars: e['stars'] as int,
  note: e['note'] as String,
);

/// Re-importing the same recipe overwrites it instead of duplicating.
String _idFor(Recipe recipe) {
  final slug = recipe.title
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-|-$'), '');
  return '${recipe.createdAt.millisecondsSinceEpoch}-$slug';
}
