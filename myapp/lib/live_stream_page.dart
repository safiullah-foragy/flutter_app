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
import 'agora_web_client.dart' if (dart.library.io) 'agora_web_client_stub.dart';
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
  AgoraWebClient? _webClient;
  String? _token;
  int _localUid = 0;
  int? _hostRemoteUid;
  final Set<int> _viewerUids = {};
  bool _isJoined = false;
  bool _isMuted = false;
  bool _isCameraOff = false;
  bool _isFrontCamera = true;
  bool _isEngineReady = false;

  // 5 Minutes Max Timer (300 seconds)
  static const int _maxLiveDurationSeconds = 300;
  int _remainingSeconds = _maxLiveDurationSeconds;
  int _elapsedSeconds = 0;
  Timer? _countdownTimer;

  // Live Comments
  final TextEditingController _commentController = TextEditingController();
  final ScrollController _commentsScrollController = ScrollController();
  List<Map<String, dynamic>> _liveComments = [];
  StreamSubscription<QuerySnapshot>? _commentsSub;
  StreamSubscription<DocumentSnapshot>? _postStreamSub;

  // Real-time Viewer Counter
  int _viewerCount = 1;
  StreamSubscription<QuerySnapshot>? _viewersSub;

  // Floating Reactions Animation
  final List<_FloatingReaction> _floatingReactions = [];
  StreamSubscription<QuerySnapshot>? _reactionsSub;

  // Live Pulse Animation
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

    _initAgoraAndLiveRoom();
    _setupFirestoreListeners();
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
      _removeViewerFromFirestore();
    }

    _leaveAgoraChannel();
    super.dispose();
  }

  Future<void> _initAgoraAndLiveRoom() async {
    _localUid = Random().nextInt(0x7FFFFFFF);

    if (widget.isHost) {
      // Start 5-minute countdown for the host
      _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (!mounted) return;
        setState(() {
          _elapsedSeconds++;
          _remainingSeconds = max(0, _maxLiveDurationSeconds - _elapsedSeconds);
        });

        if (_remainingSeconds <= 0) {
          timer.cancel();
          _showTimeExpiredDialogAndEnd();
        }
      });
    }

    if (kIsWeb) {
      await _initWeb();
    } else {
      await _initNative();
    }
  }

  Future<void> _initWeb() async {
    try {
      _webClient = AgoraWebClient();
      await _webClient!.initialize(AgoraConfig.appId);

      _webClient!.onUserJoined.listen((remoteUid) {
        if (mounted) {
          setState(() {
            _hostRemoteUid = remoteUid;
            _viewerUids.add(remoteUid);
          });
        }
      });

      _webClient!.onUserLeft.listen((remoteUid) {
        if (mounted) {
          setState(() {
            if (_hostRemoteUid == remoteUid) _hostRemoteUid = null;
            _viewerUids.remove(remoteUid);
          });
        }
      });

      _isEngineReady = true;
      _token = await AgoraTokenService.fetchRtcToken(
        channelName: widget.channelName,
        uid: _localUid,
        role: widget.isHost ? 'publisher' : 'subscriber',
      ).catchError((_) => '');

      await _webClient!.join(
        token: _token ?? '',
        channelName: widget.channelName,
        uid: _localUid,
        enableVideo: true,
      );

      if (mounted) setState(() => _isJoined = true);
    } catch (e) {
      debugPrint('AgoraWeb Live error: $e');
    }
  }

  Future<void> _initNative() async {
    try {
      if (widget.isHost) {
        await Permission.camera.request();
        await Permission.microphone.request();
      }
    } catch (_) {}

    try {
      _engine = createAgoraRtcEngine();
      await _engine!.initialize(RtcEngineContext(
        appId: AgoraConfig.appId,
        channelProfile: ChannelProfileType.channelProfileLiveBroadcasting,
      ));

      _engine!.registerEventHandler(
        RtcEngineEventHandler(
          onJoinChannelSuccess: (RtcConnection connection, int elapsed) {
            debugPrint('Live Agora: Joined channel ${connection.channelId}');
            if (mounted) setState(() => _isJoined = true);
          },
          onUserJoined: (RtcConnection connection, int remoteUid, int elapsed) {
            debugPrint('Live Agora: User joined uid $remoteUid');
            if (mounted) {
              setState(() {
                if (!widget.isHost && _hostRemoteUid == null) {
                  _hostRemoteUid = remoteUid;
                }
                _viewerUids.add(remoteUid);
              });
            }
          },
          onUserOffline: (RtcConnection connection, int remoteUid, UserOfflineReasonType reason) {
            debugPrint('Live Agora: User offline uid $remoteUid');
            if (mounted) {
              setState(() {
                if (_hostRemoteUid == remoteUid) _hostRemoteUid = null;
                _viewerUids.remove(remoteUid);
              });
              if (!widget.isHost && _hostRemoteUid == null) {
                // Host left
                _showHostEndedLiveNotification();
              }
            }
          },
        ),
      );

      await _engine!.enableVideo();
      await _engine!.enableAudio();

      if (widget.isHost) {
        await _engine!.setClientRole(role: ClientRoleType.clientRoleBroadcaster);
        await _engine!.startPreview();
      } else {
        await _engine!.setClientRole(role: ClientRoleType.clientRoleAudience);
      }

      _isEngineReady = true;

      // Token Fetch
      try {
        _token = await AgoraTokenService.fetchRtcToken(
          channelName: widget.channelName,
          uid: _localUid,
          role: widget.isHost ? 'publisher' : 'subscriber',
        );
      } catch (e) {
        debugPrint('Live Agora Token fetch: $e');
        _token = '';
      }

      await _engine!.joinChannel(
        token: _token ?? '',
        channelId: widget.channelName,
        uid: _localUid,
        options: ChannelMediaOptions(
          clientRoleType: widget.isHost ? ClientRoleType.clientRoleBroadcaster : ClientRoleType.clientRoleAudience,
          channelProfile: ChannelProfileType.channelProfileLiveBroadcasting,
          publishCameraTrack: widget.isHost,
          publishMicrophoneTrack: widget.isHost,
          autoSubscribeAudio: true,
          autoSubscribeVideo: true,
        ),
      );
    } catch (e) {
      debugPrint('Live Agora Native error: $e');
    }
  }

  Future<void> _leaveAgoraChannel() async {
    try {
      if (kIsWeb) {
        await _webClient?.leave();
      } else {
        await _engine?.leaveChannel();
        await _engine?.release();
      }
    } catch (_) {}
  }

  void _setupFirestoreListeners() {
    final user = _auth.currentUser;

    // Register active viewer
    if (!widget.isHost && user != null) {
      _firestore.collection('posts').doc(widget.postId).collection('live_viewers').doc(user.uid).set({
        'user_id': user.uid,
        'joined_at': FieldValue.serverTimestamp(),
      });
    }

    // Viewers count listener
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

    // Live Comments listener
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
        for (var doc in snap.docs) {
          comments.add({'id': doc.id, ...doc.data()});
        }
        setState(() {
          _liveComments = comments;
        });
        _scrollToBottom();
      }
    });

    // Live Reactions stream listener
    _reactionsSub = _firestore
        .collection('posts')
        .doc(widget.postId)
        .collection('live_reactions')
        .orderBy('timestamp', descending: true)
        .limit(10)
        .snapshots()
        .listen((snap) {
      if (!mounted) return;
      for (var doc in snap.docChanges) {
        if (doc.type == DocumentChangeType.added) {
          final data = doc.doc.data() as Map<String, dynamic>?;
          final emoji = data?['reaction'] as String? ?? '❤️';
          _addFloatingReaction(emoji);
        }
      }
    });

    // Listen to post status (if host ended live from another device or ended)
    _postStreamSub = _firestore.collection('posts').doc(widget.postId).snapshots().listen((doc) {
      if (!mounted || !doc.exists) return;
      final data = doc.data() as Map<String, dynamic>?;
      if (data != null) {
        final bool isLive = (data['is_live'] ?? false) as bool;
        final String liveStatus = (data['live_status'] ?? '') as String;
        if (!widget.isHost && (!isLive || liveStatus == 'ended')) {
          _showHostEndedLiveNotification();
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
    final randomX = Random().nextDouble() * 120;
    final reaction = _FloatingReaction(
      id: UniqueKey().toString(),
      emoji: emoji,
      startX: randomX,
    );
    setState(() {
      _floatingReactions.add(reaction);
    });

    Future.delayed(const Duration(milliseconds: 2000), () {
      if (mounted) {
        setState(() {
          _floatingReactions.removeWhere((r) => r.id == reaction.id);
        });
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
      final userDoc = await _firestore.collection('users').doc(user.uid).get();
      final userData = userDoc.data();

      final timestamp = DateTime.now().millisecondsSinceEpoch;
      await _firestore.collection('posts').doc(widget.postId).collection('comments').add({
        'user_id': user.uid,
        'user_name': userData?['name'] ?? 'User',
        'user_image': userData?['profile_image'],
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

  Future<void> _removeViewerFromFirestore() async {
    final user = _auth.currentUser;
    if (user == null) return;
    try {
      await _firestore
          .collection('posts')
          .doc(widget.postId)
          .collection('live_viewers')
          .doc(user.uid)
          .delete();
    } catch (_) {}
  }

  void _showTimeExpiredDialogAndEnd() {
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.timer_off_rounded, color: Colors.orange),
            SizedBox(width: 8),
            Text('5-Minute Limit Reached'),
          ],
        ),
        content: const Text('Your live broadcast has reached the 5-minute maximum duration and has now concluded.'),
        actions: [
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: ThemeController.instance.primaryColor,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            ),
            onPressed: () {
              Navigator.pop(ctx);
              Navigator.pop(context);
            },
            child: const Text('OK', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  void _showHostEndedLiveNotification() {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('The host has ended this live broadcast.')),
    );
    Navigator.pop(context);
  }

  Future<void> _confirmEndLive() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('End Live Broadcast?'),
        content: const Text('Are you sure you want to finish and end your live stream?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.redAccent,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            ),
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

  // Toggle Camera
  Future<void> _toggleCamera() async {
    if (_engine == null) return;
    _isCameraOff = !_isCameraOff;
    await _engine!.muteLocalVideoStream(_isCameraOff);
    setState(() {});
  }

  // Flip Camera
  Future<void> _flipCamera() async {
    if (_engine == null) return;
    await _engine!.switchCamera();
    setState(() => _isFrontCamera = !_isFrontCamera);
  }

  // Toggle Mic
  Future<void> _toggleMute() async {
    if (_engine == null) return;
    _isMuted = !_isMuted;
    await _engine!.muteLocalAudioStream(_isMuted);
    setState(() {});
  }

  String _formatDuration(int totalSeconds) {
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // 1. Live Video Surface
          Positioned.fill(
            child: _buildVideoView(),
          ),

          // 2. Top Header Bar (Host Profile, LIVE Badge, 5-min timer, Viewer Count, Close Button)
          Positioned(
            top: MediaQuery.of(context).padding.top + 10,
            left: 12,
            right: 12,
            child: _buildTopBar(),
          ),

          // 3. Floating Animated Reactions Overlay
          Positioned(
            bottom: 120,
            right: 16,
            width: 150,
            height: 250,
            child: IgnorePointer(
              child: Stack(
                children: _floatingReactions.map((r) => _buildAnimatedReactionItem(r)).toList(),
              ),
            ),
          ),

          // 4. Bottom Comments Overlay & Input Bar
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: _buildBottomOverlay(),
          ),
        ],
      ),
    );
  }

  Widget _buildVideoView() {
    if (kIsWeb) {
      return Center(
        child: Text(
          widget.isHost ? '🔴 Broadcasting Live Stream (Web)' : '👁️ Watching Live Stream (Web)',
          style: const TextStyle(color: Colors.white, fontSize: 16),
        ),
      );
    }

    if (_engine == null || !_isEngineReady) {
      return const Center(child: CircularProgressIndicator(color: Colors.redAccent));
    }

    if (widget.isHost) {
      if (_isCameraOff) {
        return Container(
          color: Colors.grey[900],
          child: const Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.videocam_off, color: Colors.white54, size: 60),
                SizedBox(height: 10),
                Text('Camera is Turned Off', style: TextStyle(color: Colors.white54, fontSize: 15)),
              ],
            ),
          ),
        );
      }
      return AgoraVideoView(
        controller: VideoViewController(
          rtcEngine: _engine!,
          canvas: const VideoCanvas(uid: 0),
        ),
      );
    } else {
      // Audience View
      if (_hostRemoteUid != null) {
        return AgoraVideoView(
          controller: VideoViewController.remote(
            rtcEngine: _engine!,
            canvas: VideoCanvas(uid: _hostRemoteUid),
            connection: RtcConnection(channelId: widget.channelName),
          ),
        );
      }
      return Container(
        color: Colors.black,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ScaleTransition(
                scale: _pulseAnimation,
                child: Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: Colors.redAccent.withOpacity(0.2),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.live_tv_rounded, color: Colors.redAccent, size: 50),
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Connecting to Live Stream...',
                style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      );
    }
  }

  Widget _buildTopBar() {
    final hostName = widget.hostUserData?['name'] ?? 'Host';
    final hostImage = widget.hostUserData?['profile_image'];

    return Row(
      children: [
        // Host Info
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.55),
            borderRadius: BorderRadius.circular(24),
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
                  Text(
                    hostName,
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12),
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.remove_red_eye_rounded, color: Colors.white70, size: 11),
                      const SizedBox(width: 3),
                      Text(
                        '$_viewerCount',
                        style: const TextStyle(color: Colors.white70, fontSize: 11),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(width: 6),
            ],
          ),
        ),

        const SizedBox(width: 8),

        // Glowing LIVE Badge with Timer
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: Colors.redAccent,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: Colors.redAccent.withOpacity(0.6),
                blurRadius: 8,
                spreadRadius: 1,
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
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
              const SizedBox(width: 5),
              Text(
                widget.isHost ? 'LIVE • ${_formatDuration(_remainingSeconds)}' : 'LIVE',
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11.5),
              ),
            ],
          ),
        ),

        const Spacer(),

        // Host Tools (Camera flip, Mic mute)
        if (widget.isHost) ...[
          IconButton(
            onPressed: _flipCamera,
            icon: const Icon(Icons.flip_camera_ios_rounded, color: Colors.white, size: 22),
            style: IconButton.styleFrom(backgroundColor: Colors.black45),
          ),
          const SizedBox(width: 4),
          IconButton(
            onPressed: _toggleMute,
            icon: Icon(_isMuted ? Icons.mic_off_rounded : Icons.mic_rounded, color: _isMuted ? Colors.redAccent : Colors.white, size: 22),
            style: IconButton.styleFrom(backgroundColor: Colors.black45),
          ),
          const SizedBox(width: 4),
        ],

        // Close / End Button
        IconButton(
          onPressed: widget.isHost ? _confirmEndLive : () => Navigator.pop(context),
          icon: const Icon(Icons.close_rounded, color: Colors.white, size: 24),
          style: IconButton.styleFrom(backgroundColor: Colors.black54),
        ),
      ],
    );
  }

  Widget _buildAnimatedReactionItem(_FloatingReaction reaction) {
    return _AnimatedFloatingEmoji(
      key: ValueKey(reaction.id),
      emoji: reaction.emoji,
      startX: reaction.startX,
    );
  }

  Widget _buildBottomOverlay() {
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
            Colors.black.withOpacity(0.3),
            Colors.transparent,
          ],
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Live Comments List (Transparent scroll view)
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 180),
            child: ListView.builder(
              controller: _commentsScrollController,
              shrinkWrap: true,
              itemCount: _liveComments.length,
              itemBuilder: (context, index) {
                final comment = _liveComments[index];
                final name = comment['user_name'] ?? 'User';
                final text = comment['text'] ?? '';
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
                          style: const TextStyle(
                            color: Color(0xFF64B5F6),
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
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

          // Quick Reactions Bar
          Row(
            children: [
              _buildReactionButton('❤️'),
              const SizedBox(width: 6),
              _buildReactionButton('🔥'),
              const SizedBox(width: 6),
              _buildReactionButton('👍'),
              const SizedBox(width: 6),
              _buildReactionButton('😮'),
              const SizedBox(width: 6),
              _buildReactionButton('👏'),
              const SizedBox(width: 6),
              _buildReactionButton('😂'),
            ],
          ),

          const SizedBox(height: 10),

          // Comment Input Box
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
                    boxShadow: [
                      BoxShadow(
                        color: ThemeController.instance.primaryColor.withOpacity(0.4),
                        blurRadius: 6,
                      ),
                    ],
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

  Widget _buildReactionButton(String emoji) {
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
