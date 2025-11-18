import 'dart:io' show File; // Used on mobile/desktop only
import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:image_picker/image_picker.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'app_cache_manager.dart';
import 'supabase.dart' as sb;
import 'videos.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:record/record.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
// import 'newsfeed.dart'; // No direct usage here
import 'see_profile_from_newsfeed.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'background_tasks.dart';
import 'agora_call_page.dart';
import 'audio_upload_web.dart' if (dart.library.io) 'audio_upload_stub.dart';

/// Conversations list and chat screen.
class MessagesPage extends StatefulWidget {
  const MessagesPage({super.key});

  @override
  State<MessagesPage> createState() => _MessagesPageState();
}

class _MessagesPageState extends State<MessagesPage> {
  final firebase_auth.FirebaseAuth _auth = firebase_auth.FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  Map<String, dynamic>? currentUserData;
  // Global overlay handles bubble behavior.
  final Map<String, StreamSubscription<QuerySnapshot>> _callSubs = {};
  bool _showingIncoming = false;

  @override
  void initState() {
    super.initState();
    _fetchCurrentUserData();
  }

  

  Future<void> _fetchCurrentUserData() async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return;

    try {
      final userDoc = await _firestore.collection('users').doc(uid).get();
      if (userDoc.exists) {
        setState(() {
          currentUserData = userDoc.data();
        });
      }
    } catch (e) {
      debugPrint('Error fetching current user data: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final String? uid = _auth.currentUser?.uid;
    if (uid == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Messages')),
        body: const Center(child: Text('Please sign in to view messages')),
      );
    }

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context), // pop back to previous page (avoids duplicating Newsfeed)
        ),
        title: const Text('Messages'),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            tooltip: 'Search users',
            onPressed: () => _showUserSearch(),
          ),
        ],
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: _firestore
          .collection('conversations')
          .where('participants', arrayContains: uid)
          .snapshots(includeMetadataChanges: true),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            debugPrint('Conversations stream error: ${snapshot.error}');
            return Center(child: Text('Error loading conversations: ${snapshot.error}'));
          }
          if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());

          var docs = snapshot.data!.docs;
          final List<Map<String, dynamic>> convs = docs.map((d) {
            final data = d.data() as Map<String, dynamic>? ?? {};
            final lastReadMap = Map<String, dynamic>.from(data['last_read'] ?? <String, dynamic>{});
            final lastRead = (lastReadMap[uid] ?? 0) as int;
            final lastUpdated = (data['last_updated'] ?? 0) as int;
            final unread = lastUpdated > lastRead;
            return {'doc': d, 'data': data, 'unread': unread};
          }).toList();

          // Sort: unread first, then by last_updated desc
          convs.sort((a, b) {
            final au = a['unread'] as bool;
            final bu = b['unread'] as bool;
            if (au != bu) return au ? -1 : 1;
            final ad = (a['data']['last_updated'] ?? 0) as int;
            final bd = (b['data']['last_updated'] ?? 0) as int;
            return bd.compareTo(ad);
          });

          if (convs.isEmpty) return const Center(child: Text('No conversations'));

          // Global overlay handles unread bubble; no per-page top unread detection needed here.

          final Widget listView = ListView.builder(
            restorationId: 'conversations_list',
            itemCount: convs.length,
            itemBuilder: (context, index) {
              final d = convs[index]['doc'] as QueryDocumentSnapshot;
              final data = convs[index]['data'] as Map<String, dynamic>;
              final participants = List<String>.from(data['participants'] ?? <String>[]);
              final otherId = participants.firstWhere((p) => p != uid, orElse: () => '');
              final lastMessage = data['last_message'] ?? '';
              final lastUpdated = data['last_updated'] ?? 0;
              // final archivedMap = Map<String, dynamic>.from(data['archived'] ?? <String, dynamic>{});
              final unread = convs[index]['unread'] as bool;

              if (otherId.isEmpty) {
                return ListTile(
                  leading: const CircleAvatar(child: Icon(Icons.person)),
                  title: const Text('Conversation'),
                  subtitle: Text(lastMessage, maxLines: 1, overflow: TextOverflow.ellipsis),
                  trailing: Text(_formatTimestamp(lastUpdated)),
                  onTap: () async {
                    await _markConversationRead(d.id, uid);
                    Navigator.of(context).restorablePush(
                      ChatPage.restorableRoute,
                      arguments: {
                        'conversationId': d.id,
                        'otherUserId': otherId,
                      },
                    );
                  },
                );
              }

              return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                stream: _firestore.collection('users').doc(uid).snapshots(includeMetadataChanges: true),
                builder: (context, currentUserSnap) {
                  // Check if conversation is muted
                  bool isMuted = false;
                  if (currentUserSnap.hasData && currentUserSnap.data != null && currentUserSnap.data!.exists) {
                    final userData = currentUserSnap.data!.data();
                    if (userData != null) {
                      final mutedList = userData['muted_conversations'] as List<dynamic>? ?? [];
                      isMuted = mutedList.contains(d.id);
                    }
                  }

                  return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                    stream: _firestore.collection('users').doc(otherId).snapshots(includeMetadataChanges: true),
                    builder: (context, userSnap) {
                      String title = otherId;
                      String? avatarUrl;
                      if (userSnap.hasError) {
                        debugPrint('User lookup error for $otherId: ${userSnap.error}');
                      }
                      if (userSnap.hasData && userSnap.data != null && userSnap.data!.exists) {
                        final u = userSnap.data!.data();
                        if (u != null) {
                          title = u['name'] ?? otherId;
                          avatarUrl = u['profile_image'];
                        }
                      }
                  return Dismissible(
                    key: ValueKey(d.id),
                    direction: DismissDirection.endToStart,
                    background: Container(
                      color: Colors.red, 
                      alignment: Alignment.centerRight, 
                      padding: const EdgeInsets.only(right: 20), 
                      child: const Icon(Icons.delete, color: Colors.white)
                    ),
                    confirmDismiss: (dir) async {
                      final choice = await showDialog<String?>(
                        context: context, 
                        builder: (c) {
                          return SimpleDialog(
                            title: const Text('Conversation'), 
                            children: [
                              SimpleDialogOption(
                                child: const Text('Archive'), 
                                onPressed: () => Navigator.pop(c, 'archive')
                              ),
                              SimpleDialogOption(
                                child: const Text('Delete'), 
                                onPressed: () => Navigator.pop(c, 'delete')
                              ),
                              SimpleDialogOption(
                                child: const Text('Cancel'), 
                                onPressed: () => Navigator.pop(c, null)
                              ),
                            ]
                          );
                        }
                      );
                      if (choice == 'archive') {
                        await _firestore.collection('conversations').doc(d.id).update({
                          'archived.$uid': true
                        });
                        return false;
                      }
                      if (choice == 'delete') {
                        final ok = await _deleteConversation(d.id);
                        return ok;
                      }
                      return false;
                    },
                    child: GestureDetector(
                      onLongPress: () => _showConversationOptions(d.id, uid, title, isMuted),
                      child: ListTile(
                        leading: _buildUserAvatar(avatarUrl, otherId),
                        title: Text(
                          title.isNotEmpty ? title : 'Conversation',
                          style: TextStyle(
                            fontWeight: unread ? FontWeight.bold : FontWeight.normal,
                          ),
                        ),
                        subtitle: Text(
                          lastMessage, 
                          maxLines: 1, 
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: unread ? Colors.black : Colors.grey,
                          ),
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Text(_formatTimestamp(lastUpdated), style: const TextStyle(fontSize: 12)),
                                if (unread) const Icon(Icons.circle, color: Colors.blue, size: 10),
                              ],
                            ),
                            if (isMuted) const SizedBox(width: 8),
                            if (isMuted) const Icon(Icons.notifications_off, color: Colors.grey, size: 20),
                          ],
                        ),
                        onTap: () async {
                          await _markConversationRead(d.id, uid);
                          Navigator.of(context).restorablePush(
                            ChatPage.restorableRoute,
                            arguments: {
                              'conversationId': d.id,
                              'otherUserId': otherId,
                            },
                          );
                        },
                      ),
                    ),
                    );
                  },
                );
                },
              );
            },
          );

          // Page-scoped bubble overlay removed (we show a global overlay instead).
          // Setup listeners for incoming call invites.
          _setupIncomingCallListeners(convs.map((c) => (c['doc'] as QueryDocumentSnapshot).id).toList());
          return listView;
        },
      ),
    );
  }

  @override
  void dispose() {
    for (final s in _callSubs.values) { s.cancel(); }
    _callSubs.clear();
    super.dispose();
  }

  void _setupIncomingCallListeners(List<String> conversationIds) {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return;
    // Remove obsolete listeners
    final obsolete = _callSubs.keys.where((id) => !conversationIds.contains(id)).toList();
    for (final id in obsolete) { _callSubs[id]?.cancel(); _callSubs.remove(id); }
    // Add new listeners
    for (final convId in conversationIds) {
      if (_callSubs.containsKey(convId)) continue;
      final sub = _firestore.collection('conversations').doc(convId).collection('messages')
          .orderBy('timestamp', descending: true).limit(1).snapshots().listen((snap) {
        if (snap.docs.isEmpty) return;
        final data = snap.docs.first.data() as Map<String, dynamic>? ?? {};
        final sender = data['sender_id'];
        final fileType = data['file_type'];
        final callChannel = data['call_channel'];
        final ts = (data['timestamp'] ?? 0) as int;
        final recent = DateTime.now().millisecondsSinceEpoch - ts < 60000; // last 60s
        if (sender != null && sender != uid && (fileType == 'call_audio' || fileType == 'call_video') && callChannel is String && callChannel.isNotEmpty && recent) {
          _showIncomingCall(convId: convId, fromUserId: sender, channel: callChannel, video: fileType == 'call_video');
        }
      });
      _callSubs[convId] = sub;
    }
  }

  void _showIncomingCall({required String convId, required String fromUserId, required String channel, required bool video}) async {
    if (!mounted || _showingIncoming) return;
    _showingIncoming = true;
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (c) => IncomingCallDialog(
        conversationId: convId,
        fromUserId: fromUserId,
        channelName: channel,
        video: video,
        onFinished: () { _showingIncoming = false; },
      ),
    );
  }

  Widget _buildUserAvatar(String? avatarUrl, String userId) {
    if (avatarUrl != null && avatarUrl.isNotEmpty) {
      return CircleAvatar(
        backgroundImage: CachedNetworkImageProvider(avatarUrl),
      );
    } else {
      // Generate a consistent color based on user ID
      final colors = [
        Colors.blue, Colors.red, Colors.green, Colors.orange, 
        Colors.purple, Colors.teal, Colors.pink, Colors.indigo
      ];
      final colorIndex = userId.hashCode % colors.length;
      final firstChar = userId.isNotEmpty ? userId[0].toUpperCase() : '?';
      
      return CircleAvatar(
        backgroundColor: colors[colorIndex],
        child: Text(
          firstChar,
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
      );
    }
  }

  String _formatTimestamp(int timestamp) {
    if (timestamp == 0) return '';
    final date = DateTime.fromMillisecondsSinceEpoch(timestamp).toLocal();
    final now = DateTime.now();
    if (date.year == now.year && date.month == now.month && date.day == now.day) {
      return '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
    }
    return '${date.month}/${date.day}';
  }

  Future<void> _markConversationRead(String conversationId, String uid) async {
    try {
      await _firestore.collection('conversations').doc(conversationId).update({
        'last_read.$uid': DateTime.now().millisecondsSinceEpoch
      });
    } catch (e) {
      debugPrint('Error marking conversation read: $e');
    }
  }

  Future<void> _showUserSearch() async {
    await showDialog<void>(
      context: context,
      builder: (context) {
        final searchCtrl = TextEditingController();
        List<QueryDocumentSnapshot> results = [];
        bool isLoading = false;

        return StatefulBuilder(builder: (context, setState) {
          Future<void> doSearch() async {
            final q = searchCtrl.text.trim();
            if (q.isEmpty) {
              setState(() => results = []);
              return;
            }
            
            setState(() => isLoading = true);
            try {
              final snapshot = await _firestore
                  .collection('users')
                  .where('name', isGreaterThanOrEqualTo: q)
                  .where('name', isLessThanOrEqualTo: '$q\uf8ff')
                  .limit(20)
                  .get();
              setState(() => results = snapshot.docs);
            } catch (e) {
              debugPrint('Search error: $e');
            } finally {
              setState(() => isLoading = false);
            }
          }

          return Dialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 500),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Text(
                      'Search Users',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16.0),
                    child: TextField(
                      controller: searchCtrl,
                      decoration: InputDecoration(
                        hintText: 'Enter user name...',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                      ),
                      onChanged: (_) => doSearch(),
                      autofocus: true,
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (isLoading)
                    const Padding(
                      padding: EdgeInsets.all(16.0),
                      child: CircularProgressIndicator(),
                    )
                  else if (results.isEmpty && searchCtrl.text.isNotEmpty)
                    const Padding(
                      padding: EdgeInsets.all(16.0),
                      child: Text('No users found'),
                    )
                  else if (results.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(16.0),
                      child: Text('Search for users by name'),
                    )
                  else
                    Expanded(
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: results.length,
                        itemBuilder: (context, i) {
                          final u = results[i].data() as Map<String, dynamic>;
                          final userId = results[i].id;
                          final userName = u['name'] ?? userId;
                          final userEmail = u['email'] ?? '';
                          final avatarUrl = u['profile_image'];
                          
                          return ListTile(
                            leading: _buildUserAvatar(avatarUrl, userId),
                            title: Text(
                              userName,
                              overflow: TextOverflow.ellipsis,
                              maxLines: 1,
                            ),
                            subtitle: Text(
                              userEmail,
                              overflow: TextOverflow.ellipsis,
                              maxLines: 1,
                            ),
                            onTap: () async {
                              Navigator.pop(context);
                              await _startConversationWith(userId);
                            },
                          );
                        },
                      ),
                    ),
                  const SizedBox(height: 8),
                  Padding(
                    padding: const EdgeInsets.all(8.0),
                    child: TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Close'),
                    ),
                  ),
                ],
              ),
            ),
          );
        });
      },
    );
  }

  Future<void> _startConversationWith(String otherId) async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please sign in to start a conversation')));
      return;
    }
    
    // Don't allow messaging yourself
    if (otherId == uid) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Cannot start conversation with yourself'))
      );
      return;
    }

    // Check if other user exists
    final otherUserDoc = await _firestore.collection('users').doc(otherId).get();
    if (!otherUserDoc.exists) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('User not found'))
      );
      return;
    }

    // Check for existing conversation
    final q = await _firestore
        .collection('conversations')
        .where('participants', arrayContains: uid)
        .get();
    
    String? convId;
    for (var d in q.docs) {
      final participants = List<String>.from(d.data()['participants'] ?? <String>[]);
      if (participants.contains(otherId)) {
        convId = d.id;
        break;
      }
    }

    // Create new conversation if none exists
    if (convId == null) {
      final ref = await _firestore.collection('conversations').add({
        'participants': [uid, otherId],
        'last_message': '',
        'last_updated': DateTime.now().millisecondsSinceEpoch,
        'last_read': {
          uid: DateTime.now().millisecondsSinceEpoch,
          otherId: 0,  // Set to 0 to ensure unread for receiver
        },
        'archived': {
          uid: false,
          otherId: false,
        },
        'created_at': DateTime.now().millisecondsSinceEpoch,
      });
      convId = ref.id;
    }

    Navigator.of(context).restorablePush(
      ChatPage.restorableRoute,
      arguments: {
        'conversationId': convId,
        'otherUserId': otherId,
      },
    );
  }

  Future<void> _showConversationOptions(String conversationId, String currentUserId, String conversationTitle, bool isMuted) async {
    final choice = await showDialog<String?>(
      context: context,
      builder: (c) {
        return SimpleDialog(
          title: Text('Options for $conversationTitle'),
          children: [
            SimpleDialogOption(
              child: const Row(
                children: [
                  Icon(Icons.delete, color: Colors.red),
                  SizedBox(width: 8),
                  Text('Delete Conversation', style: TextStyle(color: Colors.red)),
                ],
              ),
              onPressed: () => Navigator.pop(c, 'delete'),
            ),
            SimpleDialogOption(
              child: Row(
                children: [
                  Icon(isMuted ? Icons.notifications_active : Icons.notifications_off),
                  const SizedBox(width: 8),
                  Text(isMuted ? 'Unmute Notifications' : 'Mute Notifications'),
                ],
              ),
              onPressed: () => Navigator.pop(c, isMuted ? 'unmute' : 'mute'),
            ),
            SimpleDialogOption(
              child: const Text('Cancel'),
              onPressed: () => Navigator.pop(c, null),
            ),
          ],
        );
      },
    );

    if (choice == 'delete') {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Delete Conversation'),
          content: const Text('This will permanently delete all messages and media. Continue?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Delete', style: TextStyle(color: Colors.red)),
            ),
          ],
        ),
      );
      if (confirm == true) {
        final ok = await _deleteConversation(conversationId);
        if (mounted && ok) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Conversation deleted')),
          );
        }
      }
    } else if (choice == 'mute') {
      try {
        // Add conversation to user's muted list
        await _firestore.collection('users').doc(currentUserId).update({
          'muted_conversations': FieldValue.arrayUnion([conversationId]),
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Muted notifications for $conversationTitle')),
          );
        }
      } catch (e) {
        debugPrint('Failed to mute conversation: $e');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Failed to mute notifications')),
          );
        }
      }
    } else if (choice == 'unmute') {
      try {
        // Remove conversation from user's muted list
        await _firestore.collection('users').doc(currentUserId).update({
          'muted_conversations': FieldValue.arrayRemove([conversationId]),
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Unmuted notifications for $conversationTitle')),
          );
        }
      } catch (e) {
        debugPrint('Failed to unmute conversation: $e');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Failed to unmute notifications')),
          );
        }
      }
    }
  }

  Future<bool> _deleteConversation(String conversationId) async {
    try {
      final msgs = await _firestore
          .collection('conversations')
          .doc(conversationId)
          .collection('messages')
          .get();
      
      // Collect all Supabase file URLs for cleanup
      final List<String> supabaseUrls = [];
      for (var d in msgs.docs) {
        final data = d.data() as Map<String, dynamic>? ?? {};
        final fileUrl = data['file_url'] as String? ?? '';
        if (fileUrl.isNotEmpty && fileUrl.contains('supabase')) {
          supabaseUrls.add(fileUrl);
        }
      }

      // Delete messages from Firestore
      final batch = _firestore.batch();
      for (var d in msgs.docs) {
        batch.delete(d.reference);
      }
      await batch.commit();
      
      // Delete Supabase files
      for (final url in supabaseUrls) {
        try {
          // Extract path from URL (format: https://...supabase.co/storage/v1/object/public/bucket/path)
          final uri = Uri.parse(url);
          final pathSegments = uri.pathSegments;
          if (pathSegments.length >= 5 && pathSegments[0] == 'storage') {
            final bucket = pathSegments[4]; // bucket name
            final filePath = pathSegments.skip(5).join('/'); // file path
            await sb.supabase.storage.from(bucket).remove([filePath]);
            debugPrint('Deleted Supabase file: $bucket/$filePath');
          }
        } catch (e) {
          debugPrint('Failed to delete Supabase file $url: $e');
          // Continue cleanup even if some files fail
        }
      }
      
      // Delete conversation document
      await _firestore.collection('conversations').doc(conversationId).delete();
      return true;
    } catch (e) {
      debugPrint('Failed to delete conversation $conversationId: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to delete conversation'))
        );
      }
      return false;
    }
  }
}

