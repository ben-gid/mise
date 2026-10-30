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
/// [inline] skips the dialog, for a screen that shows its own progress.
Future<String> writeOrUpgrade(
  BuildContext context,
  List<String> verbs,
  Future<String> Function() ask, {
  bool inline = false,
}) async {
  Future<String> wait() => inline ? ask() : whileWriting(context, verbs, ask);
  try {
    return await wait();
  } on OutOfTriesException {
    if (!proOn || !context.mounted) rethrow;
    final bought = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => const ProScreen()),
    );
    if (bought != true || !context.mounted) rethrow;
    return wait();
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
  /// Null while the store answers; empty when it couldn't.
  List<Package>? _packages;
  Package? _picked;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    proPackages().then(
      (packages) {
        if (!mounted) return;
        setState(() {
          _packages = packages;
          _picked =
              packages
                  .where((p) => p.packageType == PackageType.annual)
                  .firstOrNull ??
              packages.firstOrNull;
        });
      },
      onError: (Object e) {
        debugPrint('Pro packages failed: $e');
        if (mounted) setState(() => _packages = const []);
      },
    );
  }

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
    final packages = _packages;
    final picked = _picked;
    return SpreadPage(
      title: 'Mise Pro',
      subtitle: until == null ? null : 'Pro until ${formatDay(until)}',
      bottom: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (until == null && picked != null)
            FilledButton(
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(56),
              ),
              onPressed: _busy
                  ? null
                  : () => _run(
                      () => buyPro(picked),
                      'The purchase didn\'t go through.',
                    ),
              child: Text(
                'Continue · ${picked.storeProduct.priceString} '
                '${_term(picked).$3}',
              ),
            ),
          TextButton(
            onPressed: _busy
                ? null
                : () => _run(restorePro, 'Couldn\'t restore. Try again.'),
            child: const Text('Restore purchases'),
          ),
          Text(
            'Renews until you cancel, any time, in your '
            '${theme.platform == TargetPlatform.iOS ? 'App Store' : 'Google Play'} '
            'subscriptions.',
            textAlign: TextAlign.center,
            style: muted,
          ),
        ],
      ),
      children: [
        Text(
          '200+ intelligent recipes, every month.',
          style: serif(22, height: 1.15, italic: true),
        ),
        const SizedBox(height: 20),
        const Divider(),
        const _Feature(
          icon: Icons.auto_awesome_outlined,
          title: 'Create',
          body:
              'Say what you want to eat. Mise asks a question or two, then '
              'writes it.',
        ),
        const Divider(),
        const _Feature(
          icon: Icons.tune,
          title: 'Adapt',
          body:
              'Halve the sugar, make it vegan. Every change is kept, and '
              'undoable.',
        ),
        const Divider(),
        const _Feature(
          icon: Icons.menu_book_outlined,
          title: 'Import',
          body: 'Paste a link, or photograph a cookbook page.',
        ),
        const Divider(),
        const SizedBox(height: 10),
        Text('Pasting, photos, scaling and units stay free.', style: muted),
        if (until == null) ...[
          const SizedBox(height: 24),
          const SectionLabel('Choose a plan'),
          const SizedBox(height: 10),
          if (packages == null || packages.isEmpty)
            Text(
              packages == null
                  ? 'Loading prices…'
                  : 'Couldn\'t reach the store. Try again in a moment.',
              style: theme.textTheme.bodyMedium,
            )
          else
            for (final package in packages) ...[
              _Plan(
                package: package,
                picked: package == picked,
                onTap: _busy ? null : () => setState(() => _picked = package),
              ),
              const SizedBox(height: 10),
            ],
        ],
      ],
    );
  }
}

/// A subscription's name, how it bills, and the "a year" after its price.
(String, String, String) _term(Package package) =>
    switch (package.packageType) {
      PackageType.annual => ('Yearly', 'Billed once a year', 'a year'),
      PackageType.monthly => ('Monthly', 'Billed every month', 'a month'),
      _ => (package.storeProduct.title, '', ''),
    };

/// One thing Pro does: an icon on a herb tile, its name, a line under it.
class _Feature extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;

  const _Feature({required this.icon, required this.title, required this.body});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: herbWash(context),
              borderRadius: BorderRadius.circular(pillRadius),
            ),
            child: Icon(icon, size: 22, color: scheme.primary),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.titleMedium),
                const SizedBox(height: 2),
                Text(
                  body,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One subscription as a card to pick: the term, how it bills, and the
/// store's price in the cook's own currency. The button under the page buys
/// whichever is picked.
class _Plan extends StatelessWidget {
  final Package package;
  final bool picked;
  final VoidCallback? onTap;

  const _Plan({
    required this.package,
    required this.picked,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final (name, billing, _) = _term(package);
    return Semantics(
      selected: picked,
      inMutuallyExclusiveGroup: true,
      child: Material(
        color: picked ? herbWash(context) : glassFill(context),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(panelRadius),
          side: BorderSide(
            color: picked ? scheme.primary : Colors.transparent,
            width: 2,
          ),
        ),
        child: InkWell(
          customBorder: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(panelRadius),
          ),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 72),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Icon(
                    picked
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    color: picked ? scheme.primary : scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(name, style: theme.textTheme.titleMedium),
                        if (billing.isNotEmpty)
                          Text(
                            billing,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                      ],
                    ),
                  ),
                  Text(
                    package.storeProduct.priceString,
                    style: serif(26).copyWith(color: scheme.onSurface),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
