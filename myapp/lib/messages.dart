import 'dart:io';

import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'supabase.dart' as sb;

/// Conversations list and chat screen.
class MessagesPage extends StatefulWidget {
  const MessagesPage({super.key});

  @override
  State<MessagesPage> createState() => _MessagesPageState();
}

class _MessagesPageState extends State<MessagesPage> {
  final firebase_auth.FirebaseAuth _auth = firebase_auth.FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

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
            .orderBy('last_updated', descending: true)
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.hasError) return const Center(child: Text('Error loading conversations'));
          if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());

          final docs = snapshot.data!.docs;
          if (docs.isEmpty) return const Center(child: Text('No conversations yet'));

          return ListView.builder(
            itemCount: docs.length,
            itemBuilder: (context, index) {
              final doc = docs[index];
              final data = doc.data() as Map<String, dynamic>? ?? {};
              final participants = List<String>.from(data['participants'] ?? <String>[]);
              final otherId = participants.firstWhere((p) => p != uid, orElse: () => '');
              final lastMessage = data['last_message'] ?? '';
              final lastUpdated = data['last_updated'] ?? 0;

              // If there's no otherId, show a fallback tile; otherwise fetch the user's display name/avatar.
              if (otherId.isEmpty) {
                return ListTile(
                  leading: const CircleAvatar(child: Icon(Icons.person)),
                  title: const Text('Conversation'),
                  subtitle: Text(lastMessage, maxLines: 1, overflow: TextOverflow.ellipsis),
                  trailing: Text(lastUpdated == 0 ? '' : DateTime.fromMillisecondsSinceEpoch(lastUpdated).toLocal().toString().split('.').first),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => ChatPage(conversationId: doc.id, otherUserId: otherId)),
                  ),
                );
              }

              return FutureBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                future: _firestore.collection('users').doc(otherId).get(),
                builder: (context, userSnap) {
                  String title = otherId;
                  String? avatarUrl;
                  if (userSnap.hasData && userSnap.data != null && userSnap.data!.exists) {
                    final u = userSnap.data!.data();
                    if (u != null) {
                      title = u['name'] ?? otherId;
                      avatarUrl = u['profile_image'];
                    }
                  }
                  return ListTile(
                    leading: avatarUrl != null
                        ? CircleAvatar(backgroundImage: CachedNetworkImageProvider(avatarUrl))
                        : const CircleAvatar(child: Icon(Icons.person)),
                    title: Text(title.isNotEmpty ? title : 'Conversation'),
                    subtitle: Text(lastMessage, maxLines: 1, overflow: TextOverflow.ellipsis),
                    trailing: Text(lastUpdated == 0 ? '' : DateTime.fromMillisecondsSinceEpoch(lastUpdated).toLocal().toString().split('.').first),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => ChatPage(conversationId: doc.id, otherUserId: otherId)),
                    ),
                  );
                },
              );
            },
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        child: const Icon(Icons.create),
        onPressed: () => _showUserSearch(initialOnlyIdEntry: true),
      ),
    );
  }

  Future<void> _showUserSearch({bool initialOnlyIdEntry = false}) async {
    final TextEditingController ctrl = TextEditingController();

    if (initialOnlyIdEntry) {
      // reuse previous simple dialog to enter id
      final otherId = await showDialog<String?>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Start conversation by id'),
          content: TextField(controller: ctrl, decoration: const InputDecoration(hintText: 'Enter user id')),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            TextButton(onPressed: () => Navigator.pop(context, ctrl.text.trim()), child: const Text('Start')),
          ],
        ),
      );

      if (otherId != null && otherId.isNotEmpty) {
        await _startConversationWith(otherId);
      }
      return;
    }

    // Full name search
    await showDialog<void>(
      context: context,
      builder: (context) {
        final searchCtrl = TextEditingController();
        List<QueryDocumentSnapshot> results = [];

        return StatefulBuilder(builder: (context, setState) {
          Future<void> doSearch() async {
            final q = searchCtrl.text.trim();
            if (q.isEmpty) return;
            final snapshot = await _firestore
                .collection('users')
                .where('name', isGreaterThanOrEqualTo: q)
                .where('name', isLessThanOrEqualTo: '$q\uf8ff')
                .limit(20)
                .get();
            setState(() => results = snapshot.docs);
          }

          return AlertDialog(
            title: const Text('Search users by name'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(controller: searchCtrl, decoration: const InputDecoration(hintText: 'Name')),                
                const SizedBox(height: 12),
                if (results.isEmpty)
                  const Text('No results')
                else
                  SizedBox(
                    height: 200,
                    width: double.maxFinite,
                    child: ListView.builder(
                      itemCount: results.length,
                      itemBuilder: (context, i) {
                        final u = results[i].data() as Map<String, dynamic>;
                        final uid = results[i].id;
                        return ListTile(
                          leading: u['profile_image'] != null ? CircleAvatar(backgroundImage: CachedNetworkImageProvider(u['profile_image'])) : const CircleAvatar(child: Icon(Icons.person)),
                          title: Text(u['name'] ?? uid),
                          subtitle: Text(u['email'] ?? ''),
                          onTap: () async {
                            Navigator.pop(context);
                            await _startConversationWith(uid);
                          },
                        );
                      },
                    ),
                  ),
              ],
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
              TextButton(onPressed: () => doSearch(), child: const Text('Search')),
            ],
          );
        });
      },
    );
  }

  Future<void> _startConversationWith(String otherId) async {
    final uid = _auth.currentUser!.uid;
    final q = await _firestore.collection('conversations').where('participants', arrayContains: uid).get();
    String? convId;
    for (var d in q.docs) {
      final participants = List<String>.from(d.data()['participants'] ?? <String>[]);
      if (participants.contains(otherId) && participants.contains(uid)) {
        convId = d.id;
        break;
      }
    }
    if (convId == null) {
      final ref = await _firestore.collection('conversations').add({
        'participants': [uid, otherId],
        'last_message': '',
        'last_updated': DateTime.now().millisecondsSinceEpoch,
      });
      convId = ref.id;
    }

    Navigator.push(context, MaterialPageRoute(builder: (_) => ChatPage(conversationId: convId!, otherUserId: otherId)));
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

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _sendMessage({String? text, String? fileUrl, String? fileType}) async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return;
    if ((text == null || text.isEmpty) && (fileUrl == null || fileUrl.isEmpty)) return;

    setState(() => _sending = true);

    final msg = {
      'sender_id': uid,
      'text': text ?? '',
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'file_url': fileUrl ?? '',
      'file_type': fileType ?? '',
      // reactions stored as map: {emoji: [uid1, uid2]}
      'reactions': <String, dynamic>{},
    };

  await _firestore.collection('conversations').doc(widget.conversationId).collection('messages').add(msg);

    // update conversation last_message/last_updated and mark sender as having read up to this message
    final lastUpdated = DateTime.now().millisecondsSinceEpoch;
    final lastMessageText = text ?? (fileType == 'image' ? '[Image]' : '[File]');
    await _firestore.collection('conversations').doc(widget.conversationId).update({
      'last_message': lastMessageText,
      'last_updated': lastUpdated,
      // last_read is a map of userId -> timestamp; update sender's last_read
      'last_read.${uid}': lastUpdated,
    });

    setState(() {
      _sending = false;
      _controller.clear();
    });
  }

  Future<void> _pickAndSendImage() async {
    final XFile? picked = await _picker.pickImage(source: ImageSource.gallery, imageQuality: 80);
    if (picked == null) return;
    final File file = File(picked.path);

    // Upload to Supabase using the existing public bucket 'post-images'.
    String url = '';
    try {
      url = await sb.uploadPostImage(file);
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Failed to upload image')));
      return;
    }

    await _sendMessage(fileUrl: url, fileType: 'image');
  }

  // set typing indicator for this conversation
  Timer? _typingTimer;
  void _setTyping(bool typing) {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return;
    final doc = _firestore.collection('conversations').doc(widget.conversationId);
    doc.update({'typing.${uid}': typing});
    // auto-clear after 5 seconds of no typing
    _typingTimer?.cancel();
    if (typing) {
      _typingTimer = Timer(const Duration(seconds: 5), () => doc.update({'typing.${uid}': false}));
    }
  }

  @override
  Widget build(BuildContext context) {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return const Scaffold(body: Center(child: Text('Please sign in')));

    return Scaffold(
      appBar: AppBar(title: Text('Chat with ${widget.otherUserId}')),
      body: Column(
        children: [
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream: _firestore
                  .collection('conversations')
                  .doc(widget.conversationId)
                  .collection('messages')
                  .orderBy('timestamp', descending: false)
                  .snapshots(),
              builder: (context, snap) {
                if (snap.hasError) return const Center(child: Text('Error'));
                if (!snap.hasData) return const Center(child: CircularProgressIndicator());

                final docs = snap.data!.docs;
                return ListView.builder(
                  padding: const EdgeInsets.all(8),
                  itemCount: docs.length,
                  itemBuilder: (context, index) {
                    final d = docs[index];
                    final data = d.data() as Map<String, dynamic>? ?? {};
                    final isMe = data['sender_id'] == uid;
                    final text = data['text'] ?? '';
                    final fileUrl = data['file_url'] ?? '';
                    final fileType = data['file_type'] ?? '';

                    return Align(
                      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
                      child: Container(
                        margin: const EdgeInsets.symmetric(vertical: 4),
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: isMe ? Colors.blue[200] : Colors.grey[200],
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (fileUrl != null && fileUrl.isNotEmpty && fileType == 'image')
                              SizedBox(
                                width: 200,
                                child: CachedNetworkImage(imageUrl: fileUrl),
                              ),
                            if (text.isNotEmpty) Text(text),
                            const SizedBox(height: 4),
                            Text(
                              DateTime.fromMillisecondsSinceEpoch((data['timestamp'] ?? 0) as int)
                                  .toLocal()
                                  .toString()
                                  .split('.')
                                  .first,
                              style: const TextStyle(fontSize: 10, color: Colors.grey),
                            ),
                          ],
                        ),
                      ),
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
                IconButton(icon: const Icon(Icons.photo), onPressed: _pickAndSendImage),
                Expanded(
                  child: TextField(
                    controller: _controller,
                    decoration: const InputDecoration(hintText: 'Type a message'),
                    minLines: 1,
                    maxLines: 4,
                    onChanged: (s) {
                      _setTyping(s.isNotEmpty);
                    },
                  ),
                ),
                IconButton(
                  icon: _sending ? const CircularProgressIndicator() : const Icon(Icons.send),
                  onPressed: _sending
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
}
