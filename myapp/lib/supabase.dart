import 'package:supabase_flutter/supabase_flutter.dart';
import 'dart:io' show File, HttpClient; // not available on web; guard with kIsWeb
import 'package:flutter/foundation.dart' show kIsWeb;
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'dart:async';

class SupabaseConfig {
  static const String supabaseUrl = 'https://nqydqpllowakssgfpevt.supabase.co';
  static const String supabaseAnonKey = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im5xeWRxcGxsb3dha3NzZ2ZwZXZ0Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NTU3MTE2NTIsImV4cCI6MjA3MTI4NzY1Mn0.ngqmcjL5JG_bjTPuIPEvU3iExGhvcbYKyOJsBa5P6E0';
}

Future<void> initializeSupabase() async {
  await Supabase.initialize(
    url: SupabaseConfig.supabaseUrl,
    anonKey: SupabaseConfig.supabaseAnonKey,
  );
}

SupabaseClient get supabase => Supabase.instance.client;

Future<String> uploadImage(File imageFile, {String? fileName, String folder = 'profile-images'}) async {
  try {
    // Use provided fileName or generate a simple timestamped name WITHOUT bucket prefix
    final String finalFileName = fileName ?? '${DateTime.now().millisecondsSinceEpoch}${p.extension(imageFile.path)}';

    // Derive a reasonable contentType from file extension
    final String ext = p.extension(imageFile.path).toLowerCase();
    String? contentType;
    if (ext == '.jpg' || ext == '.jpeg') contentType = 'image/jpeg';
    else if (ext == '.png') contentType = 'image/png';
    else if (ext == '.gif') contentType = 'image/gif';
    else if (ext == '.webp') contentType = 'image/webp';
    else if (ext == '.mp4') contentType = 'video/mp4';
    else if (ext == '.mov') contentType = 'video/quicktime';
    else if (ext == '.mkv') contentType = 'video/x-matroska';

    // Try upload with upsert true so retries won't fail on duplicates.
    // On web, prefer the bytes-based path instead of dart:io File
    if (kIsWeb) {
      final bytes = await imageFile.readAsBytes();
      await supabase.storage.from(folder).uploadBinary(
        finalFileName,
        bytes,
        fileOptions: FileOptions(
          upsert: true,
          contentType: contentType,
          cacheControl: '3600',
        ),
      );
    } else {
      await supabase.storage.from(folder).upload(
        finalFileName,
        imageFile,
        fileOptions: FileOptions(
          upsert: true,
          contentType: contentType,
          cacheControl: '3600',
        ),
      );
    }
    final String publicUrl = supabase.storage.from(folder).getPublicUrl(finalFileName);

    // Validate public URL is accessible. If not, try to create a signed URL
    // (useful when buckets are private or RLS blocks public access).
    final ok = await _headOk(publicUrl);
    if (ok) return publicUrl;

    try {
      final dynamic signed = await supabase.storage.from(folder).createSignedUrl(finalFileName, 60 * 60);
      final String? signedUrl = signed?.toString();
      if (signedUrl != null && await _headOk(signedUrl)) {
        return signedUrl;
      }
    } catch (e) {
      // ignore and fallthrough to returning publicUrl which may still be useful
      print('createSignedUrl failed: $e');
    }

    return publicUrl;
  } catch (e) {
    print('Error uploading to Supabase (exception): $e');
    throw Exception('Failed to upload image: $e');
  }
}

