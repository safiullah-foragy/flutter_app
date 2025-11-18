import 'dart:async';
import 'dart:js' as js;
import 'dart:html' as html;
import 'package:flutter/foundation.dart';

/// Web-specific Agora RTC client using JavaScript interop
/// This directly calls the Agora Web SDK loaded in index.html
class AgoraWebClient {
  js.JsObject? _client;
  js.JsObject? _localAudioTrack;
  js.JsObject? _localVideoTrack;
  final StreamController<int> _userJoinedController = StreamController.broadcast();
  final StreamController<int> _userLeftController = StreamController.broadcast();
  String? _appId; // Store appId for join

  Stream<int> get onUserJoined => _userJoinedController.stream;
  Stream<int> get onUserLeft => _userLeftController.stream;

  /// Create video containers dynamically in the DOM
  void _createVideoContainers() {
    // Remove existing containers if any
    html.querySelector('#remote-video-container')?.remove();
    html.querySelector('#local-video-container')?.remove();
    
    // Create remote video container (full screen minus controls area)
    final remoteContainer = html.DivElement()
      ..id = 'remote-video-container'
      ..style.position = 'fixed'
      ..style.top = '0'
      ..style.left = '0'
      ..style.width = '100vw'
      ..style.height = 'calc(100vh - 90px)' // Leave space for controls
      ..style.zIndex = '999999'
      ..style.backgroundColor = 'black'
      ..style.display = 'none'
      ..style.pointerEvents = 'none';
    
    // Create local video container (PiP) - position above controls
    final localContainer = html.DivElement()
      ..id = 'local-video-container'
      ..style.position = 'fixed'
      ..style.bottom = '110px' // Above controls (90px) + margin
      ..style.right = '20px'
      ..style.width = '150px'
      ..style.height = '200px'
      ..style.zIndex = '1000000'
      ..style.borderRadius = '8px'
      ..style.overflow = 'hidden'
      ..style.display = 'none'
      ..style.pointerEvents = 'auto';
    
    // Append to body
    html.document.body?.append(remoteContainer);
    html.document.body?.append(localContainer);
    
    debugPrint('AgoraWeb: Video containers created dynamically');
  }

  /// Initialize the Agora Web client
  Future<void> initialize(String appId) async {
    try {
      _appId = appId; // Store for later use
      debugPrint('AgoraWeb: Initializing with appId: $appId');
      
      // Create video containers dynamically (Flutter clears the HTML body)
      _createVideoContainers();
      
      // Check if video containers exist
      final remoteContainer = html.querySelector('#remote-video-container');
      final localContainer = html.querySelector('#local-video-container');
      debugPrint('AgoraWeb: Remote container exists: ${remoteContainer != null}');
      debugPrint('AgoraWeb: Local container exists: ${localContainer != null}');
      
      final AgoraRTC = js.context['AgoraRTC'];
      if (AgoraRTC == null) {
        throw Exception('AgoraRTC not found. Make sure the Web SDK is loaded in index.html');
      }

      debugPrint('AgoraWeb: AgoraRTC SDK version: ${AgoraRTC['VERSION']}');

      // Create RTC client with VP8 codec
      _client = AgoraRTC.callMethod('createClient', [
        js.JsObject.jsify({'mode': 'rtc', 'codec': 'vp8'})
      ]);

      debugPrint('AgoraWeb: Client created successfully');

      // Set up event listeners
      _client!.callMethod('on', [
        'user-published',
        js.allowInterop((user, mediaType) {
          debugPrint('AgoraWeb: User published - uid: ${user['uid']}, mediaType: $mediaType');
          
          // Subscribe to the remote user (fire and forget, handle errors internally)
          _subscribeToUser(user, mediaType).catchError((e) {
            debugPrint('AgoraWeb: Error in user-published handler: $e');
          });
        })
      ]);

      _client!.callMethod('on', [
        'user-joined',
        js.allowInterop((user) {
          final uid = user['uid'] as int;
          debugPrint('AgoraWeb: User joined - uid: $uid');
          _userJoinedController.add(uid);
        })
      ]);

      _client!.callMethod('on', [
        'user-left',
        js.allowInterop((user, reason) {
          final uid = user['uid'] as int;
          debugPrint('AgoraWeb: User left - uid: $uid, reason: $reason');
          _userLeftController.add(uid);
        })
      ]);

      _client!.callMethod('on', [
        'user-unpublished',
        js.allowInterop((user, mediaType) {
          debugPrint('AgoraWeb: User unpublished - uid: ${user['uid']}, mediaType: $mediaType');
        })
      ]);

      debugPrint('AgoraWeb: Event listeners registered');
    } catch (e) {
      debugPrint('AgoraWeb: Initialization error - $e');
      rethrow;
    }
  }

