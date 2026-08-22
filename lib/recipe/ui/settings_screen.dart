import 'package:flutter/material.dart';

import '../recipe_store.dart';
import '../recipe_units.dart';
import 'glass.dart';

/// Settings. Theme, then the display units — another one goes in as another
/// panel under these.
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

  /// Both systems go to disk together — they share one sidecar line.
  void _pickUnit(ValueNotifier<UnitSystem> setting, UnitSystem system) {
    setState(() => setting.value = system);
    widget.store.setUnitSystems(
      '${weightSystem.value.name},${volumeSystem.value.name}',
    );
  }

  @override
  Widget build(BuildContext context) {
    return GlassScaffold(
      appBar: glassAppBar(context, title: const Text('Settings')),
      body: ListView(
        padding: EdgeInsets.only(top: glassAppBarInset(context) + 8, bottom: 24),
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
          const Padding(
            padding: EdgeInsets.fromLTRB(28, 16, 28, 0),
            child: Text(
              'Recipes are stored as written and converted for display, '
              'rounded to measurements you can actually scoop.',
            ),
          ),
        ],
      ),
    );
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
