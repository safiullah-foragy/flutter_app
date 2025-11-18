import 'dart:async';
import 'dart:typed_data';
import 'dart:html' as html;

/// Web-specific file picker implementation
Future<Map<String, dynamic>?> pickFileWeb(List<String> allowedExtensions) async {
  final completer = Completer<Map<String, dynamic>?>();
  
  // Create a file input element
  final input = html.FileUploadInputElement();
  input.accept = allowedExtensions.map((ext) => '.$ext').join(',');
  
  input.onChange.listen((event) async {
    final files = input.files;
    if (files == null || files.isEmpty) {
      completer.complete(null);
      return;
    }
    
    final file = files[0];
    final reader = html.FileReader();
    
    reader.onLoadEnd.listen((event) {
      final bytes = reader.result as Uint8List;
      completer.complete({
        'name': file.name,
        'bytes': bytes,
      });
    });
    
    reader.onError.listen((event) {
      completer.completeError(Exception('Failed to read file'));
    });
    
    reader.readAsArrayBuffer(file);
  });
  
  input.click();
  
  return completer.future;
}
