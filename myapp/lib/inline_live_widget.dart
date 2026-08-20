import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'agora_config.dart';
import 'agora_token_service.dart';
import 'agora_web_live_player.dart' if (dart.library.io) 'agora_web_live_player_stub.dart';

class InlineLiveWidget extends StatefulWidget {
  final String postId;
  final String channelName;
  final bool isHost;
  final String hostUserId;
  final Map<String, dynamic>? hostUserData;
  final VoidCallback? onLiveEnded;

  const InlineLiveWidget({
    super.key,
    required this.postId,
    required this.channelName,
    required this.isHost,
    required this.hostUserId,
    this.hostUserData,
    this.onLiveEnded,
  });

  @override
  State<InlineLiveWidget> createState() => _InlineLiveWidgetState();
}

class _InlineLiveWidgetState extends State<InlineLiveWidget> with SingleTickerProviderStateMixin, AutomaticKeepAliveClientMixin {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  @override
  bool get wantKeepAlive => true;

  RtcEngine? _engine;
  String? _token;
  int _localUid = 0;
  int? _remoteHostUid;
  final Set<int> _remoteUids = {};
  bool _joined = false;
  bool _engineInitialized = false;
  bool _isEnded = false;

  // 5-Minute Timer for Host
  static const int _maxLiveDurationSeconds = 300;
  int _remainingSeconds = _maxLiveDurationSeconds;
  int _elapsedSeconds = 0;
  Timer? _countdownTimer;

