import 'dart:async';
import 'dart:html' as html;
import 'dart:js' as js;
import 'dart:ui_web' as ui_web;
import 'package:flutter/material.dart';
import 'agora_config.dart';
import 'agora_token_service.dart';

Widget buildWebLivePlayer({
  required String postId,
  required String channelName,
  required bool isHost,
  required int localUid,
}) {
  return AgoraWebLiveWidget(
    postId: postId,
    channelName: channelName,
    isHost: isHost,
    localUid: localUid,
  );
}

class AgoraWebLiveWidget extends StatefulWidget {
  final String postId;
  final String channelName;
  final bool isHost;
  final int localUid;

  const AgoraWebLiveWidget({
    super.key,
    required this.postId,
    required this.channelName,
    required this.isHost,
    required this.localUid,
  });

  @override
  State<AgoraWebLiveWidget> createState() => _AgoraWebLiveWidgetState();
}

class _AgoraWebLiveWidgetState extends State<AgoraWebLiveWidget> {
  late final String _viewType;
  js.JsObject? _client;
  js.JsObject? _localAudioTrack;
  js.JsObject? _localVideoTrack;
  bool _connected = false;
  bool _hasVideo = false;

  @override
  void initState() {
    super.initState();
    _viewType = 'agora-live-${widget.postId}';

    // Register HtmlElementView for this post
    ui_web.platformViewRegistry.registerViewFactory(_viewType, (int viewId) {
      final div = html.DivElement()
        ..id = _viewType
        ..style.width = '100%'
        ..style.height = '100%'
        ..style.backgroundColor = 'black'
        ..style.overflow = 'hidden';
      return div;
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _startWebStream();
    });
  }

  @override
  void dispose() {
    _cleanup();
    super.dispose();
  }

  Future<void> _cleanup() async {
    try {
      if (_localAudioTrack != null) {
        _localAudioTrack!.callMethod('close', []);
      }
      if (_localVideoTrack != null) {
        _localVideoTrack!.callMethod('close', []);
      }
      if (_client != null) {
        await _client!.callMethod('leave', []);
      }
    } catch (_) {}
  }

  Future<void> _startWebStream() async {
    try {
      final AgoraRTC = js.context['AgoraRTC'];
      if (AgoraRTC == null) return;

      _client = AgoraRTC.callMethod('createClient', [
        js.JsObject.jsify({'mode': 'rtc', 'codec': 'vp8'})
      ]);

      // Set up remote listeners (for audience & host)
      _client!.callMethod('on', [
        'user-published',
        js.allowInterop((user, mediaType) async {
          try {
            await js.context['Promise'].callMethod('resolve', [
              _client!.callMethod('subscribe', [user, mediaType])
            ]);

            if (mediaType == 'video') {
              if (mounted) setState(() => _hasVideo = true);
              final videoTrack = user['videoTrack'];
              if (videoTrack != null) {
                // Wait small tick for DOM to be ready
                Future.delayed(const Duration(milliseconds: 150), () {
                  try {
                    videoTrack.callMethod('play', [_viewType]);
                  } catch (_) {}
                });
              }
            }
            if (mediaType == 'audio' && !widget.isHost) {
              final audioTrack = user['audioTrack'];
              if (audioTrack != null) {
                try {
                  audioTrack.callMethod('play', []);
                } catch (_) {}
              }
            }
          } catch (e) {
            debugPrint('Web Live user-published error: $e');
          }
        })
      ]);

      String token = '';
      try {
        token = await AgoraTokenService.fetchRtcToken(
          channelName: widget.channelName,
          uid: widget.localUid,
          role: widget.isHost ? 'publisher' : 'subscriber',
        );
      } catch (_) {}

      // Join channel
      await js.context['Promise'].callMethod('resolve', [
        _client!.callMethod('join', [
          AgoraConfig.appId,
          widget.channelName,
          token.isNotEmpty ? token : null,
          widget.localUid,
        ])
      ]);

      if (mounted) setState(() => _connected = true);

      if (widget.isHost) {
        // Broadcaster creates mic and camera tracks
        final tracksPromise = AgoraRTC.callMethod('createMicrophoneAndCameraTracks', []);
        final tracks = await js.context['Promise'].callMethod('resolve', [tracksPromise]);

        _localAudioTrack = tracks[0] as js.JsObject;
        _localVideoTrack = tracks[1] as js.JsObject;

        // Play local camera inside the post box (video only, no audio echo)
        Future.delayed(const Duration(milliseconds: 150), () {
          try {
            _localVideoTrack!.callMethod('play', [_viewType]);
          } catch (_) {}
        });

        // Publish to channel
        await js.context['Promise'].callMethod('resolve', [
          _client!.callMethod('publish', [
            js.JsArray.from([_localAudioTrack, _localVideoTrack])
          ])
        ]);

        if (mounted) setState(() => _hasVideo = true);
      }
      // If viewer: No local tracks created! Camera & mic remain 100% OFF.
    } catch (e) {
      debugPrint('Web Live Stream error: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        HtmlElementView(viewType: _viewType),
        if (!_hasVideo)
          Container(
            color: const Color(0xFF0F1117),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.live_tv_rounded, color: Colors.redAccent, size: 30),
                  const SizedBox(height: 8),
                  Text(
                    widget.isHost ? 'Starting Camera...' : 'Connecting to Live...',
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
