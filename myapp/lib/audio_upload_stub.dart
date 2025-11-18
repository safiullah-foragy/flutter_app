import 'dart:async';
import 'dart:typed_data';

/// Stub for non-web platforms
Future<Uint8List> readAudioBlobAsBytes(String blobUrl) async {
  throw UnsupportedError('Audio blob reading is only supported on web');
}
