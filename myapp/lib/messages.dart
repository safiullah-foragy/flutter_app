import 'dart:io';
import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'supabase.dart' as sb;
import 'videos.dart';
import 'newsfeed.dart'; // Assuming newsfeed.dart exists and contains NewsfeedPage or similar
import 'see_profile_from_newsfeed.dart';

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
          .snapshots(),
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

          return ListView.builder(
            itemCount: convs.length,
            itemBuilder: (context, index) {
              final d = convs[index]['doc'] as QueryDocumentSnapshot;
              final data = convs[index]['data'] as Map<String, dynamic>;
              final participants = List<String>.from(data['participants'] ?? <String>[]);
              final otherId = participants.firstWhere((p) => p != uid, orElse: () => '');
              final lastMessage = data['last_message'] ?? '';
              final lastUpdated = data['last_updated'] ?? 0;
              final archivedMap = Map<String, dynamic>.from(data['archived'] ?? <String, dynamic>{});
              final isArchived = archivedMap[uid] == true;
              final unread = convs[index]['unread'] as bool;

              if (otherId.isEmpty) {
                return ListTile(
                  leading: const CircleAvatar(child: Icon(Icons.person)),
                  title: const Text('Conversation'),
                  subtitle: Text(lastMessage, maxLines: 1, overflow: TextOverflow.ellipsis),
                  trailing: Text(_formatTimestamp(lastUpdated)),
                  onTap: () async {
                    await _markConversationRead(d.id, uid);
                    Navigator.push(context, MaterialPageRoute(
                      builder: (_) => ChatPage(conversationId: d.id, otherUserId: otherId))
                    );
                  },
                );
              }

              return FutureBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                future: _firestore.collection('users').doc(otherId).get(),
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
                      trailing: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(_formatTimestamp(lastUpdated), style: const TextStyle(fontSize: 12)),
                          if (unread) const Icon(Icons.circle, color: Colors.blue, size: 10),
                        ],
                      ),
                      onTap: () async {
                        await _markConversationRead(d.id, uid);
                        Navigator.push(context, MaterialPageRoute(
                          builder: (_) => ChatPage(conversationId: d.id, otherUserId: otherId))
                        );
                      },
                    ),
                  );
                },
              );
            },
          );
        },
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
    final uid = _auth.currentUser!.uid;
    
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

    Navigator.push(context, MaterialPageRoute(
      builder: (_) => ChatPage(conversationId: convId!, otherUserId: otherId))
    );
  }

  Future<bool> _deleteConversation(String conversationId) async {
    try {
      final msgs = await _firestore
          .collection('conversations')
          .doc(conversationId)
          .collection('messages')
          .get();
      
      final batch = _firestore.batch();
      for (var d in msgs.docs) {
        batch.delete(d.reference);
      }
      await batch.commit();
      await _firestore.collection('conversations').doc(conversationId).delete();
      return true;
    } catch (e) {
      debugPrint('Failed to delete conversation $conversationId: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to delete conversation'))
      );
      return false;
    }
  }
}

class ChatPage extends StatefulWidget {
  final String conversationId;
  final String otherUserId;

  const ChatPage({required this.conversationId, required this.otherUserId, super.key});

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
  bool _isTyping = false;

  @override
  void initState() {
    super.initState();
    _markRead();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToBottom();
    });
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
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
    super.dispose();
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
      final lastMessageText = text ?? (fileType == 'image' ? '[Image]' : fileType == 'video' ? '[Video]' : '[File]');
      
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
        imageQuality: 80
      );
      if (picked == null) return;
      
      final File file = File(picked.path);
      setState(() => _sending = true);
      
      String url = '';
      try {
        url = await sb.uploadMessageImage(file);
      } catch (e) {
        debugPrint('Image upload error: $e');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to upload image: ${e.toString()}'))
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
      
      final File file = File(picked.path);
      setState(() => _sending = true);
      
      String url = '';
      try {
        url = await sb.uploadMessageVideo(file);
      } catch (e) {
        debugPrint('Video upload error: $e');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to upload video: ${e.toString()}'))
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
        // Removed the back button from appBar
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
      ),
      body: Column(
        children: [
          Expanded(
            child: StreamBuilder<DocumentSnapshot>(
              stream: _firestore.collection('conversations').doc(widget.conversationId).snapshots(),
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
                      .snapshots(),
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
                              final timestamp = data['timestamp'] ?? 0;
                              final seen = isMe && otherLastRead >= timestamp;
                              final edited = data['edited'] == true;

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
                                            if (fileUrl.isNotEmpty && fileType == 'image')
                                              Padding(
                                                padding: const EdgeInsets.only(bottom: 8.0),
                                                child: ClipRRect(
                                                  borderRadius: BorderRadius.circular(8),
                                                  child: CachedNetworkImage(
                                                    imageUrl: fileUrl,
                                                    width: 200,
                                                    fit: BoxFit.cover,
                                                    errorWidget: (context, url, error) => 
                                                      const Icon(Icons.error),
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
                                                    Icons.done_all,
                                                    size: 16,
                                                    color: seen ? Colors.green : Colors.grey,
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