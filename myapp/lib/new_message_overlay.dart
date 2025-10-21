import 'dart:async';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import 'package:flutter/material.dart';
import 'messages.dart' show ChatPage; // to navigate into the conversation

/// A global overlay that shows a small bubble when there's an unread conversation.
/// Appears above every page while the app is running.
class GlobalNewMessageBubble extends StatefulWidget {
  const GlobalNewMessageBubble({super.key});

  @override
  State<GlobalNewMessageBubble> createState() => _GlobalNewMessageBubbleState();
}

class _GlobalNewMessageBubbleState extends State<GlobalNewMessageBubble> {
  final _auth = firebase_auth.FirebaseAuth.instance;
  final _firestore = FirebaseFirestore.instance;

  StreamSubscription<QuerySnapshot>? _sub;
  String? _convId;
  String? _otherId;
  String? _lastMsg;
  final Set<String> _dismissed = <String>{};

  @override
  void initState() {
    super.initState();
    _startListening();
  }

  void _startListening() {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return;
    _sub?.cancel();
    _sub = _firestore
        .collection('conversations')
        .where('participants', arrayContains: uid)
        .snapshots(includeMetadataChanges: true)
        .listen((snap) async {
      String? bestConvId;
      String? bestOtherId;
      String? bestLastMsg;
      int bestUpdated = 0;

      for (final d in snap.docs) {
        final data = d.data() as Map<String, dynamic>? ?? {};
        final lastRead = (Map<String, dynamic>.from(data['last_read'] ?? {}))[uid] ?? 0;
        final updated = (data['last_updated'] ?? 0) as int;
        if (updated > lastRead && !_dismissed.contains(d.id)) {
          if (updated > bestUpdated) {
            final parts = List<String>.from(data['participants'] ?? <String>[]);
            final other = parts.firstWhere((p) => p != uid, orElse: () => '');
            bestConvId = d.id;
            bestOtherId = other;
            bestUpdated = updated;
            bestLastMsg = (data['last_message'] ?? '') as String?;
          }
        }
      }

      if (!mounted) return;
      setState(() {
        _convId = bestConvId;
        _otherId = bestOtherId;
        _lastMsg = bestLastMsg;
      });
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final convId = _convId;
    final otherId = _otherId;
    if (convId == null || otherId == null || otherId.isEmpty) return const SizedBox.shrink();

    return Positioned(
      right: 16,
      bottom: 24,
      child: _Bubble(
        conversationId: convId,
        otherUserId: otherId,
        lastMessage: _lastMsg ?? 'New message',
        onOpen: () async {
          final uid = _auth.currentUser?.uid;
          if (uid != null) {
            try {
              await _firestore.collection('conversations').doc(convId).update({
                'last_read.$uid': DateTime.now().millisecondsSinceEpoch
              });
            } catch (_) {}
          }
          if (mounted) {
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => ChatPage(conversationId: convId, otherUserId: otherId),
              ),
            );
          }
        },
        onDismiss: () {
          setState(() {
            _dismissed.add(convId);
            _convId = null;
            _otherId = null;
            _lastMsg = null;
          });
        },
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  final String conversationId;
  final String otherUserId;
  final String lastMessage;
  final VoidCallback onOpen;
  final VoidCallback onDismiss;

  const _Bubble({
    required this.conversationId,
    required this.otherUserId,
    required this.lastMessage,
    required this.onOpen,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final firestore = FirebaseFirestore.instance;
    return Material(
      color: Colors.transparent,
      child: GestureDetector(
        onTap: onOpen,
        child: Dismissible(
          key: ValueKey('global_bubble_$conversationId'),
          direction: DismissDirection.down,
          onDismissed: (_) => onDismiss(),
          child: Container(
            constraints: const BoxConstraints(maxWidth: 280),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(24),
              boxShadow: const [
                BoxShadow(color: Colors.black26, blurRadius: 8, offset: Offset(0, 4)),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                FutureBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                  future: firestore.collection('users').doc(otherUserId).get(),
                  builder: (context, snap) {
                    String name = otherUserId;
                    String? avatarUrl;
                    if (snap.hasData && snap.data != null && snap.data!.exists) {
                      final u = snap.data!.data();
                      name = (u?['name'] as String?)?.trim().isNotEmpty == true ? u!['name'] as String : otherUserId;
                      avatarUrl = u?['profile_image'] as String?;
                    }
                    return Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        (avatarUrl != null && avatarUrl.isNotEmpty)
                            ? CircleAvatar(backgroundImage: CachedNetworkImageProvider(avatarUrl))
                            : CircleAvatar(
                                backgroundColor: Colors.blue,
                                child: Text(
                                  name.isNotEmpty ? name[0].toUpperCase() : '?',
                                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                                ),
                              ),
                        const SizedBox(width: 10),
                        Flexible(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                name,
                                overflow: TextOverflow.ellipsis,
                                maxLines: 1,
                                style: const TextStyle(fontWeight: FontWeight.w700),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                lastMessage.isNotEmpty ? lastMessage : 'New message',
                                overflow: TextOverflow.ellipsis,
                                maxLines: 1,
                                style: const TextStyle(color: Colors.black54),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 6),
                        InkWell(
                          onTap: onDismiss,
                          child: const Icon(Icons.close, size: 18, color: Colors.black45),
                        ),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
