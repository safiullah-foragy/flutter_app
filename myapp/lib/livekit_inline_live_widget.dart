import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' as fb_auth;
import 'package:permission_handler/permission_handler.dart';
import 'package:livekit_client/livekit_client.dart';
import 'livekit_config.dart';
import 'livekit_token_service.dart';

/// Singleton manager for host rooms to prevent multiple widgets (e.g. Newsfeed + Profile in IndexedStack)
/// from creating duplicate conflicting connections with the same host identity.
class _HostRoomSession {
  final String roomName;
  final String hostUserId;
  Room? room;
  EventsListener<RoomEvent>? listener;
  VideoTrack? localVideoTrack;
  bool isConnected = false;
  bool isPublishing = false;
  bool muted = false;
  bool cameraMuted = false;
  int refCount = 0;
  final Set<void Function()> _listeners = {};

  _HostRoomSession({required this.roomName, required this.hostUserId});

  void addListener(void Function() listener) => _listeners.add(listener);
  void removeListener(void Function() listener) => _listeners.remove(listener);

  void notify() {
    for (final l in _listeners.toList()) {
      l();
    }
  }

  Future<void> endAndDispose() async {
    try {
      try {
        await room?.localParticipant?.setCameraEnabled(false);
        await room?.localParticipant?.setMicrophoneEnabled(false);
      } catch (_) {}
      listener?.dispose();
      await room?.disconnect();
      await room?.dispose();
    } catch (e) {
      debugPrint('Error disposing host session: $e');
    }
    room = null;
    listener = null;
    localVideoTrack = null;
    isConnected = false;
    isPublishing = false;
    notify();
  }
}

class _LiveKitHostSessionPool {
  static final Map<String, _HostRoomSession> _sessions = {};

  static _HostRoomSession getOrCreate(String roomName, String hostUserId) {
    if (!_sessions.containsKey(roomName)) {
      _sessions[roomName] = _HostRoomSession(roomName: roomName, hostUserId: hostUserId);
    }
    final session = _sessions[roomName]!;
    session.refCount++;
    return session;
  }

  static void release(String roomName) {
    final session = _sessions[roomName];
    if (session != null) {
      session.refCount--;
      if (session.refCount <= 0) {
        session.endAndDispose();
        _sessions.remove(roomName);
      }
    }
  }