  /// Join a channel with token
  Future<void> joinChannel({
    required String token,
    required String channelName,
    required int uid,
    required bool enableVideo,
  }) async {
    try {
      debugPrint('AgoraWeb: Joining channel: $channelName, uid: $uid, video: $enableVideo');

      // Create local tracks
      final AgoraRTC = js.context['AgoraRTC'];
      
      _localAudioTrack = await _promiseToFuture(
        AgoraRTC.callMethod('createMicrophoneAudioTrack')
      );
      debugPrint('AgoraWeb: Audio track created');

      if (enableVideo) {
        _localVideoTrack = await _promiseToFuture(
          AgoraRTC.callMethod('createCameraVideoTrack')
        );
        debugPrint('AgoraWeb: Video track created');
      }

      // Join the channel
      await _promiseToFuture(
        _client!.callMethod('join', [_appId, channelName, token, uid])
      );
      debugPrint('AgoraWeb: Joined channel successfully');

      // Publish local tracks
      final tracks = <js.JsObject>[_localAudioTrack!];
      if (_localVideoTrack != null) {
        tracks.add(_localVideoTrack!);
      }

      await _promiseToFuture(
        _client!.callMethod('publish', [js.JsArray.from(tracks)])
      );
      debugPrint('AgoraWeb: Published local tracks');

      // Play local video in a container
      if (_localVideoTrack != null) {
        _playLocalVideo();
        // Show local video container
        final localContainer = html.querySelector('#local-video-container');
        if (localContainer != null) {
          localContainer.style.display = 'block';
        }
      }
    } catch (e) {
      debugPrint('AgoraWeb: Join channel error - $e');
      rethrow;
    }
  }

  /// Subscribe to a remote user's media
  Future<void> _subscribeToUser(js.JsObject user, String mediaType) async {
    try {
      debugPrint('AgoraWeb: Subscribing to user ${user['uid']}, mediaType: $mediaType');
      
      await _promiseToFuture(
        _client!.callMethod('subscribe', [user, mediaType])
      );
      debugPrint('AgoraWeb: Subscribe successful for mediaType: $mediaType');

      if (mediaType == 'video') {
        // Try multiple ways to access the video track
        var remoteVideoTrack = user['videoTrack'];
        
        // If property access fails, try as a getter method
        if (remoteVideoTrack == null) {
          try {
            remoteVideoTrack = js.JsObject.fromBrowserObject(user)['videoTrack'];
          } catch (e) {
            debugPrint('AgoraWeb: Could not access videoTrack via fromBrowserObject: $e');
          }
        }
        
        debugPrint('AgoraWeb: Remote video track type: ${remoteVideoTrack?.runtimeType}');
        debugPrint('AgoraWeb: Remote video track value: $remoteVideoTrack');
        
        if (remoteVideoTrack != null) {
          // Ensure we have a JsObject
          js.JsObject? trackObject;
          if (remoteVideoTrack is js.JsObject) {
            trackObject = remoteVideoTrack;
          } else {
            try {
              trackObject = js.JsObject.fromBrowserObject(remoteVideoTrack);
            } catch (e) {
              debugPrint('AgoraWeb: Could not convert to JsObject: $e');
            }
          }
          
          if (trackObject != null) {
            // Play in remote container
            var container = html.querySelector('#remote-video-container');
            
            // If container doesn't exist, recreate it
            if (container == null) {
              debugPrint('AgoraWeb: Container not found, recreating...');
              _createVideoContainers();
              container = html.querySelector('#remote-video-container');
            }
            
            debugPrint('AgoraWeb: Container element: $container');
            
            if (container != null) {
              try {
                container.style.display = 'block';
                debugPrint('AgoraWeb: Container display set to block');
                
                // Try calling play with the container ID
                trackObject.callMethod('play', ['remote-video-container']);
                debugPrint('AgoraWeb: Playing remote video successfully');
              } catch (e) {
                debugPrint('AgoraWeb: Error calling play on video track: $e');
              }
            } else {
              debugPrint('AgoraWeb: Remote video container not found in DOM!');
              // List all elements to debug
              final allElements = html.document.querySelectorAll('div');
              debugPrint('AgoraWeb: Found ${allElements.length} div elements in DOM');
            }
          } else {
            debugPrint('AgoraWeb: Could not get JsObject for video track');
          }
        } else {
          debugPrint('AgoraWeb: Remote video track is null');
        }
      } else if (mediaType == 'audio') {
        // Get the remote audio track via property access
        final remoteAudioTrack = user['audioTrack'];
        debugPrint('AgoraWeb: Remote audio track: $remoteAudioTrack');
        
        if (remoteAudioTrack != null && remoteAudioTrack is js.JsObject) {
          // Play audio (no container needed for audio)
          try {
            remoteAudioTrack.callMethod('play', []);
            debugPrint('AgoraWeb: Playing remote audio successfully');
          } catch (e) {
            debugPrint('AgoraWeb: Error playing audio: $e');
          }
        } else {
          debugPrint('AgoraWeb: Remote audio track is null or invalid type: ${remoteAudioTrack?.runtimeType}');
        }
      }
    } catch (e, stackTrace) {
      debugPrint('AgoraWeb: Subscribe error - $e');
      debugPrint('AgoraWeb: Stack trace - $stackTrace');
    }
  }

