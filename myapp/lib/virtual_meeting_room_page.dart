import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' as fb_auth;
import 'package:permission_handler/permission_handler.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'livekit_config.dart';
import 'virtual_meeting_service.dart';

class VirtualMeetingRoomPage extends StatefulWidget {
  final String meetingId;
  final String roomName;
  final String meetingTitle;
  final bool isHost;

  const VirtualMeetingRoomPage({
    super.key,
    required this.meetingId,
    required this.roomName,
    required this.meetingTitle,
    this.isHost = false,
  });

  @override
  State<VirtualMeetingRoomPage> createState() => _VirtualMeetingRoomPageState();
}

class _VirtualMeetingRoomPageState extends State<VirtualMeetingRoomPage> {
  final fb_auth.FirebaseAuth _auth = fb_auth.FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  Room? _room;
  EventsListener<RoomEvent>? _listener;

  bool _isConnecting = true;
  bool _isMicEnabled = true;
  bool _isCameraEnabled = true;
  bool _isCreator = false;

  List<Participant> _participants = [];
  final List<String> _activeSpeakers = [];

  // Duration Timer
  int _durationSeconds = 0;
  Timer? _durationTimer;

  // In-Meeting Chat
  final List<Map<String, dynamic>> _chatMessages = [];
  final TextEditingController _chatController = TextEditingController();

  // Invite Search
  final TextEditingController _searchController = TextEditingController();
  List<Map<String, dynamic>> _searchResults = [];
  final List<Map<String, dynamic>> _selectedUsersToInvite = [];
  bool _isSearching = false;
  bool _isSendingInvites = false;

  @override
  void initState() {
    super.initState();
    _isCreator = widget.isHost;
    _fetchMeetingData();
    _connectToLiveKit();
  }

  @override
  void dispose() {
    _durationTimer?.cancel();
    _chatController.dispose();
    _searchController.dispose();
    _listener?.dispose();
    _room?.disconnect();
    _room?.dispose();
    super.dispose();
  }

  Future<void> _fetchMeetingData() async {
    final data = await VirtualMeetingService.instance.getMeeting(widget.meetingId);
    if (data != null && mounted) {
      final curUid = _auth.currentUser?.uid;
      final hostId = (data['host_id'] ?? data['caller_id'] ?? '').toString();
      setState(() {
        _isCreator = _isCreator || (curUid != null && curUid == hostId);
      });
    }
  }

  Future<void> _connectToLiveKit() async {
    setState(() => _isConnecting = true);

    try {
      // Request Camera & Microphone permissions
      try {
        await Permission.camera.request();
        await Permission.microphone.request();
      } catch (_) {}

      final user = _auth.currentUser;
      final identity = user?.uid ?? 'user_${DateTime.now().millisecondsSinceEpoch}';
      final userName = user?.displayName ?? user?.email?.split('@').first ?? 'Participant';

      // 1. Fetch JWT Token
      final token = await VirtualMeetingService.instance.getMeetingToken(
        roomName: widget.roomName,
        identity: identity,
        userName: userName,
        isPublisher: true,
      );

      if (token == null || token.isEmpty) {
        throw Exception('Failed to generate LiveKit meeting token');
      }

      // 2. Initialize Room
      final room = Room(
        roomOptions: const RoomOptions(
          adaptiveStream: true,
          dynacast: true,
        ),
      );
      _room = room;
      _listener = room.createListener();

      _setupRoomEventListeners();

      // 3. Connect to LiveKit Cloud
      await room.connect(LiveKitConfig.liveKitWsUrl, token);

      // 4. Enable Local Camera and Microphone
      await room.localParticipant?.setCameraEnabled(true);
      await room.localParticipant?.setMicrophoneEnabled(true);

      if (mounted) {
        setState(() {
          _isConnecting = false;
          _isMicEnabled = true;
          _isCameraEnabled = true;
          _syncParticipants();
        });

        _startDurationTimer();
      }
    } catch (e) {
      debugPrint('LiveKit meeting connect error: $e');
      if (mounted) {
        setState(() => _isConnecting = false);
        Fluttertoast.showToast(msg: 'Failed to connect: $e');
        Navigator.pop(context);
      }
    }
  }

