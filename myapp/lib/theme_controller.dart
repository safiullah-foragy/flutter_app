import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AppThemeData {
  final String key;
  final String name;
  final Color primary;
  final Color secondary;
  final Color accent;
  final List<Color> gradient;

  const AppThemeData({
    required this.key,
    required this.name,
    required this.primary,
    required this.secondary,
    required this.accent,
    required this.gradient,
  });
}

class ThemeController extends ChangeNotifier {
  static final ThemeController instance = ThemeController._internal();
  ThemeController._internal();

  static const _prefKey = 'theme_mode'; // 'light' | 'dark'
  static const _seedKey = 'theme_seed'; // color key

  // 10 Predefined themes with the default Connectify Ocean Blue running first
  static const List<AppThemeData> allThemes = [
    AppThemeData(
      key: 'default',
      name: 'Ocean Blue (Default)',
      primary: Color(0xFF1565C0),
      secondary: Color(0xFF0288D1),
      accent: Color(0xFF00ACC1),
      gradient: [Color(0xFF1565C0), Color(0xFF0288D1), Color(0xFF00ACC1)],
    ),
    AppThemeData(
      key: 'royal_purple',
      name: 'Royal Purple',
      primary: Color(0xFF6A1B9A),
      secondary: Color(0xFF8E24AA),
      accent: Color(0xFFAB47BC),
      gradient: [Color(0xFF4A148C), Color(0xFF7B1FA2), Color(0xFFAB47BC)],
    ),
    AppThemeData(
      key: 'emerald_green',
      name: 'Emerald Green',
      primary: Color(0xFF1B5E20),
      secondary: Color(0xFF2E7D32),
      accent: Color(0xFF43A047),
      gradient: [Color(0xFF1B5E20), Color(0xFF2E7D32), Color(0xFF43A047)],
    ),
    AppThemeData(
      key: 'sunset_orange',
      name: 'Sunset Orange',
      primary: Color(0xFFD84315),
      secondary: Color(0xFFE65100),
      accent: Color(0xFFFF8F00),
      gradient: [Color(0xFFBF360C), Color(0xFFD84315), Color(0xFFFF6F00)],
    ),
    AppThemeData(
      key: 'rose_crimson',
      name: 'Rose Crimson',
      primary: Color(0xFF880E4F),
      secondary: Color(0xFFAD1457),
      accent: Color(0xFFE91E63),
      gradient: [Color(0xFF880E4F), Color(0xFFC2185B), Color(0xFFE91E63)],
    ),
    AppThemeData(
      key: 'midnight_indigo',
      name: 'Midnight Indigo',
      primary: Color(0xFF1A237E),
      secondary: Color(0xFF283593),
      accent: Color(0xFF3F51B5),
      gradient: [Color(0xFF1A237E), Color(0xFF283593), Color(0xFF5C6BC0)],
    ),
    AppThemeData(
      key: 'cyber_teal',
      name: 'Cyber Teal',
      primary: Color(0xFF00695C),
      secondary: Color(0xFF00897B),
      accent: Color(0xFF00BFA5),
      gradient: [Color(0xFF004D40), Color(0xFF00695C), Color(0xFF00BFA5)],
    ),
    AppThemeData(
      key: 'golden_amber',
      name: 'Golden Amber',
      primary: Color(0xFFE65100),
      secondary: Color(0xFFFF6F00),
      accent: Color(0xFFFFB300),
      gradient: [Color(0xFFE65100), Color(0xFFFF8F00), Color(0xFFFFB300)],
    ),
    AppThemeData(
      key: 'coral_blush',
      name: 'Coral Blush',
      primary: Color(0xFFC2185B),
      secondary: Color(0xFFD81B60),
      accent: Color(0xFFFF5252),
      gradient: [Color(0xFF880E4F), Color(0xFFD81B60), Color(0xFFFF5252)],
    ),
    AppThemeData(
      key: 'deep_slate',
      name: 'Deep Slate',
      primary: Color(0xFF263238),
      secondary: Color(0xFF37474F),
      accent: Color(0xFF546E7A),
      gradient: [Color(0xFF1A2126), Color(0xFF263238), Color(0xFF455A64)],
    ),
  ];

  ThemeMode _mode = ThemeMode.light;
  ThemeMode get mode => _mode;
  String _seed = 'default';
  String get seedKey => _seed;

  AppThemeData get currentTheme =>
      allThemes.firstWhere((t) => t.key == _seed, orElse: () => allThemes.first);

  Color get primaryColor => currentTheme.primary;
  Color get secondaryColor => currentTheme.secondary;
  Color get accentColor => currentTheme.accent;
  List<Color> get gradientColors => currentTheme.gradient;
  Color get seedColor => currentTheme.primary;

  LinearGradient get appBarGradient => LinearGradient(
        colors: currentTheme.gradient,
        begin: Alignment.centerLeft,
        end: Alignment.centerRight,
      );

  List<String> get availableSeedKeys => allThemes.map((t) => t.key).toList(growable: false);
  Color colorFor(String key) =>
      allThemes.firstWhere((t) => t.key == key, orElse: () => allThemes.first).primary;
  String displayName(String key) =>
      allThemes.firstWhere((t) => t.key == key, orElse: () => allThemes.first).name;

  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final v = prefs.getString(_prefKey);
      if (v == 'dark') {
        _mode = ThemeMode.dark;
      } else if (v == 'light') {
        _mode = ThemeMode.light;
      }
      final s = prefs.getString(_seedKey);
      if (s != null && allThemes.any((t) => t.key == s)) {
        _seed = s;
      }
    } catch (_) {
      // ignore errors and keep default
    }
  }

  Future<void> setDark(bool dark) async {
    _mode = dark ? ThemeMode.dark : ThemeMode.light;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefKey, dark ? 'dark' : 'light');
    } catch (_) {
      // ignore persistence errors
    }
  }

  Future<void> setSeed(String key) async {
    if (!allThemes.any((t) => t.key == key)) return;
    _seed = key;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_seedKey, key);
    } catch (_) {
      // ignore
    }
  }
}