class ChatPage extends StatefulWidget {
  final String conversationId;
  final String otherUserId;

  const ChatPage({required this.conversationId, required this.otherUserId, super.key});

  // Restorable route builder for state restoration
  static Route<Object?> restorableRoute(BuildContext context, Object? arguments) {
    final Map args = (arguments as Map?) ?? const {};
    final String convId = (args['conversationId'] ?? '') as String;
    final String otherId = (args['otherUserId'] ?? '') as String;
    return MaterialPageRoute(
      builder: (_) => ChatPage(conversationId: convId, otherUserId: otherId),
    );
  }

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final firebase_auth.FirebaseAuth _auth = firebase_auth.FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final TextEditingController _controller = TextEditingController();
  final ImagePicker _picker = ImagePicker();
  bool _sending = false;
  final ScrollController _scrollController = ScrollController();
  final AudioRecorder _recorder = AudioRecorder();
  bool _isRecording = false;
  final AudioPlayer _audioPlayer = AudioPlayer();
  String? _playingMessageId;
  StreamSubscription<Duration>? _posSub;

  @override
  void initState() {
    super.initState();
    _markRead();
    // Initial scroll will be handled by StreamBuilder's postFrameCallback
    _posSub = _audioPlayer.onPositionChanged.listen((_) {
      if (mounted) setState(() {});
    });
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      // Use jumpTo for instant scroll on initial load, animateTo for updates
      if (_scrollController.position.maxScrollExtent > 0) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      }
    }
  }

  Future<void> _markRead() async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return;
    try {
      await _firestore.collection('conversations').doc(widget.conversationId).update({
        'last_read.$uid': DateTime.now().millisecondsSinceEpoch
      });
    } catch (e) {
      debugPrint('Error marking read: $e');
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    _posSub?.cancel();
    _audioPlayer.dispose();
    super.dispose();
  }

  Future<void> _startCall({required bool audioOnly}) async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return;
    final channel = 'conv_' + widget.conversationId;
    final otherId = widget.otherUserId;

    // Create /call_sessions doc for global signaling so callee gets full-screen dialog even outside MessagesPage.
    String? sessionId;
    try {
      final ref = await FirebaseFirestore.instance.collection('call_sessions').add({
        'channel': channel,
        'caller_id': uid,
        'callee_id': otherId,
        'video': !audioOnly,
        'status': 'ringing',
        'created_at': DateTime.now().millisecondsSinceEpoch,
        'accepted_at': null,
        'ended_at': null,
      });
      sessionId = ref.id;
    } catch (e) {
      debugPrint('Failed to create call session: $e');
    }

    // Send a call invitation message so the other user gets a join button
    try {
      await _firestore
          .collection('conversations')
          .doc(widget.conversationId)
          .collection('messages')
          .add({
        'sender_id': uid,
        'text': audioOnly ? 'Started an audio call' : 'Started a video call',
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'file_url': '',
        'file_type': audioOnly ? 'call_audio' : 'call_video',
        'call_channel': channel,
        'reactions': <String, dynamic>{},
        'edited': false,
      });
      await _firestore.collection('conversations').doc(widget.conversationId).update({
        'last_message': audioOnly ? '[Audio call]' : '[Video call]',
        'last_updated': DateTime.now().millisecondsSinceEpoch,
      });
    } catch (e) {
      debugPrint('Error sending call invite: $e');
      String userMsg = 'Failed to send call invite: ${e.toString()}';
      if (e is FirebaseException) {
        userMsg = 'Failed to send call invite: ${e.code} - ${e.message}';
      }
      // Surface permission errors to the user so they understand why receiver didn't get the invite
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(userMsg)));
      }
    }

    if (!mounted) return;
    // Even if sending the Firestore invite failed (permissions or network), open the local call UI so the caller can start/join.
    Navigator.push(context, CallPage.route(channelName: channel, video: !audioOnly, callSessionId: sessionId));
  }

  Future<void> _sendMessage({String? text, String? fileUrl, String? fileType}) async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return;
    if ((text == null || text.isEmpty) && (fileUrl == null || fileUrl.isEmpty)) return;

    setState(() => _sending = true);

    try {
      final msg = {
        'sender_id': uid,
        'text': text ?? '',
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'file_url': fileUrl ?? '',
        'file_type': fileType ?? '',
        'reactions': <String, dynamic>{},
        'edited': false,
      };

      await _firestore
          .collection('conversations')
          .doc(widget.conversationId)
          .collection('messages')
          .add(msg);

      final lastUpdated = DateTime.now().millisecondsSinceEpoch;
      String lastMessageText = text ?? '';
      if ((lastMessageText).isEmpty) {
        if (fileType == 'image') lastMessageText = '[Image]';
        else if (fileType == 'video') lastMessageText = '[Video]';
        else if (fileType == 'audio') lastMessageText = '[Voice]';
        else lastMessageText = '[File]';
      }
      
      await _firestore.collection('conversations').doc(widget.conversationId).update({
        'last_message': lastMessageText,
        'last_updated': lastUpdated,
        'last_read.$uid': lastUpdated,
      });

    } catch (e) {
      debugPrint('Error sending message: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to send message: ${e.toString()}'))
      );
    } finally {
      setState(() {
        _sending = false;
        _controller.clear();
      });
      _scrollToBottom();
    }
  }

  Future<void> _pickAndSendImage() async {
    try {
      final XFile? picked = await _picker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 80,
      );
      if (picked == null) return;
      setState(() => _sending = true);

      // If offline on mobile/desktop, enqueue upload with a placeholder message
      final conn = await Connectivity().checkConnectivity();
      final offline = conn == ConnectivityResult.none;
      if (!kIsWeb && offline) {
        final uid = _auth.currentUser?.uid;
        if (uid != null) {
          final msgRef = await _firestore
              .collection('conversations')
              .doc(widget.conversationId)
              .collection('messages')
              .add({
            'sender_id': uid,
            'text': '',
            'timestamp': DateTime.now().millisecondsSinceEpoch,
            'file_url': '',
            'file_type': 'image',
            'reactions': <String, dynamic>{},
            'edited': false,
            'uploading': true,
          });

          await BackgroundTasks.enqueueAction({
            'type': 'upload_message_image',
            'conversationId': widget.conversationId,
            'messageId': msgRef.id,
            'localPath': picked.path,
          });

          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Image will upload when back online')),
          );
          setState(() => _sending = false);
          return;
        }
      }

      // Online path (or web): upload now
      String url = '';
      try {
        if (kIsWeb) {
          final bytes = await picked.readAsBytes();
          final name = picked.name;
          String? ct;
          final lower = name.toLowerCase();
          if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) ct = 'image/jpeg';
          else if (lower.endsWith('.png')) ct = 'image/png';
          else if (lower.endsWith('.gif')) ct = 'image/gif';
          else if (lower.endsWith('.webp')) ct = 'image/webp';
          url = await sb.uploadMessageImageBytes(bytes, fileName: name, contentType: ct);
        } else {
          final File file = File(picked.path);
          url = await sb.uploadMessageImage(file);
        }
      } catch (e) {
        debugPrint('Image upload error: $e');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to upload image: ${e.toString()}')),
        );
        setState(() => _sending = false);
        return;
      }

      await _sendMessage(fileUrl: url, fileType: 'image');
    } catch (e) {
      debugPrint('Image picker error: $e');
      setState(() => _sending = false);
    }
  }

  Future<void> _pickAndSendVideo() async {
    try {
      final XFile? picked = await _picker.pickVideo(source: ImageSource.gallery);
      if (picked == null) return;
      setState(() => _sending = true);

      // If offline on mobile/desktop, enqueue upload with a placeholder message
      final conn = await Connectivity().checkConnectivity();
      final offline = conn == ConnectivityResult.none;
      if (!kIsWeb && offline) {
        final uid = _auth.currentUser?.uid;
        if (uid != null) {
          final msgRef = await _firestore
              .collection('conversations')
              .doc(widget.conversationId)
              .collection('messages')
              .add({
            'sender_id': uid,
            'text': '',
            'timestamp': DateTime.now().millisecondsSinceEpoch,
            'file_url': '',
            'file_type': 'video',
            'reactions': <String, dynamic>{},
            'edited': false,
            'uploading': true,
          });

          await BackgroundTasks.enqueueAction({
            'type': 'upload_message_video',
            'conversationId': widget.conversationId,
            'messageId': msgRef.id,
            'localPath': picked.path,
          });

          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Video will upload when back online')),
          );
          setState(() => _sending = false);
          return;
        }
      }

      // Online path (or web): upload now
      String url = '';
      try {
        if (kIsWeb) {
          final bytes = await picked.readAsBytes();
          final name = picked.name;
          String? ct;
          final lower = name.toLowerCase();
          if (lower.endsWith('.mp4')) ct = 'video/mp4';
          else if (lower.endsWith('.mov')) ct = 'video/quicktime';
          else if (lower.endsWith('.mkv')) ct = 'video/x-matroska';
          else if (lower.endsWith('.webm')) ct = 'video/webm';
          url = await sb.uploadMessageVideoBytes(bytes, fileName: name, contentType: ct);
        } else {
          final File file = File(picked.path);
          url = await sb.uploadMessageVideo(file);
        }
      } catch (e) {
        debugPrint('Video upload error: $e');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to upload video: ${e.toString()}')),
        );
        setState(() => _sending = false);
        return;
      }

      await _sendMessage(fileUrl: url, fileType: 'video');
    } catch (e) {
      debugPrint('Video picker error: $e');
      setState(() => _sending = false);
    }
  }

  Future<void> _toggleRecord() async {
    if (_isRecording) {
      await _stopAndSendRecording();
      return;
    }
    // Start recording
    try {
  final hasPerm = await _recorder.hasPermission();
      if (!hasPerm) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Microphone permission not granted')));
        return;
      }
      String recPath;
      if (kIsWeb) {
        recPath = 'voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
      } else {
        final tmpDir = await getTemporaryDirectory();
        recPath = p.join(tmpDir.path, 'voice_${DateTime.now().millisecondsSinceEpoch}.m4a');
      }
      await _recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: 128000,
          sampleRate: 44100,
        ),
        path: recPath,
      );
      setState(() => _isRecording = true);
    } catch (e) {
      debugPrint('Record start error: $e');
      setState(() => _isRecording = false);
    }
  }

  Future<void> _stopAndSendRecording() async {
    try {
      final path = await _recorder.stop();
      setState(() => _isRecording = false);
      if (path == null || path.isEmpty) return;

      setState(() => _sending = true);

      // Check offline status
      final conn = await Connectivity().checkConnectivity();
      final offline = conn == ConnectivityResult.none;
      final uid = _auth.currentUser?.uid;
      if (!kIsWeb && offline && uid != null) {
        final msgRef = await _firestore
            .collection('conversations')
            .doc(widget.conversationId)
            .collection('messages')
            .add({
          'sender_id': uid,
          'text': '',
          'timestamp': DateTime.now().millisecondsSinceEpoch,
          'file_url': '',
          'file_type': 'audio',
          'reactions': <String, dynamic>{},
          'edited': false,
          'uploading': true,
        });

        await BackgroundTasks.enqueueAction({
          'type': 'upload_message_audio',
          'conversationId': widget.conversationId,
          'messageId': msgRef.id,
          'localPath': path,
        });

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Voice will upload when back online')),
        );
        return;
      }

      // Upload now
      String url = '';
      try {
        if (kIsWeb) {
          // Web: read as bytes from the recorded blob
          final bytes = await readAudioBlobAsBytes(path);
          url = await sb.uploadMessageAudioBytes(bytes, fileName: 'voice_${DateTime.now().millisecondsSinceEpoch}.m4a');
        } else {
          url = await sb.uploadMessageAudio(File(path));
        }
      } catch (e) {
        debugPrint('Audio upload error: $e');
        final msg = e.toString();
        if (msg.contains('Supabase bucket')) {
          final dashboard = sb.SupabaseConfig.supabaseUrl.replaceFirst('https://', 'https://app.supabase.com/project/');
          final bucketsUrl = '$dashboard/storage/buckets';
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Failed to upload voice: ${msg}'),
            action: SnackBarAction(
              label: 'Open Storage',
              onPressed: () async {
                final uri = Uri.parse(bucketsUrl);
                if (await canLaunchUrl(uri)) await launchUrl(uri);
              },
            ),
          ));
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to upload voice: ${e.toString()}')),
          );
        }
        return;
      }
      await _sendMessage(fileUrl: url, fileType: 'audio');
    } catch (e) {
      debugPrint('Record stop error: $e');
    }
  }

  Widget _buildAudioBubble(String messageId, String url, bool isMe) {
    final isPlaying = _playingMessageId == messageId;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          icon: Icon(isPlaying ? Icons.pause_circle_filled : Icons.play_circle_fill, color: isMe ? Colors.white : Colors.black87),
          onPressed: () async {
            try {
              if (isPlaying) {
                await _audioPlayer.pause();
                setState(() => _playingMessageId = null);
              } else {
                await _audioPlayer.stop();
                await _audioPlayer.play(UrlSource(url));
                setState(() => _playingMessageId = messageId);
                _audioPlayer.onPlayerComplete.first.then((_) {
                  if (mounted && _playingMessageId == messageId) {
                    setState(() => _playingMessageId = null);
                  }
                });
              }
            } catch (e) {
              debugPrint('Audio play error: $e');
            }
          },
        ),
        Text(
          isPlaying ? 'Playing…' : 'Voice message',
          style: TextStyle(color: isMe ? Colors.white : Colors.black87),
        ),
      ],
    );
  }

  Timer? _typingTimer;
  void _setTyping(bool typing) {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return;
    final doc = _firestore.collection('conversations').doc(widget.conversationId);
    doc.update({'typing.$uid': typing});
    
    _typingTimer?.cancel();
    if (typing) {
      _typingTimer = Timer(const Duration(seconds: 5), () => doc.update({'typing.$uid': false}));
    }
  }

  @override
  Widget build(BuildContext context) {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return const Scaffold(body: Center(child: Text('Please sign in')));

    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: () => Navigator.pop(context)),
        title: StreamBuilder<DocumentSnapshot>(
          stream: _firestore.collection('users').doc(widget.otherUserId).snapshots(),
          builder: (context, snapshot) {
            String title = widget.otherUserId;
            String? avatarUrl;
            
            if (snapshot.hasData && snapshot.data!.exists) {
              final data = snapshot.data!.data() as Map<String, dynamic>?;
              title = data?['name'] ?? widget.otherUserId;
              avatarUrl = data?['profile_image'];
            }
            
            return Row(
              children: [
                GestureDetector(
                  onTap: () {
                    // Open full profile of the other user
                    Navigator.push(context, MaterialPageRoute(
                      builder: (_) => SeeProfileFromNewsfeed(userId: widget.otherUserId)
                    ));
                  },
                  child: (avatarUrl != null && avatarUrl.isNotEmpty)
                    ? CircleAvatar(
                        backgroundImage: CachedNetworkImageProvider(avatarUrl),
                        radius: 16,
                      )
                    : CircleAvatar(
                        backgroundColor: Colors.blue,
                        radius: 16,
                        child: Text(
                          title.isNotEmpty ? title[0].toUpperCase() : '?',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    title,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 16),
                  ),
                ),
              ],
            );
          },
        ),
        actions: [
          IconButton(
            tooltip: 'Audio Call',
            icon: const Icon(Icons.call),
            onPressed: () => _startCall(audioOnly: true),
          ),
          IconButton(
            tooltip: 'Video Call',
            icon: const Icon(Icons.video_call),
            onPressed: () => _startCall(audioOnly: false),
          ),
          IconButton(
            tooltip: 'All media',
            icon: const Icon(Icons.perm_media_outlined),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => ConversationMediaPage(
                    conversationId: widget.conversationId,
                    otherUserId: widget.otherUserId,
                  ),
                ),
              );
            },
          ),

        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: StreamBuilder<DocumentSnapshot>(
              stream: _firestore.collection('conversations').doc(widget.conversationId).snapshots(includeMetadataChanges: true),
              builder: (context, convSnap) {
                bool otherIsTyping = false;
                int otherLastRead = 0;
                if (convSnap.hasData && convSnap.data!.exists) {
                  final convData = convSnap.data!.data() as Map<String, dynamic>? ?? {};
                  final typingMap = convData['typing'] as Map<String, dynamic>? ?? {};
                  otherIsTyping = typingMap[widget.otherUserId] == true;
                  final lastReadMap = convData['last_read'] as Map<String, dynamic>? ?? {};
                  otherLastRead = lastReadMap[widget.otherUserId] ?? 0;
                }

                return StreamBuilder<QuerySnapshot>(
                  stream: _firestore
                      .collection('conversations')
                      .doc(widget.conversationId)
                      .collection('messages')
                      .orderBy('timestamp', descending: false)
                      .snapshots(includeMetadataChanges: true),
                  builder: (context, snap) {
                    if (snap.hasError) {
                      debugPrint('Messages stream error: ${snap.error}');
                      return Center(child: Text('Error: ${snap.error}'));
                    }
                    
                    if (!snap.hasData) return const Center(child: CircularProgressIndicator());

                    final docs = snap.data!.docs;
                    
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      _scrollToBottom();
                    });

                    return Column(
                      children: [
                        Expanded(
                          child: ListView.builder(
                            restorationId: 'chat_list_' + widget.conversationId,
                            controller: _scrollController,
                            padding: const EdgeInsets.all(8),
                            itemCount: docs.length + (otherIsTyping ? 1 : 0),
                            itemBuilder: (context, index) {
                              if (otherIsTyping && index == docs.length) {
                                return const Align(
                                  alignment: Alignment.centerLeft,
                                  child: Padding(
                                    padding: EdgeInsets.all(8.0),
                                    child: Text('Typing...'),
                                  ),
                                );
                              }

                              final d = docs[index];
                              final data = d.data() as Map<String, dynamic>? ?? {};
                              final isMe = data['sender_id'] == uid;
                              final text = data['text'] ?? '';
                              final fileUrl = data['file_url'] ?? '';
                              final fileType = data['file_type'] ?? '';
                              final callChannel = data['call_channel'] ?? '';
                              final timestamp = data['timestamp'] ?? 0;
                              final seen = isMe && otherLastRead >= timestamp;
                              final edited = data['edited'] == true;
                              final uploading = data['uploading'] == true;
                              final pending = d.metadata.hasPendingWrites;

                              return Align(
                                alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
                                child: Column(
                                  crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                                  children: [
                                    GestureDetector(
                                      onLongPress: () => _showMessageOptions(d.id, data, isMe),
                                      child: Container(
                                        margin: const EdgeInsets.symmetric(vertical: 4),
                                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                                        decoration: BoxDecoration(
                                          color: isMe ? Colors.blue : Colors.grey[200],
                                          borderRadius: BorderRadius.only(
                                            topLeft: Radius.circular(isMe ? 16 : 0),
                                            topRight: Radius.circular(isMe ? 0 : 16),
                                            bottomLeft: const Radius.circular(16),
                                            bottomRight: const Radius.circular(16),
                                          ),
                                        ),
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            if (fileUrl.isNotEmpty && fileType == 'audio')
                                              Padding(
                                                padding: const EdgeInsets.only(bottom: 8.0),
                                                child: _buildAudioBubble(d.id, fileUrl, isMe),
                                              ),
                                            if (fileUrl.isNotEmpty && fileType == 'image')
                                              GestureDetector(
                                                onTap: () {
                                                  Navigator.push(
                                                    context,
                                                    MaterialPageRoute(
                                                      builder: (_) => ImageViewerPage(
                                                        imageUrl: fileUrl,
                                                        conversationId: widget.conversationId,
                                                      ),
                                                    ),
                                                  );
                                                },
                                                child: Padding(
                                                  padding: const EdgeInsets.only(bottom: 8.0),
                                                  child: ClipRRect(
                                                    borderRadius: BorderRadius.circular(8),
                                                    child: CachedNetworkImage(
                                                      imageUrl: fileUrl,
                                                      cacheManager: AppCacheManager.instance,
                                                      width: 200,
                                                      fit: BoxFit.cover,
                                                      errorWidget: (context, url, error) => const Icon(Icons.error),
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            if (fileUrl.isNotEmpty && fileType == 'video')
                                              GestureDetector(
                                                onTap: () {
                                                  Navigator.push(
                                                    context,
                                                    MaterialPageRoute(
                                                      builder: (_) => VideoPlayerScreen(
                                                        videos: [{'video_url': fileUrl, 'text': text}],
                                                        startIndex: 0,
                                                      ),
                                                    ),
                                                  );
                                                },
                                                onLongPress: () => _showMessageOptions(d.id, data, isMe),
                                                child: Container(
                                                  width: 200,
                                                  height: 120,
                                                  decoration: BoxDecoration(
                                                    color: Colors.black12,
                                                    borderRadius: BorderRadius.circular(8),
                                                  ),
                                                  child: Column(
                                                    mainAxisAlignment: MainAxisAlignment.center,
                                                    children: [
                                                      const Icon(Icons.play_arrow, size: 40, color: Colors.white),
                                                      Text('Video', style: TextStyle(color: Colors.white)),
                                                    ],
                                                  ),
                                                ),
                                              ),
                                            if (text.isNotEmpty) 
                                              Padding(
                                                padding: const EdgeInsets.only(bottom: 4.0),
                                                child: Text(text, style: TextStyle(color: isMe ? Colors.white : Colors.black)),
                                              ),
                                            if (fileType == 'call_audio' || fileType == 'call_video')
                                              Padding(
                                                padding: const EdgeInsets.only(top: 4.0),
                                                child: ElevatedButton.icon(
                                                  style: ElevatedButton.styleFrom(
                                                    backgroundColor: isMe ? Colors.white : Colors.blue,
                                                    foregroundColor: isMe ? Colors.blue : Colors.white,
                                                  ),
                                                  onPressed: () {
                                                    final channel = callChannel is String && callChannel.isNotEmpty
                                                        ? callChannel
                                                        : 'conv_' + widget.conversationId;
                                                    Navigator.push(
                                                      context,
                                                      CallPage.route(
                                                        channelName: channel,
                                                        video: fileType == 'call_video',
                                                      ),
                                                    );
                                                  },
                                                  icon: Icon(fileType == 'call_video' ? Icons.videocam : Icons.call),
                                                  label: Text(fileType == 'call_video' ? 'Join video call' : 'Join audio call'),
                                                ),
                                              ),
                                            if (uploading)
                                              Padding(
                                                padding: const EdgeInsets.only(bottom: 4.0),
                                                child: Row(
                                                  mainAxisSize: MainAxisSize.min,
                                                  children: [
                                                    const SizedBox(
                                                      width: 12,
                                                      height: 12,
                                                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white70),
                                                    ),
                                                    const SizedBox(width: 8),
                                                    Text(
                                                      'Waiting for network...',
                                                      style: TextStyle(color: isMe ? Colors.white70 : Colors.black54, fontSize: 12),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            if (edited)
                                              Padding(
                                                padding: const EdgeInsets.only(top: 2.0),
                                                child: Text(
                                                  '(edited)',
                                                  style: TextStyle(fontSize: 10, color: isMe ? Colors.white70 : Colors.grey),
                                                ),
                                              ),
                                            // FIXED: Reactions now properly persist and display
                                            if ((data['reactions'] as Map<String, dynamic>?)?.isNotEmpty ?? false)
                                              Padding(
                                                padding: const EdgeInsets.only(top: 4.0),
                                                child: Wrap(
                                                  spacing: 6,
                                                  children: (data['reactions'] as Map<String, dynamic>).entries.map((e) {
                                                    final emoji = e.key;
                                                    final users = List<String>.from(e.value ?? <String>[]);
                                                    final hasMyReaction = users.contains(uid);
                                                    return Container(
                                                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                                      decoration: BoxDecoration(
                                                        color: hasMyReaction ? Colors.blue.shade100 : Colors.white.withOpacity(0.8),
                                                        borderRadius: BorderRadius.circular(12),
                                                        border: Border.all(
                                                          color: hasMyReaction ? Colors.blue : Colors.transparent,
                                                          width: 1,
                                                        ),
                                                      ),
                                                      child: Row(
                                                        mainAxisSize: MainAxisSize.min,
                                                        children: [
                                                          Text(emoji),
                                                          const SizedBox(width: 4),
                                                          Text(users.length.toString()),
                                                        ],
                                                      ),
                                                    );
                                                  }).toList(),
                                                ),
                                              ),
                                            Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                Text(
                                                  _formatMessageTimestamp(timestamp),
                                                  style: TextStyle(fontSize: 10, color: isMe ? Colors.white70 : Colors.grey),
                                                ),
                                                if (isMe)
                                                  Icon(
                                                    pending ? Icons.schedule : Icons.done_all,
                                                    size: 16,
                                                    color: pending
                                                        ? (isMe ? Colors.white70 : Colors.grey)
                                                        : (seen
                                                            ? const Color.fromARGB(255, 175, 135, 76)
                                                            : const Color.fromARGB(255, 235, 238, 237)),
                                                  ),
                                              ],
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                        ),
                      ],
                    );
                  },
                );
              },
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.photo), 
                  onPressed: _sending ? null : _pickAndSendImage
                ),
                IconButton(
                  icon: const Icon(Icons.videocam), 
                  onPressed: _sending ? null : _pickAndSendVideo
                ),
                IconButton(
                  tooltip: _isRecording ? 'Stop' : 'Hold to record voice',
                  icon: Icon(_isRecording ? Icons.stop_circle : Icons.mic),
                  color: _isRecording ? Colors.red : null,
                  onPressed: _sending ? null : _toggleRecord,
                ),
                Expanded(
                  child: TextField(
                    controller: _controller,
                    decoration: const InputDecoration(
                      hintText: 'Type a message',
                      border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(30))),
                      contentPadding: EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                    ),
                    minLines: 1,
                    maxLines: 4,
                    enabled: !_sending,
                    onChanged: (s) {
                      _setTyping(s.trim().isNotEmpty);
                      setState(() {});
                    },
                    onSubmitted: (s) {
                      if (!_sending && s.trim().isNotEmpty) {
                        _sendMessage(text: s.trim());
                      }
                    },
                  ),
                ),
                IconButton(
                  icon: _sending 
                      ? const CircularProgressIndicator() 
                      : const Icon(Icons.send),
                  onPressed: _sending || _controller.text.trim().isEmpty
                      ? null
                      : () => _sendMessage(text: _controller.text.trim()),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _formatMessageTimestamp(int timestamp) {
    final date = DateTime.fromMillisecondsSinceEpoch(timestamp).toLocal();
    return '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
  }

  Future<void> _showMessageOptions(String messageId, Map<String, dynamic> data, bool isMe) async {
    final choice = await showModalBottomSheet<String?>(
      context: context, 
      builder: (c) {
        return SafeArea(
          child: Wrap(
            children: [
              ListTile(
                leading: const Icon(Icons.emoji_emotions),
                title: const Text('React'),
                onTap: () => Navigator.pop(c, 'react'),
              ),
              if (isMe) ListTile(
                leading: const Icon(Icons.edit),
                title: const Text('Edit'),
                onTap: () => Navigator.pop(c, 'edit'),
              ),
              if (isMe) ListTile(
                leading: const Icon(Icons.delete),
                title: const Text('Unsend'),
                onTap: () => Navigator.pop(c, 'unsend'),
              ),
              ListTile(
                leading: const Icon(Icons.cancel),
                title: const Text('Cancel'),
                onTap: () => Navigator.pop(c, null),
              ),
            ],
          ),
        );
      }
    );

    if (choice == 'react') {
      final emoji = await showModalBottomSheet<String?>(
        context: context, 
        builder: (c) {
          return SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Text('Add Reaction', style: Theme.of(context).textTheme.titleMedium),
                ),
                Wrap(
                  children: [
                    _buildEmojiOption(c, '👍'),
                    _buildEmojiOption(c, '❤️'),
                    _buildEmojiOption(c, '😂'),
                    _buildEmojiOption(c, '😮'),
                    _buildEmojiOption(c, '😢'),
                    _buildEmojiOption(c, '🔥'),
                  ],
                ),
                const SizedBox(height: 16),
                TextButton(
                  onPressed: () => Navigator.pop(c, null),
                  child: const Text('Cancel'),
                ),
              ],
            ),
          );
        }
      );
      if (emoji != null) await _toggleReaction(messageId, emoji);
    }

    if (choice == 'edit' && isMe) {
      final current = data['text'] ?? '';
      final editCtrl = TextEditingController(text: current);
      final res = await showDialog<String?>(
        context: context, 
        builder: (c) {
          return AlertDialog(
            title: const Text('Edit message'),
            content: TextField(controller: editCtrl),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(c, null), 
                child: const Text('Cancel')
              ),
              TextButton(
                onPressed: () => Navigator.pop(c, editCtrl.text.trim()), 
                child: const Text('Save')
              ),
            ],
          );
        }
      );
      if (res != null) {
        await _firestore
            .collection('conversations')
            .doc(widget.conversationId)
            .collection('messages')
            .doc(messageId)
            .update({'text': res, 'edited': true});
      }
    }

    if (choice == 'unsend' && isMe) {
      final ok = await showDialog<bool?>(
        context: context, 
        builder: (c) {
          return AlertDialog(
            title: const Text('Unsend message'),
            content: const Text('Delete this message for everyone?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(c, false), 
                child: const Text('No')
              ),
              TextButton(
                onPressed: () => Navigator.pop(c, true), 
                child: const Text('Yes')
              ),
            ],
          );
        }
      );
      if (ok == true) {
        await _firestore
            .collection('conversations')
            .doc(widget.conversationId)
            .collection('messages')
            .doc(messageId)
            .delete();
      }
    }
  }

  Widget _buildEmojiOption(BuildContext context, String emoji) {
    return IconButton(
      icon: Text(emoji, style: const TextStyle(fontSize: 24)),
      onPressed: () => Navigator.pop(context, emoji),
    );
  }

  Future<void> _toggleReaction(String messageId, String emoji) async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return;
    
    final docRef = _firestore
        .collection('conversations')
        .doc(widget.conversationId)
        .collection('messages')
        .doc(messageId);
        
    try {
      final snap = await docRef.get();
      if (!snap.exists) return;
      
      final data = snap.data() ?? {};
      final Map<String, dynamic> reactions = Map<String, dynamic>.from(data['reactions'] ?? {});
      final List<String> users = List<String>.from(reactions[emoji] ?? <String>[]);
      
      if (users.contains(uid)) {
        users.remove(uid);
      } else {
        users.add(uid);
      }
      
      if (users.isEmpty) {
        reactions.remove(emoji);
      } else {
        reactions[emoji] = users;
      }
      
      await docRef.update({'reactions': reactions});
    } catch (e) {
      debugPrint('Error toggling reaction: $e');
    }
  }
}

