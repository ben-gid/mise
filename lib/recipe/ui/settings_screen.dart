import 'package:flutter/material.dart';

import '../recipe_store.dart';
import 'glass.dart';

/// Settings. Theme is the only one for now; another goes in as another panel
/// under this one.
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GlassScaffold(
      appBar: glassAppBar(context, title: const Text('Settings')),
      body: ListView(
        padding: EdgeInsets.only(top: glassAppBarInset(context) + 8, bottom: 24),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(28, 8, 28, 8),
            child: Text('Theme', style: theme.textTheme.titleSmall),
          ),
          GlassPanel(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              children: [
                for (final entry in _modes.entries)
                  // ListTile, not RadioListTile: same one-tap behaviour, and it
                  // keeps the row a plain finger-sized target.
                  ListTile(
                    leading: Icon(entry.value.$2),
                    title: Text(entry.value.$1),
                    trailing: themeMode.value == entry.key
                        ? Icon(Icons.check, color: theme.colorScheme.primary)
                        : null,
                    onTap: () => _pick(entry.key),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
