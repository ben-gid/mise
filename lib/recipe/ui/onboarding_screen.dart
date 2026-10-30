import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../recipe_account.dart';
import '../recipe_pro.dart';
import '../recipe_store.dart';
import 'glass.dart';
import 'pro_screen.dart';
import 'settings_screen.dart' show runAccountAction;

/// What a page of the tour says: an icon on a herb tile, a title, a paragraph.
typedef _Page = (IconData, String, String);

const _tour = <_Page>[
  (
    Icons.restaurant_menu,
    'Recipes that hold together',
    'Mise keeps every recipe as structured data and checks it before it is '
        'saved: each ingredient, amount and step. Nothing goes missing, and a '
        'recipe can do what a printed page can\'t.',
  ),
  (
    Icons.straighten,
    'Any size, any units',
    'Change the servings and every amount follows, in the ingredient list and '
        'inside the steps. Grams or cups, metric or US: choose once in '
        'Settings, or tap an amount to switch just that one.',
  ),
  (
    Icons.add,
    'Import or Create',
    'Import brings in a recipe that already exists: paste it, give a link, or '
        'photograph a cookbook page. Create starts from a sentence, what you '
        'feel like eating, and writes a recipe for it.',
  ),
  (
    Icons.photo_outlined,
    'A photo for every recipe',
    'Mise finds a photo that looks like the dish and names the photographer. '
        'Choose another from the recipe, or use one of your own.',
  ),
  (
    Icons.history,
    'Cook it, then note it',
    'After you make something, log how it went: stars, a note, how many you '
        'served. Every edit is a new version, so History shows what changed, '
        'whether it was better, and undoes it if not.',
  ),
];

const _sync = (
  Icons.devices_outlined,
  'On every phone',
  'Sign in and your recipes, photos and cook log follow you to another phone '
      'or tablet, and stay in step as you edit. Mise works the same without '
      'it.',
);

/// The tour: what Mise is, page by page, ending on sign-in and then the Pro
/// paywall where this build has them. Pops true when it was seen through;
/// Skip, or back from the first page, pops without.
///
/// [followUp] is just the sign-in page, for a cook who skipped the tour —
/// [showOwedOnboarding] is what opens it that way.
class OnboardingScreen extends StatefulWidget {
  final RecipeStore store;
  final bool followUp;

  /// [accountsOn] and [proOn] unless given, which only tests do: both are
  /// off under `flutter test`.
  final bool? accounts;
  final bool? pro;

  const OnboardingScreen({
    super.key,
    required this.store,
    this.followUp = false,
    @visibleForTesting this.accounts,
    @visibleForTesting this.pro,
  });

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  late final bool _accounts = widget.accounts ?? accountsOn;
  late final bool _pro = widget.pro ?? proOn;
  late final _pages = [if (!widget.followUp) ..._tour, if (_accounts) _sync];
  int _page = 0;

  bool get _last => _page == _pages.length - 1;

  void _next() {
    if (_last) {
      _finish();
    } else {
      setState(() => _page++);
    }
  }

  /// Seen through: nothing is owed any more, and Pro takes this page's place
  /// so back from the paywall lands on the list, not on the tour.
  void _finish() {
    unawaited(widget.store.setOnboarding('done'));
    final navigator = Navigator.of(context);
    if (_pro && proUntil.value == null) {
      navigator.pushReplacement(
        MaterialPageRoute<void>(builder: (_) => const ProScreen()),
        result: true,
      );
    } else {
      navigator.pop(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final (icon, title, body) = _pages[_page];
    final syncPage = _accounts && _last;
    // Back walks the pages; only from the first does it leave, as a skip.
    return PopScope(
      canPop: _page == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(() => _page--);
      },
      child: ValueListenableBuilder(
        valueListenable: account,
        builder: (context, current, _) {
          final signedOut = syncPage && current?.email == null;
          return SpreadPage(
            title: title,
            subtitle: _pages.length > 1
                ? '${_page + 1} of ${_pages.length}'
                : null,
            bottom: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                FilledButton(
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(56),
                  ),
                  onPressed: _next,
                  child: Text(
                    signedOut ? 'Not now' : (_last ? 'Done' : 'Next'),
                  ),
                ),
                if (!_last)
                  TextButton(
                    style: TextButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                    ),
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Skip'),
                  ),
              ],
            ),
            children: [
              // Aligned, or the ListView stretches the tile to the page width.
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: Container(
                  width: 72,
                  height: 72,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: herbWash(context),
                    borderRadius: BorderRadius.circular(panelRadius),
                  ),
                  child: Icon(
                    icon,
                    size: 34,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ),
              const SizedBox(height: 24),
              Text(body, style: Theme.of(context).textTheme.bodyLarge),
              if (syncPage) ...[
                const SizedBox(height: 28),
                if (signedOut)
                  ..._signIn(context)
                else
                  Text(
                    'Signed in as ${current?.email} · recipes sync',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
              ],
            ],
          );
        },
      ),
    );
  }

  /// Settings' two buttons: each links the provider to the anonymous user
  /// this install already has, so nothing moves.
  List<Widget> _signIn(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return [
      OutlinedButton(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size.fromHeight(50),
          side: BorderSide(color: glassRim(context)),
          foregroundColor: scheme.onSurface,
          backgroundColor: scheme.surface,
        ),
        onPressed: () => runAccountAction(context, signInWithGoogle),
        child: const Text('Continue with Google'),
      ),
      // Apple's own rule: offering Google on iOS means offering Apple too.
      if (Platform.isIOS) ...[
        const SizedBox(height: 10),
        FilledButton(
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(50),
            backgroundColor: scheme.onSurface,
            foregroundColor: scheme.surface,
          ),
          onPressed: () => runAccountAction(context, signInWithApple),
          child: const Text('Continue with Apple'),
        ),
      ],
    ];
  }
}

/// What a skipped tour still owes — the sign-in page, then Pro — shown once,
/// the first time the cook comes back to the list from a recipe: by then they
/// have seen what an account would be keeping. Recorded before it opens, so
/// leaving it any way at all counts as shown.
Future<void> showOwedOnboarding(BuildContext context, RecipeStore store) async {
  await store.setOnboarding('done');
  if (!context.mounted) return;
  final signIn = accountsOn && account.value?.email == null;
  final pro = proOn && proUntil.value == null;
  if (signIn) {
    await Navigator.push(
      context,
      MaterialPageRoute<bool>(
        builder: (_) => OnboardingScreen(store: store, followUp: true),
      ),
    );
  } else if (pro) {
    await Navigator.push(
      context,
      MaterialPageRoute<bool>(builder: (_) => const ProScreen()),
    );
  }
}
