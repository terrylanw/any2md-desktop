import 'dart:ui';

import 'package:shared_preferences/shared_preferences.dart';

import '../domain/workspace_state.dart';

class SettingsService {
  static const _themeKey = 'theme_preference';
  static const _sidebarWidthKey = 'sidebar_width';
  static const _windowXKey = 'window_x';
  static const _windowYKey = 'window_y';
  static const _windowWidthKey = 'window_width';
  static const _windowHeightKey = 'window_height';
  Future<SharedPreferences>? _preferencesFuture;

  Future<SharedPreferences> _preferences() {
    return _preferencesFuture ??= SharedPreferences.getInstance();
  }

  Future<AppThemePreference> loadTheme() async {
    final preferences = await _preferences();
    final name = preferences.getString(_themeKey);
    return AppThemePreference.values
            .where((value) => value.name == name)
            .firstOrNull ??
        AppThemePreference.system;
  }

  Future<void> saveTheme(AppThemePreference value) async {
    final preferences = await _preferences();
    await preferences.setString(_themeKey, value.name);
  }

  Future<double> loadSidebarWidth() async {
    final preferences = await _preferences();
    return preferences.getDouble(_sidebarWidthKey) ?? 288;
  }

  Future<void> saveSidebarWidth(double value) async {
    final preferences = await _preferences();
    await preferences.setDouble(_sidebarWidthKey, value);
  }

  Future<Rect?> loadWindowBounds() async {
    final preferences = await _preferences();
    final x = preferences.getDouble(_windowXKey);
    final y = preferences.getDouble(_windowYKey);
    final width = preferences.getDouble(_windowWidthKey);
    final height = preferences.getDouble(_windowHeightKey);
    if (x == null || y == null || width == null || height == null) return null;
    if (width < 960 || height < 640) return null;
    return Rect.fromLTWH(x, y, width, height);
  }

  Future<void> saveWindowBounds(Rect bounds) async {
    final preferences = await SharedPreferences.getInstance();
    await Future.wait([
      preferences.setDouble(_windowXKey, bounds.left),
      preferences.setDouble(_windowYKey, bounds.top),
      preferences.setDouble(_windowWidthKey, bounds.width),
      preferences.setDouble(_windowHeightKey, bounds.height),
    ]);
  }
}
