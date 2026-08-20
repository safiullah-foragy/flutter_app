import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'livekit_config.dart';

class LiveKitTokenService {
  /// Fetches a LiveKit JWT token from the Render token server
  /// [roomName] - Channel/Post ID
  /// [identity] - Unique user ID
  /// [isPublisher] - true for Broadcaster/Host, false for Audience/Viewer
  /// [userName] - Optional display name
  static Future<String?> fetchLiveKitToken({
    required String roomName,
    required String identity,
    required bool isPublisher,
    String? userName,
  }) async {
    try {
      final base = LiveKitConfig.tokenServerBaseUrl.replaceAll(RegExp(r'/+$'), '');
      final queryParams = {
        'room': roomName,
        'identity': identity,
        'isPublisher': isPublisher.toString(),
        if (userName != null && userName.isNotEmpty) 'name': userName,
      };

      final uri = Uri.parse('$base/getToken').replace(queryParameters: queryParams);
      debugPrint('Fetching LiveKit token from: $uri');

      final response = await http.get(uri).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final token = data['token'] as String?;
        if (token != null && token.isNotEmpty) {
          debugPrint('LiveKit token successfully fetched for room: $roomName (isPublisher: $isPublisher)');
          return token;
        }
      }

      debugPrint('LiveKit token request failed with status: ${response.statusCode} body: ${response.body}');
      return null;
    } catch (e) {
      debugPrint('Error fetching LiveKit token: $e');
      return null;
    }
  }
}
