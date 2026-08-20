class LiveKitConfig {
  /// Your LiveKit Cloud WebSocket URL
  static const String liveKitWsUrl = String.fromEnvironment(
    'LIVEKIT_WS_URL',
    defaultValue: 'wss://social-media-wn3bjlz8.livekit.cloud',
  );

  /// Base URL of your LiveKit Token Server deployed on Render
  static const String tokenServerBaseUrl = String.fromEnvironment(
    'LIVEKIT_TOKEN_SERVER_URL',
    defaultValue: 'https://livekit-token-server-gh3s.onrender.com',
  );

  /// LiveKit API Key
  static const String apiKey = String.fromEnvironment(
    'LIVEKIT_API_KEY',
    defaultValue: 'APIM3QFCjJeVK7d',
  );

  /// LiveKit API Secret
  static const String apiSecret = String.fromEnvironment(
    'LIVEKIT_API_SECRET',
    defaultValue: 'NcAHWaxJvKZAjuV7mmcafeyH5Y3nfvWUnXktmOPwFW1B',
  );
}