Future<bool> _headOk(String url) async {
  final uri = Uri.parse(url);
  if (kIsWeb) {
    // Use package:http on web
    try {
      final resp = await http.head(uri);
      return resp.statusCode >= 200 && resp.statusCode < 300;
    } catch (_) {
      try {
        final resp = await http.get(uri, headers: {'Range': 'bytes=0-0'});
        final status = resp.statusCode;
        final ok = (status >= 200 && status < 300) || status == 206;
        if (!ok) print('web HEAD+GET(range) failed for $url, status=$status');
        return ok;
      } catch (e2) {
        print('web HEAD and GET(range) failed for $url: $e2');
        return false;
      }
    }
  } else {
    try {
      final client = HttpClient();
      client.userAgent = 'MyApp/1.0';
      final req = await client.openUrl('HEAD', uri);
      final resp = await req.close();
      final ok = resp.statusCode >= 200 && resp.statusCode < 300;
      client.close(force: true);
      return ok;
    } catch (e) {
      // Try GET with Range as fallback (some servers may not allow HEAD)
      try {
        final client = HttpClient();
        client.userAgent = 'MyApp/1.0';
        final req = await client.getUrl(uri);
        req.headers.add('Range', 'bytes=0-0');
        final resp = await req.close();
        final status = resp.statusCode;
        client.close(force: true);
        final ok = (status >= 200 && status < 300) || status == 206;
        if (!ok) print('HEAD+GET(range) failed for $url, status=$status');
        return ok;
      } catch (e2) {
        print('HEAD and GET(range) failed for $url: $e2');
        return false;
      }
    }
  }
}

// Bytes-based upload for web (also usable on mobile if bytes available)
Future<String> uploadImageData(
  Uint8List data, {
  String? fileName,
  String folder = 'profile-images',
  String? contentType,
}) async {
  try {
    final String finalFileName = fileName ?? '${DateTime.now().millisecondsSinceEpoch}.bin';

    // Infer contentType from extension if not provided
    final String ext = p.extension(finalFileName).toLowerCase();
    String? ct = contentType;
    if (ct == null || ct.isEmpty) {
      if (ext == '.jpg' || ext == '.jpeg') ct = 'image/jpeg';
      else if (ext == '.png') ct = 'image/png';
      else if (ext == '.gif') ct = 'image/gif';
      else if (ext == '.webp') ct = 'image/webp';
      else if (ext == '.mp4') ct = 'video/mp4';
      else if (ext == '.mov') ct = 'video/quicktime';
      else if (ext == '.mkv') ct = 'video/x-matroska';
      else ct = 'application/octet-stream';
    }

    await supabase.storage.from(folder).uploadBinary(
      finalFileName,
      data,
      fileOptions: FileOptions(
        upsert: true,
        contentType: ct,
        cacheControl: '3600',
      ),
    );
    final String publicUrl = supabase.storage.from(folder).getPublicUrl(finalFileName);

    final ok = await _headOk(publicUrl);
    if (ok) return publicUrl;

    try {
      final dynamic signed = await supabase.storage.from(folder).createSignedUrl(finalFileName, 60 * 60);
      final String? signedUrl = signed?.toString();
      if (signedUrl != null && await _headOk(signedUrl)) {
        return signedUrl;
      }
    } catch (e) {
      print('createSignedUrl (bytes) failed: $e');
    }

    return publicUrl;
  } catch (e) {
    print('Error uploading bytes to Supabase (exception): $e');
    throw Exception('Failed to upload image: $e');
  }
}

Future<String> uploadVideo(File videoFile, {String? fileName}) async {
  return uploadImage(videoFile, fileName: fileName, folder: 'post-videos');
}

Future<String> uploadPostImage(File imageFile, {String? fileName}) async {
  return uploadImage(imageFile, fileName: fileName, folder: 'post-images');
}

/// Upload image intended for messages (public folder `message-images`).
Future<String> uploadMessageImage(File imageFile, {String? fileName}) async {
  return uploadImage(imageFile, fileName: fileName, folder: 'message-images');
}

/// Upload video intended for messages (public folder `message-videos`).
Future<String> uploadMessageVideo(File videoFile, {String? fileName}) async {
  return uploadImage(videoFile, fileName: fileName, folder: 'message-videos');
}

/// Bytes-based wrappers for messages
Future<String> uploadMessageImageBytes(Uint8List data, {String? fileName, String? contentType}) async {
  return uploadImageData(data, fileName: fileName, folder: 'message-images', contentType: contentType);
}

Future<String> uploadMessageVideoBytes(Uint8List data, {String? fileName, String? contentType}) async {
  return uploadImageData(data, fileName: fileName, folder: 'message-videos', contentType: contentType);
}