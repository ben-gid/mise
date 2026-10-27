import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mise/recipe/recipe_models.dart';
import 'package:mise/recipe/recipe_parser.dart';
import 'package:mise/recipe/recipe_store.dart';

void main() {
  final parser = RecipeParser(File(recipeSchemaAsset).readAsStringSync());
  final validJson = File(
    'test/fixtures/valid/focaccia.json',
  ).readAsStringSync();

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

  // A recipe written before the headnote replaced the separate `description`
  // field. It reaches [Recipe.fromJson] without ever passing the validator —
  // which is what lets the schema drop `description` outright — so the fold is
  // the only thing carrying that text forward.
  group('a recipe saved with the old description field', () {
    String legacy({String? notes}) {
      final map = jsonDecode(validJson) as Map<String, dynamic>;
      map['description'] = 'Slow-proofed focaccia with a garlic butter crust.';
      if (notes == null) {
        map.remove('notes');
      } else {
        map['notes'] = notes;
      }
      return jsonEncode(map);
    }

    test('reads as the headnote', () async {
      File('${dir.path}/1-legacy.json').writeAsStringSync(legacy());
      final loaded = await store.loadAll();

      expect(
        loaded.single.$2.notes,
        'Slow-proofed focaccia with a garlic butter crust.',
      );
    });

    test('keeps its own notes too, description first', () async {
      File(
        '${dir.path}/1-legacy.json',
      ).writeAsStringSync(legacy(notes: 'Rest it overnight.'));
      final loaded = await store.loadAll();

      expect(
        loaded.single.$2.notes,
        'Slow-proofed focaccia with a garlic butter crust.\n\n'
        'Rest it overnight.',
      );
    });

    test('drops the old field on its next save, still schema-valid', () async {
      File('${dir.path}/1-legacy.json').writeAsStringSync(legacy());
      final loaded = await store.loadAll();

      final id = await store.save(loaded.single.$2);
      final onDisk = File('${dir.path}/$id.json').readAsStringSync();

      expect(jsonDecode(onDisk), isNot(contains('description')));
      expect(() => parser.parse(onDisk), returnsNormally);
    });
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

  CookEntry entry(
    String id,
    DateTime date, {
    int? servings = 4,
    int stars = 0,
    String note = '',
  }) => (id: id, date: date, servings: servings, stars: stars, note: note);

  test('a cook entry round-trips', () async {
    final id = await store.save(parser.parse(validJson));
    final cooked = entry(
      'a',
      DateTime(2026, 10, 3, 19),
      servings: 6,
      stars: 4,
      note: 'Halve the garlic next time',
    );

    await store.saveEntry(id, cooked);

    expect(await store.entries(id), [cooked]);
    // On disk in UTC, so the moment survives a change of timezone.
    final onDisk = File('${dir.path}/ratings.meta').readAsStringSync();
    expect(onDisk, contains(cooked.date.toUtc().toIso8601String()));
  });

  test('a date saved without an offset still reads as local time', () async {
    final id = await store.save(parser.parse(validJson));
    File('${dir.path}/ratings.meta').writeAsStringSync(
      jsonEncode({
        id: [
          {
            'id': 'a',
            'date': '2026-10-22T15:32:59.325',
            'servings': 6,
            'stars': 5,
            'note': '',
          },
        ],
      }),
    );

    expect(
      (await store.entries(id)).single.date,
      DateTime(2026, 10, 22, 15, 32, 59, 325),
    );
  });

  test('a never-cooked recipe has no entries', () async {
    final id = await store.save(parser.parse(validJson));
    expect(await store.entries(id), isEmpty);
  });

  test('saving an entry under an existing id replaces it', () async {
    final id = await store.save(parser.parse(validJson));
    await store.saveEntry(id, entry('a', DateTime(2026, 10, 3), stars: 2));

    await store.saveEntry(id, entry('a', DateTime(2026, 10, 3), stars: 5));

    expect((await store.entries(id)).single.stars, 5);
  });

  test('entries come back newest first', () async {
    final id = await store.save(parser.parse(validJson));
    await store.saveEntry(id, entry('old', DateTime(2026, 10, 3)));
    await store.saveEntry(id, entry('new', DateTime(2026, 10, 17)));
    await store.saveEntry(id, entry('mid', DateTime(2026, 10, 10)));

    expect((await store.entries(id)).map((e) => e.id), ['new', 'mid', 'old']);
  });

  test('deleting the last entry removes the recipe from the log', () async {
    final id = await store.save(parser.parse(validJson));
    await store.saveEntry(id, entry('a', DateTime(2026, 10, 3)));
    await store.saveEntry(id, entry('b', DateTime(2026, 10, 4)));

    await store.deleteEntry(id, 'a');
    expect((await store.entries(id)).map((e) => e.id), ['b']);

    await store.deleteEntry(id, 'b');
    expect(await store.entries(id), isEmpty);
    // No empty list left behind for the id.
    final onDisk = File('${dir.path}/ratings.meta').readAsStringSync();
    expect(jsonDecode(onDisk), isEmpty);
  });

  test('an old single rating reads as one entry from the version', () async {
    final id = await store.save(parser.parse(validJson));
    File('${dir.path}/ratings.meta').writeAsStringSync(
      jsonEncode({
        id: {'stars': 4, 'note': 'crisp'},
      }),
    );

    // Dated from the version itself: the id starts with its createdAt.
    final created = DateTime.fromMillisecondsSinceEpoch(
      int.parse(id.split('-').first),
    );
    expect(await store.entries(id), [
      entry('legacy', created, servings: null, stars: 4, note: 'crisp'),
    ]);

    // ...and survives the first write in the new shape.
    await store.saveEntry(id, entry('b', created.add(const Duration(days: 1))));
    expect((await store.entries(id)).map((e) => e.id), ['b', 'legacy']);
  });

  test('entries live beside the recipes without disturbing loadAll', () async {
    final id = await store.save(parser.parse(validJson));
    await store.saveEntry(id, entry('a', DateTime(2026, 10, 3), stars: 5));

    // The sidecar is not a .json file, so loadAll never tries to read it as a
    // recipe — and the recipe file itself stays schema-valid.
    expect((await store.loadAll()).single.$1, id);
    final onDisk = File('${dir.path}/$id.json').readAsStringSync();
    expect(() => parser.parse(onDisk), returnsNormally);
  });

  test('a corrupt log file loses entries, not recipes', () async {
    final id = await store.save(parser.parse(validJson));
    File('${dir.path}/ratings.meta').writeAsStringSync('{"broken": ');

    expect((await store.loadAll()).single.$1, id);
    expect(await store.entries(id), isEmpty);

    // ...and the next write starts a clean file rather than failing forever.
    final cooked = entry('a', DateTime(2026, 10, 3), stars: 1);
    await store.saveEntry(id, cooked);
    expect(await store.entries(id), [cooked]);
  });

  test('the headline is the newest entry that has stars', () {
    expect(headlineStars([]), 0);
    expect(
      headlineStars([
        // Newest first, as entries() returns them. A note-only cook doesn't
        // reset the verdict.
        entry('c', DateTime(2026, 10, 20), note: 'out of thyme'),
        entry('b', DateTime(2026, 10, 17), stars: 5),
        entry('a', DateTime(2026, 10, 3), stars: 3),
      ]),
      5,
    );
    expect(headlineStars([entry('a', DateTime(2026, 10, 3))]), 0);
  });

  test('the theme survives a restart and is not read as a recipe', () async {
    expect(await store.themeName(), isNull);

    await store.save(parser.parse(validJson));
    await store.setThemeName('dark');

    expect(await RecipeStore(dir).themeName(), 'dark');
    expect(await store.loadAll(), hasLength(1));
  });

  test('Ask me starts on and remembers being turned off', () async {
    expect(await store.askMe(), isTrue);

    await store.setAskMe(false);

    expect(await RecipeStore(dir).askMe(), isFalse);
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

  // Two directories standing in for two phones, with rows carried between
  // them by hand the way sync carries them.
  group('two phones', () {
    late Directory otherDir;
    late RecipeStore other;

    setUp(() {
      otherDir = Directory.systemTemp.createTempSync('recipe_store_other');
      other = RecipeStore(otherDir);
    });

    tearDown(() => otherDir.deleteSync(recursive: true));

    Recipe retitled(Recipe recipe, String title) =>
        Recipe.fromJson({...recipe.toJson(), 'title': title});

    Future<void> carry(RecipeStore from, RecipeStore to, String key) async =>
        to.applyRows({key: (await from.rows())[key]});

    test('one applying the other\'s rows ends up with the same rows', () async {
      final original = parser.parse(validJson);
      final a = await store.save(original);
      final b = await store.saveVersion(
        retitled(original, 'Edited'),
        parent: a,
      );
      await store.saveEntry(b.$1, (
        id: '1',
        date: DateTime(2026, 10, 20),
        servings: 4,
        stars: 5,
        note: 'More salt',
      ));
      await store.setUnitSystems('imperial,metric,weight');

      await other.applyRows(await store.rows());

      expect(await other.rows(), await store.rows());
      expect((await other.loadAll()).single.$1, b.$1);
      expect(await other.unitSystems(), 'imperial,metric,weight');
    });

    test('a pulled deletion removes one version, not its chain', () async {
      final original = parser.parse(validJson);
      final a = await store.save(original);
      final b = await store.saveVersion(
        retitled(original, 'Edited'),
        parent: a,
      );

      await store.applyRows({'v/${b.$1}': null});

      expect((await store.loadAll()).single.$1, a);
    });

    test('both editing the same version: one recipe, the older edit in its '
        'history', () async {
      final original = parser.parse(validJson);
      final a = await store.save(original);
      await carry(store, other, 'v/$a');

      final here = await store.saveVersion(
        retitled(original, 'Here'),
        parent: a,
      );
      // Distinct milliseconds, so which edit is older isn't a tie.
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final there = await other.saveVersion(
        retitled(original, 'There'),
        parent: a,
      );
      await carry(other, store, 'v/${there.$1}');
      await carry(store, other, 'v/${here.$1}');

      for (final phone in [store, other]) {
        expect((await phone.loadAll()).map((s) => s.$1), [there.$1]);
        expect((await phone.history(there.$1)).map((s) => s.$1), [
          there.$1,
          here.$1,
          a,
        ]);
        expect(await phone.forked(), {there.$1});
      }
    });

    test('deleting a forked recipe deletes both edits', () async {
      final original = parser.parse(validJson);
      final a = await store.save(original);
      await store.saveVersion(retitled(original, 'Here'), parent: a);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await carry(store, other, 'v/$a');
      final there = await other.saveVersion(
        retitled(original, 'There'),
        parent: a,
      );
      await carry(other, store, 'v/${there.$1}');

      await store.delete(there.$1);

      expect(await store.loadAll(), isEmpty);
      expect(
        (await store.rows()).keys.where((k) => k.startsWith('v/')),
        isEmpty,
      );
    });

    test('newest follows a version on to what arrived after it', () async {
      final original = parser.parse(validJson);
      final a = await store.save(original);
      await carry(store, other, 'v/$a');
      final b = await other.saveVersion(retitled(original, 'There'), parent: a);

      expect((await store.newest(a))!.$1, a);
      await carry(other, store, 'v/${b.$1}');
      expect((await store.newest(a))!.$1, b.$1);
      expect((await store.newest(b.$1))!.$1, b.$1);
    });

    test(
      'a pulled recipe is filed under its own id, never the one it names',
      () async {
        await store.save(parser.parse(validJson));
        final row = (await store.rows()).values.first;

        await other.applyRows({'v/../escaped': row});

        expect(await other.loadAll(), isEmpty);
        expect(
          File('${otherDir.parent.path}/escaped.json').existsSync(),
          isFalse,
        );
      },
    );

    test(
      'a person\'s writes notify sync once each; sync\'s own do not',
      () async {
        var writes = 0;
        store.onWrite = () => writes++;
        final original = parser.parse(validJson);

        final a = await store.save(original);
        await store.saveVersion(retitled(original, 'Edited'), parent: a);
        expect(writes, 2);

        await store.applyRows(await store.rows());
        expect(writes, 2);
      },
    );
  });
}
