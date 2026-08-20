import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' as fb_auth;
import 'package:permission_handler/permission_handler.dart';
import 'package:livekit_client/livekit_client.dart';
import 'livekit_config.dart';
import 'livekit_token_service.dart';

class LiveKitInlineLiveWidget extends StatefulWidget {
  final String postId;
  final String channelName;
  final bool isHost;
  final String hostUserId;
  final Map<String, dynamic>? hostUserData;
  final VoidCallback? onLiveEnded;

  const LiveKitInlineLiveWidget({
    super.key,
    required this.postId,
    required this.channelName,
    required this.isHost,
    required this.hostUserId,
    this.hostUserData,
    this.onLiveEnded,
  });

  @override
  State<LiveKitInlineLiveWidget> createState() => _LiveKitInlineLiveWidgetState();
}

class _LiveKitInlineLiveWidgetState extends State<LiveKitInlineLiveWidget>
    with SingleTickerProviderStateMixin, AutomaticKeepAliveClientMixin {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  @override
  bool get wantKeepAlive => true;

  Room? _room;
  EventsListener<RoomEvent>? _listener;
  VideoTrack? _remoteVideoTrack;
  VideoTrack? _localVideoTrack;

  bool _connected = false;
  bool _isLoading = true;
  bool _isEnded = false;
  bool _muted = false;
  bool _cameraMuted = false;

  // 5-Minute Host Timer
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
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    )..repeat(reverse: true);
    _pulseAnimation = Tween<double>(begin: 0.8, end: 1.2).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    _listenToPostStatus();
    _initLiveKit();
  }

  void _listenToPostStatus() {
    _postSub = _firestore.collection('posts').doc(widget.postId).snapshots().listen((snap) {
      if (!snap.exists) return;
      final data = snap.data();
      if (data == null) return;
      final liveStatus = data['live_status'] as String?;
      final isLive = (data['is_live'] ?? false) as bool;
      if (liveStatus == 'ended' || !isLive) {
        if (mounted) {
          setState(() => _isEnded = true);
          _cleanupLiveKit();
          widget.onLiveEnded?.call();
        }
      }
    });
  }

  Future<void> _initLiveKit() async {
    if (widget.isHost) {
      try {
        final micStatus = await Permission.microphone.request();
        final camStatus = await Permission.camera.request();
        if (!micStatus.isGranted || !camStatus.isGranted) {
          debugPrint('LiveKit: Permissions not granted');
        }
      } catch (e) {
        debugPrint('LiveKit: Permission request error: $e');
      }

      // Start Host 5-minute countdown
      _countdownTimer = Timer.periodic(const Duration(seconds: 1), (t) {
        if (!mounted) {
          t.cancel();
          return;
        }
        setState(() {
          _elapsedSeconds++;
          _remainingSeconds = max(0, _maxLiveDurationSeconds - _elapsedSeconds);
        });
        if (_remainingSeconds <= 0) {
          t.cancel();
          _endStream();
        }
      });
    }

    try {
      final currentUserId = fb_auth.FirebaseAuth.instance.currentUser?.uid ?? 'anon_${Random().nextInt(10000)}';
      final currentUserName = fb_auth.FirebaseAuth.instance.currentUser?.displayName ?? 'User';

      final token = await LiveKitTokenService.fetchLiveKitToken(
        roomName: widget.channelName,
        identity: widget.isHost ? widget.hostUserId : currentUserId,
        isPublisher: widget.isHost,
        userName: currentUserName,
      );

      if (token == null) {
        debugPrint('LiveKit: Failed to obtain token');
        if (mounted) setState(() => _isLoading = false);
        return;
      }

      _room = Room();
      _listener = _room!.createListener();

      _listener!
        ..on<RoomConnectedEvent>((e) {
          debugPrint('LiveKit: Room connected to ${widget.channelName}');
          if (mounted) {
            setState(() {
              _connected = true;
              _isLoading = false;
            });
          }
        })
        ..on<TrackSubscribedEvent>((e) {
          debugPrint('LiveKit: Track subscribed ${e.track.kind}');
          if (e.track is VideoTrack) {
            if (mounted) {
              setState(() {
                _remoteVideoTrack = e.track as VideoTrack;
              });
            }
          }
        })
        ..on<TrackUnsubscribedEvent>((e) {
          if (e.track is VideoTrack && e.track == _remoteVideoTrack) {
            if (mounted) {
              setState(() {
                _remoteVideoTrack = null;
              });
            }
          }
        })
        ..on<LocalTrackPublishedEvent>((e) {
          debugPrint('LiveKit: Local track published ${e.publication.kind}');
          if (e.publication.track is VideoTrack) {
            if (mounted) {
              setState(() {
                _localVideoTrack = e.publication.track as VideoTrack;
              });
            }
          }
        })
        ..on<LocalTrackUnpublishedEvent>((e) {
          if (e.publication.track == _localVideoTrack) {
            if (mounted) {
              setState(() => _localVideoTrack = null);
            }
          }
        })
        ..on<RoomDisconnectedEvent>((e) {
          debugPrint('LiveKit: Room disconnected');
          if (mounted) {
            setState(() => _connected = false);
          }
        });

      await _room!.connect(
        LiveKitConfig.liveKitWsUrl,
        token,
        roomOptions: const RoomOptions(
          adaptiveStream: true,
          dynacast: true,
          defaultCameraCaptureOptions: CameraCaptureOptions(
            maxFrameRate: 30,
            params: VideoParametersPresets.h720_169,
            cameraPosition: CameraPosition.front,
          ),
        ),
      );

      if (widget.isHost) {
        // Publish host camera and microphone
        final camPub = await _room!.localParticipant?.setCameraEnabled(true);
        await _room!.localParticipant?.setMicrophoneEnabled(true);

        final rawTrack = camPub?.track ?? _room!.localParticipant?.videoTrackPublications.firstOrNull?.track;
        if (rawTrack is VideoTrack && mounted) {
          setState(() {
            _localVideoTrack = rawTrack as VideoTrack;
          });
        }
      } else {
        // Find existing remote video track if host is already streaming
        for (final p in _room!.remoteParticipants.values) {
          for (final pub in p.videoTrackPublications) {
            if (pub.track is VideoTrack) {
              if (mounted) {
                setState(() {
                  _remoteVideoTrack = pub.track as VideoTrack;
                });
              }
              break;
            }
          }
        }
      }

      if (mounted) {
        setState(() {
          _connected = true;
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('LiveKit initialization error: $e');
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _endStream() async {
    _countdownTimer?.cancel();
    try {
      await _firestore.collection('posts').doc(widget.postId).update({
        'is_live': false,
        'live_status': 'ended',
        'ended_at': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      debugPrint('Error marking stream ended: $e');
    }
    await _cleanupLiveKit();
    if (mounted) {
      setState(() => _isEnded = true);
      widget.onLiveEnded?.call();
    }
  }

  Future<void> _cleanupLiveKit() async {
    try {
      _listener?.dispose();
      await _room?.disconnect();
      await _room?.dispose();
    } catch (_) {}
    _room = null;
    _listener = null;
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _countdownTimer?.cancel();
    _postSub?.cancel();
    _cleanupLiveKit();
    super.dispose();
  }

  String _formatTimer(int totalSecs) {
    final m = (totalSecs ~/ 60).toString().padLeft(2, '0');
    final s = (totalSecs % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    if (_isEnded) {
      return Container(
        height: 220,
        decoration: BoxDecoration(
          color: const Color(0xFF141414),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white12),
        ),
        child: const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.videocam_off, color: Colors.white38, size: 48),
              SizedBox(height: 8),
              Text(
                'Live Stream Ended',
                style: TextStyle(color: Colors.white70, fontWeight: FontWeight.bold, fontSize: 16),
              ),
            ],
          ),
        ),
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Container(
        height: 250,
        width: double.infinity,
        color: Colors.black,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Video Surface
            if (widget.isHost && _localVideoTrack != null)
              VideoTrackRenderer(_localVideoTrack!)
            else if (!widget.isHost && _remoteVideoTrack != null)
              VideoTrackRenderer(_remoteVideoTrack!)
            else
              Container(
                color: const Color(0xFF0F172A),
                child: Center(
                  child: _isLoading
                      ? const Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            CircularProgressIndicator(color: Colors.redAccent),
                            SizedBox(height: 12),
                            Text(
                              'Connecting to Live Stream...',
                              style: TextStyle(color: Colors.white70, fontSize: 13),
                            ),
                          ],
                        )
                      : const Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.sensors, color: Colors.white38, size: 48),
                            SizedBox(height: 8),
                            Text(
                              'Waiting for broadcaster video...',
                              style: TextStyle(color: Colors.white70, fontSize: 14),
                            ),
                          ],
                        ),
                ),
              ),

            // Top Badges (LIVE tag & timer)
            Positioned(
              top: 12,
              left: 12,
              right: 12,
              child: Row(
                children: [
                  // LIVE Badge
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.red.withOpacity(0.9),
                      borderRadius: BorderRadius.circular(6),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.red.withOpacity(0.4),
                          blurRadius: 8,
                          spreadRadius: 2,
                        ),
                      ],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ScaleTransition(
                          scale: _pulseAnimation,
                          child: Container(
                            width: 8,
                            height: 8,
                            decoration: const BoxDecoration(
                              color: Colors.white,
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        const Text(
                          'LIVE',
                          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),

                  // Host Timer Countdown
                  if (widget.isHost)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: _remainingSeconds <= 30
                            ? Colors.red.withOpacity(0.85)
                            : Colors.black.withOpacity(0.65),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.timer_outlined, size: 14, color: Colors.white),
                          const SizedBox(width: 4),
                          Text(
                            _formatTimer(_remainingSeconds),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),

                  const Spacer(),

                  // End Stream Button for Host
                  if (widget.isHost)
                    GestureDetector(
                      onTap: _endStream,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(
                          color: Colors.redAccent,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.stop, size: 14, color: Colors.white),
                            SizedBox(width: 4),
                            Text(
                              'End Live',
                              style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),

            // Bottom Host Controls
            if (widget.isHost && _connected)
              Positioned(
                bottom: 12,
                right: 12,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Mic toggle
                    IconButton(
                      icon: Icon(_muted ? Icons.mic_off : Icons.mic, color: Colors.white),
                      style: IconButton.styleFrom(
                        backgroundColor: Colors.black54,
                        padding: const EdgeInsets.all(8),
                      ),
                      onPressed: () async {
                        final newState = !_muted;
                        await _room?.localParticipant?.setMicrophoneEnabled(!newState);
                        if (mounted) setState(() => _muted = newState);
                      },
                    ),
                    const SizedBox(width: 6),
                    // Camera toggle
                    IconButton(
                      icon: Icon(_cameraMuted ? Icons.videocam_off : Icons.videocam, color: Colors.white),
                      style: IconButton.styleFrom(
                        backgroundColor: Colors.black54,
                        padding: const EdgeInsets.all(8),
                      ),
                      onPressed: () async {
                        final newState = !_cameraMuted;
                        await _room?.localParticipant?.setCameraEnabled(!newState);
                        if (mounted) setState(() => _cameraMuted = newState);
                      },
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
