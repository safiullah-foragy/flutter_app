import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'livekit_config.dart';

class LiveKitTokenService {
  /// Fetches a LiveKit JWT token from Render or creates a signed token locally as fallback
  static Future<String?> fetchLiveKitToken({
    required String roomName,
    required String identity,
    required bool isPublisher,
    String? userName,
  }) async {
    // 1. Try fetching from Render Token Server first
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

      final response = await http.get(uri).timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final token = data['token'] as String?;
        if (token != null && token.isNotEmpty) {
          debugPrint('LiveKit token successfully fetched from Render for room: $roomName');
          return token;
        }
      }
      debugPrint('Render token request failed with status: ${response.statusCode}');
    } catch (e) {
      debugPrint('Render token server timeout/error: $e (Falling back to local JWT signing)');
    }

    // 2. Fallback: Generate signed JWT token locally
    try {
      final now = DateTime.now().toUtc();
      final jwt = JWT(
        {
          'name': userName ?? identity,
          'video': {
            'room': roomName,
            'roomJoin': true,
            'canPublish': isPublisher,
            'canPublishData': true,
            'canSubscribe': true,
          },
        },
        issuer: LiveKitConfig.apiKey,
        subject: identity,
      );

      final token = jwt.sign(
        SecretKey(LiveKitConfig.apiSecret),
        expiresIn: const Duration(hours: 6),
        notBefore: const Duration(seconds: -10),
      );

      debugPrint('LiveKit token successfully signed locally for room: $roomName (isPublisher: $isPublisher)');
      return token;
    } catch (e) {
      debugPrint('Error creating local LiveKit token: $e');
      return null;
    }
  }
}
