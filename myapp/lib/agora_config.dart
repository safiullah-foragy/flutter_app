class AgoraConfig {
  // Fill with your Agora App ID (public) from https://console.agora.io
  // For security, tokens are fetched from your Render token server.
  static const String appId = String.fromEnvironment(
    'AGORA_APP_ID',
    defaultValue: 'df35eac788e3437ca9eb8158b6754818',
  );

  // Base URL of your token server (Render). Example formats supported by Agora’s sample servers:
  //   - GET {base}/rtc/{channelName}/publisher/uid/{uid}
  //   - GET {base}/rtm/{uid}
  // If you use a custom endpoint, adjust in AgoraTokenService.
  static const String tokenServerBaseUrl = String.fromEnvironment(
    'AGORA_TOKEN_BASE_URL',
    defaultValue: 'https://render-agora-token-server-app.onrender.com',
  );
}
