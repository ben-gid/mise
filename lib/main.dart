import 'dart:async';

import 'package:flutter/material.dart';

import 'recipe/recipe_account.dart';
import 'recipe/recipe_parser.dart';
import 'recipe/recipe_pro.dart';
import 'recipe/recipe_store.dart';
import 'recipe/recipe_sync.dart';
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
  applyUnitSystems(await store.unitSystems());
  // Written before the tour opens, so leaving it any way at all — Skip, back,
  // the app killed — counts as a skip. A build with no sign-in or Pro has
  // nothing to owe.
  final onboarding = await store.onboarding();
  if (onboarding == null) {
    await store.setOnboarding(accountsOn || proOn ? 'skipped' : 'done');
  }
  // Before startAccount, so it hears the first account it settles on.
  startSync(store, parser);
  startPro();
  // Not awaited: the account is for sync and server routes, never for opening
  // the app, and offline it can take a while to settle.
  unawaited(startAccount());
  runApp(
    RecipeApp(store: store, parser: parser, onboarding: onboarding ?? 'new'),
  );
}

class RecipeApp extends StatelessWidget {
  final RecipeStore store;
  final RecipeParser parser;
  final String onboarding;

  const RecipeApp({
    super.key,
    required this.store,
    required this.parser,
    required this.onboarding,
  });

  @override
  Widget build(BuildContext context) {
    // AnimatedBuilder over merged notifiers, not ValueListenableBuilder: a unit
    // change on the settings screen has to repaint the screens under it too.
    return AnimatedBuilder(
      animation: Listenable.merge([
        themeMode,
        weightSystem,
        volumeSystem,
        measureBy,
      ]),
      builder: (context, _) => MaterialApp(
        title: 'Mise',
        theme: AppTheme.light,
        darkTheme: AppTheme.dark,
        themeMode: themeMode.value,
        home: RecipeListScreen(
          store: store,
          parser: parser,
          onboarding: onboarding,
        ),
      ),
    );
  }
}
