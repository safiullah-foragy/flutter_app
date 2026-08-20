import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import 'package:permission_handler/permission_handler.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'agora_config.dart';
import 'agora_token_service.dart';
import 'theme_controller.dart';

class LiveStreamPage extends StatefulWidget {
  final String postId;
  final String channelName;
  final bool isHost;
  final String hostUserId;
  final Map<String, dynamic>? hostUserData;

  const LiveStreamPage({
    super.key,
    required this.postId,
    required this.channelName,
    required this.isHost,
    required this.hostUserId,
    this.hostUserData,
  });

  @override
  State<LiveStreamPage> createState() => _LiveStreamPageState();
}

class _LiveStreamPageState extends State<LiveStreamPage> with TickerProviderStateMixin {
  final firebase_auth.FirebaseAuth _auth = firebase_auth.FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  RtcEngine? _engine;
  String? _token;
  int _localUid = 0;
  int? _remoteHostUid;
  final Set<int> _remoteUids = {};
  bool _joined = false;
  bool _muted = false;
  bool _frontCamera = true;
  bool _speakerOn = true;
  bool _engineInitialized = false;

  // 5-Minute Timer (300 seconds)
  static const int _maxLiveDurationSeconds = 300;
  int _remainingSeconds = _maxLiveDurationSeconds;
  int _elapsedSeconds = 0;
  Timer? _countdownTimer;

  // Comments
  final TextEditingController _commentController = TextEditingController();
  final ScrollController _commentsScrollController = ScrollController();
  List<Map<String, dynamic>> _liveComments = [];
  StreamSubscription<QuerySnapshot>? _commentsSub;
  StreamSubscription<DocumentSnapshot>? _postStreamSub;

  // Viewers
  int _viewerCount = 1;
  StreamSubscription<QuerySnapshot>? _viewersSub;

  // Floating Reactions
  final List<_FloatingReaction> _floatingReactions = [];
  StreamSubscription<QuerySnapshot>? _reactionsSub;

