// supabase.dart
import 'package:supabase_flutter/supabase_flutter.dart';
import 'dart:io';
import 'package:path/path.dart';

class SupabaseConfig {
  static const String supabaseUrl = 'https://nqydqpllowakssgfpevt.supabase.co';
  static const String supabaseAnonKey = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im5xeWRxcGxsb3dha3NzZ2ZwZXZ0Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NTU3MTE2NTIsImV4cCI6MjA3MTI4NzY1Mn0.ngqmcjL5JG_bjTPuIPEvU3iExGhvcbYKyOJsBa5P6E0';
}

// Initialize Supabase
Future<void> initializeSupabase() async {
  await Supabase.initialize(
    url: SupabaseConfig.supabaseUrl,
    anonKey: SupabaseConfig.supabaseAnonKey,
  );
}

// Get the Supabase client instance
SupabaseClient get supabase => Supabase.instance.client;

// Upload image to Supabase Storage
Future<String> uploadImage(File imageFile) async {
  try {
    // Generate unique filename with timestamp
    final String fileName = 'profile_${DateTime.now().millisecondsSinceEpoch}${extension(imageFile.path)}';
    
    // Upload the file to Supabase Storage
    await supabase.storage
        .from('profile-images') // Make sure this bucket exists in Supabase
        .upload(fileName, imageFile);
    
    // Get the public URL
    final String publicUrl = supabase.storage
        .from('profile-images')
        .getPublicUrl(fileName);
    
    return publicUrl;
  } catch (e) {
    print('Error uploading to Supabase: $e');
    throw Exception('Failed to upload image: $e');
  }
}