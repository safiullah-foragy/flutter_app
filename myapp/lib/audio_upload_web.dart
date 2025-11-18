import 'dart:async';
import 'dart:typed_data';
import 'dart:html' as html;

/// Web-specific audio upload helper
Future<Uint8List> readAudioBlobAsBytes(String blobUrl) async {
  final response = await html.window.fetch(blobUrl);
  final blob = await response.blob();
  final reader = html.FileReader();
  reader.readAsArrayBuffer(blob);
  await reader.onLoad.first;
  return reader.result as Uint8List;
}