  // Pulse animation for LIVE badge
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    )..repeat(reverse: true);
    _pulseAnimation = Tween<double>(begin: 0.8, end: 1.2).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    _initLive();
    _setupFirestore();
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _commentsSub?.cancel();
    _postStreamSub?.cancel();
    _viewersSub?.cancel();
    _reactionsSub?.cancel();
    _pulseController.dispose();
    _commentController.dispose();
    _commentsScrollController.dispose();

    if (widget.isHost) {
      _endLiveInFirestore();
    } else {
      _removeViewer();
    }

    _leaveAndReleaseEngine();
    super.dispose();
  }

  Future<void> _initLive() async {
    _localUid = Random().nextInt(0x7FFFFFFF);

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
      await _initNative();
    }
  }

  Future<void> _initNative() async {
    try {
      final micStatus = await Permission.microphone.request();
      if (!micStatus.isGranted && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Microphone permission is required.')),
        );
      }
      final camStatus = await Permission.camera.request();
      if (!camStatus.isGranted && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Camera permission is required.')),
        );
      }
    } catch (_) {}

    try {
      _engine = createAgoraRtcEngine();
      await _engine!.initialize(RtcEngineContext(
        appId: AgoraConfig.appId,
        channelProfile: ChannelProfileType.channelProfileCommunication,
      ));

      _engine!.registerEventHandler(
        RtcEngineEventHandler(
          onJoinChannelSuccess: (RtcConnection conn, int elapsed) {
            debugPrint('Live: Joined channel ${conn.channelId} with uid ${conn.localUid}');
            if (mounted) setState(() => _joined = true);
            try { _engine?.setDefaultAudioRouteToSpeakerphone(true); } catch (_) {}
            try { _engine?.setEnableSpeakerphone(true); } catch (_) {}
            try { _engine?.adjustRecordingSignalVolume(100); } catch (_) {}
            try { _engine?.adjustPlaybackSignalVolume(100); } catch (_) {}
          },
          onUserJoined: (RtcConnection conn, int remoteUid, int elapsed) {
            debugPrint('Live: Remote user joined uid $remoteUid');
            if (mounted) {
              setState(() {
                _remoteUids.add(remoteUid);
                if (!widget.isHost) {
                  _remoteHostUid ??= remoteUid;
                }
              });
            }
            try {
              _engine?.muteRemoteAudioStream(uid: remoteUid, mute: false);
              _engine?.muteRemoteVideoStream(uid: remoteUid, mute: false);
              _engine?.adjustUserPlaybackSignalVolume(uid: remoteUid, volume: 100);
              _engine?.muteAllRemoteAudioStreams(false);
              _engine?.muteAllRemoteVideoStreams(false);
            } catch (_) {}
          },
          onUserOffline: (RtcConnection conn, int remoteUid, UserOfflineReasonType reason) {
            debugPrint('Live: Remote user offline uid $remoteUid');
            if (mounted) {
              setState(() {
                _remoteUids.remove(remoteUid);
                if (_remoteHostUid == remoteUid) {
                  _remoteHostUid = _remoteUids.isNotEmpty ? _remoteUids.first : null;
                }
              });
              if (!widget.isHost && _remoteUids.isEmpty) {
                _onHostLeft();
              }
            }
          },
        ),
      );

      await _engine!.enableAudio();
      await _engine!.enableVideo();

      if (widget.isHost) {
        await _engine!.enableLocalVideo(true);
        try { await _engine!.startPreview(); } catch (_) {}
      }

      _engineInitialized = true;

      // Fetch Token
      try {
        _token = await AgoraTokenService.fetchRtcToken(
          channelName: widget.channelName,
          uid: _localUid,
        );
      } catch (e) {
        debugPrint('Live Token fetch error: $e');
        _token = '';
      }

      await _engine!.joinChannel(
        token: _token ?? '',
        channelId: widget.channelName,
        uid: _localUid,
        options: ChannelMediaOptions(
          publishCameraTrack: widget.isHost,
          publishMicrophoneTrack: widget.isHost,
          autoSubscribeAudio: true,
          autoSubscribeVideo: true,
          clientRoleType: widget.isHost ? ClientRoleType.clientRoleBroadcaster : ClientRoleType.clientRoleAudience,
        ),
      );
    } catch (e) {
      debugPrint('Live Agora initialization error: $e');
    }
  }

  Future<void> _leaveAndReleaseEngine() async {
    try {
      if (_engine != null && _engineInitialized) {
        await _engine!.leaveChannel();
        await _engine!.release();
      }
    } catch (_) {}
  }

  void _setupFirestore() {
    final user = _auth.currentUser;

    if (!widget.isHost && user != null) {
      _firestore.collection('posts').doc(widget.postId).collection('live_viewers').doc(user.uid).set({
        'user_id': user.uid,
        'joined_at': FieldValue.serverTimestamp(),
      });
    }

    _viewersSub = _firestore
        .collection('posts')
        .doc(widget.postId)
        .collection('live_viewers')
        .snapshots()
        .listen((snap) {
      if (mounted) {
        setState(() {
          _viewerCount = max(1, snap.docs.length + (widget.isHost ? 1 : 0));
        });
      }
    });

    _commentsSub = _firestore
        .collection('posts')
        .doc(widget.postId)
        .collection('comments')
        .orderBy('timestamp', descending: false)
        .limitToLast(50)
        .snapshots()
        .listen((snap) {
      if (mounted) {
        final List<Map<String, dynamic>> comments = [];
        for (var d in snap.docs) {
          comments.add({'id': d.id, ...d.data()});
        }
        setState(() => _liveComments = comments);
        _scrollToBottom();
      }
    });

    _reactionsSub = _firestore
        .collection('posts')
        .doc(widget.postId)
        .collection('live_reactions')
        .orderBy('timestamp', descending: true)
        .limit(10)
        .snapshots()
        .listen((snap) {
      if (!mounted) return;
      for (var c in snap.docChanges) {
        if (c.type == DocumentChangeType.added) {
          final data = c.doc.data() as Map<String, dynamic>?;
          final emoji = data?['reaction'] as String? ?? '❤️';
          _addFloatingReaction(emoji);
        }
      }
    });

    _postStreamSub = _firestore.collection('posts').doc(widget.postId).snapshots().listen((doc) {
      if (!mounted || !doc.exists) return;
      final data = doc.data() as Map<String, dynamic>?;
      if (data != null) {
        final isLive = (data['is_live'] ?? false) as bool;
        final liveStatus = (data['live_status'] ?? '') as String;
        if (!widget.isHost && (!isLive || liveStatus == 'ended')) {
          _onHostLeft();
        }
      }
    });
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_commentsScrollController.hasClients) {
        _commentsScrollController.animateTo(
          _commentsScrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _addFloatingReaction(String emoji) {
    final reaction = _FloatingReaction(
      id: UniqueKey().toString(),
      emoji: emoji,
      startX: Random().nextDouble() * 120 + 20,
    );
    setState(() => _floatingReactions.add(reaction));

    Future.delayed(const Duration(milliseconds: 2000), () {
      if (mounted) {
        setState(() => _floatingReactions.removeWhere((r) => r.id == reaction.id));
      }
    });
  }

  Future<void> _sendComment() async {
    final text = _commentController.text.trim();
    if (text.isEmpty) return;
    _commentController.clear();

    final user = _auth.currentUser;
    if (user == null) return;

    try {
      final uDoc = await _firestore.collection('users').doc(user.uid).get();
      final uData = uDoc.data();

      final timestamp = DateTime.now().millisecondsSinceEpoch;
      await _firestore.collection('posts').doc(widget.postId).collection('comments').add({
        'user_id': user.uid,
        'user_name': uData?['name'] ?? 'User',
        'user_image': uData?['profile_image'],
        'text': text,
        'timestamp': timestamp,
      });

      await _firestore.collection('posts').doc(widget.postId).update({
        'comments_count': FieldValue.increment(1),
      });
    } catch (e) {
      debugPrint('Error sending live comment: $e');
    }
  }

  Future<void> _sendReaction(String emoji) async {
    final user = _auth.currentUser;
    if (user == null) return;

    _addFloatingReaction(emoji);

    try {
      await _firestore.collection('posts').doc(widget.postId).collection('live_reactions').add({
        'user_id': user.uid,
        'reaction': emoji,
        'timestamp': FieldValue.serverTimestamp(),
      });

      await _firestore.collection('posts').doc(widget.postId).update({
        'likes_count': FieldValue.increment(1),
      });
    } catch (_) {}
  }

  Future<void> _endLiveInFirestore() async {
    try {
      await _firestore.collection('posts').doc(widget.postId).update({
        'is_live': false,
        'live_status': 'ended',
        'ended_at': DateTime.now().millisecondsSinceEpoch,
        'duration_seconds': _elapsedSeconds,
      });
    } catch (_) {}
  }

  Future<void> _removeViewer() async {
    final user = _auth.currentUser;
    if (user == null) return;
    try {
      await _firestore.collection('posts').doc(widget.postId).collection('live_viewers').doc(user.uid).delete();
    } catch (_) {}
  }

  void _onTimeExpired() {
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('5-Minute Limit Reached'),
        content: const Text('Your live broadcast has reached the 5-minute maximum limit.'),
        actions: [
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              Navigator.pop(context);
            },
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  void _onHostLeft() {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('The live broadcast has ended.')),
    );
    Navigator.pop(context);
  }

  Future<void> _confirmEndLive() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('End Live Stream?'),
        content: const Text('Are you sure you want to end your live stream?'),
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
      Navigator.pop(context);
    }
  }

  Future<void> _flipCamera() async {
    if (_engine == null) return;
    await _engine!.switchCamera();
    setState(() => _frontCamera = !_frontCamera);
  }

  Future<void> _toggleMute() async {
    if (_engine == null) return;
    _muted = !_muted;
    await _engine!.muteLocalAudioStream(_muted);
    setState(() {});
  }

  String _formatDuration(int sec) {
    final m = sec ~/ 60;
    final s = sec % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // 1. Full Screen Camera Video View
          Positioned.fill(
            child: _buildVideoSurface(),
          ),

          // 2. Top Header (Host avatar/name, LIVE badge, 5m timer, viewer count, end/close button)
          Positioned(
            top: MediaQuery.of(context).padding.top + 10,
            left: 12,
            right: 12,
            child: _buildTopHeader(),
          ),

          // 3. Floating Reactions
          Positioned(
            bottom: 130,
            right: 12,
            width: 160,
            height: 260,
            child: IgnorePointer(
              child: Stack(
                children: _floatingReactions.map((r) => _buildAnimatedEmoji(r)).toList(),
              ),
            ),
          ),

          // 4. Bottom Comments Overlay & Reaction Buttons
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: _buildBottomBar(),
          ),
        ],
      ),
    );
  }

  Widget _buildVideoSurface() {
    if (kIsWeb) {
      return Center(
        child: Text(
          widget.isHost ? '🔴 Live Stream Broadcast' : '👁️ Watching Live Stream',
          style: const TextStyle(color: Colors.white, fontSize: 16),
        ),
      );
    }

    if (_engine == null || !_engineInitialized) {
      return const Center(child: CircularProgressIndicator(color: Colors.redAccent));
    }

    if (widget.isHost) {
      // Broadcaster sees own camera full-screen
      return ClipRect(
        child: FittedBox(
          fit: BoxFit.cover,
          child: SizedBox(
            width: MediaQuery.of(context).size.width,
            height: MediaQuery.of(context).size.height,
            child: AgoraVideoView(
              controller: VideoViewController(
                rtcEngine: _engine!,
                canvas: const VideoCanvas(uid: 0),
              ),
            ),
          ),
        ),
      );
    } else {
      // Audience sees host remote camera full-screen
      final hostUid = _remoteHostUid ?? (_remoteUids.isNotEmpty ? _remoteUids.first : null);
      if (hostUid != null) {
        return ClipRect(
          child: FittedBox(
            fit: BoxFit.cover,
            child: SizedBox(
              width: MediaQuery.of(context).size.width,
              height: MediaQuery.of(context).size.height,
              child: AgoraVideoView(
                controller: VideoViewController.remote(
                  rtcEngine: _engine!,
                  canvas: VideoCanvas(uid: hostUid),
                  connection: RtcConnection(channelId: widget.channelName),
                ),
              ),
            ),
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
                  padding: const EdgeInsets.all(22),
                  decoration: BoxDecoration(
                    color: Colors.redAccent.withOpacity(0.25),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.live_tv_rounded, color: Colors.redAccent, size: 55),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Connecting to ${widget.hostUserData?['name'] ?? 'Host'}\'s Live...',
                style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      );
    }
  }

  Widget _buildTopHeader() {
    final hostName = widget.hostUserData?['name'] ?? 'Host';
    final hostImage = widget.hostUserData?['profile_image'];

    return Row(
      children: [
        // Host Info Pill
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: Colors.black54,
            borderRadius: BorderRadius.circular(25),
            border: Border.all(color: Colors.white24),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircleAvatar(
                radius: 16,
                backgroundColor: Colors.grey[800],
                backgroundImage: hostImage != null ? CachedNetworkImageProvider(hostImage) : null,
                child: hostImage == null ? const Icon(Icons.person, color: Colors.white, size: 16) : null,
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(hostName, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12.5)),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.remove_red_eye_rounded, color: Colors.white70, size: 11),
                      const SizedBox(width: 3),
                      Text('$_viewerCount', style: const TextStyle(color: Colors.white70, fontSize: 11)),
                    ],
                  ),
                ],
              ),
              const SizedBox(width: 6),
            ],
          ),
        ),

        const SizedBox(width: 8),

        // LIVE Badge with Timer
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: Colors.redAccent,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: Colors.redAccent.withOpacity(0.6),
                blurRadius: 8,
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ScaleTransition(
                scale: _pulseAnimation,
                child: Container(
                  width: 7,
                  height: 7,
                  decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                ),
              ),
              const SizedBox(width: 5),
              Text(
                widget.isHost ? 'LIVE • ${_formatDuration(_remainingSeconds)}' : 'LIVE',
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12),
              ),
            ],
          ),
        ),

        const Spacer(),

        if (widget.isHost) ...[
          // Camera Flip Button
          Container(
            decoration: BoxDecoration(
              color: Colors.black54,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white24),
            ),
            child: IconButton(
              onPressed: _flipCamera,
              tooltip: 'Switch Camera',
              icon: const Icon(Icons.flip_camera_ios_rounded, color: Colors.white, size: 22),
            ),
          ),
          const SizedBox(width: 8),
          // End Live Button
          GestureDetector(
            onTap: _confirmEndLive,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              decoration: BoxDecoration(
                color: Colors.redAccent,
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                    color: Colors.redAccent.withOpacity(0.5),
                    blurRadius: 6,
                  ),
                ],
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.call_end_rounded, color: Colors.white, size: 16),
                  SizedBox(width: 4),
                  Text(
                    'End Live',
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
        ] else ...[
          Container(
            decoration: BoxDecoration(
              color: Colors.black54,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white24),
            ),
            child: IconButton(
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.close_rounded, color: Colors.white, size: 22),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildAnimatedEmoji(_FloatingReaction r) {
    return _AnimatedFloatingEmoji(
      key: ValueKey(r.id),
      emoji: r.emoji,
      startX: r.startX,
    );
  }

  Widget _buildBottomBar() {
    return Container(
      padding: EdgeInsets.only(
        left: 12,
        right: 12,
        bottom: MediaQuery.of(context).padding.bottom + 10,
        top: 10,
      ),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [
            Colors.black.withOpacity(0.85),
            Colors.black.withOpacity(0.2),
            Colors.transparent,
          ],
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Live Chat comments list
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 180),
            child: ListView.builder(
              controller: _commentsScrollController,
              shrinkWrap: true,
              itemCount: _liveComments.length,
              itemBuilder: (context, idx) {
                final c = _liveComments[idx];
                final name = c['user_name'] ?? 'User';
                final text = c['text'] ?? '';
                return Container(
                  margin: const EdgeInsets.symmetric(vertical: 3),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.45),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: RichText(
                    text: TextSpan(
                      children: [
                        TextSpan(
                          text: '$name  ',
                          style: const TextStyle(color: Color(0xFF64B5F6), fontWeight: FontWeight.bold, fontSize: 13),
                        ),
                        TextSpan(
                          text: text,
                          style: const TextStyle(color: Colors.white, fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),

          const SizedBox(height: 10),

          // Quick reaction emoji bar
          Row(
            children: [
              _buildEmojiBtn('❤️'),
              const SizedBox(width: 6),
              _buildEmojiBtn('🔥'),
              const SizedBox(width: 6),
              _buildEmojiBtn('👍'),
              const SizedBox(width: 6),
              _buildEmojiBtn('😮'),
              const SizedBox(width: 6),
              _buildEmojiBtn('👏'),
              const SizedBox(width: 6),
              _buildEmojiBtn('😂'),
            ],
          ),

          const SizedBox(height: 10),

          // Live comment input
          Row(
            children: [
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(25),
                    border: Border.all(color: Colors.white24),
                  ),
                  child: TextField(
                    controller: _commentController,
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                    decoration: const InputDecoration(
                      hintText: 'Say something live...',
                      hintStyle: TextStyle(color: Colors.white60, fontSize: 13),
                      border: InputBorder.none,
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(vertical: 10),
                    ),
                    onSubmitted: (_) => _sendComment(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: _sendComment,
                child: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: ThemeController.instance.primaryColor,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.send_rounded, color: Colors.white, size: 18),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildEmojiBtn(String emoji) {
    return GestureDetector(
      onTap: () => _sendReaction(emoji),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.18),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white24),
        ),
        child: Text(emoji, style: const TextStyle(fontSize: 16)),
      ),
    );
  }
}

class _FloatingReaction {
  final String id;
  final String emoji;
  final double startX;

  _FloatingReaction({
    required this.id,
    required this.emoji,
    required this.startX,
  });
}

class _AnimatedFloatingEmoji extends StatefulWidget {
  final String emoji;
  final double startX;

  const _AnimatedFloatingEmoji({
    super.key,
    required this.emoji,
    required this.startX,
  });

  @override
  State<_AnimatedFloatingEmoji> createState() => _AnimatedFloatingEmojiState();
}

class _AnimatedFloatingEmojiState extends State<_AnimatedFloatingEmoji> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _translateY;
  late Animation<double> _opacity;
  late Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..forward();

    _translateY = Tween<double>(begin: 0, end: -180).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic),
    );

    _scale = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 0.4, end: 1.3), weight: 30),
      TweenSequenceItem(tween: Tween(begin: 1.3, end: 1.0), weight: 70),
    ]).animate(_controller);

    _opacity = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 0.0, end: 1.0), weight: 20),
      TweenSequenceItem(tween: Tween(begin: 1.0, end: 1.0), weight: 50),
      TweenSequenceItem(tween: Tween(begin: 1.0, end: 0.0), weight: 30),
    ]).animate(_controller);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Positioned(
          bottom: -_translateY.value,
          right: widget.startX,
          child: Opacity(
            opacity: _opacity.value,
            child: Transform.scale(
              scale: _scale.value,
              child: Text(widget.emoji, style: const TextStyle(fontSize: 26)),
            ),
          ),
        );
      },
    );
  }
}
