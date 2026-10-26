import 'dart:io';

import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import '../recipe_account.dart';
import '../recipe_store.dart';
import '../recipe_units.dart';
import 'glass.dart';

/// Settings. Appearance, then the display units, then the account when this
/// build has one — another group goes in under these with its own label.
class SettingsScreen extends StatefulWidget {
  final RecipeStore store;

  const SettingsScreen({super.key, required this.store});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  static const _modes = [
    (ThemeMode.light, 'Light'),
    (ThemeMode.dark, 'Dark'),
    (ThemeMode.system, 'Auto'),
  ];

  void _pick(ThemeMode mode) {
    setState(() => themeMode.value = mode);
    widget.store.setThemeName(mode.name);
  }

  /// All three settings go to disk together — they share one sidecar line.
  void _saveUnits() => widget.store.setUnitSystems(
    '${weightSystem.value.name},'
    '${volumeSystem.value.name},'
    '${measureBy.value.name}',
  );

  void _pickUnit(ValueNotifier<UnitSystem> setting, UnitSystem system) {
    setState(() => setting.value = system);
    _saveUnits();
  }

  void _pickMeasure(MeasureBy by) {
    setState(() => measureBy.value = by);
    _saveUnits();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SpreadPage(
      title: 'Settings',
      children: [
        const SectionLabel('Appearance'),
        _row(
          'Theme',
          Segmented(
            options: _modes,
            selected: themeMode.value,
            onChanged: _pick,
          ),
        ),
        const SizedBox(height: 28),
        const SectionLabel('Units'),
        _units('Weight', weightSystem, metric: 'g', imperial: 'oz · lb'),
        _units(
          'Volume',
          volumeSystem,
          metric: 'ml',
          imperial: 'tsp · tbsp · cup',
        ),
        const SizedBox(height: 20),
        Text('Measure by', style: theme.textTheme.bodyLarge),
        const SizedBox(height: 8),
        for (final (by, label, example) in const [
          (MeasureBy.asWritten, 'As written', 'However each recipe saved it'),
          (MeasureBy.weight, 'Weight', 'On a scale wherever it can be'),
          (
            MeasureBy.volume,
            'Volume',
            'In cups and spoons wherever it can be',
          ),
        ])
          _Choice(
            label: label,
            example: example,
            selected: by == measureBy.value,
            onTap: () => _pickMeasure(by),
          ),
        const SizedBox(height: 8),
        Text(
          'Recipes are stored as written and converted for display, rounded '
          'to measurements you can actually scoop. Switching between weight '
          'and volume needs a known density, so some ingredients stay as '
          'written. Tap any amount to switch just that one.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        // Last, not first: the app works the same signed in or not, and a
        // sign-in panel at the top of Settings reads as a gate.
        if (accountsOn) ...[
          const SizedBox(height: 28),
          const SectionLabel('Account'),
          const SizedBox(height: 12),
          ValueListenableBuilder(
            valueListenable: account,
            builder: (context, current, _) => _account(current),
          ),
        ],
      ],
    );
  }

  /// A label on the left and its control on the right, wrapping under it
  /// when a large system font leaves no room beside.
  Widget _row(String label, Widget control, {String? hint}) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 12,
        runSpacing: 8,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label, style: theme.textTheme.bodyLarge),
              if (hint != null)
                Text(
                  hint,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
          control,
        ],
      ),
    );
  }

  /// The units a system reads in go under the label — "Metric" alone doesn't
  /// tell you whether flour comes out in grams.
  Widget _units(
    String label,
    ValueNotifier<UnitSystem> setting, {
    required String metric,
    required String imperial,
  }) => _row(
    label,
    Segmented(
      options: const [
        (UnitSystem.metric, 'Metric'),
        (UnitSystem.imperial, 'US'),
      ],
      selected: setting.value,
      onChanged: (system) => _pickUnit(setting, system),
    ),
    hint: setting.value == UnitSystem.metric ? metric : imperial,
  );

  Widget _account(Account? current) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final email = current?.email;
    final outlined = OutlinedButton.styleFrom(
      minimumSize: const Size.fromHeight(50),
      side: BorderSide(color: glassRim(context)),
      foregroundColor: scheme.onSurface,
      backgroundColor: scheme.surface,
    );
    return GlassPanel(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: email == null
              ? [
                  Text('Not signed in', style: serif(26, height: 1.1)),
                  const SizedBox(height: 4),
                  Text(
                    'Sign in to keep your recipes when you change phones. '
                    'Everything works without it.',
                    style: theme.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 14),
                  OutlinedButton(
                    style: outlined,
                    onPressed: () => _run(signInWithGoogle),
                    child: const Text('Continue with Google'),
                  ),
                  // Apple's own rule: offering Google on iOS means offering
                  // Apple too.
                  if (Platform.isIOS) ...[
                    const SizedBox(height: 10),
                    FilledButton(
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(50),
                        backgroundColor: scheme.onSurface,
                        foregroundColor: scheme.surface,
                      ),
                      onPressed: () => _run(signInWithApple),
                      child: const Text('Continue with Apple'),
                    ),
                  ],
                ]
              : [
                  Text(email, style: serif(24, height: 1.15)),
                  const SizedBox(height: 4),
                  Text(
                    'Signed in · recipes sync',
                    style: theme.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 14),
                  OutlinedButton(
                    style: outlined,
                    onPressed: () => _run(signOut),
                    child: const Text('Sign out'),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Your recipes stay on this phone either way.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 6),
                  TextButton(
                    style: TextButton.styleFrom(foregroundColor: scheme.error),
                    onPressed: _confirmDelete,
                    child: const Text('Delete account'),
                  ),
                ],
        ),
      ),
    );
  }

  Future<void> _confirmDelete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete your account?'),
        content: const Text(
          'Your recipes stay on this phone. The account, and anything kept '
          'with it, is deleted for good.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep it'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) await _run(deleteAccount);
  }

  /// Runs an account action, answering any failure with a SnackBar — the same
  /// way the photo picker degrades where its plugin is missing. Backing out of
  /// the Google or Apple sheet is not a failure and says nothing.
  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      // Logged before the cancel check, not after: Credential Manager reports a
      // misconfigured OAuth client ("[16] Account reauth failed") as a cancel,
      // and a silent misconfiguration is the worst kind.
      debugPrint('Account action failed: $e');
      final cancelled =
          (e is GoogleSignInException &&
              e.code == GoogleSignInExceptionCode.canceled) ||
          (e is SignInWithAppleAuthorizationException &&
              e.code == AuthorizationErrorCode.canceled);
      if (cancelled || !mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Couldn't reach your account. Try again in a moment."),
        ),
      );
    }
  }
}

/// One option in a one-of-three list, as a card the width of the page: the
/// selected one carries the accent border and a filled dot.
class _Choice extends StatelessWidget {
  final String label;
  final String example;
  final bool selected;
  final VoidCallback onTap;

  const _Choice({
    required this.label,
    required this.example,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(16),
      side: BorderSide(
        color: selected ? scheme.primary : glassRim(context),
        width: selected ? 1.5 : 1,
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Semantics(
        selected: selected,
        inMutuallyExclusiveGroup: true,
        child: Material(
          shape: shape,
          color: selected ? herbWash(context) : scheme.surface,
          child: InkWell(
            customBorder: shape,
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(
                children: [
                  Container(
                    width: 20,
                    height: 20,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: selected ? scheme.primary : scheme.outline,
                        width: selected ? 6 : 1.5,
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(label, style: theme.textTheme.titleSmall),
                        Text(
                          example,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
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
