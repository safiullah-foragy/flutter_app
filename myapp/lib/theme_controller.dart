import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ThemeController extends ChangeNotifier {
  static final ThemeController instance = ThemeController._internal();
  ThemeController._internal();

  static const _prefKey = 'theme_mode'; // 'light' | 'dark'
  static const _seedKey = 'theme_seed'; // color key

  // Predefined theme seed colors
  static final Map<String, Color> _seeds = <String, Color>{
    'blue': Colors.blue,
    'teal': Colors.teal,
    'green': Colors.green,
    'purple': Colors.deepPurple,
    'orange': Colors.orange,
    'pink': Colors.pink,
  };

  ThemeMode _mode = ThemeMode.light;
  ThemeMode get mode => _mode;
  String _seed = 'blue';
  String get seedKey => _seed;
  Color get seedColor => _seeds[_seed] ?? Colors.blue;
  List<String> get availableSeedKeys => _seeds.keys.toList(growable: false);
  Color colorFor(String key) => _seeds[key] ?? Colors.blue;
  String displayName(String key) => key.substring(0, 1).toUpperCase() + key.substring(1);

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
      if (s != null && _seeds.containsKey(s)) {
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
    if (!_seeds.containsKey(key)) return;
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