// Per-page new message bubble removed; use GlobalNewMessageBubble instead.

/// Full-screen image viewer with pinch-zoom and download + media button.
class ImageViewerPage extends StatelessWidget {
  final String imageUrl;
  final String? conversationId;
  const ImageViewerPage({super.key, required this.imageUrl, this.conversationId});

  Future<void> _download(BuildContext context) async {
    final uri = Uri.parse(imageUrl);
    if (!await canLaunchUrl(uri)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Cannot open downloader')));
      return;
    }
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Image'),
        actions: [
          IconButton(
            tooltip: 'Download',
            icon: const Icon(Icons.download),
            onPressed: () => _download(context),
          ),
          if (conversationId != null)
            IconButton(
              tooltip: 'All media',
              icon: const Icon(Icons.perm_media_outlined),
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => ConversationMediaPage(
                      conversationId: conversationId ?? '',
                      otherUserId: '',
                    ),
                  ),
                );
              },
            ),
        ],
      ),
      backgroundColor: Colors.black,
      body: Center(
        child: InteractiveViewer(
          panEnabled: true,
          minScale: 0.5,
          maxScale: 4,
          child: CachedNetworkImage(
            imageUrl: imageUrl,
            cacheManager: AppCacheManager.instance,
            fit: BoxFit.contain,
            errorWidget: (c, u, e) => const Icon(Icons.error, color: Colors.white),
          ),
        ),
      ),
    );
  }
}

