import 'package:flutter/material.dart';

import 'recipe/recipe_parser.dart';
import 'recipe/recipe_store.dart';
import 'recipe/recipe_units.dart';
import 'recipe/ui/glass.dart';
import 'recipe/ui/recipe_list_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized(); // path_provider + rootBundle
  final store = await RecipeStore.open();
  final parser = await RecipeParser.fromAsset();
  // Unset or unrecognised falls back to system rather than throwing.
  final saved = await store.themeName();
  themeMode.value = ThemeMode.values.firstWhere(
    (mode) => mode.name == saved,
    orElse: () => ThemeMode.system,
  );
  // Same fallback rule as the theme: anything unreadable reads as metric.
  final units = (await store.unitSystems())?.split(',') ?? const <String>[];
  UnitSystem savedUnit(int index) => UnitSystem.values.firstWhere(
    (system) => index < units.length && system.name == units[index],
    orElse: () => UnitSystem.metric,
  );
  weightSystem.value = savedUnit(0);
  volumeSystem.value = savedUnit(1);
  runApp(RecipeApp(store: store, parser: parser));
}

class RecipeApp extends StatelessWidget {
  final RecipeStore store;
  final RecipeParser parser;

  const RecipeApp({super.key, required this.store, required this.parser});

  @override
  Widget build(BuildContext context) {
    // AnimatedBuilder over merged notifiers, not ValueListenableBuilder: a unit
    // change on the settings screen has to repaint the screens under it too.
    return AnimatedBuilder(
      animation: Listenable.merge([themeMode, weightSystem, volumeSystem]),
      builder: (context, _) => MaterialApp(
        title: 'Mise',
        theme: AppTheme.light,
        darkTheme: AppTheme.dark,
        themeMode: themeMode.value,
        home: RecipeListScreen(store: store, parser: parser),
      ),
    );
  }
}
