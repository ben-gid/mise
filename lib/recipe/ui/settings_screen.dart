import 'dart:io';

import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import '../recipe_account.dart';
import '../recipe_store.dart';
import '../recipe_units.dart';
import 'glass.dart';

/// Settings. Theme, then the display units, then the account when this build
/// has one — another one goes in as another panel under these.
class SettingsScreen extends StatefulWidget {
  final RecipeStore store;

  const SettingsScreen({super.key, required this.store});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  static const _modes = {
    ThemeMode.light: ('Light', Icons.light_mode_outlined),
    ThemeMode.dark: ('Dark', Icons.dark_mode_outlined),
    ThemeMode.system: ('Auto', Icons.brightness_auto_outlined),
  };

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
    return GlassScaffold(
      appBar: glassAppBar(context, title: const Text('Settings')),
      body: ListView(
        padding: EdgeInsets.only(
          top: glassAppBarInset(context) + 8,
          bottom: 24,
        ),
        children: [
          _heading('Theme'),
          _panel([
            for (final entry in _modes.entries)
              // ListTile, not RadioListTile: same one-tap behaviour, and it
              // keeps the row a plain finger-sized target.
              ListTile(
                leading: Icon(entry.value.$2),
                title: Text(entry.value.$1),
                trailing: _check(entry.key == themeMode.value),
                onTap: () => _pick(entry.key),
              ),
          ]),
          _heading('Weight'),
          _units(weightSystem, metric: 'g', imperial: 'oz · lb'),
          _heading('Volume'),
          _units(volumeSystem, metric: 'ml', imperial: 'tsp · tbsp · cup'),
          _heading('Measure by'),
          _panel([
            for (final (by, label, example) in const [
              (
                MeasureBy.asWritten,
                'As written',
                'However each recipe saved it',
              ),
              (MeasureBy.weight, 'Weight', 'On a scale wherever it can be'),
              (
                MeasureBy.volume,
                'Volume',
                'In cups and spoons wherever it can be',
              ),
            ])
              ListTile(
                title: Text(label),
                subtitle: Text(example),
                trailing: _check(by == measureBy.value),
                onTap: () => _pickMeasure(by),
              ),
          ]),
          const Padding(
            padding: EdgeInsets.fromLTRB(28, 16, 28, 0),
            child: Text(
              'Recipes are stored as written and converted for display, '
              'rounded to measurements you can actually scoop. Switching '
              'between weight and volume needs a known density, so some '
              'ingredients stay as written. Tap any amount to switch just '
              'that one.',
            ),
          ),
          // Last, not first: the app works the same signed in or not, and a
          // sign-in panel at the top of Settings reads as a gate.
          if (accountsOn) ...[
            _heading('Account'),
            ValueListenableBuilder(
              valueListenable: account,
              builder: (context, current, _) => _account(current),
            ),
          ],
        ],
      ),
    );
  }

  Widget _account(Account? current) {
    final email = current?.email;
    if (email == null) {
      return _panel([
        const ListTile(
          title: Text('Not signed in'),
          subtitle: Text(
            'Sign in to keep your recipes when you change phones. '
            'Everything works without it.',
          ),
        ),
        ListTile(
          leading: const Icon(Icons.login),
          title: const Text('Continue with Google'),
          onTap: () => _run(signInWithGoogle),
        ),
        // Apple's own rule: offering Google on iOS means offering Apple too.
        if (Platform.isIOS)
          ListTile(
            leading: const Icon(Icons.apple),
            title: const Text('Continue with Apple'),
            onTap: () => _run(signInWithApple),
          ),
      ]);
    }
    final danger = Theme.of(context).colorScheme.error;
    return _panel([
      ListTile(
        leading: const Icon(Icons.account_circle_outlined),
        title: Text(email),
        subtitle: const Text('Signed in'),
      ),
      ListTile(
        leading: const Icon(Icons.logout),
        title: const Text('Sign out'),
        subtitle: const Text('Your recipes stay on this phone'),
        onTap: () => _run(signOut),
      ),
      ListTile(
        leading: Icon(Icons.delete_outline, color: danger),
        title: Text('Delete account', style: TextStyle(color: danger)),
        onTap: _confirmDelete,
      ),
    ]);
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

  /// The units the system reads in go in the subtitle rather than the title —
  /// "Metric" alone doesn't tell you whether flour comes out in grams.
  Widget _units(
    ValueNotifier<UnitSystem> setting, {
    required String metric,
    required String imperial,
  }) => _panel([
    for (final (system, example) in [
      (UnitSystem.metric, metric),
      (UnitSystem.imperial, imperial),
    ])
      ListTile(
        title: Text(system == UnitSystem.metric ? 'Metric' : 'US'),
        subtitle: Text(example),
        trailing: _check(system == setting.value),
        onTap: () => _pickUnit(setting, system),
      ),
  ]);

  Widget _heading(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(28, 16, 28, 8),
    child: Text(text, style: Theme.of(context).textTheme.titleSmall),
  );

  Widget _panel(List<Widget> children) => GlassPanel(
    margin: const EdgeInsets.symmetric(horizontal: 16),
    child: Column(children: children),
  );

  Widget? _check(bool selected) => selected
      ? Icon(Icons.check, color: Theme.of(context).colorScheme.primary)
      : null;
}
