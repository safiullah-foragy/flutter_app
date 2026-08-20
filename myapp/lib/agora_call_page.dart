import 'dart:math';
import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'agora_config.dart';
import 'agora_token_service.dart';
import 'agora_web_client.dart' if (dart.library.io) 'agora_web_client_stub.dart';
import 'notification_service.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;

class CallPage extends StatefulWidget {
  final String channelName; // e.g., conv_<conversationId>
  final bool video; // true = video call, false = audio-only call
  final String? conversationId; // extracted from channelName or passed explicitly
  final String? remoteUserId; // for displaying avatar/name
  final bool isGroupCall; // true if this is a group call
  final String? callSessionId; // Firestore call_session document id for status tracking
  final bool isCaller; // true = caller (starts in Calling/Ringing phase), false = receiver (direct talking screen)

  const CallPage({
    super.key,
    required this.channelName,
    required this.video,
    this.conversationId,
    this.remoteUserId,
    this.callSessionId,
    this.isGroupCall = false,
    this.isCaller = true,
  });

  static Route route({
    required String channelName,
    required bool video,
    String? conversationId,
    String? remoteUserId,
    String? callSessionId,
    bool isGroupCall = false,
    bool isCaller = true,
  }) =>
      MaterialPageRoute(
        builder: (_) => CallPage(
          channelName: channelName,
          video: video,
          conversationId: conversationId,
          remoteUserId: remoteUserId,
          callSessionId: callSessionId,
          isGroupCall: isGroupCall,
          isCaller: isCaller,
        ),
      );

  @override
  State<CallPage> createState() => _CallPageState();
}

class _CallPageState extends State<CallPage> with SingleTickerProviderStateMixin {
  RtcEngine? _engine;
  AgoraWebClient? _webClient; // For web platform
  String? _token;
  int _localUid = 0;
  final Set<int> _remoteUids = {};
  bool _joined = false;
  bool _muted = false;
  bool _speakerOn = true;
  bool _frontCamera = true;
  bool _videoEnabled = true;
  bool _engineInitialized = false;

  // Call status: 'calling' (waiting for receiver), 'connected' (talking), or terminal ('ended', 'rejected', 'cancelled')
  bool _isCallConnected = false;
  DateTime? _callStart;
  Duration _elapsed = Duration.zero;
  Timer? _timer;
  Timer? _ringingTimeoutTimer;

  Map<String, dynamic>? _remoteUserData; // name, profile_image
  StreamSubscription<DocumentSnapshot>? _callSessionSub;
  String? _terminalReason;
  String? _currentSessionStatus;
  bool _isCaller = true;
  bool _isJoining = false;
  bool _shouldJoinAfterInit = false;

  // Pulse animation for the calling screen
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  // Video layout state
  Offset? _pipOffset;
  bool _showLocalFull = false;

