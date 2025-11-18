// Stub for non-web platforms
// This file is imported on iOS/Android where agora_web_client.dart is not needed

class AgoraWebClient {
  Future<void> initialize(String appId) async {
    throw UnsupportedError('AgoraWebClient is only supported on web platform');
  }
  
  Future<void> joinChannel({
    required String token,
    required String channelName,
    required int uid,
    required bool enableVideo,
  }) async {
    throw UnsupportedError('AgoraWebClient is only supported on web platform');
  }
  
  Future<void> leaveChannel() async {}
  Future<void> muteLocalAudio(bool mute) async {}
  Future<void> enableLocalVideo(bool enable) async {}
  void dispose() {}
  
  Stream<int> get onUserJoined => Stream.empty();
  Stream<int> get onUserLeft => Stream.empty();
}
