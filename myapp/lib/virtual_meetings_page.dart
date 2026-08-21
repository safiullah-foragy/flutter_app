import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' as fb_auth;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'theme_controller.dart';
import 'virtual_meeting_service.dart';
import 'virtual_meeting_room_page.dart';

class VirtualMeetingsPage extends StatefulWidget {
  final Map<String, dynamic>? userData;

  const VirtualMeetingsPage({super.key, this.userData});

  @override
  State<VirtualMeetingsPage> createState() => _VirtualMeetingsPageState();
}

class _VirtualMeetingsPageState extends State<VirtualMeetingsPage> {
  final fb_auth.FirebaseAuth _auth = fb_auth.FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  final TextEditingController _joinIdController = TextEditingController();
  final TextEditingController _createTitleController = TextEditingController();

  bool _isCreating = false;

  @override
  void dispose() {
    _joinIdController.dispose();
    _createTitleController.dispose();
    super.dispose();
  }

  void _showCreateMeetingDialog() {
    _createTitleController.text = '';
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          title: const Row(
            children: [
              Icon(Icons.video_call_rounded, color: Colors.purple, size: 28),
              SizedBox(width: 8),
              Text('Create Virtual Meeting', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Meeting Topic / Title',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.grey),
              ),
              const SizedBox(height: 6),
              TextField(
                controller: _createTitleController,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: 'e.g. Project Discussion, Standup',
                  filled: true,
                  fillColor: Colors.grey.shade100,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                ),
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.purple.shade50,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: Colors.purple.shade100),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.auto_awesome, color: Colors.purple, size: 18),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Instant LiveKit HD WebRTC session with real-time contact invitations.',
                        style: TextStyle(fontSize: 11, color: Colors.purple),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.purple,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              ),
              onPressed: _isCreating
                  ? null
                  : () async {
                      final title = _createTitleController.text.trim();
                      setDialogState(() => _isCreating = true);
                      Navigator.pop(ctx);
                      await _startNewMeeting(title);
                    },
              child: _isCreating
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Text('Start Meeting Now', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _startNewMeeting(String title) async {
    final user = _auth.currentUser;
    if (user == null) return;

    final hostName = (widget.userData?['name'] ?? user.displayName ?? 'Host').toString();
    final hostAvatar = (widget.userData?['profile_image'] ?? user.photoURL ?? '').toString();

    try {
      final res = await VirtualMeetingService.instance.createMeeting(
        title: title.isNotEmpty ? title : "$hostName's Meeting",
        hostId: user.uid,
        hostName: hostName,
        hostAvatar: hostAvatar,
      );

      if (!mounted) return;

      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => VirtualMeetingRoomPage(
            meetingId: res['meetingId'],
            roomName: res['roomName'],
            meetingTitle: res['title'],
            isHost: true,
          ),
        ),
      );
    } catch (e) {
      Fluttertoast.showToast(msg: 'Failed to create meeting: $e');
    }
  }

  void _joinMeetingById() {
    final input = _joinIdController.text.trim();
    if (input.isEmpty) {
      Fluttertoast.showToast(msg: 'Enter a valid Meeting ID or Room Name');
      return;
    }

    String roomName = input;
    if (!roomName.startsWith('room_') && !roomName.startsWith('meet_')) {
      roomName = 'room_meet_$input';
    }

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => VirtualMeetingRoomPage(
          meetingId: input,
          roomName: roomName,
          meetingTitle: 'Virtual Meeting',
          isHost: false,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final curUser = _auth.currentUser;

    return Scaffold(
      appBar: AppBar(
        flexibleSpace: Container(
          decoration: BoxDecoration(gradient: ThemeController.instance.appBarGradient),
        ),
        elevation: 0,
        foregroundColor: Colors.white,
        title: const Row(
          children: [
            Icon(Icons.video_call_rounded, size: 24),
            SizedBox(width: 8),
            Text('Virtual Meetings', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
          ],
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Top Hero Banner
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(24),
                gradient: const LinearGradient(
                  colors: [Color(0xFF4A148C), Color(0xFF6A1B9A), Color(0xFF311B92)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.purple.withOpacity(0.3),
                    blurRadius: 16,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: Colors.white.withOpacity(0.3)),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.auto_awesome, color: Colors.amberAccent, size: 14),
                        SizedBox(width: 4),
                        Text(
                          'LIVEKIT WEBRTC',
                          style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 1),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Connectify Virtual Meetings',
                    style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Host HD multi-person video meetings, share screens, and invite contacts in real time with live ringing.',
                    style: TextStyle(color: Colors.purple.shade100, fontSize: 12, height: 1.4),
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.white,
                          foregroundColor: Colors.purple.shade900,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                          elevation: 2,
                        ),
                        onPressed: _showCreateMeetingDialog,
                        icon: const Icon(Icons.add_rounded, size: 20),
                        label: const Text('New Meeting', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            const SizedBox(height: 20),

            // Quick Join Bar
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: Colors.grey.shade200),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.03),
                    blurRadius: 10,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: Row(
                children: [
                  const Icon(Icons.link_rounded, color: Colors.purple),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: _joinIdController,
                      decoration: const InputDecoration(
                        hintText: 'Enter Meeting ID to join...',
                        hintStyle: TextStyle(fontSize: 13, color: Colors.grey),
                        border: InputBorder.none,
                      ),
                    ),
                  ),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.purple,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    ),
                    onPressed: _joinMeetingById,
                    child: const Text('Join', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 24),

            // Active Live Meetings Section Header
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Row(
                  children: [
                    Icon(Icons.sensors_rounded, color: Colors.green, size: 20),
                    SizedBox(width: 6),
                    Text('Active Live Meetings', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                  ],
                ),
                StreamBuilder<QuerySnapshot>(
                  stream: _firestore
                      .collection('call_sessions')
                      .where('is_meeting', isEqualTo: true)
                      .where('status', isEqualTo: 'active')
                      .snapshots(),
                  builder: (context, snap) {
                    final count = snap.hasData ? snap.data!.docs.where((d) => !d.id.startsWith('inv_')).length : 0;
                    return Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: Colors.green.shade50,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: Colors.green.shade200),
                      ),
                      child: Text(
                        '$count Active',
                        style: TextStyle(color: Colors.green.shade800, fontSize: 11, fontWeight: FontWeight.bold),
                      ),
                    );
                  },
                ),
              ],
            ),

            const SizedBox(height: 12),

            // Active Meetings Feed
            StreamBuilder<QuerySnapshot>(
              stream: _firestore
                  .collection('call_sessions')
                  .where('is_meeting', isEqualTo: true)
                  .where('status', isEqualTo: 'active')
                  .snapshots(),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: Padding(padding: EdgeInsets.all(32), child: CircularProgressIndicator()));
                }

                if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
                  return _buildEmptyMeetingsPlaceholder();
                }

                final docs = snapshot.data!.docs.where((d) => !d.id.startsWith('inv_')).toList();
                docs.sort((a, b) => ((b.data() as Map)['created_at'] ?? 0).compareTo((a.data() as Map)['created_at'] ?? 0));

                if (docs.isEmpty) {
                  return _buildEmptyMeetingsPlaceholder();
                }

                return ListView.separated(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: docs.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 12),
                  itemBuilder: (context, idx) {
                    final data = docs[idx].data() as Map<String, dynamic>;
                    final meetingId = (data['id'] ?? docs[idx].id).toString();
                    final roomName = (data['room_name'] ?? data['channel'] ?? 'room_$meetingId').toString();
                    final title = (data['title'] ?? 'Virtual Meeting').toString();
                    final hostName = (data['host_name'] ?? 'Host').toString();
                    final hostAvatar = (data['host_avatar'] ?? '').toString();
                    final hostId = (data['host_id'] ?? data['caller_id'] ?? '').toString();
                    final isUserHost = curUser != null && curUser.uid == hostId;

                    return Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: Colors.grey.shade200),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.03),
                            blurRadius: 8,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Row(
                                children: [
                                  Container(
                                    width: 8,
                                    height: 8,
                                    decoration: const BoxDecoration(
                                      color: Colors.green,
                                      shape: BoxShape.circle,
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    'Live Room',
                                    style: TextStyle(color: Colors.green.shade700, fontSize: 11, fontWeight: FontWeight.bold),
                                  ),
                                ],
                              ),
                              IconButton(
                                constraints: const BoxConstraints(),
                                padding: EdgeInsets.zero,
                                icon: const Icon(Icons.copy_rounded, size: 16, color: Colors.grey),
                                tooltip: 'Copy Meeting ID',
                                onPressed: () {
                                  Clipboard.setData(ClipboardData(text: meetingId));
                                  Fluttertoast.showToast(msg: 'Meeting ID copied');
                                },
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Text(
                            title,
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                          ),
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              CircleAvatar(
                                radius: 14,
                                backgroundColor: Colors.purple.shade100,
                                backgroundImage: hostAvatar.isNotEmpty ? CachedNetworkImageProvider(hostAvatar) : null,
                                child: hostAvatar.isEmpty
                                    ? Text(hostName.isNotEmpty ? hostName[0].toUpperCase() : 'H',
                                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.purple))
                                    : null,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text('Hosted by $hostName', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                                    Text('ID: $meetingId', style: const TextStyle(fontSize: 10, color: Colors.grey)),
                                  ],
                                ),
                              ),
                              if (isUserHost)
                                TextButton(
                                  style: TextButton.styleFrom(
                                    foregroundColor: Colors.red,
                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                  ),
                                  onPressed: () async {
                                    final confirm = await showDialog<bool>(
                                      context: context,
                                      builder: (ctx) => AlertDialog(
                                        title: const Text('End Meeting?'),
                                        content: const Text('Do you want to end this meeting for everyone?'),
                                        actions: [
                                          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                                          ElevatedButton(
                                            style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
                                            onPressed: () => Navigator.pop(ctx, true),
                                            child: const Text('End Meeting'),
                                          ),
                                        ],
                                      ),
                                    );
                                    if (confirm == true) {
                                      await VirtualMeetingService.instance.endMeeting(meetingId, roomName);
                                      Fluttertoast.showToast(msg: 'Meeting ended');
                                    }
                                  },
                                  child: const Text('End', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                                ),
                              ElevatedButton.icon(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.purple,
                                  foregroundColor: Colors.white,
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                                ),
                                onPressed: () {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) => VirtualMeetingRoomPage(
                                        meetingId: meetingId,
                                        roomName: roomName,
                                        meetingTitle: title,
                                        isHost: isUserHost,
                                      ),
                                    ),
                                  );
                                },
                                icon: const Icon(Icons.play_arrow_rounded, size: 16),
                                label: const Text('Join', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                              ),
                            ],
                          ),
                        ],
                      ),
                    );
                  },
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyMeetingsPlaceholder() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(28),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.purple.shade50,
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.videocam_outlined, size: 36, color: Colors.purple),
          ),
          const SizedBox(height: 12),
          const Text('No active meetings right now', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
          const SizedBox(height: 4),
          const Text('Start an instant meeting and invite your contacts to join.',
              textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: Colors.grey)),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.purple,
              side: const BorderSide(color: Colors.purple),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
            onPressed: _showCreateMeetingDialog,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Start Instant Meeting', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
          ),
        ],
      ),
    );
  }
}