/// Shows all images and videos in a conversation, newest first.
class ConversationMediaPage extends StatelessWidget {
  final String conversationId;
  final String otherUserId; // optional name lookup not strictly needed here
  const ConversationMediaPage({super.key, required this.conversationId, required this.otherUserId});

  @override
  Widget build(BuildContext context) {
    final FirebaseFirestore _firestore = FirebaseFirestore.instance;
    return Scaffold(
      appBar: AppBar(title: const Text('Conversation media')),
      body: StreamBuilder<QuerySnapshot>(
        stream: _firestore
            .collection('conversations')
            .doc(conversationId)
            .collection('messages')
            .orderBy('timestamp', descending: true)
            .snapshots(),
        builder: (context, snap) {
          if (snap.hasError) {
            return Center(child: Text('Error: ${snap.error}'));
          }
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }

          final docs = snap.data!.docs;
          final items = docs.map((d) => d.data() as Map<String, dynamic>? ?? {}).where((m) {
            final url = (m['file_url'] ?? '') as String;
            final t = (m['file_type'] ?? '') as String;
            return url.isNotEmpty && (t == 'image' || t == 'video');
          }).toList();

          if (items.isEmpty) {
            return const Center(child: Text('No media yet'));
          }

          return GridView.builder(
            padding: const EdgeInsets.all(8),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
            ),
            itemCount: items.length,
            itemBuilder: (context, i) {
              final m = items[i];
              final url = (m['file_url'] ?? '') as String;
              final t = (m['file_type'] ?? '') as String;
              if (t == 'image') {
                return GestureDetector(
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => ImageViewerPage(imageUrl: url, conversationId: conversationId),
                      ),
                    );
                  },
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: CachedNetworkImage(
                      imageUrl: url,
                      fit: BoxFit.cover,
                      cacheManager: AppCacheManager.instance,
                    ),
                  ),
                );
              } else {
                // video tile
                return GestureDetector(
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => VideoPlayerScreen(
                          videos: [
                            {'video_url': url, 'text': 'Video'}
                          ],
                          startIndex: 0,
                        ),
                      ),
                    );
                  },
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Container(color: Colors.black12),
                      ),
                      const Center(child: Icon(Icons.play_circle_fill, size: 36, color: Colors.white)),
                    ],
                  ),
                );
              }
            },
          );
        },
      ),
    );
  }
}