  static Future<void> endSession(String roomName) async {
    final session = _sessions.remove(roomName);
    if (session != null) {
      await session.endAndDispose();
    }
  }
}

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

  // Host session reference if host
  _HostRoomSession? _hostSession;

  // Viewer session references if viewer
  Room? _viewerRoom;
  EventsListener<RoomEvent>? _viewerListener;
  VideoTrack? _remoteVideoTrack;

  bool _connected = false;
  bool _isLoading = true;
  bool _isEnded = false;
  bool _isEnding = false;
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

  bool get _isActualHost {
    final curUid = fb_auth.FirebaseAuth.instance.currentUser?.uid;
    return widget.isHost && curUid != null && curUid == widget.hostUserId;
  }

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
    }, onError: (e) {
      debugPrint('LiveKit post status listener notice: $e');
    });
  }

  Future<void> _initLiveKit() async {
    if (_isActualHost) {
      await _initHostLiveKit();
    } else {
      await _initViewerLiveKit();
    }
  }

  Future<void> _initHostLiveKit() async {
    try {
      try {
        final micStatus = await Permission.microphone.request();
        final camStatus = await Permission.camera.request();
        if (!micStatus.isGranted || !camStatus.isGranted) {
          debugPrint('LiveKit: Camera/Mic permissions not granted');
        }
      } catch (e) {
        debugPrint('LiveKit: Permission request error: $e');
      }

      // Start Host 5-minute countdown
      _countdownTimer?.cancel();
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

      _hostSession = _LiveKitHostSessionPool.getOrCreate(widget.channelName, widget.hostUserId);
      _hostSession!.addListener(_onHostSessionUpdated);

      if (_hostSession!.isConnected && _hostSession!.localVideoTrack != null) {
        if (mounted) {
          setState(() {
            _connected = true;
            _isLoading = false;
            _muted = _hostSession!.muted;
            _cameraMuted = _hostSession!.cameraMuted;
          });
        }
        return;
      }

      if (_hostSession!.room == null) {
        final currentUserName = fb_auth.FirebaseAuth.instance.currentUser?.displayName ?? 'Host';
        final token = await LiveKitTokenService.fetchLiveKitToken(
          roomName: widget.channelName,
          identity: widget.hostUserId,
          isPublisher: true,
          userName: currentUserName,
        );

        if (token == null) {
          debugPrint('LiveKit: Failed to obtain host token');
          if (mounted) setState(() => _isLoading = false);
          return;
        }

        // 1. Create camera track early so preview appears immediately on Android & Web
        try {
          final videoTrack = await LocalVideoTrack.createCameraTrack(
            const CameraCaptureOptions(
              cameraPosition: CameraPosition.front,
              params: VideoParametersPresets.h540_169,
            ),
          );
          _hostSession!.localVideoTrack = videoTrack;
          _hostSession!.notify();
          if (mounted) setState(() => _isLoading = false);
        } catch (e) {
          debugPrint('LiveKit Host: Error creating local camera track early: $e');
        }

        final room = Room(
          roomOptions: const RoomOptions(
            adaptiveStream: false,
            dynacast: false,
          ),
        );
        final listener = room.createListener();
        _hostSession!.room = room;
        _hostSession!.listener = listener;

        listener
          ..on<RoomConnectedEvent>((e) {
            debugPrint('LiveKit Host: Room connected to ${widget.channelName}');
            _hostSession!.isConnected = true;
            _hostSession!.notify();
          })
          ..on<LocalTrackPublishedEvent>((e) {
            debugPrint('LiveKit Host: Local track published ${e.publication.kind}');
            if (e.publication.track is VideoTrack) {
              _hostSession!.localVideoTrack = e.publication.track as VideoTrack;
              _hostSession!.notify();
            }
          })
          ..on<LocalTrackUnpublishedEvent>((e) {
            if (e.publication.track?.sid == _hostSession!.localVideoTrack?.sid) {
              _hostSession!.localVideoTrack = null;
              _hostSession!.notify();
            }
          })
          ..on<RoomDisconnectedEvent>((e) {
            debugPrint('LiveKit Host: Room disconnected');
            _hostSession!.isConnected = false;
            _hostSession!.notify();
          });

        await room.connect(
          LiveKitConfig.liveKitWsUrl,
          token,
        );

        // 2. Publish camera & microphone
        try {
          if (_hostSession!.localVideoTrack is LocalVideoTrack) {
            await room.localParticipant?.publishVideoTrack(_hostSession!.localVideoTrack as LocalVideoTrack);
          } else {
            final camPub = await room.localParticipant?.setCameraEnabled(true);
            final rawTrack = camPub?.track ?? room.localParticipant?.videoTrackPublications.firstOrNull?.track;
            if (rawTrack is VideoTrack) {
              _hostSession!.localVideoTrack = rawTrack as VideoTrack;
            }
          }
          await room.localParticipant?.setMicrophoneEnabled(true);
          _hostSession!.isConnected = true;
          _hostSession!.isPublishing = true;
          _hostSession!.notify();
        } catch (e) {
          debugPrint('LiveKit Host: Error enabling camera/mic: $e');
        }
      }

      if (mounted) {
        setState(() {
          _connected = _hostSession?.isConnected ?? false;
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('LiveKit Host initialization error: $e');
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _onHostSessionUpdated() {
    if (mounted) {
      setState(() {
        _connected = _hostSession?.isConnected ?? false;
        _muted = _hostSession?.muted ?? false;
        _cameraMuted = _hostSession?.cameraMuted ?? false;
        if (_hostSession?.localVideoTrack != null) {
          _isLoading = false;
        }
      });
    }
  }

  Future<void> _initViewerLiveKit() async {
    try {
      final currentUserId = fb_auth.FirebaseAuth.instance.currentUser?.uid ?? 'anon_${Random().nextInt(10000)}';
      final currentUserName = fb_auth.FirebaseAuth.instance.currentUser?.displayName ?? 'Viewer';
      // Unique viewer identity to prevent duplicate tab / widget collision
      final viewerIdentity = '${currentUserId}_viewer_${Random().nextInt(999999)}';

      final token = await LiveKitTokenService.fetchLiveKitToken(
        roomName: widget.channelName,
        identity: viewerIdentity,
        isPublisher: false,
        userName: currentUserName,
      );

      if (token == null) {
        debugPrint('LiveKit Viewer: Failed to obtain token');
        if (mounted) setState(() => _isLoading = false);
        return;
      }

      _viewerRoom = Room(
        roomOptions: const RoomOptions(
          adaptiveStream: false,
          dynacast: false,
        ),
      );
      _viewerListener = _viewerRoom!.createListener();

      _viewerListener!
        ..on<RoomConnectedEvent>((e) {
          debugPrint('LiveKit Viewer: Connected to room ${widget.channelName}');
          _findAndAttachRemoteVideo();
          if (mounted) {
            setState(() {
              _connected = true;
              _isLoading = false;
            });
          }
        })
        ..on<TrackSubscribedEvent>((e) {
          debugPrint('LiveKit Viewer: Track subscribed ${e.track.kind}');
          if (e.track is VideoTrack) {
            if (mounted) {
              setState(() {
                _remoteVideoTrack = e.track as VideoTrack;
                _isLoading = false;
              });
            }
          }
        })
        ..on<TrackPublishedEvent>((e) {
          debugPrint('LiveKit Viewer: Track published ${e.publication.kind}');
          if (e.publication.track is VideoTrack) {
            if (mounted) {
              setState(() {
                _remoteVideoTrack = e.publication.track as VideoTrack;
                _isLoading = false;
              });
            }
          }
        })
        ..on<TrackUnsubscribedEvent>((e) {
          if (e.track is VideoTrack && e.track == _remoteVideoTrack) {
            if (mounted) {
              setState(() => _remoteVideoTrack = null);
            }
          }
        })
        ..on<ParticipantConnectedEvent>((e) {
          _findAndAttachRemoteVideo();
        })
        ..on<RoomDisconnectedEvent>((e) {
          debugPrint('LiveKit Viewer: Room disconnected');
          if (mounted) {
            setState(() => _connected = false);
          }
        });

      await _viewerRoom!.connect(
        LiveKitConfig.liveKitWsUrl,
        token,
      );

      _findAndAttachRemoteVideo();

      if (mounted) {
        setState(() {
          _connected = true;
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('LiveKit Viewer initialization error: $e');
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _findAndAttachRemoteVideo() {
    if (_viewerRoom == null) return;
    for (final p in _viewerRoom!.remoteParticipants.values) {
      for (final pub in p.videoTrackPublications) {
        if (pub.track is VideoTrack) {
          if (mounted) {
            setState(() {
              _remoteVideoTrack = pub.track as VideoTrack;
              _isLoading = false;
            });
          }
          return;
        }
      }
    }
  }

  Future<void> _endStream() async {
    if (_isEnding) return;
    if (mounted) setState(() => _isEnding = true);
    _countdownTimer?.cancel();

    try {
      if (_isActualHost) {
        await _firestore.collection('posts').doc(widget.postId).update({
          'is_live': false,
          'live_status': 'ended',
          'ended_at': FieldValue.serverTimestamp(),
        });
      }
    } catch (e) {
      debugPrint('Error marking stream ended in Firestore: $e');
    }

    await _LiveKitHostSessionPool.endSession(widget.channelName);
    await _cleanupLiveKit();

    if (mounted) {
      setState(() {
        _isEnded = true;
        _isEnding = false;
      });
      widget.onLiveEnded?.call();
    }
  }

  Future<void> _cleanupLiveKit() async {
    try {
      if (_hostSession != null) {
        _hostSession!.removeListener(_onHostSessionUpdated);
        _LiveKitHostSessionPool.release(widget.channelName);
        _hostSession = null;
      }
      _viewerListener?.dispose();
      await _viewerRoom?.disconnect();
      await _viewerRoom?.dispose();
    } catch (e) {
      debugPrint('LiveKit cleanup error: $e');
    }
    _viewerRoom = null;
    _viewerListener = null;
    _remoteVideoTrack = null;
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

    final localTrack = _hostSession?.localVideoTrack;

    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Container(
        height: 260,
        width: double.infinity,
        color: Colors.black,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Video Surface
            if (_isActualHost && localTrack != null)
              VideoTrackRenderer(localTrack)
            else if (!_isActualHost && _remoteVideoTrack != null)
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
                      : Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.sensors, color: Colors.white38, size: 48),
                            const SizedBox(height: 8),
                            Text(
                              _isActualHost ? 'Starting Camera...' : 'Waiting for broadcaster video...',
                              style: const TextStyle(color: Colors.white70, fontSize: 14),
                            ),
                          ],
                        ),
                ),
              ),

            // Top Badges (LIVE tag, timer, End Live)
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
                  if (_isActualHost)
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
                  if (_isActualHost)
                    Material(
                      color: Colors.transparent,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(6),
                        onTap: _isEnding ? null : _endStream,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                          decoration: BoxDecoration(
                            color: Colors.redAccent,
                            borderRadius: BorderRadius.circular(6),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.3),
                                blurRadius: 4,
                                offset: const Offset(0, 2),
                              ),
                            ],
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (_isEnding)
                                const SizedBox(
                                  width: 12,
                                  height: 12,
                                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                                )
                              else ...[
                                const Icon(Icons.stop, size: 14, color: Colors.white),
                                const SizedBox(width: 4),
                                const Text(
                                  'End Live',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),

            // Bottom Host Controls
            if (_isActualHost && _connected)
              Positioned(
                bottom: 12,
                right: 12,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Mic toggle
                    Material(
                      color: Colors.transparent,
                      child: IconButton(
                        icon: Icon(_muted ? Icons.mic_off : Icons.mic, color: Colors.white),
                        style: IconButton.styleFrom(
                          backgroundColor: Colors.black54,
                          padding: const EdgeInsets.all(8),
                        ),
                        onPressed: () async {
                          final newState = !_muted;
                          await _hostSession?.room?.localParticipant?.setMicrophoneEnabled(!newState);
                          _hostSession?.muted = newState;
                          if (mounted) setState(() => _muted = newState);
                        },
                      ),
                    ),
                    const SizedBox(width: 6),
                    // Camera toggle
                    Material(
                      color: Colors.transparent,
                      child: IconButton(
                        icon: Icon(_cameraMuted ? Icons.videocam_off : Icons.videocam, color: Colors.white),
                        style: IconButton.styleFrom(
                          backgroundColor: Colors.black54,
                          padding: const EdgeInsets.all(8),
                        ),
                        onPressed: () async {
                          final newState = !_cameraMuted;
                          await _hostSession?.room?.localParticipant?.setCameraEnabled(!newState);
                          _hostSession?.cameraMuted = newState;
                          if (mounted) setState(() => _cameraMuted = newState);
                        },
                      ),
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

