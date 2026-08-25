import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mise/recipe/recipe_models.dart';
import 'package:mise/recipe/recipe_parser.dart';
import 'package:mise/recipe/recipe_store.dart';
import 'package:mise/recipe/recipe_units.dart';
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

  /// The recipe's name as the detail screen renders it — a real [Text], never
  /// the editor's [EditableText].
  ///
  /// Doubles as the "this screen has rendered" signal: the name is the first
  /// thing in the body, so unlike a section heading it is built whatever the
  /// test viewport is.
  Finder titleText(String title) =>
      find.byWidgetPredicate((w) => w is Text && w.data == title);

  /// to be scrolled to before it exists to tap or assert on.
  /// [delta] is the step it scrolls by, so it is also how far past the target
  /// this can overshoot — small steps when something above the target has to
  /// stay built too.
  Future<void> scrollTo(
    WidgetTester tester,
    Finder target, {
    double delta = 200,
  }) async {
    await tester.scrollUntilVisible(
      target,
      delta,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
  }

  /// Gives the surface room for the whole recipe.
  ///
  /// The name and tags now open the page, so on a default 600px surface a
  /// SliverList has not built the ingredient rows by the time a test looks for
  /// them. A test about how an amount *reads* should not also be a test about
  /// scrolling — the ones that genuinely exercise scrolling use [scrollTo].
  void tallSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
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
    String? json,
  }) async {
    final body = json ?? validJson;
    final id = (await tester.runAsync(() => store.save(parser.parse(body))))!;
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: RecipeDetailScreen(
            id: id,
            recipe: parser.parse(body),
            store: store,
            parser: parser,
          ),
        ),
      );
      await pumpUntil(
        tester,
        ready ??
            () => titleText('Garlic Butter Focaccia').evaluate().isNotEmpty,
      );
    });
    await tester.pumpAndSettle();
    return id;
  }

  /// A real 1x1 PNG. The chain resolves through actual image decoding, so a
  /// test that needs a photo to *succeed* has to hand it a real one — no https
  /// url resolves in a test environment, which is what makes the failure path
  /// free to test and the success path not.
  const onePixelPng =
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAC'
      'hwGA60e6kgAAAABJRU5ErkJggg==';

  /// Pumps the detail screen for a recipe carrying [urls], waiting inside
  /// `runAsync` until [settled] — the chain walks real network attempts, and
  /// those need the real clock (see CLAUDE.md).
  Future<void> pumpPhotos(
    WidgetTester tester,
    List<String> urls,
    bool Function() settled,
  ) async {
    final recipe = Recipe.fromJson({
      ...(jsonDecode(validJson) as Map<String, dynamic>),
      'image_urls': urls,
    });
    final id = (await tester.runAsync(() => store.save(recipe)))!;
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: RecipeDetailScreen(
            id: id,
            recipe: recipe,
            store: store,
            parser: parser,
          ),
        ),
      );
      await pumpUntil(
        tester,
        () =>
            titleText('Garlic Butter Focaccia').evaluate().isNotEmpty &&
            settled(),
      );
    });
    await tester.pumpAndSettle();
  }

  testWidgets('a dead url falls through to the next one', (tester) async {
    File('${dir.path}/photo.png').writeAsBytesSync(base64Decode(onePixelPng));

    await pumpPhotos(
      tester,
      // The first never resolves in a test, so the chain has to walk past it.
      const ['https://www.seriouseats.com/dead.jpg', 'mise://photo.png'],
      () => find.text('Your photo').evaluate().isNotEmpty,
    );

    // Credited to the url that actually loaded, not the one ranked first.
    expect(find.text('Your photo'), findsOneWidget);
    expect(find.text('seriouseats.com'), findsNothing);

    // The hero is open, so the bar stands well clear of a plain toolbar.
    final open = tester.getSize(find.byType(FlexibleSpaceBar)).height;
    expect(open, greaterThan(kToolbarHeight * 2));

    // Scrolling closes it rather than sliding a second bar over it. The fog
    // rides this, so a broken collapse would take it with it.
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -260));
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.byType(FlexibleSpaceBar)).height,
      lessThan(open),
    );
    // The name must not live inside the hero. It did once, and the frost
    // stacked above it blurred it away on exactly this scroll — while a
    // findsWidgets assertion passed, because it was still in the tree.
    expect(
      find.descendant(
        of: find.byType(FlexibleSpaceBar),
        matching: find.text('Garlic Butter Focaccia'),
      ),
      findsNothing,
    );
  });

  testWidgets('a recipe whose photos all fail reads as one with none', (
    tester,
  ) async {
    await pumpPhotos(
      tester,
      const [
        'https://a.example/1.jpg',
        'https://b.example/2.jpg',
        'https://c.example/3.jpg',
      ],
      // The credit walks each host and then disappears — that is the chain
      // running out, and the only thing worth waiting on.
      () => find.textContaining('.example').evaluate().isEmpty,
    );

    // Eased shut down to exactly the plain bar. No credit is left, because
    // there is no photo to credit.
    expect(
      tester.getSize(find.byType(FlexibleSpaceBar)).height,
      closeTo(kToolbarHeight, 1),
    );
    expect(find.textContaining('.example'), findsNothing);
    expect(find.text('Garlic Butter Focaccia'), findsWidgets);
  });

  testWidgets('a recipe with no urls at all keeps the plain bar', (
    tester,
  ) async {
    await pumpDetail(tester);

    expect(find.byType(FlexibleSpaceBar), findsNothing);
    expect(find.byType(SliverAppBar), findsOneWidget);
  });

  testWidgets('a long name wraps instead of truncating, and the tags lead', (
    tester,
  ) async {
    const long = 'Slow-Proofed Rosemary and Sea Salt Focaccia';
    final recipe = Recipe.fromJson({
      ...(jsonDecode(validJson) as Map<String, dynamic>),
      'title': long,
    });
    final id = (await tester.runAsync(() => store.save(recipe)))!;
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: RecipeDetailScreen(
            id: id,
            recipe: recipe,
            store: store,
            parser: parser,
          ),
        ),
      );
      await pumpUntil(tester, () => titleText(long).evaluate().isNotEmpty);
    });
    await tester.pumpAndSettle();

    // A toolbar could only ever have given this 56px. At 34/1.15 a line is
    // ~39px, so clearing 60 is two lines that a truncating title never reaches.
    expect(tester.getSize(find.text(long)).height, greaterThan(60));

    // Tags name the hue the whole screen is drawn in, so they sit with the
    // title rather than three screens below it.
    expect(
      tester.getTopLeft(find.text('bread')).dy,
      lessThan(tester.getTopLeft(find.text('Ingredients')).dy),
    );
  });

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

  testWidgets('detail screen honours the unit settings', (tester) async {
    weightSystem.value = UnitSystem.imperial;
    volumeSystem.value = UnitSystem.imperial;
    addTearDown(() {
      weightSystem.value = UnitSystem.metric;
      volumeSystem.value = UnitSystem.metric;
    });
    tallSurface(tester);
    await pumpDetail(tester);

    // 500 g flour reads as a decimal off a scale; 400 ml water as a fraction
    // off a measuring cup.
    expect(find.text('1 lb 1.6 oz'), findsOneWidget);
    expect(find.text('1⅔ cups'), findsOneWidget);

    // Legacy units the prompt no longer asks for are left as written.
    expect(find.text('1 tsp'), findsOneWidget);

    // 4 -> 5 servings puts the water at 500 ml, which needs both terms.
    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    expect(find.text('2 cups + 2 tbsp'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('Mix the dough'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('2 cups + 2 tbsp water'), findsOneWidget);
  });

  testWidgets('tapping an amount switches just that ingredient', (
    tester,
  ) async {
    addTearDown(() => measureBy.value = MeasureBy.asWritten);
    tallSurface(tester);
    await pumpDetail(tester);

    // Flour carries a density, so it can leave the scale for a measuring cup.
    expect(find.text('500 g'), findsOneWidget);
    await tester.tap(find.text('500 g'));
    await tester.pumpAndSettle();
    // Marked approximate: it came through a density, not off a scale.
    expect(find.text('943 ml'), findsOneWidget);
    expect(find.text('500 g'), findsNothing);

    // Only that one — the salt beside it is untouched.
    expect(find.text('10 g'), findsOneWidget);

    // The icon marks what can switch, and only that. Yeast is in teaspoons but
    // carries no density, so it taps without offering one.
    Finder rowOf(String amount) => find
        .ancestor(of: find.text(amount), matching: find.byType(InkWell))
        .first;
    expect(
      find.descendant(
        of: rowOf('943 ml'),
        matching: find.byIcon(Icons.swap_horiz),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: rowOf('5 ml'),
        matching: find.byIcon(Icons.swap_horiz),
      ),
      findsNothing,
    );

    // The same tap goes back.
    await tester.tap(find.text('943 ml'));
    await tester.pumpAndSettle();
    expect(find.text('500 g'), findsOneWidget);

    // The step text carries no control of its own, so it has to follow.
    await tester.tap(find.text('500 g'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Mix the dough'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('943 ml bread flour'), findsOneWidget);
  });

  testWidgets('an ingredient with no density says so rather than doing '
      'nothing', (tester) async {
    tallSurface(tester);
    await pumpDetail(tester);

    // Yeast is measured in teaspoons but carries no density, so there is
    // nothing to convert through. No hover on a phone, so the tap has to talk.
    // A teaspoon reads as 5 ml under the metric default.
    await tester.tap(find.text('5 ml'));
    await tester.pumpAndSettle();

    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.textContaining('No density for instant yeast'), findsOneWidget);
    expect(find.text('5 ml'), findsOneWidget); // unchanged

    // ScaffoldMessenger queues, so the next one never shows until this one
    // has served its four seconds.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    // A pinch fails for a different reason, and pointing it at the editor
    // would be a lie — there is no density field for a unit with no size.
    await tester.scrollUntilVisible(
      find.text('1 pinch'),
      100,
      scrollable: find.byType(Scrollable).first,
    );
    // scrollUntilVisible stops as soon as the row is on screen, which here is
    // underneath the translucent app bar the body scrolls behind. Nudge it out.
    await tester.drag(find.byType(Scrollable).first, const Offset(0, 140));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1 pinch'));
    await tester.pumpAndSettle();
    expect(find.textContaining('No fixed size for flaky salt'), findsOneWidget);
  });

  /// Opens the editor from the detail screen and waits for its fields.
  Future<void> openEditor(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();
    expect(find.text('Edit recipe'), findsOneWidget);
  }

  /// Taps Save version and waits for the detail screen to show the result.
  ///
  /// Matched on the Text widget rather than on somewhere in the layout:
  /// find.text also matches EditableText, so a bare match would hit the
  /// editor's own field and race ahead of the save. Excluding it by type is
  /// what the old AppBar scoping was standing in for.
  Future<void> saveVersion(WidgetTester tester, String expectTitle) async {
    await tester.runAsync(() async {
      await tester.tap(
        find.widgetWithText(FloatingActionButton, 'Save version'),
      );
      await pumpUntil(
        tester,
        () => titleText(expectTitle).evaluate().isNotEmpty,
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

    // Renaming onto a name another ingredient already has moves *both*
    // references: the two are duplicates now, so each picks up its id and the
    // step has to say which is which. One keystroke, two labels.
    await tester.enterText(
      find.widgetWithText(TextField, 'Ingredient').first,
      'fine sea salt',
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('[fine sea salt #0001]'), findsOneWidget);
    expect(find.textContaining('[fine sea salt #0003]'), findsOneWidget);
    // Never the bare form, which would name neither of them.
    expect(find.textContaining('[fine sea salt],'), findsNothing);

    // And back out again: alone once more, each drops its id.
    await tester.enterText(
      find.widgetWithText(TextField, 'Ingredient').first,
      'bread flour',
    );
    await tester.pumpAndSettle();
    expect(
      find.textContaining('[bread flour], [fine sea salt]'),
      findsOneWidget,
    );
    expect(find.textContaining('#0001'), findsNothing);
  });

  testWidgets('two ingredients may share a name, and stay apart on save', (
    tester,
  ) async {
    // Sugar for the sponge and sugar for the buttercream: an LLM splitting a
    // recipe by component writes one name twice on purpose. Saving used to be
    // refused outright, and before that quietly resolved both references to
    // whichever came last.
    final recipe = jsonDecode(validJson) as Map<String, dynamic>;
    (recipe['ingredients'] as List).add({
      'id': '0008',
      'name': 'butter',
      'amount': 20,
      'unit': 'g',
    });
    (recipe['steps'] as List).add({
      'id': 's5',
      'title': 'Finish',
      'content': 'Beat in {0008} off the heat.',
      'timer_seconds': null,
    });

    await pumpDetail(tester, json: jsonEncode(recipe));
    await openEditor(tester);
    await saveVersion(tester, 'Garlic Butter Focaccia');

    final saved = await tester.runAsync(store.loadAll);
    final steps = {
      for (final step in saved!.single.$2.steps) step.id: step.content,
    };
    // Opened and saved with no edit at all, both butters still point where
    // they did — the round trip through bracket syntax is lossless.
    expect(steps['s5'], 'Beat in {0008} off the heat.');
    expect(steps['s3'], 'Melt {0006} with finely sliced {0005} over low heat.');
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

    // The first close icon is the first ingredient's remove button — below the
    // fold in a test viewport, since the image field sits above the list.
    await scrollTo(tester, find.byIcon(Icons.close).first);
    // Same as the pinch row above: scrollUntilVisible stops as soon as it is on
    // screen, which is underneath the app bar the body scrolls behind.
    await tester.drag(find.byType(Scrollable).first, const Offset(0, 140));
    await tester.pumpAndSettle();
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
        () => titleText('Garlic Butter Focaccia').evaluate().isNotEmpty,
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
        () => titleText('Garlic Butter Focaccia').evaluate().isNotEmpty,
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
      await pumpUntil(
        tester,
        () => find.text('Original').evaluate().isNotEmpty,
      );
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
