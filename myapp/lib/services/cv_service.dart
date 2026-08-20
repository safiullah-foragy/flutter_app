import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import '../models/cv_model.dart';

class CVService {
  static const String baseUrl = 'https://cv-generator-backend-2z8t.onrender.com';
  
  // List of all 20 CV templates
  static final List<CVTemplate> templates = [
    CVTemplate(id: 1, name: 'Professional Blue', color: '#2C3E50', description: 'Classic professional design with header photo'),
    CVTemplate(id: 2, name: 'Modern Green', color: '#27AE60', description: 'Two-column modern layout'),
    CVTemplate(id: 3, name: 'Creative Purple', color: '#8E44AD', description: 'Sidebar design with creative flair'),
    CVTemplate(id: 4, name: 'Bold Red', color: '#E74C3C', description: 'Minimalist centered photo design'),
    CVTemplate(id: 5, name: 'Elegant Orange', color: '#F39C12', description: 'Elegant left-aligned layout'),
    CVTemplate(id: 6, name: 'Clean Teal', color: '#1ABC9C', description: 'Clean modern with top photo'),
    CVTemplate(id: 7, name: 'Minimal Gray', color: '#34495E', description: 'Minimal corner photo design'),
    CVTemplate(id: 8, name: 'Warm Orange', color: '#E67E22', description: 'Timeline style layout'),
    CVTemplate(id: 9, name: 'Fresh Turquoise', color: '#16A085', description: 'Box style with large photo'),
    CVTemplate(id: 10, name: 'Classic Blue', color: '#2980B9', description: 'Traditional centered design'),
    CVTemplate(id: 11, name: 'Vibrant', color: '#D35400', description: 'Vibrant header design'),
    CVTemplate(id: 12, name: 'Corporate', color: '#7F8C8D', description: 'Corporate centered photo'),
    CVTemplate(id: 13, name: 'Executive', color: '#C0392B', description: 'Executive bold design'),
    CVTemplate(id: 14, name: 'Contemporary', color: '#16A085', description: 'Contemporary sidebar'),
    CVTemplate(id: 15, name: 'Artistic', color: '#8E44AD', description: 'Artistic layout'),
    CVTemplate(id: 16, name: 'Professional Dark', color: '#34495E', description: 'Dark professional theme'),
    CVTemplate(id: 17, name: 'Energetic', color: '#D68910', description: 'Energetic orange theme'),
    CVTemplate(id: 18, name: 'Nature', color: '#117A65', description: 'Nature green theme'),
    CVTemplate(id: 19, name: 'Luxury', color: '#6C3483', description: 'Luxury purple theme'),
    CVTemplate(id: 20, name: 'Ocean', color: '#1F618D', description: 'Ocean blue theme'),
  ];

  static Future<List<GeneratedCV>> generateCV({
    required CVFormData formData,
    required List<int> selectedTemplates,
    File? photo,
  }) async {
    try {
      final uri = Uri.parse('$baseUrl/api/generate-cv');
      final request = http.MultipartRequest('POST', uri);

      // Add all form fields
      final jsonData = formData.toJson();
      jsonData.forEach((key, value) {
        request.fields[key] = value.toString();
      });

      // Add selected templates as JSON string
      request.fields['selectedTemplates'] = jsonEncode(selectedTemplates);

      // Add previous jobs as JSON string
      request.fields['previousJobs'] = jsonEncode(
        formData.previousJobs.map((job) => job.toJson()).toList(),
      );

      // Add photo if provided
      if (photo != null) {
        final photoStream = http.ByteStream(photo.openRead());
        final photoLength = await photo.length();
        final multipartFile = http.MultipartFile(
          'photo',
          photoStream,
          photoLength,
          filename: photo.path.split('/').last,
          contentType: MediaType('image', 'jpeg'),
        );
        request.files.add(multipartFile);
      }

      // Send request
      final streamedResponse = await request.send();
      final response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['success'] == true) {
          final List<dynamic> cvsData = data['data'];
          return cvsData.map((cvJson) => GeneratedCV.fromJson(cvJson)).toList();
        } else {
          throw Exception(data['message'] ?? 'Failed to generate CV');
        }
      } else {
        throw Exception('Server error: ${response.statusCode}');
      }
    } catch (e) {
      throw Exception('Error generating CV: $e');
    }
  }
}
