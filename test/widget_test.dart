import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mise/recipe/recipe_parser.dart';
import 'package:mise/recipe/recipe_store.dart';
import 'package:mise/recipe/ui/recipe_detail_screen.dart';
import 'package:mise/recipe/ui/recipe_list_screen.dart';

/// `testWidgets` runs in a fake-async zone, so real dart:io futures never
/// complete inside it — anything that touches [RecipeStore] has to run under
/// `tester.runAsync`. Persistence itself is covered by recipe_store_test.dart;
/// these tests cover the wiring.
void main() {
  final parser = RecipeParser(File(recipeSchemaAsset).readAsStringSync());
  final validJson = File('test/fixtures/valid_recipe.json').readAsStringSync();

  late Directory dir;
  late RecipeStore store;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('recipe_widget_test');
    store = RecipeStore(dir);
  });

  tearDown(() => dir.deleteSync(recursive: true));

  /// Pumps inside [tester.runAsync] until [ready], which must describe what the
  /// screen looks like once its store read has landed.
  ///
  /// A fixed delay here is a race: it competes with the first frame's layout and
  /// paint, and if the read loses, `runAsync` exits and the real dart:io future
  /// can never complete in the fake-async zone the rest of the test runs in.
  Future<void> pumpUntil(WidgetTester tester, bool Function() ready) async {
    for (var attempt = 0; attempt < 100; attempt++) {
      await tester.pump();
      if (ready()) return;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('the store read never landed');
  }

  /// Pumps the list screen and lets its real directory read finish.
  Future<void> pumpList(WidgetTester tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: RecipeListScreen(store: store, parser: parser),
        ),
      );
      // The FutureBuilder shows a blank placeholder until it resolves, then
      // one of these two.
      await pumpUntil(
        tester,
        () =>
            find.byType(ListView).evaluate().isNotEmpty ||
            find.text('No recipes yet').evaluate().isNotEmpty,
      );
    });
    await tester.pumpAndSettle();
  }

  Future<void> openImport(WidgetTester tester) async {
    await tester.tap(find.widgetWithText(FloatingActionButton, 'Import'));
    await tester.pumpAndSettle();
  }

  testWidgets('shows the empty state with nothing saved', (tester) async {
    await pumpList(tester);
    expect(find.text('No recipes yet'), findsOneWidget);
  });

  testWidgets('lists saved recipes on launch', (tester) async {
    await tester.runAsync(() => store.save(parser.parse(validJson)));

    await pumpList(tester);

    expect(find.text('Garlic Butter Focaccia'), findsOneWidget);
    expect(find.textContaining('4 servings'), findsOneWidget);
    expect(find.text('bread'), findsOneWidget); // tag chip
  });

  testWidgets('importing valid JSON saves it and opens the recipe', (
    tester,
  ) async {
    await pumpList(tester);
    await openImport(tester);

    await tester.runAsync(() async {
      await tester.enterText(find.byType(TextField), validJson);
      await tester.tap(find.widgetWithText(FilledButton, 'Import'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1)); // route transitions
    });
    await tester.pumpAndSettle();

    expect(find.text('Ingredients'), findsOneWidget); // on the detail screen
    final saved = await tester.runAsync(store.loadAll);
    expect(saved, hasLength(1));
  });

  testWidgets('invalid JSON lists every problem and saves nothing', (
    tester,
  ) async {
    await pumpList(tester);
    await openImport(tester);

    await tester.enterText(find.byType(TextField), '{"title": "Nope"}');
    await tester.tap(find.widgetWithText(FilledButton, 'Import'));
    await tester.pumpAndSettle();

    expect(find.textContaining('nothing was saved'), findsOneWidget);
    expect(find.textContaining('base_servings'), findsWidgets);
    expect(await tester.runAsync(store.loadAll), isEmpty);
  });

  testWidgets('malformed JSON does not crash the screen', (tester) async {
    await pumpList(tester);
    await openImport(tester);

    await tester.enterText(find.byType(TextField), '{"title": ');
    await tester.tap(find.widgetWithText(FilledButton, 'Import'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Malformed JSON'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  /// Pumps the detail screen and lets its real rating read finish.
  ///
  /// The recipe itself is passed in, so the body renders on the first frame;
  /// only the rating arrives asynchronously. Pass [ready] when the test depends
  /// on that rating having landed.
  Future<String> pumpDetail(
    WidgetTester tester, {
    bool Function()? ready,
  }) async {
    final id = (await tester.runAsync(
      () => store.save(parser.parse(validJson)),
    ))!;
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: RecipeDetailScreen(
            id: id,
            recipe: parser.parse(validJson),
            store: store,
            parser: parser,
          ),
        ),
      );
      await pumpUntil(
        tester,
        ready ?? () => find.text('Ingredients').evaluate().isNotEmpty,
      );
    });
    await tester.pumpAndSettle();
    return id;
  }

  testWidgets('detail screen rescales amounts and step text live', (
    tester,
  ) async {
    await pumpDetail(tester);

    expect(find.text('500 g'), findsOneWidget);
    expect(find.text('4'), findsWidgets); // servings + countable garlic cloves

    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();

    // 4 -> 5 servings, in the ingredient list...
    expect(find.text('625 g'), findsOneWidget);
    expect(find.text('5'), findsWidgets);

    // ...and in the step body, which is below the fold in a test viewport.
    // .first is the page ListView; the note TextField is a Scrollable too.
    await tester.scrollUntilVisible(
      find.text('Mix the dough'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('625 g bread flour'), findsOneWidget);
    expect(find.textContaining('{0001}'), findsNothing);
  });

  /// Opens the editor from the detail screen and waits for its fields.
  Future<void> openEditor(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();
    expect(find.text('Edit recipe'), findsOneWidget);
  }

  /// Taps Save version and waits for the detail screen to show the result.
  /// Scoped to the AppBar because find.text also matches EditableText, so a
  /// bare match would hit the editor's own field and race ahead of the save.
  Future<void> saveVersion(WidgetTester tester, String expectTitle) async {
    await tester.runAsync(() async {
      await tester.tap(
        find.widgetWithText(FloatingActionButton, 'Save version'),
      );
      await pumpUntil(
        tester,
        () => find.widgetWithText(AppBar, expectTitle).evaluate().isNotEmpty,
      );
    });
    await tester.pumpAndSettle();
  }

  testWidgets('editing an amount saves a version and keeps the original', (
    tester,
  ) async {
    await pumpDetail(tester);
    await openEditor(tester);

    // First ingredient row: bread flour, 500 g.
    await tester.enterText(
      find.widgetWithText(TextField, 'Amount').first,
      '1000',
    );
    await saveVersion(tester, 'Garlic Butter Focaccia');

    expect(find.text('1000 g'), findsOneWidget);

    final saved = await tester.runAsync(store.loadAll);
    expect(saved, hasLength(1)); // one row, not two
    final chain = await tester.runAsync(() => store.history(saved!.single.$1));
    expect(chain, hasLength(2));
    expect(chain!.last.$2.ingredientById('0001')!.amount, 500);
  });

  /// A ListView only builds near the viewport, so anything below the fold has
  /// to be scrolled to before it exists to tap or assert on.
  Future<void> scrollTo(WidgetTester tester, Finder target) async {
    await tester.scrollUntilVisible(
      target,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
  }

  testWidgets('steps show ingredients by name, never as {0001}', (
    tester,
  ) async {
    await pumpDetail(tester);
    await openEditor(tester);
    await scrollTo(tester, find.text('Mix the dough'));

    await tester.tap(find.text('Mix the dough'));
    await tester.pumpAndSettle();

    expect(find.textContaining('[bread flour]'), findsOneWidget);
    expect(find.textContaining('{0001}'), findsNothing);
  });

  testWidgets('a rename reaches the steps as it is typed, before any save', (
    tester,
  ) async {
    // Tall enough that an ingredient field and a step are on screen together;
    // at the default size the steps are below the fold and never built.
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await pumpDetail(tester);
    await openEditor(tester);

    await tester.tap(find.text('Mix the dough'));
    await tester.pumpAndSettle();
    expect(find.textContaining('[bread flour]'), findsOneWidget);

    await tester.enterText(
      find.widgetWithText(TextField, 'Ingredient').first,
      'strong white flour',
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('[strong white flour]'), findsOneWidget);
    expect(find.textContaining('[bread flour]'), findsNothing);
    // Nothing has been written — this is the editor keeping up, not a save.
    expect(await tester.runAsync(store.loadAll), hasLength(1));

    // Renaming onto a name another ingredient already has holds instead of
    // rewriting that one's references too.
    await tester.enterText(
      find.widgetWithText(TextField, 'Ingredient').first,
      'fine sea salt',
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('[strong white flour]'), findsOneWidget);
    expect(find.textContaining('[fine sea salt]'), findsOneWidget);
  });

  testWidgets('renaming an ingredient carries its step references along', (
    tester,
  ) async {
    await pumpDetail(tester);
    await openEditor(tester);

    await tester.enterText(
      find.widgetWithText(TextField, 'Ingredient').first,
      'strong white flour',
    );
    await saveVersion(tester, 'Garlic Butter Focaccia');

    final saved = await tester.runAsync(store.loadAll);
    final recipe = saved!.single.$2;
    expect(recipe.ingredientById('0001')!.name, 'strong white flour');
    // The reference survived the rename, so the step still scales it.
    expect(recipe.steps.first.content, contains('{0001}'));

    await scrollTo(tester, find.text('Mix the dough'));
    expect(find.textContaining('500 g strong white flour'), findsOneWidget);
  });

  testWidgets('removing an ingredient warns, then leaves the words behind', (
    tester,
  ) async {
    await pumpDetail(tester);
    await openEditor(tester);

    // The first close icon is the first ingredient's remove button.
    await tester.tap(find.byIcon(Icons.close).first);
    await tester.pumpAndSettle();
    expect(find.textContaining('step 1'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
    await tester.pumpAndSettle();
    await saveVersion(tester, 'Garlic Butter Focaccia');

    final saved = await tester.runAsync(store.loadAll);
    final recipe = saved!.single.$2;
    expect(recipe.ingredients, hasLength(6));
    expect(recipe.ingredientById('0001'), isNull);
    // Unbracketed rather than deleted: the sentence still reads.
    expect(recipe.steps.first.content, startsWith('Whisk bread flour,'));
  });

  /// The fixture with an ingredient no step mentions.
  String withUnusedIngredient() {
    final json = jsonDecode(validJson) as Map<String, dynamic>;
    (json['ingredients'] as List).add({
      'id': '0008',
      'name': 'olive oil',
      'amount': 2,
      'unit': 'tbsp',
    });
    return jsonEncode(json);
  }

  /// Puts [json] into the editor through JSON mode, which is quicker than
  /// building the same state by scrolling the form, and covers that path too.
  Future<void> enterJson(WidgetTester tester, String json) async {
    await tester.tap(find.text('JSON'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, json);
    await tester.pumpAndSettle();
  }

  testWidgets('an unused ingredient is raised before saving', (tester) async {
    await pumpDetail(tester);
    await openEditor(tester);
    await enterJson(tester, withUnusedIngredient());

    await tester.tap(find.widgetWithText(FloatingActionButton, 'Save version'));
    await tester.pumpAndSettle();

    expect(find.text('One ingredient is never used'), findsOneWidget);
    expect(find.textContaining('olive oil'), findsWidgets);

    // Back to editing saves nothing and leaves the editor open.
    await tester.tap(find.text('Back to editing'));
    await tester.pumpAndSettle();
    expect(await tester.runAsync(store.loadAll), hasLength(1));
    expect(find.text('Edit recipe'), findsOneWidget);
  });

  testWidgets('an unused ingredient can be dropped, or kept anyway', (
    tester,
  ) async {
    await pumpDetail(tester);
    await openEditor(tester);
    await enterJson(tester, withUnusedIngredient());

    await tester.tap(find.widgetWithText(FloatingActionButton, 'Save version'));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.text('Remove it'));
      await pumpUntil(
        tester,
        () => find
            .widgetWithText(AppBar, 'Garlic Butter Focaccia')
            .evaluate()
            .isNotEmpty,
      );
    });
    await tester.pumpAndSettle();

    var saved = await tester.runAsync(store.loadAll);
    expect(saved!.single.$2.ingredients, hasLength(7)); // dropped again

    // ...and the other way: keep it despite the warning.
    await openEditor(tester);
    await enterJson(tester, withUnusedIngredient());
    await tester.tap(find.widgetWithText(FloatingActionButton, 'Save version'));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.text('Save anyway'));
      await pumpUntil(
        tester,
        () => find
            .widgetWithText(AppBar, 'Garlic Butter Focaccia')
            .evaluate()
            .isNotEmpty,
      );
    });
    await tester.pumpAndSettle();

    saved = await tester.runAsync(store.loadAll);
    expect(saved!.single.$2.ingredients, hasLength(8));
  });

  testWidgets('a stranded reference is refused, not saved', (tester) async {
    await pumpDetail(tester);
    await openEditor(tester);

    // Emptying the name leaves step 1 pointing at an ingredient that is gone.
    await tester.enterText(
      find.widgetWithText(TextField, 'Ingredient').first,
      '',
    );
    await tester.tap(find.widgetWithText(FloatingActionButton, 'Save version'));
    await tester.pumpAndSettle();

    expect(find.textContaining('[bread flour]'), findsWidgets);
    expect(find.textContaining('nothing was saved'), findsOneWidget);
    expect(await tester.runAsync(store.loadAll), hasLength(1));
  });

  /// Saves a version built by [mutate] on top of the fixture, then opens the
  /// history screen showing it.
  Future<void> openHistoryAfter(
    WidgetTester tester,
    void Function(Map<String, dynamic> json) mutate,
  ) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // Built through the store so the editor's dialogs stay out of the way.
    final saved = await tester.runAsync(() async {
      final first = await store.save(parser.parse(validJson));
      final json = jsonDecode(validJson) as Map<String, dynamic>;
      mutate(json);
      return store.saveVersion(parser.parse(jsonEncode(json)), parent: first);
    });

    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: RecipeDetailScreen(
            id: saved!.$1,
            recipe: saved.$2,
            store: store,
            parser: parser,
          ),
        ),
      );
      await pumpUntil(
        tester,
        () => find.text('Ingredients').evaluate().isNotEmpty,
      );
    });
    await tester.pumpAndSettle();

    await tester.runAsync(() async {
      await tester.tap(find.byIcon(Icons.history));
      await pumpUntil(tester, () => find.text('Original').evaluate().isNotEmpty);
    });
    await tester.pumpAndSettle();
  }

  testWidgets('history keeps green and red for what arrived or left', (
    tester,
  ) async {
    await openHistoryAfter(tester, (json) {
      (json['ingredients'] as List)[5]['amount'] = 120;
      json['tags'] = ['bread', 'vegetarian', 'weeknight'];
    });

    // A swap is one line becoming another, not a removal beside an addition.
    expect(
      find.textContaining('60 g butter  \u2192  120 g butter'),
      findsOneWidget,
    );
    expect(find.text('~'), findsOneWidget);

    // The green and the red are kept for what really did arrive or leave —
    // here one tag each way.
    expect(find.text('+'), findsOneWidget);
    expect(find.text('\u2212'), findsOneWidget);
    expect(find.text('weeknight'), findsOneWidget);
    expect(find.text('make-ahead'), findsOneWidget);

    // ...and each change says what was done to it.
    expect(find.text('ingredient \u00b7 amount'), findsOneWidget);
    expect(find.text('1 tag'), findsNWidgets(2));
    expect(find.byIcon(Icons.remove), findsOneWidget);
    expect(find.byIcon(Icons.add), findsOneWidget);
  });

  testWidgets('a long change stacks instead of reading across', (tester) async {
    await openHistoryAfter(tester, (json) {
      (json['steps'] as List)[0]['content'] =
          'Whisk {0001} and {0003} together in the largest bowl you own, '
          'then pour in {0002} and mix to a shaggy dough.';
    });

    // Too long for one line, so the two versions stack under a down arrow
    // rather than hiding the change mid-sentence.
    expect(find.byIcon(Icons.arrow_downward), findsOneWidget);
    expect(
      find.text(
        'Whisk [bread flour] and [fine sea salt] together in the largest '
        'bowl you own, then pour in [water] and mix to a shaggy dough.',
      ),
      findsOneWidget,
    );
    expect(find.text('~'), findsOneWidget);
    expect(find.text('step 1 \u00b7 wording'), findsOneWidget);
  });

  testWidgets('a rating and note survive reopening the recipe', (tester) async {
    await pumpDetail(tester);

    await tester.runAsync(() async {
      await tester.tap(find.byIcon(Icons.star_border).at(3)); // 4th star
      await tester.pump();
      await tester.enterText(
        find.widgetWithText(TextField, 'My note'),
        'Halve the garlic',
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.star), findsNWidgets(4));

    // Reopen from disk, waiting for the stored rating rather than just the body.
    await pumpDetail(
      tester,
      ready: () => find.byIcon(Icons.star).evaluate().length == 4,
    );

    expect(find.byIcon(Icons.star), findsNWidgets(4));
    expect(find.text('Halve the garlic'), findsOneWidget);
  });
}
