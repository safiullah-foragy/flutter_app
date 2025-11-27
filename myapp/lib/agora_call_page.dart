import 'dart:math';
import 'dart:async';
import 'dart:ui';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'agora_config.dart';
import 'agora_token_service.dart';
import 'agora_web_client.dart' if (dart.library.io) 'agora_web_client_stub.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:audioplayers/audioplayers.dart';

class CallPage extends StatefulWidget {
  final String channelName; // e.g., conv_<conversationId>
  final bool video; // true = video call, false = audio-only call
  final String? conversationId; // extracted from channelName or passed explicitly
  final String? remoteUserId; // for displaying avatar/name
  const CallPage({super.key, required this.channelName, required this.video, this.conversationId, this.remoteUserId, this.callSessionId});
  final String? callSessionId; // Firestore call_session document id for status tracking

      static Route route({required String channelName, required bool video, String? conversationId, String? remoteUserId, String? callSessionId}) =>
        MaterialPageRoute(builder: (_) => CallPage(channelName: channelName, video: video, conversationId: conversationId, remoteUserId: remoteUserId, callSessionId: callSessionId));

  @override
  State<CallPage> createState() => _CallPageState();
}

class _CallPageState extends State<CallPage> {
  RtcEngine? _engine;
  AgoraWebClient? _webClient; // For web platform
  String? _token;
  int _localUid = 0;
  final Set<int> _remoteUids = {};
  bool _joined = false;
  bool _muted = false;
  bool _speakerOn = true;
  bool _frontCamera = true;
  bool _videoEnabled = true; // Track if video is enabled
  bool _engineInitialized = false;
  DateTime? _callStart;
  Duration _elapsed = Duration.zero;
  Timer? _timer;
  Map<String, dynamic>? _remoteUserData; // name, profile_image
  StreamSubscription<DocumentSnapshot>? _callSessionSub;
  String? _terminalReason; // 'rejected','ended','missed'
  Timer? _outgoingToneTimer;
  AudioPlayer? _outgoingPlayer;
  bool _outgoingPlayerActive = false;
  bool _outgoingToneStarted = false;
  bool _isCaller = true;
  bool _isJoining = false; // Track if currently joining to prevent duplicate joins
  bool _shouldJoinAfterInit = false; // Track if we need to join after engine initialization completes
  // Video layout state
  Offset? _pipOffset; // position of PiP window
  bool _showLocalFull = false; // when true, show local full-screen and remote as PiP
  double _zoomLevel = 1.0; // Zoom level for video (1.0 = no zoom, 2.0 = 2x zoom)
  Offset _zoomOffset = Offset.zero; // Pan offset when zoomed
  bool _zoomEnabled = false; // Web: require click to enable zoom

  @override
  void initState() {
    super.initState();
    _init();
    _attachCallSessionListener();
  }