  StreamSubscription<DocumentSnapshot>? _postSub;

  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();
    _localUid = Random().nextInt(0x7FFFFFFF);

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    )..repeat(reverse: true);
    _pulseAnimation = Tween<double>(begin: 0.8, end: 1.2).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    _initLive();
    _listenToPost();
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _postSub?.cancel();
    _pulseController.dispose();
    _cleanupAgora();
    super.dispose();
  }

  Future<void> _cleanupAgora() async {
    try {
      if (_engine != null && _engineInitialized) {
        await _engine!.leaveChannel();
        await _engine!.release();
        _engine = null;
      }
    } catch (_) {}
  }

  Future<void> _initLive() async {
    if (widget.isHost) {
      _countdownTimer = Timer.periodic(const Duration(seconds: 1), (t) {
        if (!mounted) return;
        setState(() {
          _elapsedSeconds++;
          _remainingSeconds = max(0, _maxLiveDurationSeconds - _elapsedSeconds);
        });
        if (_remainingSeconds <= 0) {
          t.cancel();
          _onTimeExpired();
        }
      });
    }

    if (!kIsWeb) {
      await _initAgora();
    }
  }

  Future<void> _initAgora() async {
    if (widget.isHost) {
      try {
        final micStatus = await Permission.microphone.request();
        final camStatus = await Permission.camera.request();
        if (!micStatus.isGranted || !camStatus.isGranted) {
          debugPrint('Microphone or Camera permission denied for host');
        }
      } catch (_) {}
    }

    try {
      _engine = createAgoraRtcEngine();
      await _engine!.initialize(RtcEngineContext(
        appId: AgoraConfig.appId,
        channelProfile: ChannelProfileType.channelProfileCommunication,
      ));

      _engine!.registerEventHandler(
        RtcEngineEventHandler(
          onJoinChannelSuccess: (RtcConnection conn, int elapsed) {
            debugPrint('LiveStream: Joined channel ${conn.channelId} uid ${conn.localUid}');
            if (mounted) setState(() => _joined = true);

            if (widget.isHost) {
              // Host: Mute local playback audio so host doesn't hear own voice echo
              try { _engine?.adjustPlaybackSignalVolume(0); } catch (_) {}
            } else {
              // Viewers: Ensure speaker audio is turned on to hear the host
              try { _engine?.setDefaultAudioRouteToSpeakerphone(true); } catch (_) {}
              try { _engine?.setEnableSpeakerphone(true); } catch (_) {}
              try { _engine?.adjustPlaybackSignalVolume(100); } catch (_) {}
            }
          },
          onUserJoined: (RtcConnection conn, int remoteUid, int elapsed) {
            debugPrint('LiveStream: Remote user joined uid $remoteUid');
            if (mounted) {
              setState(() {
                _remoteUids.add(remoteUid);
                if (!widget.isHost) {
                  _remoteHostUid ??= remoteUid;
                }
              });
            }
            if (!widget.isHost) {
              try {
                _engine?.muteRemoteAudioStream(uid: remoteUid, mute: false);
                _engine?.muteRemoteVideoStream(uid: remoteUid, mute: false);
                _engine?.adjustUserPlaybackSignalVolume(uid: remoteUid, volume: 100);
              } catch (_) {}
            }
          },
          onUserOffline: (RtcConnection conn, int remoteUid, UserOfflineReasonType reason) {
            debugPrint('LiveStream: Remote user offline uid $remoteUid');
            if (mounted) {
              setState(() {
                _remoteUids.remove(remoteUid);
                if (_remoteHostUid == remoteUid) {
                  _remoteHostUid = _remoteUids.isNotEmpty ? _remoteUids.first : null;
                }
              });
            }
          },
        ),
      );

      if (widget.isHost) {
        // --- HOST (BROADCASTER) ---
        await _engine!.enableAudio();
        await _engine!.enableVideo();
        await _engine!.enableLocalVideo(true);
        await _engine!.enableLocalAudio(true);
        await _engine!.muteLocalVideoStream(false);
        await _engine!.muteLocalAudioStream(false);
        try { await _engine!.startPreview(); } catch (_) {}
      } else {
        // --- VIEWERS (AUDIENCE ONLY) ---
        // Viewers NEVER access local camera or local mic
        await _engine!.enableAudio();
        await _engine!.enableVideo();
        try { await _engine!.enableLocalVideo(false); } catch (_) {}
        try { await _engine!.enableLocalAudio(false); } catch (_) {}
        try { await _engine!.muteLocalVideoStream(true); } catch (_) {}
        try { await _engine!.muteLocalAudioStream(true); } catch (_) {}
      }

      _engineInitialized = true;
      if (mounted) setState(() {});

      try {
        _token = await AgoraTokenService.fetchRtcToken(
          channelName: widget.channelName,
          uid: _localUid,
          role: widget.isHost ? 'publisher' : 'subscriber',
        );
      } catch (e) {
        _token = '';
      }

      try {
        await _engine!.leaveChannel();
      } catch (_) {}

      try {
        await _engine!.joinChannel(
          token: _token ?? '',
          channelId: widget.channelName,
          uid: _localUid,
          options: ChannelMediaOptions(
            publishCameraTrack: widget.isHost,
            publishMicrophoneTrack: widget.isHost,
            autoSubscribeAudio: !widget.isHost,
            autoSubscribeVideo: !widget.isHost,
            clientRoleType: widget.isHost ? ClientRoleType.clientRoleBroadcaster : ClientRoleType.clientRoleAudience,
          ),
        );
      } catch (e) {
        debugPrint('First joinChannel error: $e');
        await Future.delayed(const Duration(milliseconds: 300));
        try {
          await _engine?.leaveChannel();
          await _engine?.joinChannel(
            token: _token ?? '',
            channelId: widget.channelName,
            uid: _localUid,
            options: ChannelMediaOptions(
              publishCameraTrack: widget.isHost,
              publishMicrophoneTrack: widget.isHost,
              autoSubscribeAudio: !widget.isHost,
              autoSubscribeVideo: !widget.isHost,
              clientRoleType: widget.isHost ? ClientRoleType.clientRoleBroadcaster : ClientRoleType.clientRoleAudience,
            ),
          );
        } catch (_) {}
      }

      if (mounted) setState(() {});
    } catch (e) {
      debugPrint('LiveStream Agora init error: $e');
    }
  }

  void _listenToPost() {
    _postSub = _firestore.collection('posts').doc(widget.postId).snapshots().listen((doc) {
      if (!mounted || !doc.exists) return;
      final data = doc.data() as Map<String, dynamic>?;
      if (data != null) {
        final isLive = (data['is_live'] ?? false) as bool;
        final liveStatus = (data['live_status'] ?? '') as String;
        if (!isLive || liveStatus == 'ended') {
          setState(() => _isEnded = true);
          widget.onLiveEnded?.call();
        }
      }
    }, onError: (_) {});
  }

  Future<void> _endLiveInFirestore() async {
    _isEnded = true;
    try {
      await _firestore.collection('posts').doc(widget.postId).update({
        'is_live': false,
        'live_status': 'ended',
        'ended_at': DateTime.now().millisecondsSinceEpoch,
        'duration_seconds': _elapsedSeconds,
      });
    } catch (_) {}
  }

  Future<void> _flipCamera() async {
    if (_engine == null) return;
    await _engine!.switchCamera();
  }

  Future<void> _confirmEndLive() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('End Live Broadcast?'),
        content: const Text('Are you sure you want to end your live broadcast?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('End Live', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );

    if (confirm == true && mounted) {
      await _endLiveInFirestore();
      await _cleanupAgora();
      setState(() => _isEnded = true);
      widget.onLiveEnded?.call();
    }
  }

  void _onTimeExpired() async {
    await _endLiveInFirestore();
    await _cleanupAgora();
    if (mounted) {
      setState(() => _isEnded = true);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('5-Minute Live limit reached. Broadcast ended.')),
      );
      widget.onLiveEnded?.call();
    }
  }

  String _formatDuration(int sec) {
    final m = sec ~/ 60;
    final s = sec % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    if (_isEnded) {
      return Container(
        height: 100,
        margin: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: Colors.grey[900],
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white24),
        ),
        child: Center(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.videocam_off_rounded, color: Colors.white60, size: 28),
              const SizedBox(width: 10),
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Live Broadcast Ended',
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                  ),
                  if (_elapsedSeconds > 0)
                    Text(
                      'Duration: ${_formatDuration(_elapsedSeconds)}',
                      style: const TextStyle(color: Colors.white60, fontSize: 11),
                    ),
                ],
              ),
            ],
          ),
        ),
      );
    }

    final viewerCount = max(1, _remoteUids.length + (widget.isHost ? 1 : 0));

    // Standard posting box size on timeline (same height as photo/video posts)
    return Container(
      height: 220,
      margin: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.redAccent.withOpacity(0.5), width: 1.5),
        boxShadow: [
          BoxShadow(
            color: Colors.redAccent.withOpacity(0.15),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(11),
        child: Stack(
          children: [
            // 1. The Video Surface
            Positioned.fill(
              child: _buildVideoContent(),
            ),

            // 2. Top Header Overlays (LIVE badge, timer, viewer count)
            Positioned(
              top: 8,
              left: 8,
              right: 8,
              child: Row(
                children: [
                  // LIVE Pill
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3.5),
                    decoration: BoxDecoration(
                      color: Colors.redAccent,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ScaleTransition(
                          scale: _pulseAnimation,
                          child: Container(
                            width: 6,
                            height: 6,
                            decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                          ),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          widget.isHost ? 'LIVE • ${_formatDuration(_remainingSeconds)}' : 'LIVE',
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 10.5),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(width: 6),

                  // Viewer counter
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3.5),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Colors.white24),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.remove_red_eye_rounded, color: Colors.white70, size: 11),
                        const SizedBox(width: 3),
                        Text('$viewerCount', style: const TextStyle(color: Colors.white, fontSize: 10.5, fontWeight: FontWeight.w600)),
                      ],
                    ),
                  ),

                  const Spacer(),

                  if (widget.isHost) ...[
                    // Flip Camera Button (Host only)
                    GestureDetector(
                      onTap: _flipCamera,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.black87,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: Colors.white54, width: 1),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.flip_camera_ios_rounded, color: Colors.white, size: 13),
                            SizedBox(width: 4),
                            Text(
                              'Flip',
                              style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 10.5),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    // End Live Button (Host only)
                    GestureDetector(
                      onTap: _confirmEndLive,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.redAccent,
                          borderRadius: BorderRadius.circular(14),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.redAccent.withOpacity(0.5),
                              blurRadius: 4,
                            ),
                          ],
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.call_end_rounded, color: Colors.white, size: 13),
                            SizedBox(width: 3),
                            Text(
                              'End',
                              style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 10.5),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildVideoContent() {
    if (kIsWeb) {
      return buildWebLivePlayer(
        postId: widget.postId,
        channelName: widget.channelName,
        isHost: widget.isHost,
        localUid: _localUid,
      );
    }

    if (_engine == null || !_engineInitialized) {
      return Container(
        color: Colors.black87,
        child: const Center(child: CircularProgressIndicator(color: Colors.redAccent, strokeWidth: 2)),
      );
    }

    if (widget.isHost) {
      // Broadcaster sees own camera inside this post box
      return AgoraVideoView(
        controller: VideoViewController(
          rtcEngine: _engine!,
          canvas: const VideoCanvas(
            uid: 0,
            renderMode: RenderModeType.renderModeHidden,
          ),
        ),
      );
    } else {
      // Viewers see the host remote camera inside this post box
      final hostUid = _remoteHostUid ?? (_remoteUids.isNotEmpty ? _remoteUids.first : null);
      if (hostUid != null) {
        return AgoraVideoView(
          controller: VideoViewController.remote(
            rtcEngine: _engine!,
            canvas: VideoCanvas(
              uid: hostUid,
              renderMode: RenderModeType.renderModeHidden,
            ),
            connection: RtcConnection(channelId: widget.channelName),
          ),
        );
      }

      return Container(
        color: const Color(0xFF0F1117),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ScaleTransition(
                scale: _pulseAnimation,
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.redAccent.withOpacity(0.2),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.live_tv_rounded, color: Colors.redAccent, size: 32),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Connecting to ${widget.hostUserData?['name'] ?? 'Host'}\'s Live...',
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ],
          ),
        ),
      );
    }
  }
}
