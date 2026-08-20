import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:url_launcher/url_launcher.dart';
import 'theme_controller.dart';
import 'notification_service.dart';

class NotificationsPage extends StatefulWidget {
  const NotificationsPage({super.key});

  @override
  State<NotificationsPage> createState() => _NotificationsPageState();
}

class _NotificationsPageState extends State<NotificationsPage> with SingleTickerProviderStateMixin {
  final firebase_auth.FirebaseAuth _auth = firebase_auth.FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  String _selectedFilter = 'all'; // all, unread, like, comment, job, connect
  bool _hasNotificationPermission = true;
  bool _checkingPermission = true;

  @override
  void initState() {
    super.initState();
    _checkPermission();
  }

  Future<void> _checkPermission() async {
    final granted = await NotificationService.instance.checkNotificationPermission();
    if (mounted) {
      setState(() {
        _hasNotificationPermission = granted;
        _checkingPermission = false;
      });
    }
  }

  Future<void> _requestPermission() async {
    final granted = await NotificationService.instance.requestNotificationPermissions();
    if (mounted) {
      setState(() {
        _hasNotificationPermission = granted;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            granted
                ? '🔔 Device notifications enabled! You will be alerted directly on your phone.'
                : '⚠️ Notification permission was not granted.',
          ),
          backgroundColor: granted ? Colors.green.shade700 : Colors.orange.shade800,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _markAllAsRead(String uid) async {
    try {
      final query = await _firestore
          .collection('notifications')
          .where('to', isEqualTo: uid)
          .where('read', isEqualTo: false)
          .get();

      final docs = query.docs;
      if (docs.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('All notifications already marked as read'),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
        return;
      }

      const int chunk = 450;
      for (int i = 0; i < docs.length; i += chunk) {
        final end = (i + chunk < docs.length) ? i + chunk : docs.length;
        final batch = _firestore.batch();
        for (int j = i; j < end; j++) {
          batch.update(docs[j].reference, {'read': true});
        }
        await batch.commit();
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Marked ${docs.length} notifications as read'),
            backgroundColor: Colors.green.shade700,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error updating: $e'), backgroundColor: Colors.red.shade700),
        );
      }
    }
  }

  Future<void> _deleteNotification(DocumentReference ref) async {
    try {
      await ref.delete();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Notification removed'),
            duration: Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not delete: $e'), backgroundColor: Colors.red.shade700),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final uid = _auth.currentUser?.uid;
    final theme = ThemeController.instance;

    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(
        flexibleSpace: Container(
          decoration: BoxDecoration(gradient: theme.appBarGradient),
        ),
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        elevation: 1,
        title: const Row(
          children: [
            Icon(Icons.notifications_active_rounded, color: Colors.white, size: 24),
            SizedBox(width: 10),
            Text(
              'Notifications',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 19),
            ),
          ],
        ),
        actions: [
          if (uid != null) ...[
            IconButton(
              tooltip: 'Mark all as read',
              icon: const Icon(Icons.done_all_rounded, color: Colors.white),
              onPressed: () => _markAllAsRead(uid),
            ),
            IconButton(
              tooltip: 'Notification Settings',
              icon: const Icon(Icons.tune_rounded, color: Colors.white),
              onPressed: () => _showSettingsModal(context),
            ),
          ],
        ],
      ),
      body: uid == null
          ? const Center(child: Text('Please sign in to view notifications'))
          : Column(
              children: [
                // Real-time Permission Banner (if not granted)
                if (!_checkingPermission && !_hasNotificationPermission)
                  _buildPermissionBanner(theme),

                // Category Filter Pills
                _buildFilterBar(theme),

                // Notification Stream
                Expanded(
                  child: StreamBuilder<QuerySnapshot>(
                    stream: _firestore
                        .collection('notifications')
                        .where('to', isEqualTo: uid)
                        .snapshots(),
                    builder: (context, snap) {
                      if (snap.hasError) {
                        return _buildIndexError(context, snap.error);
                      }
                      if (snap.connectionState == ConnectionState.waiting) {
                        return const Center(
                          child: CircularProgressIndicator(),
                        );
                      }

                      final allDocs = (snap.data?.docs ?? []).toList();
                      // Sort in memory by timestamp descending
                      allDocs.sort((a, b) {
                        final aTs = ((a.data() as Map<String, dynamic>?)?['timestamp'] ?? 0) as int;
                        final bTs = ((b.data() as Map<String, dynamic>?)?['timestamp'] ?? 0) as int;
                        return bTs.compareTo(aTs);
                      });
                      
                      // Filter in memory according to selected category
                      final docs = allDocs.where((d) {
                        final data = d.data() as Map<String, dynamic>? ?? {};
                        final type = (data['type'] ?? '').toString().toLowerCase();
                        final isRead = (data['read'] ?? false) as bool;

                        if (_selectedFilter == 'unread') return !isRead;
                        if (_selectedFilter == 'like') return type == 'like';
                        if (_selectedFilter == 'comment') return type == 'comment';
                        if (_selectedFilter == 'job') return type == 'job';
                        if (_selectedFilter == 'connect') {
                          return type == 'connect' || type == 'friend';
                        }
                        return true;
                      }).toList();

                      if (docs.isEmpty) {
                        return _buildEmptyState(theme);
                      }

                      return ListView.separated(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                        itemCount: docs.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemBuilder: (context, index) {
                          final doc = docs[index];
                          final data = doc.data() as Map<String, dynamic>? ?? {};
                          return _buildNotificationCard(context, doc, data, theme);
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
    );
  }

  // Permission Request Banner
  Widget _buildPermissionBanner(ThemeController theme) {
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 12, 14, 4),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFEFF6FF), // blue-50
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFBFDBFE)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: const BoxDecoration(
              color: Color(0xFFDBEAFE),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.notifications_active, color: Color(0xFF2563EB), size: 22),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Enable Device Alerts',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13.5, color: Color(0xFF1E3A8A)),
                ),
                SizedBox(height: 2),
                Text(
                  'Get real-time push alerts on your phone status bar for likes & messages.',
                  style: TextStyle(fontSize: 11.5, color: Color(0xFF3B82F6), height: 1.25),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          ElevatedButton(
            onPressed: _requestPermission,
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF2563EB),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
              elevation: 0,
            ),
            child: const Text('Allow', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  // Filter Pill Bar
  Widget _buildFilterBar(ThemeController theme) {
    final filters = [
      {'id': 'all', 'label': 'All', 'icon': Icons.all_inbox_rounded},
      {'id': 'unread', 'label': 'Unread', 'icon': Icons.mark_email_unread_rounded},
      {'id': 'like', 'label': 'Likes', 'icon': Icons.favorite_rounded},
      {'id': 'comment', 'label': 'Comments', 'icon': Icons.chat_bubble_rounded},
      {'id': 'connect', 'label': 'Connects', 'icon': Icons.people_rounded},
      {'id': 'job', 'label': 'Jobs', 'icon': Icons.work_rounded},
    ];

    return Container(
      height: 52,
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        itemCount: filters.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final f = filters[i];
          final isSelected = _selectedFilter == f['id'];

          return InkWell(
            onTap: () => setState(() => _selectedFilter = f['id'] as String),
            borderRadius: BorderRadius.circular(20),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              decoration: BoxDecoration(
                color: isSelected ? theme.primaryColor : Colors.white,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: isSelected ? theme.primaryColor : Colors.grey.shade300,
                ),
                boxShadow: isSelected
                    ? [
                        BoxShadow(
                          color: theme.primaryColor.withValues(alpha: 0.3),
                          blurRadius: 6,
                          offset: const Offset(0, 2),
                        ),
                      ]
                    : [],
              ),
              child: Row(
                children: [
                  Icon(
                    f['icon'] as IconData,
                    size: 15,
                    color: isSelected ? Colors.white : Colors.grey.shade700,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    f['label'] as String,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                      color: isSelected ? Colors.white : Colors.grey.shade800,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  // Individual Notification Card
  Widget _buildNotificationCard(
    BuildContext context,
    QueryDocumentSnapshot doc,
    Map<String, dynamic> data,
    ThemeController theme,
  ) {
    final type = (data['type'] ?? '').toString().toLowerCase();
    final fromName = (data['fromName'] ?? 'Someone') as String;
    final fromImage = data['fromImage'] as String?;
    final ts = (data['timestamp'] ?? 0) as int;
    final isRead = (data['read'] ?? false) as bool;
    final customText = (data['text'] ?? '') as String;

    String actionText = 'sent you a notification';
    IconData badgeIcon = Icons.notifications_rounded;
    Color badgeColor = Colors.blue;

    final reaction = (data['reaction'] ?? '').toString().toLowerCase();
    final commentText = (data['commentText'] ?? '').toString();

    if (type == 'like') {
      String reactionLabel = 'liked your post';
      badgeIcon = Icons.thumb_up_rounded;
      badgeColor = Colors.blue;

      if (reaction == 'love') {
        reactionLabel = 'reacted ❤️ Love to your post';
        badgeIcon = Icons.favorite_rounded;
        badgeColor = Colors.redAccent;
      } else if (reaction == 'like') {
        reactionLabel = 'reacted 👍 Like to your post';
        badgeIcon = Icons.thumb_up_rounded;
        badgeColor = Colors.blue;
      } else if (reaction == 'care') {
        reactionLabel = 'reacted 🥰 Care to your post';
        badgeIcon = Icons.favorite_rounded;
        badgeColor = Colors.amber.shade700;
      } else if (reaction == 'wow') {
        reactionLabel = 'reacted 😮 Wow to your post';
        badgeIcon = Icons.sentiment_very_satisfied_rounded;
        badgeColor = Colors.amber.shade700;
      } else if (reaction == 'sad') {
        reactionLabel = 'reacted 😢 Sad to your post';
        badgeIcon = Icons.sentiment_dissatisfied_rounded;
        badgeColor = Colors.orange;
      } else if (reaction == 'angry') {
        reactionLabel = 'reacted 😡 Angry to your post';
        badgeIcon = Icons.sentiment_very_dissatisfied_rounded;
        badgeColor = Colors.deepOrange;
      } else if (reaction.isNotEmpty) {
        reactionLabel = 'reacted $reaction to your post';
      }
      actionText = reactionLabel;
    } else if (type == 'comment') {
      actionText = commentText.isNotEmpty
          ? 'commented: "$commentText"'
          : 'commented on your post';
      badgeIcon = Icons.chat_bubble_rounded;
      badgeColor = const Color(0xFF9333EA); // Purple
    } else if (type == 'connect' || type == 'friend') {
      actionText = 'sent you a connection request';
      badgeIcon = Icons.person_add_rounded;
      badgeColor = Colors.teal;
    } else if (type == 'job') {
      actionText = customText.isNotEmpty ? customText : 'posted a new job match';
      badgeIcon = Icons.work_rounded;
      badgeColor = Colors.orange.shade700;
    } else if (customText.isNotEmpty) {
      actionText = customText;
    }

    return Dismissible(
      key: Key(doc.id),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        decoration: BoxDecoration(
          color: Colors.red.shade600,
          borderRadius: BorderRadius.circular(14),
        ),
        child: const Icon(Icons.delete_sweep_rounded, color: Colors.white, size: 26),
      ),
      onDismissed: (_) => _deleteNotification(doc.reference),
      child: Material(
        color: isRead ? Colors.white : const Color(0xFFF1F5F9), // Light blue-gray for unread
        borderRadius: BorderRadius.circular(14),
        elevation: isRead ? 0.5 : 1.5,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () async {
            if (!isRead) {
              await doc.reference.update({'read': true});
            }
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: isRead ? Colors.grey.shade200 : theme.primaryColor.withValues(alpha: 0.35),
                width: isRead ? 1 : 1.5,
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // Avatar with Action Badge
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    CircleAvatar(
                      radius: 23,
                      backgroundColor: theme.primaryColor.withValues(alpha: 0.12),
                      backgroundImage: fromImage != null && fromImage.isNotEmpty
                          ? CachedNetworkImageProvider(fromImage)
                          : null,
                      child: fromImage == null || fromImage.isEmpty
                          ? Text(
                              fromName.isNotEmpty ? fromName[0].toUpperCase() : 'U',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: theme.primaryColor,
                                fontSize: 16,
                              ),
                            )
                          : null,
                    ),
                    Positioned(
                      bottom: -2,
                      right: -2,
                      child: Container(
                        padding: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          color: badgeColor,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 2),
                        ),
                        child: Icon(badgeIcon, color: Colors.white, size: 11),
                      ),
                    ),
                  ],
                ),
                const SizedBox(width: 14),

                // Text Content
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      RichText(
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        text: TextSpan(
                          style: const TextStyle(fontSize: 13.5, color: Color(0xFF1E293B), height: 1.3),
                          children: [
                            TextSpan(
                              text: '$fromName ',
                              style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF0F172A)),
                            ),
                            TextSpan(text: actionText),
                          ],
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _formatRelativeTime(ts),
                        style: TextStyle(
                          fontSize: 11.5,
                          color: isRead ? Colors.grey.shade500 : theme.primaryColor,
                          fontWeight: isRead ? FontWeight.normal : FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),

                // Unread Dot & Options
                if (!isRead)
                  Container(
                    width: 9,
                    height: 9,
                    margin: const EdgeInsets.symmetric(horizontal: 6),
                    decoration: BoxDecoration(
                      color: theme.primaryColor,
                      shape: BoxShape.circle,
                    ),
                  ),

                PopupMenuButton<String>(
                  icon: Icon(Icons.more_vert_rounded, size: 18, color: Colors.grey.shade500),
                  onSelected: (val) {
                    if (val == 'toggle_read') {
                      doc.reference.update({'read': !isRead});
                    } else if (val == 'delete') {
                      _deleteNotification(doc.reference);
                    }
                  },
                  itemBuilder: (ctx) => [
                    PopupMenuItem(
                      value: 'toggle_read',
                      child: Row(
                        children: [
                          Icon(isRead ? Icons.mark_email_unread_outlined : Icons.mark_email_read_outlined, size: 18),
                          const SizedBox(width: 8),
                          Text(isRead ? 'Mark as unread' : 'Mark as read'),
                        ],
                      ),
                    ),
                    const PopupMenuItem(
                      value: 'delete',
                      child: Row(
                        children: [
                          Icon(Icons.delete_outline_rounded, color: Colors.red, size: 18),
                          SizedBox(width: 8),
                          Text('Delete', style: TextStyle(color: Colors.red)),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // Empty State
  Widget _buildEmptyState(ThemeController theme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                color: theme.primaryColor.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(
                _selectedFilter == 'unread'
                    ? Icons.mark_email_read_rounded
                    : Icons.notifications_none_rounded,
                size: 42,
                color: theme.primaryColor,
              ),
            ),
            const SizedBox(height: 18),
            Text(
              _selectedFilter == 'unread'
                  ? "You're all caught up!"
                  : 'No notifications found',
              style: const TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.bold,
                color: Color(0xFF1E293B),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              _selectedFilter == 'unread'
                  ? 'There are no unread notifications waiting for you.'
                  : 'New likes, comments, and connection requests will show up here.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: Colors.grey.shade600, height: 1.4),
            ),
          ],
        ),
      ),
    );
  }

  // Index error helper
  Widget _buildIndexError(BuildContext context, Object? error) {
    final msg = error?.toString() ?? 'Unknown error';
    final url = _extractFirstUrl(msg);
    final isIndexError = msg.contains('requires an index') || msg.contains('FAILED_PRECONDITION');
    return Padding(
      padding: const EdgeInsets.all(20.0),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(isIndexError ? Icons.storage_rounded : Icons.error_outline_rounded, size: 48, color: Colors.orange),
          const SizedBox(height: 12),
          Text(
            isIndexError ? 'Notifications index building...' : 'Error loading notifications',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Text(
            isIndexError ? 'Firebase is building the notification index. Please check back in 1-2 minutes.' : msg,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 13, color: Colors.grey),
          ),
          if (isIndexError && url != null) ...[
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: () async {
                final uri = Uri.parse(url);
                if (await canLaunchUrl(uri)) {
                  await launchUrl(uri, mode: LaunchMode.externalApplication);
                }
              },
              icon: const Icon(Icons.open_in_new_rounded, size: 18),
              label: const Text('Open Firebase Index Link'),
            ),
          ],
        ],
      ),
    );
  }

  // Relative Time Formatter
  String _formatRelativeTime(int ts) {
    if (ts <= 0) return '';
    final dt = DateTime.fromMillisecondsSinceEpoch(ts);
    final diff = DateTime.now().difference(dt);

    if (diff.inSeconds < 45) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays == 1) return 'Yesterday';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${dt.day}/${dt.month}/${dt.year}';
  }

  String? _extractFirstUrl(String text) {
    final reg = RegExp(r'https?://[^\s)\"]+');
    final m = reg.firstMatch(text);
    return m?.group(0);
  }

  void _showSettingsModal(BuildContext context) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) => Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Notification Preferences',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Device Status Bar Notifications', style: TextStyle(fontWeight: FontWeight.w600)),
                subtitle: const Text('Alert directly on phone when app is running or in background'),
                value: _hasNotificationPermission,
                onChanged: (val) async {
                  await _requestPermission();
                  setModalState(() {});
                },
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Close'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}