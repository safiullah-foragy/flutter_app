import 'dart:async';

/// Stub for non-web platforms - downloads not supported natively
Future<void> downloadDocument(String url, String fileName) async {
  throw UnsupportedError('Direct download is only supported on web platform');
}
