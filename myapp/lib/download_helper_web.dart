import 'dart:html' as html;
import 'package:http/http.dart' as http;

/// Web-specific download implementation using blob URLs
Future<void> downloadDocument(String url, String fileName) async {
  final response = await http.get(Uri.parse(url));
  final bytes = response.bodyBytes;
  
  final blob = html.Blob([bytes]);
  final blobUrl = html.Url.createObjectUrlFromBlob(blob);
  html.AnchorElement(href: blobUrl)
    ..setAttribute('download', fileName)
    ..click();
  html.Url.revokeObjectUrl(blobUrl);
}
