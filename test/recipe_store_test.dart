import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mise/recipe/recipe_parser.dart';
import 'package:mise/recipe/recipe_store.dart';

void main() {
  final parser = RecipeParser(File(recipeSchemaAsset).readAsStringSync());
  final validJson = File('test/fixtures/valid_recipe.json').readAsStringSync();

  late Directory dir;
  late RecipeStore store;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('recipe_store_test');
    store = RecipeStore(dir);
  });

  tearDown(() => dir.deleteSync(recursive: true));

  /// The fixture with a different title and timestamp, so ids differ.
  String variant(String title, String createdAt) {
    final map = jsonDecode(validJson) as Map<String, dynamic>;
    map['title'] = title;
    map['created_at'] = createdAt;
    return jsonEncode(map);
  }

  test('empty store loads nothing', () async {
    expect(await store.loadAll(), isEmpty);
  });

  test('saves and loads a recipe intact', () async {
    final id = await store.save(parser.parse(validJson));
    final loaded = await store.loadAll();

    expect(loaded, hasLength(1));
    expect(loaded.single.$1, id);
    expect(loaded.single.$2.title, 'Garlic Butter Focaccia');
    expect(loaded.single.$2.ingredients, hasLength(7));
    expect(loaded.single.$2.ingredientById('0005')!.unit, isNull);
    expect(loaded.single.$2.steps[1].timerSeconds, 7200);
  });

  test('saved file is still schema-valid on disk', () async {
    final id = await store.save(parser.parse(validJson));
    final onDisk = File('${dir.path}/$id.json').readAsStringSync();

    expect(() => parser.parse(onDisk), returnsNormally);
  });

  test('loads newest first', () async {
    await store.save(parser.parse(variant('Older', '2026-01-01T00:00:00Z')));
    await store.save(parser.parse(variant('Newer', '2026-08-01T00:00:00Z')));

    final titles = (await store.loadAll()).map((s) => s.$2.title);
    expect(titles, ['Newer', 'Older']);
  });

  test('re-saving the same recipe overwrites rather than duplicates', () async {
    await store.save(parser.parse(validJson));
    await store.save(parser.parse(validJson));

    expect(await store.loadAll(), hasLength(1));
  });

  test('delete removes only that recipe', () async {
    final keep = await store.save(parser.parse(validJson));
    final drop = await store.save(
      parser.parse(variant('Doomed', '2026-01-01T00:00:00Z')),
    );

    await store.delete(drop);

    expect((await store.loadAll()).single.$1, keep);
    expect(() => store.delete('does-not-exist'), returnsNormally);
  });

  test('a version chains to its parent and replaces it in the list', () async {
    final first = await store.save(parser.parse(validJson));
    final second = await store.saveVersion(
      parser.parse(variant('Focaccia v2', '2026-01-01T00:00:00Z')),
      parent: first,
    );

    // The parent is still on disk, just no longer a tip.
    expect(File('${dir.path}/$first.json').existsSync(), isTrue);
    expect((await store.loadAll()).single.$1, second.$1);

    final chain = await store.history(second.$1);
    expect(chain.map((s) => s.$1), [second.$1, first]);
    expect(chain.last.$2.title, 'Garlic Butter Focaccia');
  });

  test('saveVersion stamps a new createdAt rather than overwriting', () async {
    final first = await store.save(parser.parse(validJson));
    // Same title and same createdAt as its parent: without the stamp this
    // would regenerate the parent's own id and clobber it.
    final second = await store.saveVersion(
      parser.parse(validJson),
      parent: first,
    );

    expect(second.$1, isNot(first));
    expect(
      second.$2.createdAt.isAfter(parser.parse(validJson).createdAt),
      isTrue,
    );
    expect(await store.loadAll(), hasLength(1));
    expect((await store.history(second.$1)), hasLength(2));
  });

  test('restoring an older version keeps that version intact', () async {
    final first = await store.save(parser.parse(validJson));
    final second = await store.saveVersion(
      parser.parse(variant('Doubled', '2026-01-01T00:00:00Z')),
      parent: first,
    );

    // Restore = save the old snapshot as a new tip. If it reused the old id it
    // would overwrite v1, which is still v2's parent, and loadAll would then
    // drop the recipe entirely.
    final original = (await store.history(second.$1)).last;
    final restored = await store.saveVersion(original.$2, parent: second.$1);

    expect(restored.$1, isNot(first));
    expect(File('${dir.path}/$first.json').existsSync(), isTrue);
    expect((await store.loadAll()).single.$1, restored.$1);
    expect((await store.history(restored.$1)).map((s) => s.$2.title), [
      'Garlic Butter Focaccia',
      'Doubled',
      'Garlic Butter Focaccia',
    ]);
  });

  test('deleting a recipe deletes its earlier versions too', () async {
    final first = await store.save(parser.parse(validJson));
    final second = await store.saveVersion(
      parser.parse(variant('v2', '2026-01-01T00:00:00Z')),
      parent: first,
    );
    final other = await store.save(
      parser.parse(variant('Untouched', '2026-02-02T00:00:00Z')),
    );

    await store.delete(second.$1);

    // Not just the tip: leaving the parent behind would promote it back into
    // the list, so the recipe would reappear as its previous version.
    expect(File('${dir.path}/$first.json').existsSync(), isFalse);
    expect((await store.loadAll()).single.$1, other);
  });

  test('a corrupt history file loses versions, not recipes', () async {
    final first = await store.save(parser.parse(validJson));
    final second = await store.saveVersion(
      parser.parse(variant('v2', '2026-01-01T00:00:00Z')),
      parent: first,
    );
    File('${dir.path}/history.meta').writeAsStringSync('{"broken": ');

    // Both files survive and both list, rather than the recipe vanishing.
    expect(
      (await store.loadAll()).map((s) => s.$1),
      unorderedEquals([first, second.$1]),
    );
    expect(await store.history(second.$1), hasLength(1));
  });

  test('history of a never-edited recipe is just itself', () async {
    final id = await store.save(parser.parse(validJson));
    expect((await store.history(id)).map((s) => s.$1), [id]);
  });

  test('a rating round-trips', () async {
    final id = await store.save(parser.parse(validJson));

    await store.setRating(id, (stars: 4, note: 'Halve the garlic next time'));

    expect(await store.rating(id), (
      stars: 4,
      note: 'Halve the garlic next time',
    ));
  });

  test('an unrated recipe has no rating', () async {
    final id = await store.save(parser.parse(validJson));
    expect(await store.rating(id), isNull);
  });

  test('an empty rating is removed rather than stored blank', () async {
    final id = await store.save(parser.parse(validJson));

    await store.setRating(id, (stars: 3, note: 'meh'));
    await store.setRating(id, (stars: 0, note: ''));

    expect(await store.rating(id), isNull);
  });

  test('ratings live beside the recipes without disturbing loadAll', () async {
    final id = await store.save(parser.parse(validJson));
    await store.setRating(id, (stars: 5, note: 'keeper'));

    // The sidecar is not a .json file, so loadAll never tries to read it as a
    // recipe — and the recipe file itself stays schema-valid.
    expect((await store.loadAll()).single.$1, id);
    final onDisk = File('${dir.path}/$id.json').readAsStringSync();
    expect(() => parser.parse(onDisk), returnsNormally);
  });

  test('a corrupt ratings file loses ratings, not recipes', () async {
    final id = await store.save(parser.parse(validJson));
    File('${dir.path}/ratings.meta').writeAsStringSync('{"broken": ');

    expect((await store.loadAll()).single.$1, id);
    expect(await store.rating(id), isNull);

    // ...and the next write starts a clean file rather than failing forever.
    await store.setRating(id, (stars: 1, note: ''));
    expect(await store.rating(id), (stars: 1, note: ''));
  });

  test('the theme survives a restart and is not read as a recipe', () async {
    expect(await store.themeName(), isNull);

    await store.save(parser.parse(validJson));
    await store.setThemeName('dark');

    expect(await RecipeStore(dir).themeName(), 'dark');
    expect(await store.loadAll(), hasLength(1));
  });

  test('a corrupt file is skipped, not fatal', () async {
    await store.save(parser.parse(validJson));
    File('${dir.path}/broken.json').writeAsStringSync('{"title": ');

    final loaded = await store.loadAll();

    expect(loaded, hasLength(1));
    expect(loaded.single.$2.title, 'Garlic Butter Focaccia');
    // Skipped, never deleted — still there to recover by hand.
    expect(File('${dir.path}/broken.json').existsSync(), isTrue);
  });
}