  /// Play local video in PiP container
  void _playLocalVideo() {
    if (_localVideoTrack != null) {
      var container = html.querySelector('#local-video-container');
      
      // If container doesn't exist, recreate it
      if (container == null) {
        debugPrint('AgoraWeb: Local container not found, recreating...');
        _createVideoContainers();
        container = html.querySelector('#local-video-container');
      }
      
      if (container != null) {
        _localVideoTrack!.callMethod('play', ['local-video-container']);
        debugPrint('AgoraWeb: Playing local video');
      }
    }
  }

  /// Leave channel and clean up
  Future<void> leaveChannel() async {
    try {
      debugPrint('AgoraWeb: Leaving channel');

      // Stop and close local tracks
      if (_localAudioTrack != null) {
        _localAudioTrack!.callMethod('stop');
        _localAudioTrack!.callMethod('close');
      }
      if (_localVideoTrack != null) {
        _localVideoTrack!.callMethod('stop');
        _localVideoTrack!.callMethod('close');
      }

      // Leave channel
      if (_client != null) {
        await _promiseToFuture(_client!.callMethod('leave'));
      }

      // Hide video containers
      final remoteContainer = html.querySelector('#remote-video-container');
      if (remoteContainer != null) {
        remoteContainer.style.display = 'none';
      }
      final localContainer = html.querySelector('#local-video-container');
      if (localContainer != null) {
        localContainer.style.display = 'none';
      }

      debugPrint('AgoraWeb: Left channel successfully');
    } catch (e) {
      debugPrint('AgoraWeb: Leave channel error - $e');
    }
  }

  /// Toggle local audio mute state
  Future<void> muteLocalAudio(bool mute) async {
    if (_localAudioTrack != null) {
      await _promiseToFuture(
        _localAudioTrack!.callMethod('setEnabled', [!mute])
      );
      debugPrint('AgoraWeb: Local audio ${mute ? 'muted' : 'unmuted'}');
    }
  }

  /// Toggle local video enable state
  Future<void> enableLocalVideo(bool enable) async {
    if (_localVideoTrack != null) {
      await _promiseToFuture(
        _localVideoTrack!.callMethod('setEnabled', [enable])
      );
      debugPrint('AgoraWeb: Local video ${enable ? 'enabled' : 'disabled'}');
    }
  }

  /// Convert JavaScript Promise to Dart Future
  Future<T> _promiseToFuture<T>(js.JsObject promise) {
    final completer = Completer<T>();
    promise.callMethod('then', [
      js.allowInterop((result) {
        if (!completer.isCompleted) {
          completer.complete(result as T);
        }
      })
    ]);
    promise.callMethod('catch', [
      js.allowInterop((error) {
        if (!completer.isCompleted) {
          final errorMsg = error != null ? error.toString() : 'Unknown error';
          debugPrint('AgoraWeb: Promise error - $errorMsg');
          completer.completeError(errorMsg);
        }
      })
    ]);
    return completer.future;
  }

  void dispose() {
    _userJoinedController.close();
    _userLeftController.close();
  }
}