  void _setupRoomEventListeners() {
    final listener = _listener;
    if (listener == null) return;

    listener.on<ParticipantConnectedEvent>((e) {
      Fluttertoast.showToast(msg: '${e.participant.name.isNotEmpty ? e.participant.name : 'A user'} joined the meeting');
      if (mounted) setState(() => _syncParticipants());
    });

    listener.on<ParticipantDisconnectedEvent>((e) {
      Fluttertoast.showToast(msg: '${e.participant.name.isNotEmpty ? e.participant.name : 'A user'} left');
      if (mounted) setState(() => _syncParticipants());
    });

    listener.on<TrackSubscribedEvent>((e) {
      if (mounted) setState(() => _syncParticipants());
    });

    listener.on<TrackUnsubscribedEvent>((e) {
      if (mounted) setState(() => _syncParticipants());
    });

    listener.on<TrackMutedEvent>((e) {
      if (mounted) setState(() {});
    });

    listener.on<TrackUnmutedEvent>((e) {
      if (mounted) setState(() {});
    });

    listener.on<ActiveSpeakersChangedEvent>((e) {
      if (mounted) {
        setState(() {
          _activeSpeakers.clear();
          _activeSpeakers.addAll(e.speakers.map((s) => s.identity));
        });
      }
    });

    // Control Packets & Chat Listener
    listener.on<DataReceivedEvent>((e) {
      try {
        final str = utf8.decode(e.data);
        final parsed = jsonDecode(str) as Map<String, dynamic>;

        // A: Meeting Ended by Creator
        if (parsed['type'] == 'meeting_ended') {
          Fluttertoast.showToast(msg: 'The meeting creator has ended this session for all.');
          _room?.disconnect();
          if (mounted) Navigator.pop(context);
          return;
        }

        // B: Removed by Creator
        if (parsed['type'] == 'remove_participant') {
          final curUid = _auth.currentUser?.uid ?? _room?.localParticipant?.identity;
          if (parsed['targetIdentity'] == curUid) {
            Fluttertoast.showToast(msg: 'You have been removed from the meeting by the creator.');
            _room?.disconnect();
            if (mounted) Navigator.pop(context);
            return;
          }
        }

        // C: Chat Message
        if (parsed['type'] == 'chat' && mounted) {
          setState(() {
            _chatMessages.add({
              'sender': parsed['sender'] ?? 'Someone',
              'text': parsed['text'] ?? '',
              'isSelf': false,
            });
          });
        }
      } catch (_) {}
    });

    listener.on<RoomDisconnectedEvent>((e) {
      if (mounted) {
        Fluttertoast.showToast(msg: 'Disconnected from meeting');
        Navigator.pop(context);
      }
    });
  }

  void _syncParticipants() {
    final room = _room;
    if (room == null) return;

    final List<Participant> list = [];
    if (room.localParticipant != null) {
      list.add(room.localParticipant!);
    }
    list.addAll(room.remoteParticipants.values);

    _participants = list;
  }

