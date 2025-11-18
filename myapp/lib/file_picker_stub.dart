import 'dart:async';

/// Stub for non-web platforms
Future<Map<String, dynamic>?> pickFileWeb(List<String> allowedExtensions) async {
  throw UnsupportedError('pickFileWeb is only supported on web platform');
}