  Future<void> _init() async {
    // Validate channel name early to avoid bad token requests
    if (widget.channelName.trim().isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Call channel is empty. Please retry call.'),
        ));
      }
      return;
    }

    // Attempt to derive conversation ID if not provided (channel pattern conv_<id>)
    final convId = widget.conversationId ?? (widget.channelName.startsWith('conv_') ? widget.channelName.substring(5) : null);
    if (convId != null && widget.remoteUserId != null) {
      // Fetch remote user profile for avatar/name
      try {
        final doc = await FirebaseFirestore.instance.collection('users').doc(widget.remoteUserId!).get();
        if (doc.exists) _remoteUserData = doc.data();
      } catch (_) {}
    }
    if (AgoraConfig.appId == 'YOUR_AGORA_APP_ID_HERE' || AgoraConfig.appId.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Please set AGORA_APP_ID (agora_config.dart or --dart-define).'),
        ));
      }
      return;
    }

    // Pick a random UID per session to avoid collisions
    _localUid = Random().nextInt(0x7FFFFFFF);

    // Branch: Web vs Native initialization
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
      
      // Listen to user joined/left events
      _webClient!.onUserJoined.listen((remoteUid) {
        debugPrint('AgoraWeb: Remote user joined - uid: $remoteUid');
        setState(() {
          _remoteUids.add(remoteUid);
        });
        _startElapsedTimer();
      });

      _webClient!.onUserLeft.listen((remoteUid) {
        debugPrint('AgoraWeb: Remote user left - uid: $remoteUid');
        setState(() => _remoteUids.remove(remoteUid));
      });

      _engineInitialized = true;
      debugPrint('AgoraWeb: Web client initialized successfully');
    } catch (e) {
      debugPrint('AgoraWeb: Initialization error - $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Failed to initialize Agora Web: $e'),
        ));
      }
      return;
    }

    // Get token
    try {
      debugPrint('AgoraWeb: Fetching token for channel: ${widget.channelName}, uid: $_localUid');
      _token = await AgoraTokenService.fetchRtcToken(channelName: widget.channelName, uid: _localUid);
      debugPrint('AgoraWeb: Token fetched successfully');
    } catch (e) {
      debugPrint('AgoraWeb: Token fetch FAILED: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to fetch token: $e')));
      }
      return;
    }

    // Don't join channel yet - wait for call acceptance
    debugPrint('AgoraWeb: Initialization complete, waiting for call acceptance');
    
    // If we received 'accepted' before initialization, join now
    if (_shouldJoinAfterInit && !_joined && !_isJoining) {
      debugPrint('AgoraWeb: Performing deferred join after initialization...');
      _shouldJoinAfterInit = false;
      await _joinChannel();
    }
  }

  /// Initialize Agora for Native platforms (Android/iOS)
  Future<void> _initNative() async {
    // Ask for mic/camera permissions
    final micStatus = await Permission.microphone.request();
    if (!micStatus.isGranted) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Microphone permission denied')));
      }
      return;
    }
    if (widget.video) {
      final camStatus = await Permission.camera.request();
      if (!camStatus.isGranted) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Camera permission denied')));
        }
        return;
      }
    }

    try {
      // Create engine
      _engine = createAgoraRtcEngine();
      await _engine!.initialize(RtcEngineContext(
        appId: AgoraConfig.appId,
        channelProfile: ChannelProfileType.channelProfileCommunication,
      ));
      debugPrint('Agora: Engine initialized successfully');

      // Basic event handlers
      if (_engine != null) {
        _engine!.registerEventHandler(RtcEngineEventHandler(
      onJoinChannelSuccess: (RtcConnection conn, int elapsed) {
        debugPrint('Agora: Join channel SUCCESS - channel: ${conn.channelId}, localUid: ${conn.localUid}');
        setState(() => _joined = true);
        _isJoining = false;
        _startElapsedTimer();
        _startCallForeground();
      },
      onUserJoined: (RtcConnection conn, int remoteUid, int elapsed) {
        debugPrint('Agora: Remote user JOINED - uid: $remoteUid');
        setState(() => _remoteUids.add(remoteUid));
      },
      onUserOffline: (RtcConnection conn, int remoteUid, UserOfflineReasonType reason) {
        debugPrint('Agora: Remote user OFFLINE - uid: $remoteUid, reason: $reason');
        setState(() => _remoteUids.remove(remoteUid));
      },
      onTokenPrivilegeWillExpire: (RtcConnection conn, String token) async {
        debugPrint('Agora: Token will expire, renewing...');
        try {
          final newToken = await AgoraTokenService.fetchRtcToken(channelName: widget.channelName, uid: _localUid);
          if (_engine != null) await _engine!.renewToken(newToken);
        } catch (_) {}
      },
      onError: (ErrorCodeType err, String msg) {
        debugPrint('Agora ERROR: $err - $msg');
      },
    ));
      }

      if (_engine != null) {
        if (widget.video) {
          await _engine!.enableVideo();
          try { await _engine!.startPreview(); } catch (_) {}
        } else {
          await _engine!.disableVideo();
          await _engine!.enableAudio();
        }
      }

      _engineInitialized = true;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Failed to initialize Agora engine: ${e.toString()}'),
        ));
      }
      return;
    }

    // Get token
    try {
      debugPrint('Agora: Fetching token for channel: ${widget.channelName}, uid: $_localUid');
      _token = await AgoraTokenService.fetchRtcToken(channelName: widget.channelName, uid: _localUid);
      debugPrint('Agora: Token fetched successfully');
    } catch (e) {
      debugPrint('Agora: Token fetch FAILED: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to fetch token: $e')));
      }
      return;
    }

    // Don't join channel yet - wait for call acceptance
    debugPrint('Agora: Initialization complete, waiting for call acceptance');
    
    // If we received 'accepted' before initialization, join now
    if (_shouldJoinAfterInit && !_joined && !_isJoining) {
      debugPrint('Agora: Performing deferred join after initialization...');
      _shouldJoinAfterInit = false;
      await _joinChannel();
    }
  }

  // Join channel after call is accepted
  Future<void> _joinChannel() async {
    if (_joined || _isJoining) {
      debugPrint('AgoraWeb: Skipping join - already joined or joining (_joined=$_joined, _isJoining=$_isJoining)');
      return;
    }
    
    _isJoining = true;
    
    if (kIsWeb) {
      // Web join
      if (_webClient != null && _engineInitialized && _token != null) {
        try {
          debugPrint('AgoraWeb: Joining channel: ${widget.channelName}, uid: $_localUid, video: ${widget.video}');
          await _webClient!.joinChannel(
            token: _token!,
            channelName: widget.channelName,
            uid: _localUid,
            enableVideo: widget.video,
          );
          debugPrint('AgoraWeb: Join channel completed, setting _joined=true');
          setState(() => _joined = true);
          _isJoining = false;
          _startElapsedTimer();
          debugPrint('AgoraWeb: Joined channel successfully, _joined=$_joined');
        } catch (e) {
          debugPrint('AgoraWeb: Join channel error - $e');
          _isJoining = false;
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text('Failed to join channel: $e'),
            ));
          }
        }
      }
    } else {
      // Native join
      if (_engine != null && _engineInitialized) {
        if (_token == null || _token!.isEmpty) {
          debugPrint('Agora: Token is empty, cannot join');
          _isJoining = false;
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Missing Agora token — cannot join channel')));
          }
          return;
        }

        debugPrint('Agora: Joining channel: ${widget.channelName}, uid: $_localUid, video: ${widget.video}');
        await _engine!.joinChannel(
          token: _token!,
          channelId: widget.channelName,
          uid: _localUid,
          options: const ChannelMediaOptions(
            channelProfile: ChannelProfileType.channelProfileCommunication,
            clientRoleType: ClientRoleType.clientRoleBroadcaster,
          ),
        );
        // _isJoining will be reset in onJoinChannelSuccess callback
        debugPrint('Agora: joinChannel() called, waiting for onJoinChannelSuccess callback...');
      } else {
        _isJoining = false;
      }
    }
  }

  // Leave channel
  Future<void> _leaveChannel() async {
    if (!_joined) return;
    
    if (kIsWeb) {
      try {
        await _webClient?.leaveChannel();
        debugPrint('AgoraWeb: Left channel');
      } catch (e) {
        debugPrint('AgoraWeb: Error leaving channel: $e');
      }
    } else {
      try {
        await _engine?.leaveChannel();
        debugPrint('Agora: Left channel');
      } catch (e) {
        debugPrint('Agora: Error leaving channel: $e');
      }
    }
    
    if (mounted) {
      setState(() {
        _joined = false;
        _remoteUids.clear();
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _stopOutgoingTone();
    _callSessionSub?.cancel();
    
    // Clean up based on platform
    if (kIsWeb) {
      // Web cleanup
      if (_webClient != null) {
        try {
          _webClient!.leaveChannel();
        } catch (_) {}
        _webClient!.dispose();
      }
    } else {
      // Native cleanup
      if (_engine != null && _engineInitialized) {
        try {
          _engine!.leaveChannel();
        } catch (_) {}
        try {
          _engine!.release();
        } catch (_) {}
      }
      _stopCallForeground();
    }
    
    super.dispose();
  }

  void _attachCallSessionListener() {
    final id = widget.callSessionId;
    if (id == null) return;
    
    // First, check the current status immediately
    FirebaseFirestore.instance.collection('call_sessions').doc(id).get().then((doc) async {
      if (!doc.exists) return;
      final data = doc.data() ?? {};
      final status = data['status'] as String?;
      final uid = firebase_auth.FirebaseAuth.instance.currentUser?.uid;
      
      // Determine if we're the caller
      if (uid != null && data['caller_id'] is String) {
        _isCaller = (data['caller_id'] == uid);
      }
      
      debugPrint('Initial call session status: $status, isCaller: $_isCaller');
      
      // If already accepted when page opens (receiver case), join immediately
      if (status == 'accepted' && !_joined && _engineInitialized) {
        debugPrint('Call already accepted on page load, joining channel immediately...');
        await _joinChannel();
        return; // Don't start outgoing tone if already accepted
      }
      
      // Start outgoing tone for caller ONLY if still ringing (not if accepted)
      if (_isCaller && !_outgoingToneStarted && status == 'ringing') {
        debugPrint('Starting outgoing tone for caller...');
        _outgoingToneStarted = true;
        await _startOutgoingTone();
      }
    });
    
    // Then listen for status changes
    _callSessionSub = FirebaseFirestore.instance.collection('call_sessions').doc(id).snapshots().listen((doc) async {
      if (!doc.exists) {
        // Document deleted - treat as ended
        debugPrint('Call session deleted - ending call');
        _terminalReason ??= 'Call ended';
        _stopOutgoingTone();
        await _leaveChannel();
        if (mounted) {
          setState(() {});
          Future.delayed(const Duration(milliseconds: 500), () {
            if (mounted) Navigator.pop(context);
          });
        }
        return;
      }
      
      final data = doc.data() ?? {};
      final status = data['status'] as String?;
      final uid = firebase_auth.FirebaseAuth.instance.currentUser?.uid;
      
      // Determine if we're the caller
      if (uid != null && data['caller_id'] is String) {
        _isCaller = (data['caller_id'] == uid);
      }
      
      debugPrint('Call session status: $status, isCaller: $_isCaller, joined: $_joined, callStart: $_callStart, terminalReason: $_terminalReason');
      
      // If already in terminal state, ignore further updates
      if (_terminalReason != null) {
        debugPrint('Already in terminal state ($_terminalReason), ignoring status update');
        return;
      }
      
      // Start outgoing tone for caller only when ringing
      if (_isCaller && !_outgoingToneStarted && status == 'ringing') {
        _outgoingToneStarted = true;
        await _startOutgoingTone();
      }
      
      // When call is accepted, stop ringtone and join channel (caller & callee)
      if (status == 'accepted') {
        debugPrint('=== Call ACCEPTED - Stopping all ringtones ===');
        
        // CRITICAL: Stop outgoing tone IMMEDIATELY for caller
        _stopOutgoingTone();

        // For debugging: see which side is reacting
        debugPrint('Call accepted snapshot: isCaller=$_isCaller, joined=$_joined, isJoining=$_isJoining, engineInitialized=$_engineInitialized');

        // Join channel only after acceptance and only once, on both sides
        if (!_joined && !_isJoining && _engineInitialized) {
          debugPrint('Call accepted (isCaller=$_isCaller), joining channel NOW...');
          await _joinChannel();
        } else if (!_engineInitialized && !_joined && !_isJoining) {
          // Engine not ready yet, defer join until initialization completes
          debugPrint('Call accepted but engine not initialized yet, deferring join...');
          _shouldJoinAfterInit = true;
        } else {
          debugPrint('Call accepted but skipping join (_joined=$_joined, _isJoining=$_isJoining, _engineInitialized=$_engineInitialized)');
        }
      } else if (status == 'rejected') {
        debugPrint('Call rejected - closing immediately');
        _terminalReason = 'Call rejected';
        _stopOutgoingTone();
        await _leaveChannel();
        if (mounted) {
          setState(() {});
          Future.delayed(const Duration(milliseconds: 500), () {
            if (mounted) Navigator.pop(context);
          });
        }
      } else if (status == 'ended') {
        debugPrint('Call ended - closing immediately');
        _terminalReason = 'Call ended';
        _stopOutgoingTone();
        await _leaveChannel();
        if (mounted) {
          setState(() {});
          Future.delayed(const Duration(milliseconds: 500), () {
            if (mounted) Navigator.pop(context);
          });
        }
      } else if (status == 'missed') {
        debugPrint('Call missed - closing immediately');
        _terminalReason = 'Missed call';
        _stopOutgoingTone();
        await _leaveChannel();
        if (mounted) {
          setState(() {});
          Future.delayed(const Duration(milliseconds: 500), () {
            if (mounted) Navigator.pop(context);
          });
        }
      }
    });
  }

  Future<void> _startOutgoingTone() async {
    // Skip audio playback on web for now (asset loading issues)
    if (kIsWeb) return;
    
    // Respect Silent setting and selected ringtone from SharedPreferences; fallback to system beeps
    try {
      final prefs = await SharedPreferences.getInstance();
      final silent = prefs.getBool('ringtone_call_silent') ?? false;
      if (silent) return;

      String path = prefs.getString('ringtone_call') ?? '';
      if (path.isEmpty) {
        path = 'assets/mp3 file/Lovely-Alarm.mp3';
      }
      
      debugPrint('Starting outgoing tone with path: $path');
      
      // Ensure asset exists; if not, let it throw and we will fallback
      if (!kIsWeb) {
        await rootBundle.load(path);
        debugPrint('Asset loaded successfully');
      }

      _outgoingPlayer?.stop();
      await _outgoingPlayer?.dispose();
      _outgoingPlayer = AudioPlayer();
      
      // Configure audio context for outgoing call
      await _outgoingPlayer!.setAudioContext(AudioContext(
        android: const AudioContextAndroid(
          isSpeakerphoneOn: true,
          contentType: AndroidContentType.music,
          usageType: AndroidUsageType.notificationRingtone,
          audioFocus: AndroidAudioFocus.gain,
        ),
      ));
      
      await _outgoingPlayer!.setReleaseMode(ReleaseMode.loop);
      await _outgoingPlayer!.setVolume(1.0);
      
      // Strip 'assets/' prefix for AssetSource
      String strippedPath = path.replaceFirst('assets/', '');
      debugPrint('Playing outgoing tone: $strippedPath');
      
      // Start playing selected asset in loop
      await _outgoingPlayer!.play(AssetSource(strippedPath));
      _outgoingPlayerActive = true;
      debugPrint('Outgoing tone started successfully');
      return; // Success; skip fallback beeps
    } catch (e) {
      debugPrint('Error starting outgoing tone: $e');
      // Fallback to periodic system alert beeps
    }

    _outgoingToneTimer?.cancel();
    _outgoingToneTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
      if (_terminalReason != null || _joined) { _stopOutgoingTone(); return; }
      try { await SystemSound.play(SystemSoundType.alert); } catch (_) {}
    });
  }
  void _stopOutgoingTone() {
    _outgoingToneTimer?.cancel();
    _outgoingToneTimer = null;
    if (_outgoingPlayerActive) {
      try { _outgoingPlayer?.stop(); } catch (_) {}
      try { _outgoingPlayer?.dispose(); } catch (_) {}
      _outgoingPlayer = null;
      _outgoingPlayerActive = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.video ? 'Video Call' : 'Audio Call'),
      ),
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // Video or audio content
          Positioned.fill(
            child: Column(
              children: [
                Expanded(
                  child: widget.video ? _buildVideoViews() : _buildAudioStatus(),
                ),
                const SizedBox(height: 90), // Space for controls
              ],
            ),
          ),
          // Controls always on top (especially important for web)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _buildControls(),
          ),
        ],
      ),
    );
  }

  static const MethodChannel _appChannel = MethodChannel('com.example.myapp/app');
  Future<void> _startCallForeground() async {
    if (kIsWeb) return; // No foreground service on web
    // Android 15+ requires RECORD_AUDIO permission to be actively granted before starting FGS with microphone type
    if (!kIsWeb) {
      try {
        final status = await Permission.microphone.status;
        if (!status.isGranted) return; // Skip if permission not granted
      } catch (_) {
        return; // Permission check failed; skip service
      }
    }
    final title = widget.video ? 'Video call' : 'Audio call';
    final name = _remoteUserData?['name'] ?? widget.remoteUserId ?? '';
    final text = name.isNotEmpty ? 'Talking with $name' : '';
    try { await _appChannel.invokeMethod('startCallForeground', {'title': title, 'text': text, 'video': widget.video}); } catch (_) {}
  }
  Future<void> _stopCallForeground() async {
    if (kIsWeb) return; // No foreground service on web
    try { await _appChannel.invokeMethod('stopCallForeground'); } catch (_) {}
  }

  Widget _buildAudioStatus() {
    final name = _remoteUserData?['name'] ?? widget.remoteUserId ?? 'User';
    final avatarUrl = _remoteUserData?['profile_image'];
    final elapsedStr = _formatElapsed();
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircleAvatar(
            radius: 42,
            backgroundColor: Colors.blueGrey,
            backgroundImage: (avatarUrl is String && avatarUrl.isNotEmpty)
                ? NetworkImage(avatarUrl)
                : null,
            child: (avatarUrl is String && avatarUrl.isNotEmpty)
                ? null
                : Text(name.isNotEmpty ? name[0].toUpperCase() : '?', style: const TextStyle(fontSize: 28, color: Colors.white)),
          ),
          const SizedBox(height: 16),
            Text(
              _joined ? name : 'Calling...'
              ,style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w500),
            ),
          const SizedBox(height: 8),
          Text(
            _joined ? elapsedStr : 'Waiting for the other user...',
            style: const TextStyle(color: Colors.white70, fontSize: 14),
          ),
        ],
      ),
    );
  }

  Widget _buildZoomableVideo(Widget child) {
    return kIsWeb
        ? _buildWebZoomableVideo(child)
        : _buildMobileZoomableVideo(child);
  }

  // Web: Mouse wheel zoom (requires click first to enable)
  Widget _buildWebZoomableVideo(Widget child) {
    return MouseRegion(
      cursor: _zoomEnabled ? SystemMouseCursors.zoomIn : SystemMouseCursors.basic,
      child: GestureDetector(
        onTap: () {
          // Single tap to enable/disable zoom
          setState(() {
            _zoomEnabled = !_zoomEnabled;
            debugPrint('Web zoom ${_zoomEnabled ? "enabled" : "disabled"}');
          });
        },
        onDoubleTap: () {
          // Double tap to reset zoom
          setState(() {
            _zoomLevel = 1.0;
            _zoomOffset = Offset.zero;
            _zoomEnabled = false;
            debugPrint('Web zoom reset');
          });
        },
        child: Listener(
          onPointerSignal: (signal) {
            if (signal is PointerScrollEvent && _zoomEnabled) {
              setState(() {
                // Zoom in/out with mouse wheel (only if enabled)
                final delta = signal.scrollDelta.dy;
                if (delta < 0) {
                  // Scroll up = zoom in
                  _zoomLevel = (_zoomLevel + 0.2).clamp(1.0, 5.0);
                } else {
                  // Scroll down = zoom out
                  _zoomLevel = (_zoomLevel - 0.2).clamp(1.0, 5.0);
                }
                debugPrint('Web zoom level: $_zoomLevel');
              });
            }
          },
          child: ClipRect(
            child: OverflowBox(
              alignment: Alignment.center,
              child: Transform.scale(
                scale: _zoomLevel,
                alignment: Alignment.center,
                child: child,
              ),
            ),
          ),
        ),
      ),
    );
  }

  // Mobile: Pinch-to-zoom with two fingers
  Widget _buildMobileZoomableVideo(Widget child) {
    return GestureDetector(
      onScaleStart: (details) {
        // Store initial zoom level
      },
      onScaleUpdate: (details) {
        setState(() {
          // Update zoom level based on pinch gesture
          _zoomLevel = (details.scale * _zoomLevel).clamp(1.0, 5.0);
        });
      },
      onScaleEnd: (details) {
        // Optionally snap back if zoomed out too far
        if (_zoomLevel < 1.0) {
          setState(() {
            _zoomLevel = 1.0;
            _zoomOffset = Offset.zero;
          });
        }
      },
      onDoubleTap: () {
        // Double tap to reset zoom
        setState(() {
          _zoomLevel = 1.0;
          _zoomOffset = Offset.zero;
        });
      },
      child: Transform.scale(
        scale: _zoomLevel,
        child: Transform.translate(
          offset: _zoomOffset,
          child: child,
        ),
      ),
    );
  }

  Widget _buildVideoViews() {
    // On web, video is rendered in HTML containers, so we show Flutter overlay
    if (kIsWeb) {
      // If video is disabled, show profile picture overlay
      if (!_videoEnabled && _remoteUserData != null) {
        final profileUrl = _remoteUserData!['profile_image'] as String?;
        return Stack(
          children: [
            // Blurred background
            Positioned.fill(
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                child: Container(color: Colors.black.withOpacity(0.5)),
              ),
            ),
            // Profile picture in center
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircleAvatar(
                    radius: 80,
                    backgroundImage: profileUrl != null && profileUrl.isNotEmpty
                        ? NetworkImage(profileUrl)
                        : null,
                    child: profileUrl == null || profileUrl.isEmpty
                        ? const Icon(Icons.person, size: 80, color: Colors.white)
                        : null,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    _remoteUserData!['name'] ?? 'Unknown',
                    style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Video is off',
                    style: TextStyle(color: Colors.white70, fontSize: 16),
                  ),
                ],
              ),
            ),
          ],
        );
      }
      // Video containers are in HTML DOM, so just show a transparent container
      return Container(color: Colors.transparent);
    }
    
    // Picture-in-Picture with draggable local preview and tap-to-swap full-screen
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxW = constraints.maxWidth;
        final maxH = constraints.maxHeight;
        const pipW = 120.0;
        const pipH = 160.0;
        // Initialize PiP to bottom-right on first build where size is known
        _pipOffset ??= Offset(maxW - pipW - 12, maxH - pipH - 12);

        int? primaryRemoteUid = _remoteUids.isNotEmpty ? _remoteUids.first : null;

        Widget buildRemoteFull() {
          if (primaryRemoteUid == null) {
            return const Center(child: Text('Waiting for the other user...', style: TextStyle(color: Colors.white38)));
          }
          if (_engine == null) {
            return const Center(child: Text('Remote video unavailable', style: TextStyle(color: Colors.white70)));
          }
          // If remote video is disabled, show profile picture with blurred background
          if (!_videoEnabled && _remoteUserData != null) {
            final profileUrl = _remoteUserData!['profile_image'] as String?;
            return Stack(
              children: [
                // Blurred background
                Positioned.fill(
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                    child: Container(color: Colors.black.withOpacity(0.5)),
                  ),
                ),
                // Profile picture in center
                Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircleAvatar(
                        radius: 80,
                        backgroundImage: profileUrl != null && profileUrl.isNotEmpty
                            ? NetworkImage(profileUrl)
                            : null,
                        child: profileUrl == null || profileUrl.isEmpty
                            ? const Icon(Icons.person, size: 80, color: Colors.white)
                            : null,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        _remoteUserData!['name'] ?? 'Unknown',
                        style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Video is off',
                        style: TextStyle(color: Colors.white70, fontSize: 16),
                      ),
                    ],
                  ),
                ),
              ],
            );
          }
          // Fill screen: use FittedBox to cover while preserving aspect
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

        final mainView = _terminalReason != null
          ? Center(child: Text(_terminalReason!, style: const TextStyle(color: Colors.white, fontSize: 22)))
          : _buildZoomableVideo(_showLocalFull ? buildLocalFull() : buildRemoteFull());
        final pipView = (_terminalReason != null)
          ? const SizedBox.shrink()
          : (_showLocalFull ? buildRemotePip() : buildLocalPip());

        return Stack(
          children: [
            Positioned.fill(child: mainView),
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
                child: pipView,
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildControls() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.black,
        boxShadow: kIsWeb ? [
          const BoxShadow(
            color: Colors.black87,
            blurRadius: 10,
            offset: Offset(0, -2),
          )
        ] : null,
      ),
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 24),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          CircleAvatar(
            backgroundColor: _muted ? Colors.red : Colors.grey[800],
            child: IconButton(
              icon: Icon(_muted ? Icons.mic_off : Icons.mic, color: Colors.white),
              onPressed: () async {
                setState(() => _muted = !_muted);
                if (kIsWeb) {
                  // Web platform
                  if (_webClient != null) await _webClient!.muteLocalAudio(_muted);
                } else {
                  // Native platform
                  if (_engine != null) await _engine!.muteLocalAudioStream(_muted);
                }
              },
            ),
          ),
          if (widget.video && !kIsWeb)
            CircleAvatar(
              backgroundColor: Colors.grey[800],
              child: IconButton(
                icon: const Icon(Icons.switch_camera, color: Colors.white),
                  onPressed: () async {
                  _frontCamera = !_frontCamera;
                  if (_engine != null) await _engine!.switchCamera();
                },
              ),
            ),
          if (widget.video)
            CircleAvatar(
              backgroundColor: _videoEnabled ? Colors.grey[800] : Colors.red,
              child: IconButton(
                icon: Icon(_videoEnabled ? Icons.videocam : Icons.videocam_off, color: Colors.white),
                onPressed: () async {
                  setState(() => _videoEnabled = !_videoEnabled);
                  if (kIsWeb) {
                    // Web platform
                    if (_webClient != null) await _webClient!.enableLocalVideo(_videoEnabled);
                  } else {
                    // Native platform
                    if (_engine != null) {
                      if (_videoEnabled) {
                        await _engine!.enableLocalVideo(true);
                      } else {
                        await _engine!.enableLocalVideo(false);
                      }
                    }
                  }
                },
              ),
            ),
          CircleAvatar(
            backgroundColor: Colors.red,
            child: IconButton(
              icon: const Icon(Icons.call_end, color: Colors.white),
              onPressed: () async {
                try {
                  final id = widget.callSessionId;
                  if (id != null) {
                    final uid = firebase_auth.FirebaseAuth.instance.currentUser?.uid;
                    final updates = <String, dynamic>{
                      'status': 'ended',
                      'ended_at': DateTime.now().millisecondsSinceEpoch,
                    };
                    if (uid != null) updates['ended_by'] = uid;
                    await FirebaseFirestore.instance.collection('call_sessions').doc(id).update(updates);
                  }
                } catch (_) {}
                Navigator.pop(context);
              },
            ),
          ),
          if (!kIsWeb) // Speaker toggle only on mobile
            CircleAvatar(
              backgroundColor: Colors.grey[800],
              child: IconButton(
                icon: Icon(_speakerOn ? Icons.volume_up : Icons.hearing, color: Colors.white),
                  onPressed: () async {
                  _speakerOn = !_speakerOn;
                  if (_engine != null) await _engine!.setEnableSpeakerphone(_speakerOn);
                  setState(() {});
                },
              ),
            ),
        ],
      ),
    );
  }

  void _startElapsedTimer() {
    _callStart ??= DateTime.now();
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_callStart != null) {
        setState(() => _elapsed = DateTime.now().difference(_callStart!));
      }
    });
  }

  String _formatElapsed() {
    final d = _elapsed;
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }
}
