import 'package:supabase_flutter/supabase_flutter.dart';
import 'dart:io';
import 'package:path/path.dart';

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
    final String finalFileName = fileName ?? '${folder}/${DateTime.now().millisecondsSinceEpoch}${extension(imageFile.path)}';

    // Try upload with upsert true so retries won't fail on duplicates.
    await supabase.storage.from(folder).upload(finalFileName, imageFile, fileOptions: FileOptions(upsert: true));
    final String publicUrl = supabase.storage.from(folder).getPublicUrl(finalFileName);
    return publicUrl;
  } catch (e) {
    print('Error uploading to Supabase (exception): $e');
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