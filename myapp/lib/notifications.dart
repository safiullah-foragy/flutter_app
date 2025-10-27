import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import 'package:url_launcher/url_launcher.dart';

class NotificationsPage extends StatelessWidget {
  const NotificationsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final auth = firebase_auth.FirebaseAuth.instance;
    final fs = FirebaseFirestore.instance;
    final uid = auth.currentUser?.uid;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Notifications'),
        backgroundColor: Colors.blue[800],
        foregroundColor: Colors.white,
        actions: [
          if (uid != null)
            IconButton(
              tooltip: 'Mark all as read',
              icon: const Icon(Icons.done_all),
              onPressed: () async {
                // Only fetch unread to satisfy security rules and avoid no-op updates
                final query = await fs
                    .collection('notifications')
                    .where('to', isEqualTo: uid)
                    .where('read', isEqualTo: false)
                    .get();

                final docs = query.docs;
                if (docs.isEmpty) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('All caught up')),
                    );
                  }
                  return;
                }

                // Commit in chunks to respect Firestore write limits
                int updated = 0;
                const int chunk = 450; // conservative under 500 writes per batch
                for (int i = 0; i < docs.length; i += chunk) {
                  final end = (i + chunk < docs.length) ? i + chunk : docs.length;
                  final batch = fs.batch();
                  for (int j = i; j < end; j++) {
                    batch.update(docs[j].reference, {'read': true});
                  }
                  await batch.commit();
                  updated += (end - i);
                }

                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Marked $updated as read')),
                  );
                }
              },
            ),
        ],
      ),
      body: uid == null
          ? const Center(child: Text('Please sign in'))
          : StreamBuilder<QuerySnapshot>(
              stream: fs
                  .collection('notifications')
                  .where('to', isEqualTo: uid)
                  .orderBy('timestamp', descending: true)
                  .snapshots(),
              builder: (context, snap) {
                if (snap.hasError) return _buildIndexError(context, snap.error);
                if (!snap.hasData) return const Center(child: CircularProgressIndicator());
                final docs = snap.data!.docs;
                if (docs.isEmpty) return const Center(child: Text('No notifications'));
                return ListView.separated(
                  itemCount: docs.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final d = docs[i];
                    final data = d.data() as Map<String, dynamic>? ?? {};
                    final type = (data['type'] ?? '') as String; // like | comment
                    final fromName = (data['fromName'] ?? 'Someone') as String;
                    final ts = (data['timestamp'] ?? 0) as int;
                    final read = (data['read'] ?? false) as bool;
                    final text = type == 'comment'
                        ? '$fromName commented on your post'
                        : type == 'like'
                            ? '$fromName liked your post'
                            : data['text'] ?? 'Notification';
                    return ListTile(
                      leading: Icon(
                        type == 'comment' ? Icons.comment : Icons.thumb_up,
                        color: read ? Colors.grey : Colors.blue,
                      ),
                      title: Text(text),
                      subtitle: Text(_formatTime(ts)),
                      trailing: read ? null : const Icon(Icons.fiber_manual_record, size: 10, color: Colors.blue),
                      onTap: () async {
                        // Only update if unread to satisfy rules (changedKeys must only be 'read')
                        if (!read) {
                          await d.reference.update({'read': true});
                        }
                        Navigator.pop(context); // back to feed; optional: navigate to post detail if available
                      },
                    );
                  },
                );
              },
            ),
    );
  }

  Widget _buildIndexError(BuildContext context, Object? error) {
    final msg = error?.toString() ?? 'Unknown error';
    final url = _extractFirstUrl(msg);
    final isIndexError = msg.contains('requires an index') || msg.contains('FAILED_PRECONDITION');
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(isIndexError ? Icons.storage : Icons.error_outline, size: 48, color: Colors.orange),
          const SizedBox(height: 12),
          Text(
            isIndexError
                ? 'Notifications index is missing or still building.'
                : 'Error loading notifications.',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Text(
            isIndexError
                ? 'Please create the suggested Firestore index, then wait a couple of minutes for it to finish building.'
                : msg,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          if (isIndexError && url != null)
            ElevatedButton.icon(
              onPressed: () async {
                final uri = Uri.parse(url);
                if (await canLaunchUrl(uri)) {
                  await launchUrl(uri, mode: LaunchMode.externalApplication);
                } else {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Could not open the Firebase Console link.')),
                    );
                  }
                }
              },
              icon: const Icon(Icons.open_in_new),
              label: const Text('Open Console'),
            ),
        ],
      ),
    );
  }

  String? _extractFirstUrl(String text) {
    final reg = RegExp(r'https?://[^\s)\"]+');
    final m = reg.firstMatch(text);
    return m?.group(0);
  }

  String _formatTime(int ts) {
    if (ts <= 0) return '';
    final dt = DateTime.fromMillisecondsSinceEpoch(ts);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final thatDay = DateTime(dt.year, dt.month, dt.day);
    if (thatDay == today) {
      return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}'
          ' • Today';
    }
    return '${dt.month}/${dt.day}/${dt.year}';
  }
}