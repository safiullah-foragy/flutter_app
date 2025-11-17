import 'dart:math';
import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:permission_handler/permission_handler.dart';
import 'agora_config.dart';
import 'agora_token_service.dart';
import 'package:flutter/services.dart';

class CallPage extends StatefulWidget {
  final String channelName; // e.g., conv_<conversationId>
  final bool video; // true = video call, false = audio-only call
  final String? conversationId; // extracted from channelName or passed explicitly
  final String? remoteUserId; // for displaying avatar/name
  const CallPage({super.key, required this.channelName, required this.video, this.conversationId, this.remoteUserId});

  static Route route({required String channelName, required bool video, String? conversationId, String? remoteUserId}) =>
      MaterialPageRoute(builder: (_) => CallPage(channelName: channelName, video: video, conversationId: conversationId, remoteUserId: remoteUserId));

  @override
  State<CallPage> createState() => _CallPageState();
}

class _CallPageState extends State<CallPage> {
  RtcEngine? _engine;
  String? _token;
  int _localUid = 0;
  final Set<int> _remoteUids = {};
  bool _joined = false;
  bool _muted = false;
  bool _speakerOn = true;
  bool _frontCamera = true;
  bool _engineInitialized = false;
  DateTime? _callStart;
  Duration _elapsed = Duration.zero;
  Timer? _timer;
  Map<String, dynamic>? _remoteUserData; // name, profile_image

  @override
  void initState() {
    super.initState();
    _init();
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

    // Ask for mic/camera permissions as needed
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

    // Pick a random UID per session to avoid collisions
    _localUid = Random().nextInt(0x7FFFFFFF);

    try {
      // Create engine
      _engine = createAgoraRtcEngine();
      await _engine!.initialize(RtcEngineContext(appId: AgoraConfig.appId));

      // Basic event handlers
      if (_engine != null) {
        _engine!.registerEventHandler(RtcEngineEventHandler(
      onJoinChannelSuccess: (RtcConnection conn, int elapsed) {
        setState(() => _joined = true);
        _startElapsedTimer();
        _startCallForeground();
      },
      onUserJoined: (RtcConnection conn, int remoteUid, int elapsed) {
        setState(() => _remoteUids.add(remoteUid));
      },
      onUserOffline: (RtcConnection conn, int remoteUid, UserOfflineReasonType reason) {
        setState(() => _remoteUids.remove(remoteUid));
      },
      onTokenPrivilegeWillExpire: (RtcConnection conn, String token) async {
        try {
          final newToken = await AgoraTokenService.fetchRtcToken(channelName: widget.channelName, uid: _localUid);
          if (_engine != null) await _engine!.renewToken(newToken);
        } catch (_) {}
      },
    ));
      }

      if (_engine != null) {
        if (widget.video) {
          await _engine!.enableVideo();
          // Start local preview so the small window is not blank before join
          try { await _engine!.startPreview(); } catch (_) {}
        } else {
          await _engine!.disableVideo();
          await _engine!.enableAudio();
        }
      }

      _engineInitialized = true;
    } catch (e) {
      // Engine init failed (possible on web or missing native bindings). Surface a friendly message and abort join.
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Failed to initialize Agora engine: ${e.toString()}'),
        ));
      }
      return;
    }

    // Get token
    try {
      _token = await AgoraTokenService.fetchRtcToken(channelName: widget.channelName, uid: _localUid);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to fetch token: $e')));
      }
      return;
    }

    // Join channel
    if (_engine != null && _engineInitialized) {
      if (_token == null || _token!.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Missing Agora token — cannot join channel')));
        }
        return;
      }

      await _engine!.joinChannel(
        token: _token!,
        channelId: widget.channelName,
        uid: _localUid,
        options: const ChannelMediaOptions(
          channelProfile: ChannelProfileType.channelProfileCommunication,
          clientRoleType: ClientRoleType.clientRoleBroadcaster,
        ),
      );
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    // Only leave/release if engine initialized successfully. Avoid LateInitializationError.
    if (_engine != null && _engineInitialized) {
      try {
        _engine!.leaveChannel();
      } catch (_) {}
      try {
        _engine!.release();
      } catch (_) {}
    }
    _stopCallForeground();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.video ? 'Video Call' : 'Audio Call'),
      ),
      backgroundColor: Colors.black,
      body: Column(
        children: [
          Expanded(
            child: widget.video ? _buildVideoViews() : _buildAudioStatus(),
          ),
          _buildControls(),
        ],
      ),
    );
  }

  static const MethodChannel _appChannel = MethodChannel('com.example.myapp/app');
  Future<void> _startCallForeground() async {
    final title = widget.video ? 'Video call' : 'Audio call';
    final name = _remoteUserData?['name'] ?? widget.remoteUserId ?? '';
    final text = name.isNotEmpty ? 'Talking with $name' : '';
    try { await _appChannel.invokeMethod('startCallForeground', {'title': title, 'text': text, 'video': widget.video}); } catch (_) {}
  }
  Future<void> _stopCallForeground() async {
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

  Widget _buildVideoViews() {
    return Stack(
      children: [
        // Remote grid or placeholder
        Positioned.fill(
          child: _remoteUids.isEmpty
              ? const Center(child: Text('Waiting for the other user...', style: TextStyle(color: Colors.white38)))
              : GridView.count(
                  crossAxisCount: _remoteUids.length <= 1 ? 1 : 2,
                  children: _remoteUids.map((uid) {
                    if (_engine == null) {
                      return const Center(child: Text('Remote video unavailable'));
                    }
                    return AgoraVideoView(
                      controller: VideoViewController.remote(
                        rtcEngine: _engine!,
                        canvas: VideoCanvas(uid: uid),
                        connection: RtcConnection(channelId: widget.channelName),
                      ),
                    );
                  }).toList(),
                ),
        ),
        // Local preview small window in corner
        Positioned(
          right: 12,
          bottom: 12,
          width: 120,
          height: 160,
          child: Container(
            decoration: BoxDecoration(
              color: Colors.black54,
              borderRadius: BorderRadius.circular(8),
            ),
                child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: _engine == null
                    ? const Center(child: Text('Local preview unavailable'))
                    : AgoraVideoView(
                        controller: VideoViewController(
                          rtcEngine: _engine!,
                          canvas: const VideoCanvas(uid: 0),
                        ),
                      ),
              ),
          ),
        ),
      ],
    );
  }

  Widget _buildControls() {
    return Container(
      color: Colors.black,
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
                if (_engine != null) await _engine!.muteLocalAudioStream(_muted);
              },
            ),
          ),
          if (widget.video)
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
          CircleAvatar(
            backgroundColor: Colors.red,
            child: IconButton(
              icon: const Icon(Icons.call_end, color: Colors.white),
              onPressed: () => Navigator.pop(context),
            ),
          ),
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