class IncomingCallDialog extends StatefulWidget {
  final String conversationId;
  final String fromUserId;
  final String channelName;
  final bool video;
  final VoidCallback onFinished;
  const IncomingCallDialog({super.key, required this.conversationId, required this.fromUserId, required this.channelName, required this.video, required this.onFinished});
  @override
  State<IncomingCallDialog> createState() => _IncomingCallDialogState();
}

class _IncomingCallDialogState extends State<IncomingCallDialog> {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  Map<String, dynamic>? _user;

  @override
  void initState() {
    super.initState();
    _loadUser();
  }

  Future<void> _loadUser() async {
    try {
      final doc = await _firestore.collection('users').doc(widget.fromUserId).get();
      if (doc.exists) setState(() => _user = doc.data());
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final name = _user?['name'] ?? widget.fromUserId;
    final avatarUrl = _user?['profile_image'];
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      backgroundColor: Colors.black87,
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircleAvatar(
              radius: 48,
              backgroundColor: Colors.blueGrey,
              backgroundImage: (avatarUrl is String && avatarUrl.isNotEmpty) ? NetworkImage(avatarUrl) : null,
              child: (avatarUrl is String && avatarUrl.isNotEmpty) ? null : Text(name[0].toUpperCase(), style: const TextStyle(fontSize: 32, color: Colors.white)),
            ),
            const SizedBox(height: 16),
            Text('${widget.video ? 'Video' : 'Audio'} call from', style: const TextStyle(color: Colors.white70)),
            const SizedBox(height: 8),
            Text(name, style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w600)),
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
                  onPressed: () { Navigator.pop(context); widget.onFinished(); },
                  icon: const Icon(Icons.call_end),
                  label: const Text('Decline'),
                ),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
                  onPressed: () {
                    Navigator.pop(context); widget.onFinished();
                    Navigator.push(context, CallPage.route(channelName: widget.channelName, video: widget.video, conversationId: widget.conversationId, remoteUserId: widget.fromUserId));
                  },
                  icon: Icon(widget.video ? Icons.videocam : Icons.call),
                  label: const Text('Accept'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}