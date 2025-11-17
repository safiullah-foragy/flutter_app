import 'dart:convert';
import 'package:http/http.dart' as http;
import 'agora_config.dart';

class AgoraTokenService {
  // Basic RTC token fetcher compatible with common sample token servers.
  // Adjust the path if your server uses a different route.
  static Future<String> fetchRtcToken({
    required String channelName,
    required int uid,
    String role = 'publisher',
    int expireSeconds = 3600,
  }) async {
    final base = AgoraConfig.tokenServerBaseUrl.replaceAll(RegExp(r'/+$'), '');

    // First try the explicit /rtc endpoint
    final rtcUrl = Uri.parse('$base/rtc/$channelName/$role/uid/$uid?expiry=$expireSeconds');
    final res = await http.get(rtcUrl);
    if (res.statusCode >= 200 && res.statusCode < 300) {
      final body = json.decode(res.body) as Map<String, dynamic>;
      final token = _extractTokenFromBody(body);
      if (token.isNotEmpty) return token;
      throw Exception('Token server did not return token field');
    }

    // If /rtc returns 404, try the more generic /all endpoint (some servers expose combined route)
    if (res.statusCode == 404) {
      // 1) Many servers expect channelName not channel
      final allUrlCN = Uri.parse('$base/all?channelName=$channelName&uid=$uid&role=$role&expiry=$expireSeconds');
      var res2 = await http.get(allUrlCN);
      if (res2.statusCode >= 200 && res2.statusCode < 300) {
        final body = json.decode(res2.body) as Map<String, dynamic>;
        final token = _extractTokenFromBody(body);
        if (token.isNotEmpty) return token;
        throw Exception('Token server /all (channelName) did not return token field');
      }

      // 2) Some servers accept a JSON POST body
      final res3 = await http.post(
        Uri.parse('$base/all'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'channelName': channelName,
          'uid': uid,
          'role': role,
          'expiry': expireSeconds,
        }),
      );
      if (res3.statusCode >= 200 && res3.statusCode < 300) {
        final body = json.decode(res3.body) as Map<String, dynamic>;
        final token = _extractTokenFromBody(body);
        if (token.isNotEmpty) return token;
        throw Exception('Token server /all POST did not return token field');
      }

      // 3) Legacy: try channel query param name
      final allUrlLegacy = Uri.parse('$base/all?channel=$channelName&uid=$uid&role=$role&expiry=$expireSeconds');
      final res4 = await http.get(allUrlLegacy);
      if (res4.statusCode >= 200 && res4.statusCode < 300) {
        final body = json.decode(res4.body) as Map<String, dynamic>;
        final token = _extractTokenFromBody(body);
        if (token.isNotEmpty) return token;
        throw Exception('Token server /all (channel) did not return token field');
      }

      throw Exception('Token server /all error: ${res2.statusCode} ${res2.body.isEmpty ? res3.body : res2.body}');
    }

    throw Exception('Token server /rtc error: ${res.statusCode} ${res.body}');
  }

  static String _extractTokenFromBody(Map<String, dynamic> body) {
    // Common responses: {"rtcToken":"..."} or {"token":"..."} or nested structures
    String token = '';
    try {
  token = (body['rtcToken'] ?? body['token'] ?? '') as String;
  if (token.isNotEmpty) return token;
    } catch (_) {}

    // Some servers return { "rtc": { "token": "..." } } or similar
    try {
      if (body.containsKey('rtc') && body['rtc'] is Map) {
        final inner = body['rtc'] as Map<String, dynamic>;
  token = (inner['rtcToken'] ?? inner['token'] ?? '') as String;
  if (token.isNotEmpty) return token;
      }
    } catch (_) {}

    return '';
  }
}