  @override
  void initState() {
    super.initState();
    _isCaller = widget.isCaller;
    if (!_isCaller) {
      _onCallConnected();
      _shouldJoinAfterInit = true;
      final sessId = widget.callSessionId;
      if (sessId != null && sessId.isNotEmpty) {
        try {
          FirebaseFirestore.instance.collection('call_sessions').doc(sessId).set({
            'status': 'accepted',
            'accepted_at': DateTime.now().millisecondsSinceEpoch,
          }, SetOptions(merge: true));
        } catch (_) {}
      }
    }

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);

    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.12).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    _init();
    _attachCallSessionListener();
  }

  Future<void> _init() async {
    if (widget.channelName.trim().isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Call channel is empty. Please retry call.')),
        );
      }
      return;
    }

    // Fetch remote user profile for avatar/name
    final targetUid = widget.remoteUserId;
    if (targetUid != null && targetUid.isNotEmpty) {
      try {
        final doc = await FirebaseFirestore.instance.collection('users').doc(targetUid).get();
        if (doc.exists && mounted) {
          setState(() {
            _remoteUserData = doc.data();
          });
        }
      } catch (_) {}
    } else if (widget.conversationId != null) {
      try {
        final currentUid = firebase_auth.FirebaseAuth.instance.currentUser?.uid;
        final convDoc = await FirebaseFirestore.instance.collection('conversations').doc(widget.conversationId).get();
        if (convDoc.exists) {
          final parts = List<String>.from(convDoc.data()?['participants'] ?? []);
          final otherUid = parts.firstWhere((p) => p != currentUid, orElse: () => '');
          if (otherUid.isNotEmpty) {
            final uDoc = await FirebaseFirestore.instance.collection('users').doc(otherUid).get();
            if (uDoc.exists && mounted) {
              setState(() {
                _remoteUserData = uDoc.data();
              });
            }
          }
        }
      } catch (_) {}
    }

    if (AgoraConfig.appId == 'YOUR_AGORA_APP_ID_HERE' || AgoraConfig.appId.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please set AGORA_APP_ID in agora_config.dart.')),
        );
      }
      return;
    }

    _localUid = Random().nextInt(0x7FFFFFFF);

    if (kIsWeb) {
      await _initWeb();
    } else {
      await _initNative();
    }
  }

  /// Initialize Agora for Web platform
  Future<void> _initWeb() async {
    try {
      debugPrint('AgoraWeb: Initializing web client');
      _webClient = AgoraWebClient();
      await _webClient!.initialize(AgoraConfig.appId);

      _webClient!.onUserJoined.listen((remoteUid) {
        debugPrint('AgoraWeb: Remote user joined - uid: $remoteUid');
        if (mounted) {
          setState(() {
            _remoteUids.add(remoteUid);
          });
          if (widget.isGroupCall || _currentSessionStatus == 'accepted') {
            _onCallConnected();
          }
        }
      });

      _webClient!.onUserLeft.listen((remoteUid) {
        debugPrint('AgoraWeb: Remote user left - uid: $remoteUid');
        if (mounted) {
          setState(() => _remoteUids.remove(remoteUid));
        }
      });

      _engineInitialized = true;
      debugPrint('AgoraWeb: Web client initialized successfully');
    } catch (e) {
      debugPrint('AgoraWeb: Initialization error - $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to initialize Agora Web: $e')),
        );
      }
      return;
    }

    try {
      _token = await AgoraTokenService.fetchRtcToken(channelName: widget.channelName, uid: _localUid);
    } catch (e) {
      debugPrint('AgoraWeb: Token fetch FAILED: $e');
    }

    if (_shouldJoinAfterInit && !_joined && !_isJoining) {
      _shouldJoinAfterInit = false;
      await _joinChannel();
    } else if (_isCaller && !_joined && !_isJoining) {
      await _joinChannel();
    }
  }

  /// Initialize Agora for Native platforms (Android/iOS)
  Future<void> _initNative() async {
    try {
      final micStatus = await Permission.microphone.request();
      if (!micStatus.isGranted && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Microphone permission is required for calls')),
        );
        return;
      }
      if (widget.video) {
        final camStatus = await Permission.camera.request();
        if (!camStatus.isGranted && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Camera permission is required for video calls')),
          );
          return;
        }
      }
    } catch (_) {}

    try {
      _engine = createAgoraRtcEngine();
      try {
        await _engine!.initialize(RtcEngineContext(
          appId: AgoraConfig.appId,
          channelProfile: ChannelProfileType.channelProfileCommunication,
        ));
      } catch (initErr) {
        debugPrint('Agora initial initialize failed ($initErr), releasing and retrying...');
        try { await _engine!.leaveChannel(); } catch (_) {}
        try { await _engine!.release(); } catch (_) {}
        _engine = createAgoraRtcEngine();
        await _engine!.initialize(RtcEngineContext(
          appId: AgoraConfig.appId,
          channelProfile: ChannelProfileType.channelProfileCommunication,
        ));
      }

      _engine!.registerEventHandler(RtcEngineEventHandler(
        onJoinChannelSuccess: (RtcConnection conn, int elapsed) {
          debugPrint('Agora: Join channel SUCCESS - channel: ${conn.channelId}, localUid: ${conn.localUid}');
          if (mounted) {
            setState(() => _joined = true);
          }
          _isJoining = false;
          try { _engine?.setEnableSpeakerphone(_speakerOn); } catch (_) {}
          try { _engine?.adjustRecordingSignalVolume(100); } catch (_) {}
          try { _engine?.adjustPlaybackSignalVolume(100); } catch (_) {}
        },
        onUserJoined: (RtcConnection conn, int remoteUid, int elapsed) {
          debugPrint('Agora: Remote user JOINED - uid: $remoteUid');
          if (mounted) {
            setState(() => _remoteUids.add(remoteUid));
            if (widget.isGroupCall || _currentSessionStatus == 'accepted') {
              _onCallConnected();
            }
          }
          try {
            _engine?.muteRemoteAudioStream(uid: remoteUid, mute: false);
            _engine?.muteRemoteVideoStream(uid: remoteUid, mute: false);
            _engine?.adjustUserPlaybackSignalVolume(uid: remoteUid, volume: 100);
            _engine?.muteAllRemoteAudioStreams(false);
            _engine?.muteAllRemoteVideoStreams(false);
          } catch (_) {}
        },
        onAudioVolumeIndication: (RtcConnection conn, List<AudioVolumeInfo> speakers, int totalVolume, int speakerNumber) {
          for (final s in speakers) {
            if (s.volume != null && s.volume! > 5) {
              debugPrint('Agora Audio Activity: uid=${s.uid}, volume=${s.volume}');
            }
          }
        },
        onUserOffline: (RtcConnection conn, int remoteUid, UserOfflineReasonType reason) {
          debugPrint('Agora: Remote user OFFLINE - uid: $remoteUid, reason: $reason');
          if (mounted) {
            setState(() => _remoteUids.remove(remoteUid));
          }
        },
        onTokenPrivilegeWillExpire: (RtcConnection conn, String token) async {
          try {
            final newToken = await AgoraTokenService.fetchRtcToken(channelName: widget.channelName, uid: _localUid);
            if (_engine != null) await _engine!.renewToken(newToken);
          } catch (_) {}
        },
        onError: (ErrorCodeType err, String msg) {
          debugPrint('Agora ERROR: $err - $msg');
        },
      ));

      try { await _engine!.enableAudio(); } catch (_) {}
      try { await _engine!.enableLocalAudio(true); } catch (_) {}
      try { await _engine!.setAudioProfile(profile: AudioProfileType.audioProfileDefault, scenario: AudioScenarioType.audioScenarioDefault); } catch (_) {}
      try { await _engine!.setDefaultAudioRouteToSpeakerphone(true); } catch (_) {}
      try { await _engine!.adjustRecordingSignalVolume(100); } catch (_) {}
      try { await _engine!.adjustPlaybackSignalVolume(100); } catch (_) {}
      try { await _engine!.enableAudioVolumeIndication(interval: 300, smooth: 3, reportVad: true); } catch (_) {}

      if (widget.video) {
        await _engine!.enableVideo();
        await _engine!.enableLocalVideo(true);
        try { await _engine!.startPreview(); } catch (_) {}
      } else {
        await _engine!.disableVideo();
      }

      _engineInitialized = true;
    } catch (e) {
      debugPrint('Agora engine init error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to initialize Agora: $e')),
        );
      }
      return;
    }

    try {
      _token = await AgoraTokenService.fetchRtcToken(channelName: widget.channelName, uid: _localUid);
    } catch (e) {
      debugPrint('Agora: Token fetch FAILED: $e');
    }

    if (_shouldJoinAfterInit && !_joined && !_isJoining) {
      _shouldJoinAfterInit = false;
      await _joinChannel();
    } else if (_isCaller && !_joined && !_isJoining) {
      debugPrint('Agora: Caller pre-joining channel...');
      await _joinChannel();
    }
  }

  Future<void> _joinChannel() async {
    if (_joined || _isJoining) return;
    _isJoining = true;

    final tokenToUse = _token ?? '';

    if (kIsWeb) {
      if (_webClient != null && _engineInitialized) {
        try {
          await _webClient!.joinChannel(
            token: tokenToUse,
            channelName: widget.channelName,
            uid: _localUid,
            enableVideo: widget.video,
          );
          if (mounted) setState(() => _joined = true);
          _isJoining = false;
        } catch (e) {
          debugPrint('AgoraWeb join error: $e');
          _isJoining = false;
        }
      } else {
        _isJoining = false;
      }
    } else {
      if (_engine != null && _engineInitialized) {
        try {
          try { await _engine!.enableAudio(); } catch (_) {}
          try { await _engine!.enableLocalAudio(true); } catch (_) {}
          try { await _engine!.setDefaultAudioRouteToSpeakerphone(true); } catch (_) {}
          try { await _engine!.muteLocalAudioStream(_muted); } catch (_) {}
          try { await _engine!.adjustRecordingSignalVolume(100); } catch (_) {}
          try { await _engine!.adjustPlaybackSignalVolume(100); } catch (_) {}
          await _engine!.joinChannel(
            token: tokenToUse,
            channelId: widget.channelName,
            uid: _localUid,
            options: ChannelMediaOptions(
              channelProfile: ChannelProfileType.channelProfileCommunication,
              clientRoleType: ClientRoleType.clientRoleBroadcaster,
              publishMicrophoneTrack: true,
              publishCameraTrack: widget.video,
              autoSubscribeAudio: true,
              autoSubscribeVideo: widget.video,
              enableAudioRecordingOrPlayout: true,
            ),
          );
        } catch (e) {
          debugPrint('Agora native join error: $e');
          _isJoining = false;
        }
      } else {
        _isJoining = false;
      }
    }
  }

  Future<void> _leaveChannel() async {
    if (!_joined) return;
    if (kIsWeb) {
      try { await _webClient?.leaveChannel(); } catch (_) {}
    } else {
      try { await _engine?.leaveChannel(); } catch (_) {}
    }
    if (mounted) {
      setState(() {
        _joined = false;
        _remoteUids.clear();
      });
    }
  }

  void _startRingingTimeout() {
    _ringingTimeoutTimer?.cancel();
    _ringingTimeoutTimer = Timer(const Duration(seconds: 45), () async {
      if (!_isCallConnected && mounted) {
        debugPrint('Call timed out after 45s (no answer)');
        final id = widget.callSessionId;
        if (id != null) {
          try {
            await FirebaseFirestore.instance.collection('call_sessions').doc(id).update({
              'status': 'missed',
              'ended_at': DateTime.now().millisecondsSinceEpoch,
            });
          } catch (_) {}
        }
        _terminateCall('No answer');
      }
    });
  }

  Future<void> _playOutgoingRingtone() async {
    try {
      await NotificationService.instance.playOutgoingRingtone();
    } catch (_) {}
  }

  Future<void> _stopOutgoingRingtone() async {
    try {
      await NotificationService.instance.stopOutgoingRingtone();
    } catch (_) {}
  }

  void _attachCallSessionListener() {
    final id = widget.callSessionId;
    if (widget.isGroupCall) {
      _isCaller = false;
      _onCallConnected();
      if (_engineInitialized && !_joined && !_isJoining) {
        _joinChannel();
      } else {
        _shouldJoinAfterInit = true;
      }
      return;
    }

    if (id == null) {
      // Direct call without session tracking (fallback)
      _playOutgoingRingtone();
      _startRingingTimeout();
      return;
    }

    // Check initial state
    FirebaseFirestore.instance.collection('call_sessions').doc(id).get().then((doc) async {
      if (!doc.exists) return;
      final data = doc.data() ?? {};
      final status = data['status'] as String?;
      final uid = firebase_auth.FirebaseAuth.instance.currentUser?.uid;

      _currentSessionStatus = status;
      if (uid != null && data['caller_id'] is String) {
        final isMeCaller = (data['caller_id'] == uid);
        if (mounted) {
          setState(() {
            _isCaller = isMeCaller;
          });
        } else {
          _isCaller = isMeCaller;
        }

        if (_isCaller && status == 'ringing') {
          _playOutgoingRingtone();
          _startRingingTimeout();
        } else if (!_isCaller && status == 'ringing') {
          try {
            await doc.reference.set({
              'status': 'accepted',
              'accepted_at': DateTime.now().millisecondsSinceEpoch,
            }, SetOptions(merge: true));
          } catch (_) {}
        }
      }

      debugPrint('Initial call session status: $status, isCaller: $_isCaller');

      // If receiver opened the page, or status is already accepted
      if (status == 'accepted' || !_isCaller) {
        _onCallConnected();
        if (_engineInitialized && !_joined && !_isJoining) {
          await _joinChannel();
        } else {
          _shouldJoinAfterInit = true;
        }
      }
    });

    // Real-time status listener
    _callSessionSub = FirebaseFirestore.instance.collection('call_sessions').doc(id).snapshots().listen((doc) async {
      if (!doc.exists) {
        // Session deleted by caller/server
        debugPrint('Call session document deleted - ending call');
        _terminateCall('Call ended');
        return;
      }

      final data = doc.data() ?? {};
      final status = data['status'] as String?;
      final uid = firebase_auth.FirebaseAuth.instance.currentUser?.uid;

      _currentSessionStatus = status;
      if (uid != null && data['caller_id'] is String) {
        final newIsCaller = (data['caller_id'] == uid);
        if (_isCaller != newIsCaller && mounted) {
          setState(() {
            _isCaller = newIsCaller;
          });
        } else {
          _isCaller = newIsCaller;
        }
      }

      debugPrint('Call session status update: $status, isCaller: $_isCaller');

      if (_terminalReason != null) return;

      if (status == 'accepted') {
        // Receiver accepted! Start talking session and timer immediately
        _onCallConnected();
        if (!_joined && !_isJoining && _engineInitialized) {
          await _joinChannel();
        } else if (!_engineInitialized) {
          _shouldJoinAfterInit = true;
        }
      } else if (status == 'rejected') {
        debugPrint('Call rejected by receiver - closing caller screen immediately');
        _terminateCall('Call declined');
      } else if (status == 'cancelled') {
        debugPrint('Call cancelled by caller - closing receiver screen immediately');
        _terminateCall('Call cancelled');
      } else if (status == 'ended') {
        debugPrint('Call ended');
        _terminateCall('Call ended');
      } else if (status == 'missed') {
        _terminateCall('Missed call');
      }
    });
  }

  void _onCallConnected() {
    if (_isCallConnected) return;
    debugPrint('=== CALL CONNECTED - Transitioning to Talking Screen & Starting Timer ===');
    _stopOutgoingRingtone();
    _ringingTimeoutTimer?.cancel();
    setState(() {
      _isCallConnected = true;
    });
    _startElapsedTimer();
    _startCallForeground();

    // Ensure audio routes and video streams are active
    if (!kIsWeb && _engine != null) {
      try { _engine!.enableAudio(); } catch (_) {}
      try { _engine!.enableLocalAudio(true); } catch (_) {}
      try { _engine!.muteLocalAudioStream(_muted); } catch (_) {}
      try { _engine!.setEnableSpeakerphone(_speakerOn); } catch (_) {}
      try { _engine!.adjustRecordingSignalVolume(100); } catch (_) {}
      try { _engine!.adjustPlaybackSignalVolume(100); } catch (_) {}
      try { _engine!.muteAllRemoteAudioStreams(false); } catch (_) {}
      if (widget.video) {
        try {
          _engine!.enableVideo();
          _engine!.enableLocalVideo(true);
        } catch (_) {}
      }
    }
  }

  void _terminateCall(String reason) {
    if (_terminalReason != null) return;
    _terminalReason = reason;
    _stopOutgoingRingtone();
    _ringingTimeoutTimer?.cancel();
    _timer?.cancel();
    _leaveChannel();
    _stopCallForeground();
    if (mounted) {
      setState(() {});
      // Close screen immediately
      Navigator.pop(context);
      if (reason.isNotEmpty && reason != 'Call ended') {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(reason),
            duration: const Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  void _startElapsedTimer() {
    _timer?.cancel();
    _callStart = DateTime.now();
    _elapsed = Duration.zero;
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_callStart != null && mounted) {
        setState(() {
          _elapsed = DateTime.now().difference(_callStart!);
        });
      }
    });
  }

  static const MethodChannel _appChannel = MethodChannel('com.example.myapp/app');
  Future<void> _startCallForeground() async {
    if (kIsWeb) return;
    final title = widget.video ? 'Video call' : 'Audio call';
    final name = _remoteUserData?['name'] ?? widget.remoteUserId ?? '';
    final text = name.isNotEmpty ? 'Talking with $name' : '';
    try {
      await _appChannel.invokeMethod('startCallForeground', {
        'title': title,
        'text': text,
        'video': widget.video,
      });
    } catch (_) {}
  }

  Future<void> _stopCallForeground() async {
    if (kIsWeb) return;
    try { await _appChannel.invokeMethod('stopCallForeground'); } catch (_) {}
  }

  Future<void> _cancelOrEndCall() async {
    final id = widget.callSessionId;
    final uid = firebase_auth.FirebaseAuth.instance.currentUser?.uid;
    _stopOutgoingRingtone();
    _ringingTimeoutTimer?.cancel();
    if (id != null) {
      try {
        final statusToSet = _isCallConnected ? 'ended' : 'cancelled';
        final updates = <String, dynamic>{
          'status': statusToSet,
          'ended_at': DateTime.now().millisecondsSinceEpoch,
        };
        if (uid != null) updates['ended_by'] = uid;
        await FirebaseFirestore.instance.collection('call_sessions').doc(id).update(updates);
      } catch (_) {}
    }
    _terminateCall(_isCallConnected ? 'Call ended' : 'Call cancelled');
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _stopOutgoingRingtone();
    _ringingTimeoutTimer?.cancel();
    _timer?.cancel();
    _callSessionSub?.cancel();
    if (kIsWeb) {
      if (_webClient != null) {
        try { _webClient!.leaveChannel(); } catch (_) {}
        _webClient!.dispose();
      }
    } else {
      if (_engine != null && _engineInitialized) {
        try { _engine!.leaveChannel(); } catch (_) {}
        try { _engine!.release(); } catch (_) {}
      }
      _stopCallForeground();
    }
    super.dispose();
  }

  String _formatElapsed() {
    final d = _elapsed;
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    // If not connected yet and caller -> show dedicated Calling Screen (Receiver Avatar, Name, "Calling...", Cancel button)
    final isCallingPhase = !_isCallConnected && _isCaller;

    return Scaffold(
      backgroundColor: const Color(0xFF0F1117),
      body: SafeArea(
        child: isCallingPhase
            ? _buildCallingScreen()
            : _buildTalkingScreen(),
      ),
    );
  }

  /// Calling Screen: Shown to the caller while waiting for the receiver to answer
  Widget _buildCallingScreen() {
    final name = _remoteUserData?['name'] ?? widget.remoteUserId ?? 'User';
    final avatarUrl = _remoteUserData?['profile_image'];

    return Stack(
      children: [
        // Background subtle gradient
        Positioned.fill(
          child: Container(
            decoration: const BoxDecoration(
              gradient: RadialGradient(
                center: Alignment(0, -0.25),
                radius: 1.2,
                colors: [Color(0xFF1E2638), Color(0xFF0A0D14)],
              ),
            ),
          ),
        ),
        Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Pulsing Avatar with glow rings
              ScaleTransition(
                scale: _pulseAnimation,
                child: Container(
                  width: 140,
                  height: 140,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: (widget.video ? Colors.purpleAccent : Colors.greenAccent).withOpacity(0.6),
                      width: 3,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: (widget.video ? Colors.purpleAccent : Colors.greenAccent).withOpacity(0.35),
                        blurRadius: 36,
                        spreadRadius: 8,
                      ),
                    ],
                  ),
                  child: ClipOval(
                    child: (avatarUrl is String && avatarUrl.isNotEmpty)
                        ? Image.network(avatarUrl, fit: BoxFit.cover)
                        : Container(
                            color: const Color(0xFF2A3447),
                            alignment: Alignment.center,
                            child: Text(
                              name.isNotEmpty ? name[0].toUpperCase() : '?',
                              style: const TextStyle(fontSize: 52, color: Colors.white, fontWeight: FontWeight.bold),
                            ),
                          ),
                  ),
                ),
              ),
              const SizedBox(height: 32),
              // Receiver Name
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Text(
                  name,
                  style: const TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.bold),
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(height: 12),
              // Calling / Ringing status badge
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: Colors.white12, width: 1),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      widget.video ? Icons.videocam : Icons.call,
                      size: 16,
                      color: widget.video ? Colors.purpleAccent : Colors.greenAccent,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      widget.video ? 'Calling (Video)...' : 'Ringing...',
                      style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w500, letterSpacing: 0.5),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        // Bottom Cancel Button
        Positioned(
          left: 0,
          right: 0,
          bottom: 48,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              InkWell(
                onTap: _cancelOrEndCall,
                borderRadius: BorderRadius.circular(40),
                child: Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    color: Colors.redAccent.shade700,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: Colors.redAccent.withOpacity(0.45),
                        blurRadius: 18,
                        spreadRadius: 3,
                      ),
                    ],
                  ),
                  child: const Icon(Icons.call_end, color: Colors.white, size: 36),
                ),
              ),
              const SizedBox(height: 12),
              const Text('Cancel', style: TextStyle(color: Colors.white70, fontSize: 14, fontWeight: FontWeight.w500)),
            ],
          ),
        ),
      ],
    );
  }

  /// Talking Screen: Shown once receiver accepts the call and talking session begins
  Widget _buildTalkingScreen() {
    return Stack(
      children: [
        Positioned.fill(
          child: Column(
            children: [
              Expanded(
                child: widget.video ? _buildVideoViews() : _buildAudioTalkingView(),
              ),
              const SizedBox(height: 90),
            ],
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: _buildControls(),
        ),
      ],
    );
  }

  Widget _buildAudioTalkingView() {
    final name = _remoteUserData?['name'] ?? widget.remoteUserId ?? 'User';
    final avatarUrl = _remoteUserData?['profile_image'];
    final elapsedStr = _formatElapsed();

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 120,
            height: 120,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: Colors.greenAccent.withOpacity(0.6), width: 3),
              boxShadow: [
                BoxShadow(
                  color: Colors.greenAccent.withOpacity(0.15),
                  blurRadius: 24,
                  spreadRadius: 4,
                ),
              ],
            ),
            child: ClipOval(
              child: (avatarUrl is String && avatarUrl.isNotEmpty)
                  ? Image.network(avatarUrl, fit: BoxFit.cover)
                  : Container(
                      color: const Color(0xFF2A3447),
                      alignment: Alignment.center,
                      child: Text(
                        name.isNotEmpty ? name[0].toUpperCase() : '?',
                        style: const TextStyle(fontSize: 44, color: Colors.white, fontWeight: FontWeight.bold),
                      ),
                    ),
            ),
          ),
          const SizedBox(height: 20),
          Text(
            name,
            style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 10),
          // Talking duration count
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.white10,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              elapsedStr,
              style: const TextStyle(color: Colors.greenAccent, fontSize: 16, fontWeight: FontWeight.w600, letterSpacing: 1),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildVideoViews() {
    if (kIsWeb) {
      if (!_videoEnabled && _remoteUserData != null) {
        final profileUrl = _remoteUserData!['profile_image'] as String?;
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircleAvatar(
                radius: 64,
                backgroundImage: profileUrl != null && profileUrl.isNotEmpty ? NetworkImage(profileUrl) : null,
                child: profileUrl == null || profileUrl.isEmpty ? const Icon(Icons.person, size: 64, color: Colors.white) : null,
              ),
              const SizedBox(height: 16),
              Text(_remoteUserData!['name'] ?? 'User', style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold)),
              const SizedBox(height: 6),
              Text(_formatElapsed(), style: const TextStyle(color: Colors.greenAccent, fontSize: 16)),
            ],
          ),
        );
      }
      return Container(color: Colors.transparent);
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final maxW = constraints.maxWidth;
        final maxH = constraints.maxHeight;
        const pipW = 120.0;
        const pipH = 160.0;
        _pipOffset ??= Offset(maxW - pipW - 12, maxH - pipH - 12);

        int? primaryRemoteUid = _remoteUids.isNotEmpty ? _remoteUids.first : null;

        Widget buildRemoteFull() {
          if (primaryRemoteUid == null || _engine == null) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(color: Colors.white70),
                  const SizedBox(height: 16),
                  Text('Connecting with ${_remoteUserData?['name'] ?? 'User'}...', style: const TextStyle(color: Colors.white70)),
                ],
              ),
            );
          }
          return ClipRect(
            child: FittedBox(
              fit: BoxFit.cover,
              child: SizedBox(
                width: maxW,
                height: maxH,
                child: AgoraVideoView(
                  controller: VideoViewController.remote(
                    rtcEngine: _engine!,
                    canvas: VideoCanvas(uid: primaryRemoteUid),
                    connection: RtcConnection(channelId: widget.channelName),
                  ),
                ),
              ),
            ),
          );
        }

        Widget buildLocalFull() {
          if (_engine == null) {
            return const Center(child: Text('Local preview unavailable', style: TextStyle(color: Colors.white70)));
          }
          return ClipRect(
            child: FittedBox(
              fit: BoxFit.cover,
              child: SizedBox(
                width: maxW,
                height: maxH,
                child: AgoraVideoView(
                  controller: VideoViewController(
                    rtcEngine: _engine!,
                    canvas: const VideoCanvas(uid: 0),
                  ),
                ),
              ),
            ),
          );
        }

        Widget buildLocalPip() {
          return Container(
            decoration: BoxDecoration(
              color: Colors.black54,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.white24, width: 1),
              boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 6)],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: _engine == null
                  ? const ColoredBox(color: Colors.black54)
                  : AgoraVideoView(
                      controller: VideoViewController(
                        rtcEngine: _engine!,
                        canvas: const VideoCanvas(uid: 0),
                      ),
                    ),
            ),
          );
        }

        Widget buildRemotePip() {
          if (primaryRemoteUid == null || _engine == null) {
            return const ColoredBox(color: Colors.black54);
          }
          return Container(
            decoration: BoxDecoration(
              color: Colors.black54,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.white24, width: 1),
              boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 6)],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: AgoraVideoView(
                controller: VideoViewController.remote(
                  rtcEngine: _engine!,
                  canvas: VideoCanvas(uid: primaryRemoteUid),
                  connection: RtcConnection(channelId: widget.channelName),
                ),
              ),
            ),
          );
        }

        return Stack(
          children: [
            Positioned.fill(child: _showLocalFull ? buildLocalFull() : buildRemoteFull()),
            // Top duration badge
            Positioned(
              top: 16,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Text(
                    _formatElapsed(),
                    style: const TextStyle(color: Colors.greenAccent, fontSize: 14, fontWeight: FontWeight.bold),
                  ),
                ),
              ),
            ),
            Positioned(
              left: _pipOffset!.dx,
              top: _pipOffset!.dy,
              width: pipW,
              height: pipH,
              child: GestureDetector(
                onTap: () => setState(() => _showLocalFull = !_showLocalFull),
                onPanUpdate: (details) {
                  final dx = (_pipOffset!.dx + details.delta.dx).clamp(0.0, maxW - pipW);
                  final dy = (_pipOffset!.dy + details.delta.dy).clamp(0.0, maxH - pipH);
                  setState(() => _pipOffset = Offset(dx, dy));
                },
                child: _showLocalFull ? buildRemotePip() : buildLocalPip(),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildControls() {
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF141822),
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 24),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          // Mute Mic
          CircleAvatar(
            radius: 26,
            backgroundColor: _muted ? Colors.redAccent : const Color(0xFF2A3447),
            child: IconButton(
              icon: Icon(_muted ? Icons.mic_off : Icons.mic, color: Colors.white),
              onPressed: () async {
                setState(() => _muted = !_muted);
                if (kIsWeb) {
                  if (_webClient != null) await _webClient!.muteLocalAudio(_muted);
                } else {
                  if (_engine != null) await _engine!.muteLocalAudioStream(_muted);
                }
              },
            ),
          ),
          // Switch Camera (for video on mobile)
          if (widget.video && !kIsWeb)
            CircleAvatar(
              radius: 26,
              backgroundColor: const Color(0xFF2A3447),
              child: IconButton(
                icon: const Icon(Icons.switch_camera, color: Colors.white),
                onPressed: () async {
                  _frontCamera = !_frontCamera;
                  if (_engine != null) await _engine!.switchCamera();
                },
              ),
            ),
          // Toggle Video
          if (widget.video)
            CircleAvatar(
              radius: 26,
              backgroundColor: _videoEnabled ? const Color(0xFF2A3447) : Colors.redAccent,
              child: IconButton(
                icon: Icon(_videoEnabled ? Icons.videocam : Icons.videocam_off, color: Colors.white),
                onPressed: () async {
                  setState(() => _videoEnabled = !_videoEnabled);
                  if (kIsWeb) {
                    if (_webClient != null) await _webClient!.enableLocalVideo(_videoEnabled);
                  } else {
                    if (_engine != null) await _engine!.enableLocalVideo(_videoEnabled);
                  }
                },
              ),
            ),
          // Speaker toggle (mobile)
          if (!kIsWeb)
            CircleAvatar(
              radius: 26,
              backgroundColor: const Color(0xFF2A3447),
              child: IconButton(
                icon: Icon(_speakerOn ? Icons.volume_up : Icons.hearing, color: Colors.white),
                onPressed: () async {
                  _speakerOn = !_speakerOn;
                  if (_engine != null) await _engine!.setEnableSpeakerphone(_speakerOn);
                  setState(() {});
                },
              ),
            ),
          // End Call button (Red)
          CircleAvatar(
            radius: 28,
            backgroundColor: Colors.redAccent.shade700,
            child: IconButton(
              icon: const Icon(Icons.call_end, color: Colors.white, size: 28),
              onPressed: _cancelOrEndCall,
            ),
          ),
        ],
      ),
    );
  }
}
