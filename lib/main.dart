import 'package:flutter/material.dart';

import 'recipe/recipe_parser.dart';
import 'recipe/recipe_store.dart';
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
  runApp(RecipeApp(store: store, parser: parser));
}

class RecipeApp extends StatelessWidget {
  final RecipeStore store;
  final RecipeParser parser;

  const RecipeApp({super.key, required this.store, required this.parser});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: themeMode,
      builder: (context, mode, _) => MaterialApp(
        title: 'Mise',
        theme: AppTheme.light,
        darkTheme: AppTheme.dark,
        themeMode: mode,
        home: RecipeListScreen(store: store, parser: parser),
      ),
    );
  }
}
