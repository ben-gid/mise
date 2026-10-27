import 'package:flutter/material.dart';
import 'package:purchases_flutter/purchases_flutter.dart';

import '../recipe_account.dart';
import '../recipe_pro.dart';
import '../recipe_server.dart';
import 'cook_log.dart' show formatDay;
import 'glass.dart';
import 'import_recipe_screen.dart' show whileWriting;

/// [whileWriting] for a server recipe, with the paywall in the way of a 402:
/// buying Pro there asks again, so the recipe the cook was waiting for still
/// comes. Backing out rethrows, and the caller says what it always said.
Future<String> writeOrUpgrade(
  BuildContext context,
  String message,
  Future<String> Function() ask,
) async {
  try {
    return await whileWriting(context, message, ask);
  } on OutOfTriesException {
    if (!proOn || !context.mounted) rethrow;
    final bought = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => const ProScreen()),
    );
    if (bought != true || !context.mounted) rethrow;
    return whileWriting(context, message, ask);
  }
}

/// Mise Pro: what it is, the two prices, and Restore. Pops true once this
/// phone is Pro. Only ever pushed when [proOn], so never under `flutter test`.
class ProScreen extends StatefulWidget {
  const ProScreen({super.key});

  @override
  State<ProScreen> createState() => _ProScreenState();
}

class _ProScreenState extends State<ProScreen> {
  late final Future<List<Package>> _packages = proPackages();
  bool _busy = false;

  Future<void> _run(Future<bool> Function() action, String failed) async {
    setState(() => _busy = true);
    final bool pro;
    try {
      pro = await action();
    } catch (e) {
      debugPrint('Pro action failed: $e');
      if (mounted) {
        setState(() => _busy = false);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(failed)));
      }
      return;
    }
    if (!mounted) return;
    setState(() => _busy = false);
    if (!pro) return;
    // An anonymous user's Pro lives on this install's user id. Restore gets it
    // back after a reinstall, but signing in is what follows it to a new phone.
    if (account.value?.email == null) {
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('You\'re Pro'),
          content: const Text(
            'Sign in under Settings to keep Pro and your recipes on a new '
            'phone. Restore purchases there works too.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    }
    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final until = proUntil.value;
    return SpreadPage(
      title: 'Mise Pro',
      subtitle: until == null
          ? 'Recipes written for you'
          : 'Pro until ${formatDay(until)}',
      children: [
        Text(
          'Write a recipe from a sentence, change one you already have, or '
          'bring one in from a link or a photo of a cookbook page — up to 200 '
          'a month. Pasting a recipe, photos, scaling and units stay free.',
          style: theme.textTheme.bodyLarge,
        ),
        const SizedBox(height: 24),
        if (until == null)
          FutureBuilder(
            future: _packages,
            builder: (context, snapshot) {
              final packages = snapshot.data;
              if (packages == null || packages.isEmpty) {
                return Text(
                  snapshot.connectionState == ConnectionState.done
                      ? 'Couldn\'t reach the store. Try again in a moment.'
                      : 'Loading prices…',
                  style: theme.textTheme.bodyMedium,
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final package in packages) ...[
                    _Price(
                      package: package,
                      onTap: _busy
                          ? null
                          : () => _run(
                              () => buyPro(package),
                              'The purchase didn\'t go through.',
                            ),
                    ),
                    const SizedBox(height: 10),
                  ],
                ],
              );
            },
          ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: _busy
              ? null
              : () => _run(restorePro, 'Couldn\'t restore. Try again.'),
          child: const Text('Restore purchases'),
        ),
        const SizedBox(height: 8),
        Text(
          'Renews until you cancel, which you can do any time in your '
          '${Theme.of(context).platform == TargetPlatform.iOS ? 'App Store' : 'Google Play'} '
          'subscriptions.',
          textAlign: TextAlign.center,
          style: muted,
        ),
      ],
    );
  }
}

/// One subscription as a full-width button: the term, and the store's price
/// in the cook's own currency.
class _Price extends StatelessWidget {
  final Package package;
  final VoidCallback? onTap;

  const _Price({required this.package, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final term = switch (package.packageType) {
      PackageType.annual => ('Yearly', 'a year'),
      PackageType.monthly => ('Monthly', 'a month'),
      _ => (package.storeProduct.title, ''),
    };
    return FilledButton(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(56),
        backgroundColor: scheme.onSurface,
        foregroundColor: scheme.surface,
      ),
      onPressed: onTap,
      child: Text(
        '${term.$1} · ${package.storeProduct.priceString} ${term.$2}'.trim(),
      ),
    );
  }
}
