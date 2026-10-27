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

  /// Called once after every write a person made — never after [applyRows],
  /// which is sync writing what it pulled. Set by `startSync`; null otherwise.
  void Function()? onWrite;

  RecipeStore(this.dir);

  static Future<RecipeStore> open() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/recipes');
    await dir.create(recursive: true);
    return RecipeStore(dir);
  }

  File _file(String id) => File('${dir.path}/$id.json');

  Future<String> save(Recipe recipe) async {
    final id = await _save(recipe);
    onWrite?.call();
    return id;
  }

  /// [save] without the [onWrite], for [saveVersion]: sync must not read a
  /// version before its parent link is written.
  Future<String> _save(Recipe recipe) async {
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
  ///
  /// Walks [_linear]'s parents, so a recipe two phones forked goes whole.
  Future<void> delete(String id) async {
    final recorded = await _history();
    final parents = _linear(recorded);
    // `seen` only matters if the sidecar has been corrupted into a cycle;
    // saveVersion can't create one. Cheaper than a hung delete.
    final seen = <String>{};
    var unlinked = false;
    for (String? current = id; current != null && seen.add(current);) {
      final file = _file(current);
      if (file.existsSync()) await file.delete();
      unlinked |= recorded.remove(current) != null;
      current = parents[current];
    }
    // Deleting something with no history stays a no-op rather than writing a
    // sidecar that has nothing to say.
    if (unlinked) await _historyFile.writeAsString(jsonEncode(recorded));
    onWrite?.call();
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

  /// The parents [loadAll], [history] and [delete] go by, as opposed to the
  /// ones [_history] recorded.
  ///
  /// Two phones that each edited the same version leave two children naming
  /// it, and both would list as the recipe. Chaining every version of a
  /// recipe by when it was made puts the older edit into the newer one's
  /// history instead — the same order on every phone, so nothing needs
  /// syncing back. A plain chain comes back unchanged, because a child is
  /// always newer than its parent.
  Map<String, String> _linear(Map<String, dynamic> recorded) {
    String rootOf(String id) {
      // `seen` for the same corrupted-into-a-cycle sidecar [delete] guards.
      final seen = {id};
      var current = id;
      while (true) {
        final parent = recorded[current];
        if (parent is! String || !seen.add(parent)) return current;
        current = parent;
      }
    }

    final recipes = <String, List<String>>{};
    for (final id in {
      ...recorded.keys,
      ...recorded.values.whereType<String>(),
    }) {
      (recipes[rootOf(id)] ??= []).add(id);
    }
    return {
      for (final versions in recipes.values)
        for (final (i, id) in (versions..sort(_byAge)).indexed.skip(1))
          id: versions[i - 1],
    };
  }

  /// The newest version of the recipe [id] belongs to — [id] itself unless a
  /// later one has arrived, which with sync can happen while it's on screen.
  Future<SavedRecipe?> newest(String id) async {
    final children = {
      for (final MapEntry(key: child, value: parent) in _linear(
        await _history(),
      ).entries)
        parent: child,
    };
    final seen = {id};
    var tip = id;
    for (var child = children[tip]; child != null && seen.add(child);) {
      tip = child;
      child = children[tip];
    }
    final recipe = await _read(_file(tip));
    return recipe == null ? null : (tip, recipe);
  }

  /// Versions whose place in the chain is not the version they were edited
  /// from — the newer half of a fork. Their diff is against the other phone's
  /// edit, which the history screen says.
  Future<Set<String>> forked() async {
    final recorded = await _history();
    return {
      for (final MapEntry(key: id, value: parent) in _linear(recorded).entries)
        if (recorded[id] != parent) id,
    };
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
    final id = await _save(versioned);
    final parents = await _history()
      ..[id] = parent;
    await _historyFile.writeAsString(jsonEncode(parents));
    onWrite?.call();
    return (id, versioned);
  }

  /// [id] first, then each version it was edited from, oldest last. A recipe
  /// that was never edited returns just itself.
  Future<List<SavedRecipe>> history(String id) async {
    final parents = _linear(await _history());
    final chain = <SavedRecipe>[];
    final seen = <String>{};
    for (String? current = id; current != null && seen.add(current);) {
      final recipe = await _read(_file(current));
      if (recipe != null) chain.add((current, recipe));
      current = parents[current];
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
            List() => [for (final e in value) decodeEntry(e as Map)],
            // A version's single rating from before the log. Dated from the
            // version itself — its id starts with its createdAt — since when
            // it was cooked was never recorded.
            Map() => [
              (
                id: 'legacy',
                date: DateTime.fromMillisecondsSinceEpoch(_millis(id)),
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
            id: [for (final e in entries) encodeEntry(e)],
        }),
      );

  /// Every time version [id] was cooked, newest first.
  Future<List<CookEntry>> entries(String id) async =>
      [...?(await _log())[id]]..sort((a, b) => b.date.compareTo(a.date));

  /// Every version's log, each newest first: one read for a whole library,
  /// where [entries] per recipe would be one read per row.
  Future<Map<String, List<CookEntry>>> allEntries() async => {
    for (final MapEntry(key: id, value: log) in (await _log()).entries)
      id: [...log]..sort((a, b) => b.date.compareTo(a.date)),
  };

  /// Adds [entry] to version [id]'s log, or replaces the one with its id.
  Future<void> saveEntry(String id, CookEntry entry) async {
    final log = await _log();
    log[id] = [
      for (final e in log[id] ?? const <CookEntry>[])
        if (e.id != entry.id) e,
      entry,
    ];
    await _writeLog(log);
    onWrite?.call();
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
    onWrite?.call();
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

  Future<void> setUnitSystems(String names) async {
    await _unitsFile.writeAsString(names);
    onWrite?.call();
  }

  /// Whether Create asks questions before writing, on until turned off. A
  /// sidecar like the theme, and not synced: it is how this cook likes to
  /// start, not part of the library.
  File get _askMeFile => File('${dir.path}/ask.meta');

  Future<bool> askMe() async =>
      !_askMeFile.existsSync() || await _askMeFile.readAsString() != 'off';

  Future<void> setAskMe(bool on) => _askMeFile.writeAsString(on ? 'on' : 'off');

  /// Everything sync carries, flattened to one value per key:
  /// `v/<id>` → `{recipe, parent}` with the *recorded* parent, `e/<version>/<entry>`
  /// → a cook entry, `units` → the [setUnitSystems] line. A key that isn't
  /// here is a deletion. Photos are files, not rows; sync handles them apart.
  Future<Map<String, Object?>> rows() async {
    final parents = await _history();
    final rows = <String, Object?>{};
    for (final MapEntry(key: id, value: file) in _files().entries) {
      final recipe = await _read(file);
      if (recipe == null) continue;
      rows['v/$id'] = {'recipe': recipe.toJson(), 'parent': parents[id]};
    }
    for (final MapEntry(key: version, value: entries)
        in (await _log()).entries) {
      for (final e in entries) {
        rows['e/$version/${e.id}'] = encodeEntry(e);
      }
    }
    final units = await unitSystems();
    if (units != null) rows['units'] = units;
    return rows;
  }

  /// Writes what sync pulled, in [rows]' shape; null deletes that one version
  /// or entry. Recipes arrive validated. Doesn't call [onWrite] — this isn't a
  /// person's write, and syncing it back would be an echo.
  ///
  /// A recipe is filed under [_idFor] its own content, never a key it came
  /// with: an id is a filename, and a row naming `../` would write outside
  /// [dir].
  // ponytail: no lock against a saveEntry landing mid-apply, the same as two
  // saveEntry calls today. Serialise writes if a lost entry ever turns up.
  Future<void> applyRows(Map<String, Object?> changes) async {
    final parents = await _history();
    final log = await _log();
    for (final MapEntry(:key, :value) in changes.entries) {
      final [kind, ...rest] = key.split('/');
      switch (kind) {
        case 'v':
          final id = rest.join('/');
          final row = value as Map<String, dynamic>?;
          if (row == null) {
            final file = _file(id);
            if (_idPattern.hasMatch(id) && file.existsSync()) {
              await file.delete();
            }
            parents.remove(id);
            continue;
          }
          final recipe = Recipe.fromJson(row['recipe'] as Map<String, dynamic>);
          if (_idFor(recipe) != id) {
            debugPrint('Skipping synced recipe filed under the wrong id: $id');
            continue;
          }
          await _save(recipe);
          final parent = row['parent'];
          if (parent is String) {
            parents[id] = parent;
          } else {
            parents.remove(id);
          }
        case 'e':
          final [version, ...entry] = rest;
          final entryId = entry.join('/');
          final kept = [
            for (final e in log[version] ?? const <CookEntry>[])
              if (e.id != entryId) e,
            if (value != null) decodeEntry(value as Map),
          ];
          if (kept.isEmpty) {
            log.remove(version);
          } else {
            log[version] = kept;
          }
        case 'units':
          if (value is String) {
            await _unitsFile.writeAsString(value);
          } else if (_unitsFile.existsSync()) {
            await _unitsFile.delete();
          }
      }
    }
    await _historyFile.writeAsString(jsonEncode(parents));
    await _writeLog(log);
  }

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
    final ids = _files();
    // A tip is a version no *existing* file names as its parent. Reading the
    // links off surviving files means a deleted child can't strand its parent.
    final parents = _linear(await _history());
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

  /// Every recipe file by id.
  Map<String, File> _files() => !dir.existsSync()
      ? {}
      : {
          for (final file in dir.listSync().whereType<File>())
            if (file.path.endsWith('.json'))
              file.uri.pathSegments.last.replaceFirst('.json', ''): file,
        };
}

/// What [_idFor] makes, so a pulled deletion can't name a file outside the
/// recipes.
final _idPattern = RegExp(r'^\d+-[a-z0-9-]*$');

/// A version's createdAt, read off its id.
int _millis(String id) => int.tryParse(id.split('-').first) ?? 0;

int _byAge(String a, String b) {
  final byTime = _millis(a).compareTo(_millis(b));
  return byTime != 0 ? byTime : a.compareTo(b);
}

/// A cook entry as `ratings.meta` holds it, and as sync carries it.
Map<String, Object?> encodeEntry(CookEntry e) => {
  'id': e.id,
  // UTC on disk, so a cook keeps its moment when the phone changes timezone —
  // or changes phone.
  'date': e.date.toUtc().toIso8601String(),
  'servings': e.servings,
  'stars': e.stars,
  'note': e.note,
};

CookEntry decodeEntry(Map e) => (
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
