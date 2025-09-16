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

Future<String> uploadImage(File imageFile) async {
  try {
    final String fileName = 'profile_${DateTime.now().millisecondsSinceEpoch}${extension(imageFile.path)}';
    
    await supabase.storage
        .from('profile-images')
        .upload(fileName, imageFile);
    
    final String publicUrl = supabase.storage
        .from('profile-images')
        .getPublicUrl(fileName);
    
    return publicUrl;
  } catch (e) {
    print('Error uploading to Supabase: $e');
    throw Exception('Failed to upload image: $e');
  }
}