  void _startDurationTimer() {
    _durationTimer?.cancel();
    _durationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() => _durationSeconds++);
      }
    });
  }

  String _formatDuration(int totalSecs) {
    final m = totalSecs ~/ 60;
    final s = totalSecs % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  Future<void> _toggleMic() async {
    final local = _room?.localParticipant;
    if (local == null) return;
    final next = !_isMicEnabled;
    await local.setMicrophoneEnabled(next);
    setState(() => _isMicEnabled = next);
  }

  Future<void> _toggleCamera() async {
    final local = _room?.localParticipant;
    if (local == null) return;
    final next = !_isCameraEnabled;
    await local.setCameraEnabled(next);
    setState(() => _isCameraEnabled = next);
  }

  bool _isFrontCamera = true;

  Future<void> _switchCamera() async {
    final local = _room?.localParticipant;
    if (local == null) return;
    try {
      final camPub = local.videoTrackPublications.firstOrNull;
      final camTrack = camPub?.track;
      if (camTrack is LocalVideoTrack) {
        final nextPos = _isFrontCamera ? CameraPosition.back : CameraPosition.front;
        await camTrack.setCameraPosition(nextPos);
        setState(() => _isFrontCamera = !_isFrontCamera);
      }
    } catch (_) {}
  }

  // Creator Action: Remove Member from Meeting
  Future<void> _removeParticipant(Participant target) async {
    final name = target.name.isNotEmpty ? target.name : target.identity;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove Participant?'),
        content: Text('Are you sure you want to remove $name from the meeting?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    try {
      final kickPacket = utf8.encode(jsonEncode({
        'type': 'remove_participant',
        'targetIdentity': target.identity,
      }));
      await _room?.localParticipant?.publishData(kickPacket, reliable: true);

      await VirtualMeetingService.instance.removeMemberFromMeeting(widget.meetingId, target.identity);

      Fluttertoast.showToast(msg: 'Removed $name from the meeting');
    } catch (e) {
      Fluttertoast.showToast(msg: 'Failed to remove: $e');
    }
  }

  // Creator Action: End Meeting for All
  Future<void> _endMeetingForAll() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('End Meeting for Everyone?'),
        content: const Text('As creator, closing the meeting will disconnect all participants immediately.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('End for All'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    try {
      final endPacket = utf8.encode(jsonEncode({'type': 'meeting_ended'}));
      await _room?.localParticipant?.publishData(endPacket, reliable: true);
      await VirtualMeetingService.instance.endMeeting(widget.meetingId, widget.roomName);
      Fluttertoast.showToast(msg: 'Meeting ended');
    } catch (_) {}

    await _room?.disconnect();
    if (mounted) Navigator.pop(context);
  }

  void _leaveMeeting() async {
    await _room?.disconnect();
    if (mounted) Navigator.pop(context);
  }

  // Participants Bottom Sheet / Drawer
  void _showParticipantsSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.grey.shade900,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => StatefulBuilder(
        builder: (context, setSheetState) => Padding(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Participants (${_participants.length})',
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.grey),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: _participants.length,
                  separatorBuilder: (_, __) => const Divider(color: Colors.grey, height: 16),
                  itemBuilder: (context, idx) {
                    final p = _participants[idx];
                    final isSelf = p == _room?.localParticipant;
                    final displayName = p.name.isNotEmpty ? p.name : p.identity;

                    return Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            CircleAvatar(
                              radius: 18,
                              backgroundColor: Colors.purple.shade700,
                              child: Text(
                                displayName.isNotEmpty ? displayName[0].toUpperCase() : 'U',
                                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '$displayName ${isSelf ? '(You)' : ''}',
                                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
                                ),
                                Text(
                                  isSelf && _isCreator ? 'Creator & Host' : isSelf ? 'Joined' : 'Member',
                                  style: const TextStyle(color: Colors.grey, fontSize: 11),
                                ),
                              ],
                            ),
                          ],
                        ),
                        if (_isCreator && !isSelf)
                          ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.red.shade900,
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                            ),
                            onPressed: () {
                              Navigator.pop(ctx);
                              _removeParticipant(p);
                            },
                            icon: const Icon(Icons.person_remove_rounded, size: 14),
                            label: const Text('Remove', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                          ),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // Invite Contacts Dialog
  void _showInviteDialog() {
    _searchController.text = '';
    _searchResults = [];
    _selectedUsersToInvite.clear();

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: Colors.grey.shade900,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          title: const Row(
            children: [
              Icon(Icons.person_add_rounded, color: Colors.purpleAccent),
              SizedBox(width: 8),
              Text('Invite Contacts', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18)),
            ],
          ),
          content: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: _searchController,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                  decoration: InputDecoration(
                    hintText: 'Search user by name or email...',
                    hintStyle: const TextStyle(color: Colors.grey, fontSize: 12),
                    prefixIcon: const Icon(Icons.search, color: Colors.purpleAccent, size: 18),
                    filled: true,
                    fillColor: Colors.grey.shade800,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  ),
                  onChanged: (val) async {
                    if (val.trim().isEmpty) {
                      setDialogState(() => _searchResults = []);
                      return;
                    }
                    setDialogState(() => _isSearching = true);
                    try {
                      final snap = await _firestore.collection('users').limit(40).get();
                      final curUid = _auth.currentUser?.uid;
                      final list = snap.docs
                          .map((d) => {'id': d.id, ...d.data()})
                          .filter((u) => u['id'] != curUid)
                          .filter((u) =>
                              (u['name'] ?? '').toString().toLowerCase().contains(val.toLowerCase()) ||
                              (u['email'] ?? '').toString().toLowerCase().contains(val.toLowerCase()))
                          .take(6)
                          .toList();

                      setDialogState(() {
                        _searchResults = list;
                        _isSearching = false;
                      });
                    } catch (_) {
                      setDialogState(() => _isSearching = false);
                    }
                  },
                ),
                const SizedBox(height: 12),
                SizedBox(
                  height: 180,
                  child: _isSearching
                      ? const Center(child: CircularProgressIndicator())
                      : _searchResults.isEmpty
                          ? const Center(child: Text('Type a name to find users', style: TextStyle(color: Colors.grey, fontSize: 12)))
                          : ListView.separated(
                              itemCount: _searchResults.length,
                              separatorBuilder: (_, __) => const SizedBox(height: 6),
                              itemBuilder: (context, idx) {
                                final u = _searchResults[idx];
                                final isSel = _selectedUsersToInvite.any((item) => item['id'] == u['id']);
                                return InkWell(
                                  onTap: () {
                                    setDialogState(() {
                                      if (isSel) {
                                        _selectedUsersToInvite.removeWhere((item) => item['id'] == u['id']);
                                      } else {
                                        _selectedUsersToInvite.add(u);
                                      }
                                    });
                                  },
                                  child: Container(
                                    padding: const EdgeInsets.all(8),
                                    decoration: BoxDecoration(
                                      color: isSel ? Colors.purple.withOpacity(0.3) : Colors.grey.shade800,
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(color: isSel ? Colors.purpleAccent : Colors.transparent),
                                    ),
                                    child: Row(
                                      children: [
                                        CircleAvatar(
                                          radius: 14,
                                          backgroundImage: (u['profile_image'] != null && (u['profile_image'] as String).isNotEmpty)
                                              ? CachedNetworkImageProvider(u['profile_image'])
                                              : null,
                                          child: (u['profile_image'] == null || (u['profile_image'] as String).isEmpty)
                                              ? const Icon(Icons.person, size: 14, color: Colors.white)
                                              : null,
                                        ),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: Text(u['name'] ?? 'User',
                                              style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
                                        ),
                                        Icon(isSel ? Icons.check_circle : Icons.circle_outlined,
                                            color: isSel ? Colors.purpleAccent : Colors.grey, size: 18),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.purple, foregroundColor: Colors.white),
              onPressed: _isSendingInvites || _selectedUsersToInvite.isEmpty
                  ? null
                  : () async {
                      setDialogState(() => _isSendingInvites = true);
                      final cur = _auth.currentUser;
                      final hostInfo = {
                        'id': cur?.uid ?? '',
                        'name': cur?.displayName ?? 'Host',
                        'avatar': cur?.photoURL ?? '',
                      };

                      await VirtualMeetingService.instance.inviteUsersToMeeting(
                        meetingId: widget.meetingId,
                        roomName: widget.roomName,
                        title: widget.meetingTitle,
                        hostInfo: hostInfo,
                        selectedUsers: _selectedUsersToInvite,
                      );

                      Navigator.pop(ctx);
                      Fluttertoast.showToast(msg: 'Meeting call sent to ${_selectedUsersToInvite.length} contact(s)!');
                    },
              child: Text(_isSendingInvites ? 'Calling...' : 'Send Call (${_selectedUsersToInvite.length})'),
            ),
          ],
        ),
      ),
    );
  }

  // In-Meeting Chat Dialog
  void _showChatDialog() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.grey.shade900,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => StatefulBuilder(
        builder: (context, setChatState) => Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom,
            left: 16,
            right: 16,
            top: 16,
          ),
          child: SizedBox(
            height: 380,
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.chat_bubble_outline_rounded, color: Colors.purpleAccent, size: 20),
                        SizedBox(width: 8),
                        Text('In-Meeting Chat', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
                      ],
                    ),
                    IconButton(icon: const Icon(Icons.close, color: Colors.grey), onPressed: () => Navigator.pop(ctx)),
                  ],
                ),
                Expanded(
                  child: _chatMessages.isEmpty
                      ? const Center(child: Text('No messages yet in this room.', style: TextStyle(color: Colors.grey, fontSize: 12)))
                      : ListView.separated(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          itemCount: _chatMessages.length,
                          separatorBuilder: (_, __) => const SizedBox(height: 8),
                          itemBuilder: (context, idx) {
                            final m = _chatMessages[idx];
                            final isSelf = m['isSelf'] == true;
                            return Align(
                              alignment: isSelf ? Alignment.centerRight : Alignment.centerLeft,
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                decoration: BoxDecoration(
                                  color: isSelf ? Colors.purple.shade700 : Colors.grey.shade800,
                                  borderRadius: BorderRadius.circular(14),
                                ),
                                child: Column(
                                  crossAxisAlignment: isSelf ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                                  children: [
                                    Text(m['sender'] ?? '',
                                        style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.purple.shade200)),
                                    const SizedBox(height: 2),
                                    Text(m['text'] ?? '', style: const TextStyle(color: Colors.white, fontSize: 13)),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 12, top: 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _chatController,
                          style: const TextStyle(color: Colors.white, fontSize: 13),
                          decoration: InputDecoration(
                            hintText: 'Type message...',
                            hintStyle: const TextStyle(color: Colors.grey, fontSize: 12),
                            filled: true,
                            fillColor: Colors.grey.shade800,
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(20), borderSide: BorderSide.none),
                            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        style: IconButton.styleFrom(backgroundColor: Colors.purple, foregroundColor: Colors.white),
                        icon: const Icon(Icons.send_rounded, size: 18),
                        onPressed: () async {
                          final text = _chatController.text.trim();
                          if (text.isEmpty || _room == null) return;

                          final cur = _auth.currentUser;
                          final myName = cur?.displayName ?? 'Me';

                          final packet = utf8.encode(jsonEncode({
                            'type': 'chat',
                            'sender': myName,
                            'text': text,
                          }));
                          await _room?.localParticipant?.publishData(packet, reliable: true);

                          setChatState(() {
                            _chatMessages.add({
                              'sender': 'You',
                              'text': text,
                              'isSelf': true,
                            });
                          });
                          _chatController.clear();
                        },
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F0F1A),
      body: SafeArea(
        child: Column(
          children: [
            // Top Bar
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.4),
                border: Border(bottom: BorderSide(color: Colors.white.withOpacity(0.08))),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: Colors.purple.withOpacity(0.2),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.videocam_rounded, color: Colors.purpleAccent, size: 18),
                      ),
                      const SizedBox(width: 10),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text(
                                widget.meetingTitle,
                                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
                              ),
                              const SizedBox(width: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: Colors.green.withOpacity(0.2),
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: Colors.green.withOpacity(0.4)),
                                ),
                                child: const Row(
                                  children: [
                                    Icon(Icons.circle, color: Colors.green, size: 6),
                                    SizedBox(width: 3),
                                    Text('LIVE', style: TextStyle(color: Colors.green, fontSize: 8, fontWeight: FontWeight.bold)),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          Text(
                            '${_formatDuration(_durationSeconds)} • ${_participants.length} in room',
                            style: TextStyle(color: Colors.purple.shade200, fontSize: 11),
                          ),
                        ],
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.person_add_alt_1_rounded, color: Colors.purpleAccent, size: 22),
                        tooltip: 'Invite Contacts',
                        onPressed: _showInviteDialog,
                      ),
                      IconButton(
                        icon: const Icon(Icons.flip_camera_ios_rounded, color: Colors.white70, size: 20),
                        tooltip: 'Switch Camera',
                        onPressed: _switchCamera,
                      ),
                    ],
                  ),
                ],
              ),
            ),

            // Video Grid Viewport
            Expanded(
              child: _isConnecting
                  ? const Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          CircularProgressIndicator(color: Colors.purpleAccent),
                          SizedBox(height: 16),
                          Text('Connecting to LiveKit Room...', style: TextStyle(color: Colors.white, fontSize: 14)),
                        ],
                      ),
                    )
                  : _buildVideoGrid(),
            ),

            // Floating Bottom Controls
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.85),
                borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
                border: Border(top: BorderSide(color: Colors.white.withOpacity(0.08))),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  // Mic
                  IconButton(
                    style: IconButton.styleFrom(
                      backgroundColor: _isMicEnabled ? Colors.grey.shade800 : Colors.red,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.all(12),
                    ),
                    icon: Icon(_isMicEnabled ? Icons.mic : Icons.mic_off),
                    onPressed: _toggleMic,
                  ),
                  // Camera
                  IconButton(
                    style: IconButton.styleFrom(
                      backgroundColor: _isCameraEnabled ? Colors.grey.shade800 : Colors.red,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.all(12),
                    ),
                    icon: Icon(_isCameraEnabled ? Icons.videocam : Icons.videocam_off),
                    onPressed: _toggleCamera,
                  ),
                  // Participants
                  IconButton(
                    style: IconButton.styleFrom(
                      backgroundColor: Colors.grey.shade800,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.all(12),
                    ),
                    icon: const Icon(Icons.people_alt_rounded),
                    onPressed: _showParticipantsSheet,
                  ),
                  // In-Meeting Chat
                  IconButton(
                    style: IconButton.styleFrom(
                      backgroundColor: Colors.grey.shade800,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.all(12),
                    ),
                    icon: const Icon(Icons.chat_bubble_outline_rounded),
                    onPressed: _showChatDialog,
                  ),
                  // Creator End vs Member Leave
                  if (_isCreator)
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      ),
                      onPressed: _endMeetingForAll,
                      icon: const Icon(Icons.call_end, size: 16),
                      label: const Text('End', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                    )
                  else
                    IconButton(
                      style: IconButton.styleFrom(
                        backgroundColor: Colors.red,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.all(12),
                      ),
                      icon: const Icon(Icons.call_end),
                      onPressed: _leaveMeeting,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildVideoGrid() {
    final count = _participants.length;

    if (count <= 1) {
      return Padding(
        padding: const EdgeInsets.all(12.0),
        child: _buildParticipantTile(_participants.firstOrNull ?? _room!.localParticipant!),
      );
    }

    if (count == 2) {
      return Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          children: [
            Expanded(child: _buildParticipantTile(_participants[0])),
            const SizedBox(height: 8),
            Expanded(child: _buildParticipantTile(_participants[1])),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: GridView.builder(
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          crossAxisSpacing: 8,
          mainAxisSpacing: 8,
          childAspectRatio: 1.0,
        ),
        itemCount: count,
        itemBuilder: (context, idx) => _buildParticipantTile(_participants[idx]),
      ),
    );
  }

  Widget _buildParticipantTile(Participant p) {
    final isSelf = p == _room?.localParticipant;
    final isSpeaker = _activeSpeakers.contains(p.identity);
    final displayName = p.name.isNotEmpty ? p.name : (isSelf ? 'You' : p.identity);

    final videoTrack = p.videoTrackPublications.firstOrNull?.track as VideoTrack?;
    final isCameraMuted = p.videoTrackPublications.firstOrNull?.muted ?? (videoTrack == null);
    final isMicMuted = p.audioTrackPublications.firstOrNull?.muted ?? false;

    return Container(
      decoration: BoxDecoration(
        color: Colors.grey.shade900,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isSpeaker ? Colors.greenAccent : Colors.grey.shade800,
          width: isSpeaker ? 2.5 : 1,
        ),
        boxShadow: isSpeaker
            ? [BoxShadow(color: Colors.greenAccent.withOpacity(0.3), blurRadius: 10, spreadRadius: 1)]
            : null,
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          // Video Renderer or Avatar Fallback
          if (videoTrack != null && !isCameraMuted)
            Positioned.fill(
              child: VideoTrackRenderer(
                videoTrack,
              ),
            )
          else
            Positioned.fill(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircleAvatar(
                      radius: 32,
                      backgroundColor: Colors.purple.shade800,
                      child: Text(
                        displayName.isNotEmpty ? displayName[0].toUpperCase() : 'U',
                        style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold),
                      ),
                    ),
                    const SizedBox(height: 6),
                    const Text('Camera off', style: TextStyle(color: Colors.grey, fontSize: 10)),
                  ],
                ),
              ),
            ),

          // Name and Mic status badge
          Positioned(
            bottom: 8,
            left: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.65),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '$displayName ${isSelf ? '(You)' : ''}',
                    style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(width: 4),
                  if (isMicMuted)
                    const Icon(Icons.mic_off, color: Colors.redAccent, size: 12)
                  else if (isSpeaker)
                    const Icon(Icons.volume_up, color: Colors.greenAccent, size: 12),
                ],
              ),
            ),
          ),

          // Creator Kick/Remove Button for Remote Member
          if (_isCreator && !isSelf)
            Positioned(
              top: 8,
              right: 8,
              child: InkWell(
                onTap: () => _removeParticipant(p),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.red.shade900.withOpacity(0.9),
                    borderRadius: BorderRadius.circular(10),
                    boxShadow: [
                      BoxShadow(color: Colors.black.withOpacity(0.4), blurRadius: 4),
                    ],
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.person_remove_rounded, color: Colors.white, size: 12),
                      SizedBox(width: 3),
                      Text('Remove', style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold)),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

extension _IterableExt<T> on Iterable<T> {
  Iterable<T> filter(bool Function(T) test) => where(test);
}
