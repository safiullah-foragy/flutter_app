import 'dart:io' show File; // Used on mobile/desktop only
import 'dart:async';
import 'dart:typed_data';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:image_picker/image_picker.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'app_cache_manager.dart';
import 'supabase.dart' as sb;
import 'videos.dart';
import 'document_viewer.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:record/record.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:file_picker/file_picker.dart';
import 'file_picker_web.dart' if (dart.library.io) 'file_picker_stub.dart' as web_picker;
// import 'newsfeed.dart'; // No direct usage here
import 'see_profile_from_newsfeed.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'background_tasks.dart';
import 'agora_call_page.dart';
import 'audio_upload_web.dart' if (dart.library.io) 'audio_upload_stub.dart';
import 'create_group_page.dart';
import 'group_info_page.dart';

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
  final Map<String, StreamSubscription<QuerySnapshot>> _callSubs = {};
  bool _showingIncoming = false;
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _fetchCurrentUserData();
  }

  @override
  void dispose() {
    _searchController.dispose();
    for (final s in _callSubs.values) {
      s.cancel();
    }
    _callSubs.clear();
    super.dispose();
  }

  Future<void> _fetchCurrentUserData() async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return;

    try {
      final userDoc = await _firestore.collection('users').doc(uid).get();
      if (userDoc.exists && mounted) {
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
        appBar: AppBar(
          elevation: 0,
          title: const Text('Messages', style: TextStyle(fontWeight: FontWeight.bold)),
        ),
        body: const Center(child: Text('Please sign in to view messages')),
      );
    }

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = Theme.of(context).primaryColor;

    return Scaffold(
      backgroundColor: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(60),
        child: Container(
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF1E293B) : Colors.white,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.04),
                offset: const Offset(0, 2),
                blurRadius: 8,
              ),
            ],
          ),
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 6.0),
              child: Row(
                children: [
                  IconButton(
                    icon: Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: isDark ? Colors.white10 : Colors.grey.shade100,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(Icons.arrow_back, size: 20, color: isDark ? Colors.white : Colors.black87),
                    ),
                    onPressed: () => Navigator.pop(context),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Row(
                      children: [
                        Text(
                          'Messages',
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.5,
                            color: isDark ? Colors.white : const Color(0xFF0F172A),
                          ),
                        ),
                        const SizedBox(width: 8),
                        StreamBuilder<QuerySnapshot>(
                          stream: _firestore
                              .collection('conversations')
                              .where('participants', arrayContains: uid)
                              .snapshots(includeMetadataChanges: !kIsWeb),
                          builder: (context, snap) {
                            if (!snap.hasData) return const SizedBox.shrink();
                            int totalUnread = 0;
                            for (var d in snap.data!.docs) {
                              final data = d.data() as Map<String, dynamic>? ?? {};
                              final lastReadMap = Map<String, dynamic>.from(data['last_read'] ?? <String, dynamic>{});
                              final lastRead = (lastReadMap[uid] ?? 0) as int;
                              final lastUpdated = (data['last_updated'] ?? 0) as int;
                              if (lastUpdated > lastRead) totalUnread++;
                            }
                            if (totalUnread == 0) return const SizedBox.shrink();
                            return Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                gradient: const LinearGradient(
                                  colors: [Color(0xFF2563EB), Color(0xFF3B82F6)],
                                ),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(
                                '$totalUnread',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'New Group',
                    icon: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: isDark ? Colors.white10 : Colors.grey.shade100,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(Icons.group_add_outlined, size: 20, color: isDark ? Colors.white : Colors.black87),
                    ),
                    onPressed: () => _showCreateGroup(),
                  ),
                  IconButton(
                    tooltip: 'Find People',
                    icon: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: isDark ? Colors.white10 : Colors.grey.shade100,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(Icons.person_search_outlined, size: 20, color: isDark ? Colors.white : Colors.black87),
                    ),
                    onPressed: () => _showUserSearch(),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: primaryColor,
        elevation: 4,
        icon: const Icon(Icons.edit_outlined, color: Colors.white, size: 20),
        label: const Text('New Chat', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        onPressed: () => _showUserSearch(),
      ),
      body: CustomScrollView(
        slivers: [
          // Search Bar
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Container(
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF1E293B) : Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.03),
                      blurRadius: 6,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: TextField(
                  controller: _searchController,
                  onChanged: (val) {
                    setState(() => _searchQuery = val.trim().toLowerCase());
                  },
                  decoration: InputDecoration(
                    hintText: 'Search chats, people, groups...',
                    hintStyle: TextStyle(
                      fontSize: 14,
                      color: isDark ? Colors.white38 : Colors.grey.shade500,
                    ),
                    prefixIcon: Icon(
                      Icons.search,
                      size: 20,
                      color: isDark ? Colors.white54 : Colors.grey.shade600,
                    ),
                    suffixIcon: _searchQuery.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.close, size: 18),
                            onPressed: () {
                              _searchController.clear();
                              setState(() => _searchQuery = '');
                            },
                          )
                        : null,
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  ),
                ),
              ),
            ),
          ),

          // Active Online Contacts Horizontal Tray
          SliverToBoxAdapter(
            child: _buildActiveUsersRow(uid, isDark),
          ),

          // Header Label
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'RECENT CHATS',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.0,
                      color: isDark ? Colors.white54 : Colors.grey.shade600,
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Conversations Stream List
          StreamBuilder<QuerySnapshot>(
            stream: _firestore
                .collection('conversations')
                .where('participants', arrayContains: uid)
                .snapshots(includeMetadataChanges: !kIsWeb),
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                debugPrint('Conversations stream error: ${snapshot.error}');
                return SliverFillRemaining(
                  child: Center(child: Text('Error loading conversations: ${snapshot.error}')),
                );
              }
              if (!snapshot.hasData) {
                return const SliverFillRemaining(
                  child: Center(child: CircularProgressIndicator()),
                );
              }

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

              // Filter by search query if any
              final filteredConvs = convs.where((c) {
                if (_searchQuery.isEmpty) return true;
                final data = c['data'] as Map<String, dynamic>;
                final groupName = (data['group_name'] ?? '').toString().toLowerCase();
                final lastMessage = (data['last_message'] ?? '').toString().toLowerCase();
                return groupName.contains(_searchQuery) || lastMessage.contains(_searchQuery);
              }).toList();

              if (filteredConvs.isEmpty) {
                return SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32.0),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Container(
                            width: 80,
                            height: 80,
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: [
                                  primaryColor.withValues(alpha: 0.15),
                                  primaryColor.withValues(alpha: 0.05),
                                ],
                              ),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(Icons.chat_bubble_outline_rounded, size: 40, color: primaryColor),
                          ),
                          const SizedBox(height: 16),
                          Text(
                            _searchQuery.isNotEmpty ? 'No conversations found' : 'No messages yet',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: isDark ? Colors.white : Colors.black87,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            _searchQuery.isNotEmpty
                                ? 'Try searching with a different name or keyword'
                                : 'Start chatting with friends, classmates, or create a study group!',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 13,
                              color: isDark ? Colors.white54 : Colors.grey.shade600,
                            ),
                          ),
                          if (_searchQuery.isEmpty) ...[
                            const SizedBox(height: 20),
                            ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: primaryColor,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                elevation: 0,
                              ),
                              icon: const Icon(Icons.person_search, size: 18),
                              label: const Text('Start a Conversation', style: TextStyle(fontWeight: FontWeight.bold)),
                              onPressed: () => _showUserSearch(),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                );
              }

              return SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final d = filteredConvs[index]['doc'] as QueryDocumentSnapshot;
                    final data = filteredConvs[index]['data'] as Map<String, dynamic>;
                    final participants = List<String>.from(data['participants'] ?? <String>[]);
                    final lastMessage = data['last_message'] ?? '';
                    final lastUpdated = data['last_updated'] ?? 0;
                    final unread = filteredConvs[index]['unread'] as bool;
                    final isGroup = data['is_group'] == true;

                    if (isGroup) {
                      return _buildGroupConversationItem(
                        d: d,
                        data: data,
                        uid: uid,
                        unread: unread,
                        lastMessage: lastMessage,
                        lastUpdated: lastUpdated,
                        isDark: isDark,
                      );
                    }

                    final otherId = participants.firstWhere((p) => p != uid, orElse: () => '');
                    if (otherId.isEmpty) {
                      return const SizedBox.shrink();
                    }

                    return _buildOneOnOneConversationItem(
                      d: d,
                      data: data,
                      uid: uid,
                      otherId: otherId,
                      unread: unread,
                      lastMessage: lastMessage,
                      lastUpdated: lastUpdated,
                      isDark: isDark,
                    );
                  },
                  childCount: filteredConvs.length,
                ),
              );
            },
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 80)),
        ],
      ),
    );
  }

  Widget _buildActiveUsersRow(String currentUid, bool isDark) {
    return StreamBuilder<QuerySnapshot>(
      stream: _firestore
          .collection('users')
          .where('is_online', isEqualTo: true)
          .limit(12)
          .snapshots(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) return const SizedBox.shrink();
        final docs = snapshot.data!.docs.where((d) => d.id != currentUid).toList();
        if (docs.isEmpty) return const SizedBox.shrink();

        return Container(
          height: 100,
          margin: const EdgeInsets.only(top: 4, bottom: 6),
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            itemCount: docs.length,
            itemBuilder: (context, index) {
              final userData = docs[index].data() as Map<String, dynamic>? ?? {};
              final userId = docs[index].id;
              final name = (userData['name'] ?? 'User').toString();
              final firstName = name.split(' ').first;
              final profileImage = userData['profile_image'] as String?;

              return GestureDetector(
                onTap: () => _startConversationWith(userId),
                child: Container(
                  width: 70,
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Stack(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(2.5),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: const LinearGradient(
                                colors: [Color(0xFF10B981), Color(0xFF059669)],
                              ),
                            ),
                            child: CircleAvatar(
                              radius: 24,
                              backgroundColor: Colors.grey.shade300,
                              backgroundImage: (profileImage != null && profileImage.isNotEmpty)
                                  ? CachedNetworkImageProvider(profileImage)
                                  : null,
                              child: (profileImage == null || profileImage.isEmpty)
                                  ? Text(
                                      name.isNotEmpty ? name[0].toUpperCase() : '?',
                                      style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.black87),
                                    )
                                  : null,
                            ),
                          ),
                          Positioned(
                            right: 2,
                            bottom: 2,
                            child: Container(
                              width: 13,
                              height: 13,
                              decoration: BoxDecoration(
                                color: const Color(0xFF10B981),
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: isDark ? const Color(0xFF0F172A) : Colors.white,
                                  width: 2.5,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        firstName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: isDark ? Colors.white70 : Colors.grey.shade800,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }

  Widget _buildOneOnOneConversationItem({
    required QueryDocumentSnapshot d,
    required Map<String, dynamic> data,
    required String uid,
    required String otherId,
    required bool unread,
    required String lastMessage,
    required int lastUpdated,
    required bool isDark,
  }) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: _firestore.collection('users').doc(uid).snapshots(includeMetadataChanges: !kIsWeb),
      builder: (context, currentUserSnap) {
        bool isMuted = false;
        if (currentUserSnap.hasData && currentUserSnap.data != null && currentUserSnap.data!.exists) {
          final userData = currentUserSnap.data!.data();
          if (userData != null) {
            final mutedList = userData['muted_conversations'] as List<dynamic>? ?? [];
            isMuted = mutedList.contains(d.id);
          }
        }

        return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
          stream: _firestore.collection('users').doc(otherId).snapshots(includeMetadataChanges: !kIsWeb),
          builder: (context, userSnap) {
            String title = otherId;
            String? avatarUrl;
            bool isOnline = false;

            if (userSnap.hasData && userSnap.data != null && userSnap.data!.exists) {
              final u = userSnap.data!.data();
              if (u != null) {
                title = u['name'] ?? otherId;
                avatarUrl = u['profile_image'];
                isOnline = u['is_online'] == true;
              }
            }

            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
              child: Dismissible(
                key: ValueKey(d.id),
                direction: DismissDirection.endToStart,
                background: Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFFEF4444),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  alignment: Alignment.centerRight,
                  padding: const EdgeInsets.only(right: 20),
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Icon(Icons.delete_outline, color: Colors.white, size: 24),
                      SizedBox(width: 6),
                      Text('Delete', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                    ],
                  ),
                ),
                confirmDismiss: (dir) async {
                  final choice = await showDialog<String?>(
                    context: context,
                    builder: (c) {
                      return SimpleDialog(
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                        title: const Text('Conversation Options', style: TextStyle(fontWeight: FontWeight.bold)),
                        children: [
                          SimpleDialogOption(
                            child: const Padding(
                              padding: EdgeInsets.symmetric(vertical: 4),
                              child: Row(
                                children: [
                                  Icon(Icons.archive_outlined, color: Colors.blue),
                                  SizedBox(width: 12),
                                  Text('Archive Chat', style: TextStyle(fontWeight: FontWeight.w600)),
                                ],
                              ),
                            ),
                            onPressed: () => Navigator.pop(c, 'archive'),
                          ),
                          SimpleDialogOption(
                            child: const Padding(
                              padding: EdgeInsets.symmetric(vertical: 4),
                              child: Row(
                                children: [
                                  Icon(Icons.delete_outline, color: Colors.red),
                                  SizedBox(width: 12),
                                  Text('Delete Chat', style: TextStyle(color: Colors.red, fontWeight: FontWeight.w600)),
                                ],
                              ),
                            ),
                            onPressed: () => Navigator.pop(c, 'delete'),
                          ),
                          SimpleDialogOption(
                            child: const Padding(
                              padding: EdgeInsets.symmetric(vertical: 4),
                              child: Text('Cancel', textAlign: TextAlign.center, style: TextStyle(color: Colors.grey)),
                            ),
                            onPressed: () => Navigator.pop(c, null),
                          ),
                        ],
                      );
                    },
                  );
                  if (choice == 'archive') {
                    await _firestore.collection('conversations').doc(d.id).update({
                      'archived.$uid': true,
                    });
                    return false;
                  }
                  if (choice == 'delete') {
                    final ok = await _deleteConversation(d.id);
                    return ok;
                  }
                  return false;
                },
                child: Material(
                  color: isDark ? const Color(0xFF1E293B) : Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  elevation: unread ? 1.5 : 0,
                  shadowColor: Colors.black.withValues(alpha: 0.05),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(16),
                    onTap: () async {
                      await _markConversationRead(d.id, uid);
                      if (context.mounted) {
                        Navigator.of(context).restorablePush(
                          ChatPage.restorableRoute,
                          arguments: {
                            'conversationId': d.id,
                            'otherUserId': otherId,
                          },
                        );
                      }
                    },
                    onLongPress: () => _showConversationOptions(d.id, uid, title, isMuted),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: unread
                              ? const Color(0xFF3B82F6).withValues(alpha: 0.3)
                              : (isDark ? Colors.white.withValues(alpha: 0.05) : Colors.grey.shade200),
                          width: unread ? 1.5 : 1.0,
                        ),
                      ),
                      child: Row(
                        children: [
                          // Avatar with online status
                          Stack(
                            children: [
                              _buildUserAvatar(avatarUrl, otherId),
                              if (isOnline)
                                Positioned(
                                  right: 0,
                                  bottom: 0,
                                  child: Container(
                                    width: 14,
                                    height: 14,
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF10B981),
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                        color: isDark ? const Color(0xFF1E293B) : Colors.white,
                                        width: 2.5,
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(width: 14),

                          // Text Column
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        title.isNotEmpty ? title : 'Chat',
                                        style: TextStyle(
                                          fontSize: 15,
                                          fontWeight: unread ? FontWeight.w800 : FontWeight.w600,
                                          color: isDark ? Colors.white : const Color(0xFF0F172A),
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    Text(
                                      _formatTimestamp(lastUpdated),
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: unread ? FontWeight.w700 : FontWeight.normal,
                                        color: unread
                                            ? const Color(0xFF2563EB)
                                            : (isDark ? Colors.white38 : Colors.grey.shade500),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 4),
                                Row(
                                  children: [
                                    Expanded(
                                      child: _buildLastMessagePreview(lastMessage, unread, isDark),
                                    ),
                                    if (isMuted) ...[
                                      const SizedBox(width: 6),
                                      Icon(Icons.notifications_off_outlined, size: 15, color: isDark ? Colors.white38 : Colors.grey.shade400),
                                    ],
                                    if (unread) ...[
                                      const SizedBox(width: 8),
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                                        decoration: BoxDecoration(
                                          gradient: const LinearGradient(
                                            colors: [Color(0xFF2563EB), Color(0xFF3B82F6)],
                                          ),
                                          borderRadius: BorderRadius.circular(10),
                                        ),
                                        child: const Text(
                                          'NEW',
                                          style: TextStyle(
                                            color: Colors.white,
                                            fontSize: 9,
                                            fontWeight: FontWeight.w800,
                                            letterSpacing: 0.5,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildGroupConversationItem({
    required QueryDocumentSnapshot d,
    required Map<String, dynamic> data,
    required String uid,
    required bool unread,
    required String lastMessage,
    required int lastUpdated,
    required bool isDark,
  }) {
    final groupName = data['group_name'] ?? 'Unnamed Group';
    final participants = List<String>.from(data['participants'] ?? []);
    final memberCount = participants.length;

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: _firestore.collection('users').doc(uid).snapshots(includeMetadataChanges: !kIsWeb),
      builder: (context, currentUserSnap) {
        bool isMuted = false;
        if (currentUserSnap.hasData && currentUserSnap.data != null && currentUserSnap.data!.exists) {
          final userData = currentUserSnap.data!.data();
          if (userData != null) {
            final mutedList = userData['muted_conversations'] as List<dynamic>? ?? [];
            isMuted = mutedList.contains(d.id);
          }
        }

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
          child: Dismissible(
            key: ValueKey(d.id),
            direction: DismissDirection.endToStart,
            background: Container(
              decoration: BoxDecoration(
                color: const Color(0xFFEF4444),
                borderRadius: BorderRadius.circular(16),
              ),
              alignment: Alignment.centerRight,
              padding: const EdgeInsets.only(right: 20),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Icon(Icons.delete_outline, color: Colors.white, size: 24),
                  SizedBox(width: 6),
                  Text('Delete', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                ],
              ),
            ),
            confirmDismiss: (dir) async {
              final choice = await showDialog<String?>(
                context: context,
                builder: (c) {
                  return SimpleDialog(
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    title: const Text('Group Options', style: TextStyle(fontWeight: FontWeight.bold)),
                    children: [
                      SimpleDialogOption(
                        child: const Padding(
                          padding: EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            children: [
                              Icon(Icons.archive_outlined, color: Colors.blue),
                              SizedBox(width: 12),
                              Text('Archive Group', style: TextStyle(fontWeight: FontWeight.w600)),
                            ],
                          ),
                        ),
                        onPressed: () => Navigator.pop(c, 'archive'),
                      ),
                      SimpleDialogOption(
                        child: const Padding(
                          padding: EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            children: [
                              Icon(Icons.delete_outline, color: Colors.red),
                              SizedBox(width: 12),
                              Text('Delete Group', style: TextStyle(color: Colors.red, fontWeight: FontWeight.w600)),
                            ],
                          ),
                        ),
                        onPressed: () => Navigator.pop(c, 'delete'),
                      ),
                      SimpleDialogOption(
                        child: const Padding(
                          padding: EdgeInsets.symmetric(vertical: 4),
                          child: Text('Cancel', textAlign: TextAlign.center, style: TextStyle(color: Colors.grey)),
                        ),
                        onPressed: () => Navigator.pop(c, null),
                      ),
                    ],
                  );
                },
              );
              if (choice == 'archive') {
                await _firestore.collection('conversations').doc(d.id).update({
                  'archived.$uid': true,
                });
                return false;
              }
              if (choice == 'delete') {
                final ok = await _deleteConversation(d.id);
                return ok;
              }
              return false;
            },
            child: Material(
              color: isDark ? const Color(0xFF1E293B) : Colors.white,
              borderRadius: BorderRadius.circular(16),
              elevation: unread ? 1.5 : 0,
              shadowColor: Colors.black.withValues(alpha: 0.05),
              child: InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: () async {
                  await _markConversationRead(d.id, uid);
                  if (context.mounted) {
                    Navigator.of(context).restorablePush(
                      ChatPage.restorableRoute,
                      arguments: {
                        'conversationId': d.id,
                        'otherUserId': '',
                        'isGroup': true,
                      },
                    );
                  }
                },
                onLongPress: () => _showConversationOptions(d.id, uid, groupName, isMuted),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: unread
                          ? const Color(0xFF3B82F6).withValues(alpha: 0.3)
                          : (isDark ? Colors.white.withValues(alpha: 0.05) : Colors.grey.shade200),
                      width: unread ? 1.5 : 1.0,
                    ),
                  ),
                  child: Row(
                    children: [
                      _buildGroupAvatar(data['group_photo']),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Row(
                                    children: [
                                      Flexible(
                                        child: Text(
                                          groupName,
                                          style: TextStyle(
                                            fontSize: 15,
                                            fontWeight: unread ? FontWeight.w800 : FontWeight.w600,
                                            color: isDark ? Colors.white : const Color(0xFF0F172A),
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                      const SizedBox(width: 4),
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                                        decoration: BoxDecoration(
                                          color: Colors.teal.withValues(alpha: 0.15),
                                          borderRadius: BorderRadius.circular(6),
                                        ),
                                        child: Text(
                                          '$memberCount',
                                          style: const TextStyle(
                                            color: Colors.teal,
                                            fontSize: 10,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                Text(
                                  _formatTimestamp(lastUpdated),
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: unread ? FontWeight.w700 : FontWeight.normal,
                                    color: unread
                                        ? const Color(0xFF2563EB)
                                        : (isDark ? Colors.white38 : Colors.grey.shade500),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Row(
                              children: [
                                Expanded(
                                  child: _buildLastMessagePreview(lastMessage, unread, isDark),
                                ),
                                if (isMuted) ...[
                                  const SizedBox(width: 6),
                                  Icon(Icons.notifications_off_outlined, size: 15, color: isDark ? Colors.white38 : Colors.grey.shade400),
                                ],
                                if (unread) ...[
                                  const SizedBox(width: 8),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                                    decoration: BoxDecoration(
                                      gradient: const LinearGradient(
                                        colors: [Color(0xFF2563EB), Color(0xFF3B82F6)],
                                      ),
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    child: const Text(
                                      'NEW',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 9,
                                        fontWeight: FontWeight.w800,
                                        letterSpacing: 0.5,
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildLastMessagePreview(String message, bool unread, bool isDark) {
    IconData? icon;
    String displayText = message;

    if (message.startsWith('[Photo]') || message.toLowerCase().contains('image')) {
      icon = Icons.photo_outlined;
    } else if (message.startsWith('[Voice') || message.toLowerCase().contains('audio')) {
      icon = Icons.mic_none_outlined;
    } else if (message.startsWith('[Video')) {
      icon = Icons.videocam_outlined;
    } else if (message.startsWith('[Document') || message.startsWith('[File')) {
      icon = Icons.description_outlined;
    } else if (message.contains('call')) {
      icon = Icons.phone_outlined;
    }

    return Row(
      children: [
        if (icon != null) ...[
          Icon(
            icon,
            size: 14,
            color: unread ? const Color(0xFF2563EB) : (isDark ? Colors.white54 : Colors.grey.shade600),
          ),
          const SizedBox(width: 4),
        ],
        Expanded(
          child: Text(
            displayText.isNotEmpty ? displayText : 'Tap to chat',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13,
              fontWeight: unread ? FontWeight.w600 : FontWeight.normal,
              color: unread
                  ? (isDark ? Colors.white : const Color(0xFF0F172A))
                  : (isDark ? Colors.white54 : Colors.grey.shade600),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildUserAvatar(String? avatarUrl, String userId) {
    if (avatarUrl != null && avatarUrl.isNotEmpty) {
      return CircleAvatar(
        radius: 25,
        backgroundColor: Colors.grey.shade300,
        backgroundImage: CachedNetworkImageProvider(avatarUrl),
      );
    } else {
      final colors = [
        const Color(0xFF2563EB),
        const Color(0xFF7C3AED),
        const Color(0xFF059669),
        const Color(0xFFD97706),
        const Color(0xFFDC2626),
        const Color(0xFF0891B2),
        const Color(0xFFDB2777),
      ];
      final colorIndex = userId.hashCode % colors.length;
      final firstChar = userId.isNotEmpty ? userId[0].toUpperCase() : '?';

      return CircleAvatar(
        radius: 25,
        backgroundColor: colors[colorIndex],
        child: Text(
          firstChar,
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18),
        ),
      );
    }
  }

  Widget _buildGroupAvatar(String? groupPhotoUrl) {
    if (groupPhotoUrl != null && groupPhotoUrl.isNotEmpty) {
      return CircleAvatar(
        radius: 25,
        backgroundColor: Colors.grey.shade300,
        backgroundImage: CachedNetworkImageProvider(groupPhotoUrl),
      );
    } else {
      return Container(
        width: 50,
        height: 50,
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFF0D9488), Color(0xFF14B8A6)],
          ),
          shape: BoxShape.circle,
        ),
        child: const Icon(Icons.groups_rounded, color: Colors.white, size: 26),
      );
    }
  }

  Future<void> _showCreateGroup() async {
    final result = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => const CreateGroupPage()),
    );
    
    // If a group was created, navigate to it
    if (result != null && result.isNotEmpty) {
      final uid = _auth.currentUser?.uid;
      if (uid != null) {
        await _markConversationRead(result, uid);
        if (mounted) {
          Navigator.of(context).restorablePush(
            ChatPage.restorableRoute,
            arguments: {
              'conversationId': result,
              'otherUserId': '',
              'isGroup': true,
            },
          );
        }
      }
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
  final bool isGroup;

  const ChatPage({
    required this.conversationId, 
    required this.otherUserId, 
    this.isGroup = false,
    super.key
  });

  // Restorable route builder for state restoration
  static Route<Object?> restorableRoute(BuildContext context, Object? arguments) {
    final Map args = (arguments as Map?) ?? const {};
    final String convId = (args['conversationId'] ?? '') as String;
    final String otherId = (args['otherUserId'] ?? '') as String;
    final bool isGroup = (args['isGroup'] ?? false) as bool;
    return MaterialPageRoute(
      builder: (_) => ChatPage(conversationId: convId, otherUserId: otherId, isGroup: isGroup),
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
  final AudioPlayer _notificationPlayer = AudioPlayer();
  String? _playingMessageId;
  StreamSubscription<Duration>? _posSub;
  int _previousMessageCount = 0;

  // Group chat state
  Map<String, dynamic>? _groupData;
  List<String> _groupParticipants = [];
  String? _groupAdmin;

  // Chat customization settings
  double _messageFontSize = 14.0;
  double _tagFontSize = 10.0;
  Color _myBubbleColor = Colors.blue;
  Color _sentTagColor = Colors.white70;
  Color _seenTagColor = const Color.fromARGB(255, 238, 3, 3);

  @override
  void initState() {
    super.initState();
    _markRead();
    _loadChatSettings();
    _configureNotificationPlayer();
    if (widget.isGroup) {
      _loadGroupData();
    }
    // Initial scroll will be handled by StreamBuilder's postFrameCallback
    _posSub = _audioPlayer.onPositionChanged.listen((_) {
      if (mounted) setState(() {});
    });
  }

  Future<void> _loadGroupData() async {
    try {
      final doc = await _firestore.collection('conversations').doc(widget.conversationId).get();
      if (doc.exists) {
        final data = doc.data();
        if (data != null) {
          setState(() {
            _groupData = data;
            _groupParticipants = List<String>.from(data['participants'] ?? []);
            _groupAdmin = data['group_admin'] as String?;
          });
        }
      }
    } catch (e) {
      debugPrint('Error loading group data: $e');
    }
  }

  Future<void> _loadChatSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _messageFontSize = prefs.getDouble('chat_message_font_size') ?? 14.0;
      _tagFontSize = prefs.getDouble('chat_tag_font_size') ?? 10.0;
      _myBubbleColor = Color(prefs.getInt('chat_bubble_color') ?? Colors.blue.value);
      _sentTagColor = Color(prefs.getInt('chat_sent_tag_color') ?? Colors.white70.value);
      _seenTagColor = Color(prefs.getInt('chat_seen_tag_color') ?? const Color.fromARGB(255, 238, 3, 3).value);
    });
  }

  Future<void> _saveChatSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('chat_message_font_size', _messageFontSize);
    await prefs.setDouble('chat_tag_font_size', _tagFontSize);
    await prefs.setInt('chat_bubble_color', _myBubbleColor.value);
    await prefs.setInt('chat_sent_tag_color', _sentTagColor.value);
    await prefs.setInt('chat_seen_tag_color', _seenTagColor.value);
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      // Use jumpTo for instant scroll on initial load, animateTo for updates
      if (_scrollController.position.maxScrollExtent > 0) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      }
    }
  }

  Future<void> _configureNotificationPlayer() async {
    try {
      // Configure audio player to use system notification volume
      await _notificationPlayer.setAudioContext(
        AudioContext(
          iOS: AudioContextIOS(
            category: AVAudioSessionCategory.ambient,
            options: {
              AVAudioSessionOptions.mixWithOthers,
            },
          ),
          android: AudioContextAndroid(
            isSpeakerphoneOn: false,
            stayAwake: false,
            contentType: AndroidContentType.sonification,
            usageType: AndroidUsageType.notification,
            audioFocus: AndroidAudioFocus.none,
          ),
        ),
      );
    } catch (e) {
      debugPrint('Failed to configure notification player: $e');
    }
  }

  Future<void> _playNotificationSound() async {
    try {
      await _notificationPlayer.stop();
      await _notificationPlayer.setVolume(0.3); // Set to 30% volume to respect system notification level
      await _notificationPlayer.play(AssetSource('mp3 file/Iphone-Notification.mp3'));
    } catch (e) {
      debugPrint('Failed to play notification sound: $e');
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
    _notificationPlayer.dispose();
    super.dispose();
  }

  Future<void> _startCall({required bool audioOnly}) async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return;
    final otherId = widget.otherUserId;
    if (otherId.isEmpty) return;

    final now = DateTime.now().millisecondsSinceEpoch;
    final sessionRef = FirebaseFirestore.instance.collection('call_sessions').doc();
    final sessionId = sessionRef.id;
    final channel = 'call_${widget.conversationId}_$now';

    // Create /call_sessions doc for global signaling
    try {
      await sessionRef.set({
        'id': sessionId,
        'channel': channel,
        'caller_id': uid,
        'callee_id': otherId,
        'video': !audioOnly,
        'status': 'ringing',
        'timestamp': now,
        'created_at': now,
        'accepted_at': null,
        'ended_at': null,
      });
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
        'timestamp': now,
        'file_url': '',
        'file_type': audioOnly ? 'call_audio' : 'call_video',
        'call_channel': channel,
        'call_session_id': sessionId,
        'reactions': <String, dynamic>{},
        'edited': false,
      });
      await _firestore.collection('conversations').doc(widget.conversationId).update({
        'last_message': audioOnly ? '[Audio call]' : '[Video call]',
        'last_updated': now,
      });
    } catch (e) {
      debugPrint('Error sending call invite: $e');
      String userMsg = 'Failed to send call invite: ${e.toString()}';
      if (e is FirebaseException) {
        userMsg = 'Failed to send call invite: ${e.code} - ${e.message}';
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(userMsg)));
      }
    }

    if (!mounted) return;
    Navigator.push(
      context,
      CallPage.route(
        channelName: channel,
        video: !audioOnly,
        conversationId: widget.conversationId,
        remoteUserId: otherId,
        callSessionId: sessionId,
      ),
    );
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
        if (fileType == 'image') {
          lastMessageText = '[Image]';
        } else if (fileType == 'video') lastMessageText = '[Video]';
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
      final offline = conn.isEmpty || conn.contains(ConnectivityResult.none);
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
          if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) {
            ct = 'image/jpeg';
          } else if (lower.endsWith('.png')) ct = 'image/png';
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
      final offline = conn.isEmpty || conn.contains(ConnectivityResult.none);
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
          if (lower.endsWith('.mp4')) {
            ct = 'video/mp4';
          } else if (lower.endsWith('.mov')) ct = 'video/quicktime';
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
      final offline = conn.isEmpty || conn.contains(ConnectivityResult.none);
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
            content: Text('Failed to upload voice: $msg'),
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

  Future<void> _showAttachmentOptions() async {
    final choice = await showModalBottomSheet<String?>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return SafeArea(
          child: Wrap(
            children: [
              ListTile(
                leading: const Icon(Icons.videocam, color: Colors.blue),
                title: const Text('Video'),
                onTap: () => Navigator.pop(context, 'video'),
              ),
              ListTile(
                leading: const Icon(Icons.insert_drive_file, color: Colors.orange),
                title: const Text('Document'),
                onTap: () => Navigator.pop(context, 'document'),
              ),
              ListTile(
                leading: const Icon(Icons.picture_as_pdf, color: Colors.red),
                title: const Text('PDF'),
                onTap: () => Navigator.pop(context, 'pdf'),
              ),
              ListTile(
                leading: const Icon(Icons.text_snippet, color: Colors.green),
                title: const Text('Text File'),
                onTap: () => Navigator.pop(context, 'txt'),
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );

    if (choice == null) return;

    switch (choice) {
      case 'video':
        await _pickAndSendVideo();
        break;
      case 'document':
        await _pickAndSendDocument('document');
        break;
      case 'pdf':
        await _pickAndSendDocument('pdf');
        break;
      case 'txt':
        await _pickAndSendDocument('txt');
        break;
    }
  }

  Future<void> _pickAndSendDocument(String docType) async {
    try {
      debugPrint('📄 Starting _pickAndSendDocument for docType: $docType');
      
      // Determine file type filter and bucket based on docType
      List<String> allowedExtensions;
      String bucket;
      
      if (docType == 'pdf') {
        allowedExtensions = ['pdf'];
        bucket = 'message-pdf';
      } else if (docType == 'txt') {
        allowedExtensions = ['txt'];
        bucket = 'message-txt';
      } else {
        allowedExtensions = ['doc', 'docx', 'pdf', 'txt'];
        bucket = 'message-docs';
      }

      // Pick file using file_picker
      debugPrint('📄 Starting file picker for docType: $docType, extensions: $allowedExtensions, bucket: $bucket');
      debugPrint('📄 Platform check: kIsWeb = $kIsWeb');
      
      if (kIsWeb) {
        // Web: Use HTML input element directly to avoid plugin issues
        debugPrint('📄 Using HTML file input for web');
        try {
          final html = await web_picker.pickFileWeb(allowedExtensions);
          if (html == null) {
            debugPrint('📄 File picker cancelled');
            return;
          }
          
          final fileName = html['name'] as String;
          final bytes = html['bytes'] as Uint8List;
          
          debugPrint('📄 File picked: $fileName, size: ${bytes.length} bytes');
          setState(() => _sending = true);
          
          try {
            debugPrint('📄 Starting upload to Supabase bucket: $bucket');
            final url = await sb.uploadMessageDocumentBytes(bytes, fileName: fileName, bucket: bucket);
            debugPrint('📄 Upload successful! URL: $url');
            
            await _sendMessage(fileUrl: url, fileType: docType, text: fileName);
            
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Document "$fileName" sent successfully')),
              );
            }
          } catch (e) {
            debugPrint('📄 Document upload error: $e');
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Failed to upload document: ${e.toString()}')),
              );
            }
          } finally {
            setState(() => _sending = false);
          }
        } catch (e) {
          debugPrint('📄 Web file picker error: $e');
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('File picker error: ${e.toString()}')),
            );
          }
        }
        return;
      }
      
      // Mobile/Desktop: Use file_picker plugin
      FilePickerResult? result;
      try {
        result = await FilePicker.platform.pickFiles(
          type: FileType.custom,
          allowedExtensions: allowedExtensions,
          allowMultiple: false,
        );
      } catch (pickerError) {
        debugPrint('📄 FilePicker.platform error: $pickerError');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('File picker error: ${pickerError.toString()}. Try refreshing the page.')),
          );
        }
        return;
      }
      
      if (result == null || result.files.isEmpty) {
        debugPrint('📄 File picker cancelled or no file selected');
        return;
      }
      
      debugPrint('📄 File picked: ${result.files.first.name}, size: ${result.files.first.size} bytes');
      setState(() => _sending = true);
      
      final pickedFile = result.files.first;
      final fileName = pickedFile.name;
      
      String url = '';
      try {
        debugPrint('📄 Starting upload to Supabase bucket: $bucket');
        if (kIsWeb) {
          // Web: use bytes
          final bytes = pickedFile.bytes;
          if (bytes == null) {
            throw Exception('Failed to read file bytes');
          }
          debugPrint('📄 Web: uploading ${bytes.length} bytes');
          url = await sb.uploadMessageDocumentBytes(bytes, fileName: fileName, bucket: bucket);
        } else {
          // Mobile/Desktop: use file path
          final filePath = pickedFile.path;
          if (filePath == null) {
            throw Exception('Failed to get file path');
          }
          debugPrint('📄 Mobile: uploading from path: $filePath');
          final file = File(filePath);
          url = await sb.uploadMessageDocument(file, fileName: fileName, bucket: bucket);
        }
        
        debugPrint('📄 Upload successful! URL: $url');
        // Send with filename as text so it displays in the message
        await _sendMessage(fileUrl: url, fileType: docType, text: fileName);
        
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Document "$fileName" sent successfully')),
          );
        }
      } catch (e) {
        debugPrint('📄 Document upload error: $e');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to upload document: ${e.toString()}')),
          );
        }
      } finally {
        setState(() => _sending = false);
      }
    } catch (e) {
      debugPrint('Document picker error: $e');
      if (mounted) {
        setState(() => _sending = false);
      }
    }
  }

  Future<void> _openDocument(String url, String fileName, String fileType) async {
    try {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => DocumentViewer(
            documentUrl: url,
            fileName: fileName,
            fileType: fileType,
          ),
        ),
      );
    } catch (e) {
      debugPrint('Error opening document: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error opening document: ${e.toString()}')),
        );
      }
    }
  }

  String _getFileTypeLabel(String fileType) {
    switch (fileType) {
      case 'pdf':
        return 'PDF Document';
      case 'txt':
        return 'Text File';
      case 'document':
        return 'Document';
      default:
        return 'File';
    }
  }

  Widget _buildAudioBubble(String messageId, String url, bool isMe) {
    final isPlaying = _playingMessageId == messageId;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: isMe ? Colors.white.withValues(alpha: 0.15) : Colors.black.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          GestureDetector(
            onTap: () async {
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
            child: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isMe ? Colors.white : Theme.of(context).primaryColor,
              ),
              child: Icon(
                isPlaying ? Icons.pause : Icons.play_arrow_rounded,
                color: isMe ? Theme.of(context).primaryColor : Colors.white,
                size: 22,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // Waveform representation
              Row(
                mainAxisSize: MainAxisSize.min,
                children: List.generate(14, (i) {
                  final heights = [8.0, 14.0, 18.0, 10.0, 22.0, 16.0, 12.0, 20.0, 24.0, 14.0, 10.0, 18.0, 12.0, 8.0];
                  final h = heights[i % heights.length];
                  return Container(
                    margin: const EdgeInsets.symmetric(horizontal: 1.5),
                    width: 3,
                    height: isPlaying ? (h * 0.8 + (i % 3) * 4) : h,
                    decoration: BoxDecoration(
                      color: isMe
                          ? Colors.white.withValues(alpha: (isPlaying && i < 7) ? 1.0 : 0.6)
                          : (isPlaying && i < 7 ? Theme.of(context).primaryColor : Colors.grey.shade400),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  );
                }),
              ),
              const SizedBox(height: 4),
              Text(
                isPlaying ? 'Playing audio...' : 'Voice message',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: isMe ? Colors.white.withValues(alpha: 0.85) : Colors.black54,
                ),
              ),
            ],
          ),
          const SizedBox(width: 4),
        ],
      ),
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

  void _showChatSettings() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Chat Settings'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Message Font Option
            ListTile(
              leading: const Icon(Icons.text_fields),
              title: const Text('Message Font'),
              trailing: const Icon(Icons.arrow_forward_ios, size: 16),
              onTap: () {
                Navigator.pop(context);
                _showFontSizeDialog('message');
              },
            ),
            const Divider(),
            
            // Tag Font Option
            ListTile(
              leading: const Icon(Icons.label),
              title: const Text('Tag Font (Sent/Seen)'),
              trailing: const Icon(Icons.arrow_forward_ios, size: 16),
              onTap: () {
                Navigator.pop(context);
                _showFontSizeDialog('tag');
              },
            ),
            const Divider(),
            
            // Bubble Color Option
            ListTile(
              leading: Icon(Icons.color_lens, color: _myBubbleColor),
              title: const Text('Message Bubble Color'),
              trailing: const Icon(Icons.arrow_forward_ios, size: 16),
              onTap: () {
                Navigator.pop(context);
                _showColorDialog('bubble');
              },
            ),
            const Divider(),
            
            // Sent Tag Color Option
            ListTile(
              leading: Icon(Icons.access_time, color: _sentTagColor),
              title: const Text('Sent Tag Color'),
              trailing: const Icon(Icons.arrow_forward_ios, size: 16),
              onTap: () {
                Navigator.pop(context);
                _showColorDialog('sent');
              },
            ),
            const Divider(),
            
            // Seen Tag Color Option
            ListTile(
              leading: Icon(Icons.done_all, color: _seenTagColor),
              title: const Text('Seen Tag Color'),
              trailing: const Icon(Icons.arrow_forward_ios, size: 16),
              onTap: () {
                Navigator.pop(context);
                _showColorDialog('seen');
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  void _showFontSizeDialog(String type) {
    double currentSize = type == 'message' ? _messageFontSize : _tagFontSize;
    double tempSize = currentSize;
    
    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            title: Text(type == 'message' ? 'Message Font Size' : 'Tag Font Size'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Size: ${tempSize.toInt()}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                const SizedBox(height: 16),
                Slider(
                  value: tempSize,
                  min: type == 'message' ? 10 : 8,
                  max: type == 'message' ? 24 : 16,
                  divisions: type == 'message' ? 14 : 8,
                  label: tempSize.toInt().toString(),
                  onChanged: (value) {
                    setDialogState(() {
                      tempSize = value;
                    });
                  },
                ),
                const SizedBox(height: 16),
                Text(
                  'Preview Text',
                  style: TextStyle(fontSize: tempSize),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () {
                  setState(() {
                    if (type == 'message') {
                      _messageFontSize = tempSize;
                    } else {
                      _tagFontSize = tempSize;
                    }
                  });
                  _saveChatSettings();
                  Navigator.pop(context);
                },
                child: const Text('Save'),
              ),
            ],
          );
        },
      ),
    );
  }

  void _showColorDialog(String type) {
    List<Color> colors = [];
    String title = '';
    
    if (type == 'bubble') {
      title = 'Message Bubble Color';
      colors = [
        Colors.blue, Colors.green, Colors.purple, Colors.orange,
        Colors.teal, Colors.pink, Colors.indigo, Colors.deepOrange,
        Colors.cyan, Colors.amber, Colors.brown, Colors.blueGrey,
      ];
    } else if (type == 'sent') {
      title = 'Sent Tag Color';
      colors = [
        Colors.white70, Colors.white, Colors.grey[300]!,
        Colors.blue[200]!, Colors.green[200]!, Colors.purple[200]!,
        Colors.orange[200]!, Colors.teal[200]!, Colors.pink[200]!,
        Colors.yellow[200]!, Colors.cyan[200]!, Colors.amber[200]!,
      ];
    } else {
      title = 'Seen Tag Color';
      colors = [
        const Color.fromARGB(255, 238, 3, 3), Colors.red, Colors.green,
        Colors.blue, Colors.orange, Colors.purple, Colors.teal,
        Colors.pink, Colors.indigo, Colors.amber, Colors.cyan, Colors.lime,
      ];
    }
    
    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            title: Text(title),
            content: Wrap(
              spacing: 12,
              runSpacing: 12,
              children: colors.map((color) {
                bool isSelected = false;
                if (type == 'bubble') {
                  isSelected = _myBubbleColor.value == color.value;
                } else if (type == 'sent') {
                  isSelected = _sentTagColor.value == color.value;
                } else {
                  isSelected = _seenTagColor.value == color.value;
                }
                
                return GestureDetector(
                  onTap: () {
                    setState(() {
                      if (type == 'bubble') {
                        _myBubbleColor = color;
                      } else if (type == 'sent') {
                        _sentTagColor = color;
                      } else {
                        _seenTagColor = color;
                      }
                    });
                    _saveChatSettings();
                    Navigator.pop(context);
                  },
                  child: Container(
                    width: 50,
                    height: 50,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: isSelected ? Colors.black : Colors.grey[300]!,
                        width: isSelected ? 3 : 1,
                      ),
                    ),
                    child: isSelected ? const Icon(Icons.check, color: Colors.white, size: 24) : null,
                  ),
                );
              }).toList(),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Close'),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildGroupTitle(bool isDark) {
    final groupName = _groupData?['group_name'] ?? 'Group';
    final groupPhotoUrl = _groupData?['group_photo'];
    final memberCount = _groupParticipants.length;

    return Row(
      children: [
        CircleAvatar(
          radius: 19,
          backgroundImage: groupPhotoUrl != null && groupPhotoUrl.isNotEmpty
              ? CachedNetworkImageProvider(groupPhotoUrl)
              : null,
          backgroundColor: const Color(0xFF0D9488),
          child: groupPhotoUrl == null || groupPhotoUrl.isEmpty
              ? const Icon(Icons.groups_rounded, color: Colors.white, size: 20)
              : null,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                groupName,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: isDark ? Colors.white : const Color(0xFF0F172A),
                ),
              ),
              Text(
                '$memberCount members',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  color: isDark ? Colors.white54 : Colors.grey.shade600,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildUserTitle(bool isDark) {
    return StreamBuilder<DocumentSnapshot>(
      stream: _firestore.collection('users').doc(widget.otherUserId).snapshots(),
      builder: (context, snapshot) {
        String title = widget.otherUserId;
        String? avatarUrl;
        bool isOnline = false;
        int lastActive = 0;

        if (snapshot.hasData && snapshot.data!.exists) {
          final data = snapshot.data!.data() as Map<String, dynamic>?;
          title = data?['name'] ?? widget.otherUserId;
          avatarUrl = data?['profile_image'];
          isOnline = data?['is_online'] == true;
          lastActive = data?['last_active'] ?? 0;
        }

        String statusText = '';
        if (isOnline) {
          statusText = 'Online';
        } else if (lastActive > 0) {
          final now = DateTime.now().millisecondsSinceEpoch;
          final diff = now - lastActive;
          final minutes = diff ~/ 60000;
          final hours = diff ~/ 3600000;
          final days = diff ~/ 86400000;

          if (minutes < 1) {
            statusText = 'Active just now';
          } else if (minutes < 60) {
            statusText = 'Active ${minutes}m ago';
          } else if (hours < 24) {
            statusText = 'Active ${hours}h ago';
          } else if (days < 7) {
            statusText = 'Active ${days}d ago';
          } else {
            statusText = '';
          }
        }

        return GestureDetector(
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => SeeProfileFromNewsfeed(userId: widget.otherUserId),
              ),
            );
          },
          child: Row(
            children: [
              Stack(
                children: [
                  CircleAvatar(
                    radius: 19,
                    backgroundColor: Colors.grey.shade300,
                    backgroundImage: (avatarUrl != null && avatarUrl.isNotEmpty)
                        ? CachedNetworkImageProvider(avatarUrl)
                        : null,
                    child: (avatarUrl == null || avatarUrl.isEmpty)
                        ? Text(
                            title.isNotEmpty ? title[0].toUpperCase() : '?',
                            style: const TextStyle(
                              color: Colors.black87,
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                            ),
                          )
                        : null,
                  ),
                  if (isOnline)
                    Positioned(
                      right: 0,
                      bottom: 0,
                      child: Container(
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(
                          color: const Color(0xFF10B981),
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: isDark ? const Color(0xFF1E293B) : Colors.white,
                            width: 2,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: isDark ? Colors.white : const Color(0xFF0F172A),
                      ),
                    ),
                    if (statusText.isNotEmpty)
                      Row(
                        children: [
                          if (isOnline)
                            Container(
                              width: 6,
                              height: 6,
                              margin: const EdgeInsets.only(right: 4),
                              decoration: const BoxDecoration(
                                color: Color(0xFF10B981),
                                shape: BoxShape.circle,
                              ),
                            ),
                          Text(
                            statusText,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: isOnline ? FontWeight.w600 : FontWeight.normal,
                              color: isOnline
                                  ? const Color(0xFF10B981)
                                  : (isDark ? Colors.white54 : Colors.grey.shade600),
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _startGroupCall({required bool audioOnly}) async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return;
    final channel = 'conv_${widget.conversationId}';

    String? sessionId;
    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      final ref = await FirebaseFirestore.instance.collection('call_sessions').add({
        'channel': channel,
        'caller_id': uid,
        'video': !audioOnly,
        'status': 'ringing',
        'timestamp': now,
        'created_at': now,
        'is_group': true,
        'group_id': widget.conversationId,
      });
      sessionId = ref.id;
    } catch (e) {
      debugPrint('Failed to create group call session: $e');
    }

    try {
      await _firestore
          .collection('conversations')
          .doc(widget.conversationId)
          .collection('messages')
          .add({
        'sender_id': uid,
        'text': audioOnly ? 'Started a group audio call' : 'Started a group video call',
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'file_url': '',
        'file_type': audioOnly ? 'call_audio' : 'call_video',
        'call_channel': channel,
        'reactions': <String, dynamic>{},
        'edited': false,
      });
      await _firestore.collection('conversations').doc(widget.conversationId).update({
        'last_message': audioOnly ? '[Group audio call]' : '[Group video call]',
        'last_updated': DateTime.now().millisecondsSinceEpoch,
      });
    } catch (e) {
      debugPrint('Error sending group call invite: $e');
    }

    if (!mounted) return;
    Navigator.push(
      context,
      CallPage.route(
        channelName: channel,
        video: !audioOnly,
        callSessionId: sessionId,
        conversationId: widget.conversationId,
        isGroupCall: true,
      ),
    );
  }

  Future<void> _showGroupInfo() async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => GroupInfoSheet(
        conversationId: widget.conversationId,
        groupData: _groupData,
        participants: _groupParticipants,
        adminId: _groupAdmin,
        onMembersUpdated: () {
          _loadGroupData();
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return const Scaffold(body: Center(child: Text('Please sign in')));

    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: isDark ? const Color(0xFF0F172A) : const Color(0xFFF1F5F9),
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(60),
        child: Container(
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF1E293B) : Colors.white,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.04),
                offset: const Offset(0, 2),
                blurRadius: 8,
              ),
            ],
          ),
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6.0, vertical: 4.0),
              child: Row(
                children: [
                  IconButton(
                    icon: Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: isDark ? Colors.white10 : Colors.grey.shade100,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(Icons.arrow_back, size: 20, color: isDark ? Colors.white : Colors.black87),
                    ),
                    onPressed: () => Navigator.pop(context),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: widget.isGroup ? _buildGroupTitle(isDark) : _buildUserTitle(isDark),
                  ),
                  if (!widget.isGroup) ...[
                    IconButton(
                      tooltip: 'Audio Call',
                      icon: Container(
                        padding: const EdgeInsets.all(7),
                        decoration: BoxDecoration(
                          color: isDark ? Colors.white10 : Colors.grey.shade100,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(Icons.call_outlined, size: 18, color: isDark ? Colors.white : Colors.black87),
                      ),
                      onPressed: () => _startCall(audioOnly: true),
                    ),
                    IconButton(
                      tooltip: 'Video Call',
                      icon: Container(
                        padding: const EdgeInsets.all(7),
                        decoration: BoxDecoration(
                          color: isDark ? Colors.white10 : Colors.grey.shade100,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(Icons.videocam_outlined, size: 18, color: isDark ? Colors.white : Colors.black87),
                      ),
                      onPressed: () => _startCall(audioOnly: false),
                    ),
                  ],
                  if (widget.isGroup) ...[
                    IconButton(
                      tooltip: 'Group Audio Call',
                      icon: Container(
                        padding: const EdgeInsets.all(7),
                        decoration: BoxDecoration(
                          color: isDark ? Colors.white10 : Colors.grey.shade100,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(Icons.call_outlined, size: 18, color: isDark ? Colors.white : Colors.black87),
                      ),
                      onPressed: () => _startGroupCall(audioOnly: true),
                    ),
                    IconButton(
                      tooltip: 'Group Video Call',
                      icon: Container(
                        padding: const EdgeInsets.all(7),
                        decoration: BoxDecoration(
                          color: isDark ? Colors.white10 : Colors.grey.shade100,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(Icons.videocam_outlined, size: 18, color: isDark ? Colors.white : Colors.black87),
                      ),
                      onPressed: () => _startGroupCall(audioOnly: false),
                    ),
                    IconButton(
                      tooltip: 'Group Info',
                      icon: Container(
                        padding: const EdgeInsets.all(7),
                        decoration: BoxDecoration(
                          color: isDark ? Colors.white10 : Colors.grey.shade100,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(Icons.info_outline_rounded, size: 18, color: isDark ? Colors.white : Colors.black87),
                      ),
                      onPressed: () => _showGroupInfo(),
                    ),
                  ],
                  if (!widget.isGroup)
                    IconButton(
                      tooltip: 'All Media',
                      icon: Container(
                        padding: const EdgeInsets.all(7),
                        decoration: BoxDecoration(
                          color: isDark ? Colors.white10 : Colors.grey.shade100,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(Icons.perm_media_outlined, size: 18, color: isDark ? Colors.white : Colors.black87),
                      ),
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
                  IconButton(
                    tooltip: 'Settings',
                    icon: Container(
                      padding: const EdgeInsets.all(7),
                      decoration: BoxDecoration(
                        color: isDark ? Colors.white10 : Colors.grey.shade100,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(Icons.more_vert, size: 18, color: isDark ? Colors.white : Colors.black87),
                    ),
                    onPressed: () => _showChatSettings(),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: StreamBuilder<DocumentSnapshot>(
              stream: _firestore
                  .collection('conversations')
                  .doc(widget.conversationId)
                  .snapshots(includeMetadataChanges: !kIsWeb),
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
                  .snapshots(includeMetadataChanges: !kIsWeb),
                  builder: (context, snap) {
                    if (snap.hasError) {
                      debugPrint('Messages stream error: ${snap.error}');
                      return Center(child: Text('Error: ${snap.error}'));
                    }

                    if (!snap.hasData) return const Center(child: CircularProgressIndicator());

                    final docs = snap.data!.docs;

                    if (_previousMessageCount > 0 && docs.length > _previousMessageCount) {
                      final newMessage = docs.last;
                      final newMessageData = newMessage.data() as Map<String, dynamic>? ?? {};
                      final senderId = newMessageData['sender_id'];
                      if (senderId != uid) {
                        _playNotificationSound();
                      }
                    }
                    _previousMessageCount = docs.length;

                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      _scrollToBottom();
                    });

                    return ListView.builder(
                      restorationId: 'chat_list_${widget.conversationId}',
                      controller: _scrollController,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                      itemCount: docs.length + (otherIsTyping ? 1 : 0),
                      itemBuilder: (context, index) {
                        if (otherIsTyping && index == docs.length) {
                          return Align(
                            alignment: Alignment.centerLeft,
                            child: Container(
                              margin: const EdgeInsets.only(left: 8, top: 4, bottom: 8),
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                              decoration: BoxDecoration(
                                color: isDark ? const Color(0xFF1E293B) : Colors.white,
                                borderRadius: BorderRadius.circular(16),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.04),
                                    blurRadius: 4,
                                    offset: const Offset(0, 2),
                                  ),
                                ],
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Container(
                                    width: 6,
                                    height: 6,
                                    decoration: const BoxDecoration(
                                      color: Color(0xFF3B82F6),
                                      shape: BoxShape.circle,
                                    ),
                                  ),
                                  const SizedBox(width: 4),
                                  Container(
                                    width: 6,
                                    height: 6,
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF3B82F6).withValues(alpha: 0.7),
                                      shape: BoxShape.circle,
                                    ),
                                  ),
                                  const SizedBox(width: 4),
                                  Container(
                                    width: 6,
                                    height: 6,
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF3B82F6).withValues(alpha: 0.4),
                                      shape: BoxShape.circle,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    'Typing...',
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontStyle: FontStyle.italic,
                                      color: isDark ? Colors.white70 : Colors.grey.shade600,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        }

                        final d = docs[index];
                        final data = d.data() as Map<String, dynamic>? ?? {};
                        final senderId = data['sender_id'] ?? '';
                        final isMe = senderId == uid;
                        final text = data['text'] ?? '';
                        final fileUrl = data['file_url'] ?? '';
                        final fileType = data['file_type'] ?? '';
                        final callChannel = data['call_channel'] ?? '';
                        final timestamp = data['timestamp'] ?? 0;
                        final seen = isMe && otherLastRead >= timestamp;
                        final edited = data['edited'] == true;
                        final uploading = data['uploading'] == true;
                        final pending = d.metadata.hasPendingWrites;

                        // Check if we need to show date separator
                        bool showDateSeparator = false;
                        if (index == 0) {
                          showDateSeparator = true;
                        } else {
                          final prevData = docs[index - 1].data() as Map<String, dynamic>? ?? {};
                          final prevTimestamp = prevData['timestamp'] ?? 0;
                          final prevDate = DateTime.fromMillisecondsSinceEpoch(prevTimestamp);
                          final curDate = DateTime.fromMillisecondsSinceEpoch(timestamp);
                          if (prevDate.year != curDate.year ||
                              prevDate.month != curDate.month ||
                              prevDate.day != curDate.day) {
                            showDateSeparator = true;
                          }
                        }

                        Widget? senderInfoWidget;
                        if (widget.isGroup && !isMe && senderId.isNotEmpty) {
                          senderInfoWidget = StreamBuilder<DocumentSnapshot>(
                            stream: _firestore.collection('users').doc(senderId).snapshots(),
                            builder: (context, userSnap) {
                              String senderName = senderId;
                              String? senderPhotoUrl;
                              if (userSnap.hasData && userSnap.data!.exists) {
                                final userData = userSnap.data!.data() as Map<String, dynamic>?;
                                senderName = userData?['name'] ?? senderId;
                                senderPhotoUrl = userData?['profile_image'];
                              }
                              return Padding(
                                padding: const EdgeInsets.only(left: 8, bottom: 3),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    CircleAvatar(
                                      radius: 9,
                                      backgroundImage: (senderPhotoUrl != null && senderPhotoUrl.isNotEmpty)
                                          ? CachedNetworkImageProvider(senderPhotoUrl)
                                          : null,
                                      child: (senderPhotoUrl == null || senderPhotoUrl.isEmpty)
                                          ? Text(
                                              senderName.isNotEmpty ? senderName[0].toUpperCase() : '?',
                                              style: const TextStyle(fontSize: 8, fontWeight: FontWeight.bold),
                                            )
                                          : null,
                                    ),
                                    const SizedBox(width: 5),
                                    Text(
                                      senderName,
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w700,
                                        color: isDark ? Colors.white60 : Colors.grey.shade700,
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            },
                          );
                        }

                        return Column(
                          children: [
                            if (showDateSeparator && timestamp > 0)
                              _buildDateSeparator(timestamp, isDark),
                            Align(
                              alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(vertical: 3),
                                child: Column(
                                  crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                                  children: [
                                    if (senderInfoWidget != null) senderInfoWidget,
                                    GestureDetector(
                                      onLongPress: () => _showMessageOptions(d.id, data, isMe),
                                      child: Container(
                                        constraints: BoxConstraints(
                                          maxWidth: MediaQuery.of(context).size.width * 0.76,
                                        ),
                                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                                        decoration: BoxDecoration(
                                          gradient: isMe
                                              ? LinearGradient(
                                                  colors: [
                                                    _myBubbleColor,
                                                    _myBubbleColor.withValues(alpha: 0.88),
                                                  ],
                                                  begin: Alignment.topLeft,
                                                  end: Alignment.bottomRight,
                                                )
                                              : null,
                                          color: isMe
                                              ? null
                                              : (isDark ? const Color(0xFF1E293B) : Colors.white),
                                          borderRadius: BorderRadius.only(
                                            topLeft: const Radius.circular(18),
                                            topRight: const Radius.circular(18),
                                            bottomLeft: Radius.circular(isMe ? 18 : 4),
                                            bottomRight: Radius.circular(isMe ? 4 : 18),
                                          ),
                                          boxShadow: [
                                            BoxShadow(
                                              color: Colors.black.withValues(alpha: isMe ? 0.08 : 0.03),
                                              blurRadius: 4,
                                              offset: const Offset(0, 2),
                                            ),
                                          ],
                                          border: isMe
                                              ? null
                                              : Border.all(
                                                  color: isDark
                                                      ? Colors.white.withValues(alpha: 0.05)
                                                      : Colors.grey.shade200,
                                                  width: 1,
                                                ),
                                        ),
                                        child: Column(
                                          crossAxisAlignment:
                                              isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                                          children: [
                                            // Audio bubble
                                            if (fileUrl.isNotEmpty && fileType == 'audio')
                                              Padding(
                                                padding: const EdgeInsets.only(bottom: 6.0),
                                                child: _buildAudioBubble(d.id, fileUrl, isMe),
                                              ),

                                            // Image attachment
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
                                                  padding: const EdgeInsets.only(bottom: 6.0),
                                                  child: ClipRRect(
                                                    borderRadius: BorderRadius.circular(12),
                                                    child: CachedNetworkImage(
                                                      imageUrl: fileUrl,
                                                      cacheManager: AppCacheManager.instance,
                                                      width: double.infinity,
                                                      fit: BoxFit.cover,
                                                      errorWidget: (context, url, error) =>
                                                          const Icon(Icons.broken_image_rounded, size: 40),
                                                    ),
                                                  ),
                                                ),
                                              ),

                                            // Video attachment
                                            if (fileUrl.isNotEmpty && fileType == 'video')
                                              GestureDetector(
                                                onTap: () {
                                                  final videoData = {
                                                    'video_url': fileUrl,
                                                    'text': text.isNotEmpty ? text : 'Video',
                                                  };
                                                  Navigator.push(
                                                    context,
                                                    MaterialPageRoute(
                                                      builder: (_) => VideoPlayerScreen(
                                                        videos: [videoData],
                                                        startIndex: 0,
                                                      ),
                                                    ),
                                                  );
                                                },
                                                child: Container(
                                                  height: 140,
                                                  margin: const EdgeInsets.only(bottom: 6),
                                                  decoration: BoxDecoration(
                                                    color: Colors.black87,
                                                    borderRadius: BorderRadius.circular(12),
                                                  ),
                                                  child: Stack(
                                                    alignment: Alignment.center,
                                                    children: [
                                                      Container(
                                                        padding: const EdgeInsets.all(12),
                                                        decoration: BoxDecoration(
                                                          color: Colors.white.withValues(alpha: 0.2),
                                                          shape: BoxShape.circle,
                                                        ),
                                                        child: const Icon(Icons.play_arrow_rounded,
                                                            size: 36, color: Colors.white),
                                                      ),
                                                      Positioned(
                                                        bottom: 8,
                                                        left: 12,
                                                        right: 12,
                                                        child: Text(
                                                          text.isNotEmpty ? text : 'Video',
                                                          style: const TextStyle(color: Colors.white, fontSize: 12),
                                                          maxLines: 1,
                                                          overflow: TextOverflow.ellipsis,
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                              ),

                                            // Document attachment
                                            if (fileUrl.isNotEmpty &&
                                                (fileType == 'document' || fileType == 'pdf' || fileType == 'txt'))
                                              GestureDetector(
                                                onTap: () => _openDocument(
                                                  fileUrl,
                                                  text.isNotEmpty ? text : 'Document',
                                                  fileType,
                                                ),
                                                child: Container(
                                                  margin: const EdgeInsets.only(bottom: 6),
                                                  padding: const EdgeInsets.all(10),
                                                  decoration: BoxDecoration(
                                                    color: isMe
                                                        ? Colors.white.withValues(alpha: 0.15)
                                                        : (isDark
                                                            ? Colors.black.withValues(alpha: 0.2)
                                                            : Colors.grey.shade100),
                                                    borderRadius: BorderRadius.circular(12),
                                                  ),
                                                  child: Row(
                                                    mainAxisSize: MainAxisSize.min,
                                                    children: [
                                                      Container(
                                                        padding: const EdgeInsets.all(8),
                                                        decoration: BoxDecoration(
                                                          color: fileType == 'pdf'
                                                              ? Colors.red.withValues(alpha: 0.15)
                                                              : Colors.blue.withValues(alpha: 0.15),
                                                          borderRadius: BorderRadius.circular(8),
                                                        ),
                                                        child: Icon(
                                                          fileType == 'pdf'
                                                              ? Icons.picture_as_pdf_rounded
                                                              : Icons.description_rounded,
                                                          color: fileType == 'pdf' ? Colors.red : Colors.blue,
                                                          size: 24,
                                                        ),
                                                      ),
                                                      const SizedBox(width: 10),
                                                      Flexible(
                                                        child: Column(
                                                          crossAxisAlignment: CrossAxisAlignment.start,
                                                          mainAxisSize: MainAxisSize.min,
                                                          children: [
                                                            Text(
                                                              text.isNotEmpty
                                                                  ? text
                                                                  : _getFileTypeLabel(fileType),
                                                              style: TextStyle(
                                                                color: isMe
                                                                    ? Colors.white
                                                                    : (isDark ? Colors.white : Colors.black87),
                                                                fontWeight: FontWeight.w600,
                                                                fontSize: 13,
                                                              ),
                                                              maxLines: 1,
                                                              overflow: TextOverflow.ellipsis,
                                                            ),
                                                            Text(
                                                              _getFileTypeLabel(fileType),
                                                              style: TextStyle(
                                                                color: isMe
                                                                    ? Colors.white70
                                                                    : (isDark ? Colors.white54 : Colors.black54),
                                                                fontSize: 11,
                                                              ),
                                                            ),
                                                          ],
                                                        ),
                                                      ),
                                                      const SizedBox(width: 8),
                                                      Icon(
                                                        Icons.download_rounded,
                                                        color: isMe
                                                            ? Colors.white70
                                                            : (isDark ? Colors.white54 : Colors.black54),
                                                        size: 18,
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                              ),

                                            // Text Message
                                            if (text.isNotEmpty)
                                              Padding(
                                                padding: const EdgeInsets.only(bottom: 4.0),
                                                child: Text(
                                                  text,
                                                  style: TextStyle(
                                                    color: isMe
                                                        ? Colors.white
                                                        : (isDark ? Colors.white : const Color(0xFF0F172A)),
                                                    fontSize: _messageFontSize,
                                                    height: 1.35,
                                                  ),
                                                ),
                                              ),

                                            // Call invite card
                                            if (fileType == 'call_audio' || fileType == 'call_video')
                                              Padding(
                                                padding: const EdgeInsets.only(top: 4.0, bottom: 4.0),
                                                child: ElevatedButton.icon(
                                                  style: ElevatedButton.styleFrom(
                                                    backgroundColor: isMe ? Colors.white : const Color(0xFF2563EB),
                                                    foregroundColor: isMe ? const Color(0xFF2563EB) : Colors.white,
                                                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                                                    shape: RoundedRectangleBorder(
                                                      borderRadius: BorderRadius.circular(12),
                                                    ),
                                                    elevation: 0,
                                                  ),
                                                  onPressed: () async {
                                                    final channel = callChannel is String && callChannel.isNotEmpty
                                                        ? callChannel
                                                        : 'conv_${widget.conversationId}';
                                                    String? matchedSessionId;
                                                    try {
                                                      final callSnap = await _firestore
                                                          .collection('call_sessions')
                                                          .where('channel', isEqualTo: channel)
                                                          .where('status', isEqualTo: 'ringing')
                                                          .limit(1)
                                                          .get();
                                                      if (callSnap.docs.isNotEmpty) {
                                                        matchedSessionId = callSnap.docs.first.id;
                                                        if (!isMe) {
                                                          await callSnap.docs.first.reference.update({
                                                            'status': 'accepted',
                                                            'accepted_at': DateTime.now().millisecondsSinceEpoch,
                                                          });
                                                        }
                                                      }
                                                    } catch (_) {}
                                                    if (!context.mounted) return;
                                                    Navigator.push(
                                                      context,
                                                      CallPage.route(
                                                        channelName: channel,
                                                        video: fileType == 'call_video',
                                                        conversationId: widget.conversationId,
                                                        remoteUserId: isMe ? widget.otherUserId : senderId,
                                                        callSessionId: matchedSessionId,
                                                        isGroupCall: widget.isGroup,
                                                      ),
                                                    );
                                                  },
                                                  icon: Icon(
                                                    fileType == 'call_video'
                                                        ? Icons.videocam_rounded
                                                        : Icons.call_rounded,
                                                    size: 16,
                                                  ),
                                                  label: Text(
                                                    fileType == 'call_video' ? 'Join Video Call' : 'Join Audio Call',
                                                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                                                  ),
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
                                                    const SizedBox(width: 6),
                                                    Text(
                                                      'Uploading...',
                                                      style: TextStyle(
                                                        color: isMe ? Colors.white70 : Colors.black54,
                                                        fontSize: 11,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),

                                            if (edited)
                                              Padding(
                                                padding: const EdgeInsets.only(bottom: 2.0),
                                                child: Text(
                                                  '(edited)',
                                                  style: TextStyle(
                                                    fontSize: 10,
                                                    fontStyle: FontStyle.italic,
                                                    color: isMe ? Colors.white60 : Colors.grey,
                                                  ),
                                                ),
                                              ),

                                            // Meta timestamp and read checkmarks
                                            Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                Text(
                                                  _formatMessageTimestamp(timestamp),
                                                  style: TextStyle(
                                                    fontSize: 10,
                                                    color: isMe
                                                        ? Colors.white.withValues(alpha: 0.75)
                                                        : (isDark ? Colors.white38 : Colors.grey.shade500),
                                                  ),
                                                ),
                                                if (isMe) ...[
                                                  const SizedBox(width: 4),
                                                  if (pending)
                                                    Icon(
                                                      Icons.schedule_rounded,
                                                      size: 11,
                                                      color: Colors.white.withValues(alpha: 0.75),
                                                    )
                                                  else if (seen)
                                                    const Icon(
                                                      Icons.done_all_rounded,
                                                      size: 13,
                                                      color: Color(0xFF67E8F9),
                                                    )
                                                  else
                                                    Icon(
                                                      Icons.done_rounded,
                                                      size: 13,
                                                      color: Colors.white.withValues(alpha: 0.75),
                                                    ),
                                                ],
                                              ],
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),

                                    // Reactions pill
                                    if ((data['reactions'] as Map<String, dynamic>?)?.isNotEmpty ?? false)
                                      Padding(
                                        padding: const EdgeInsets.only(top: 2.0, left: 4, right: 4),
                                        child: Wrap(
                                          spacing: 4,
                                          children:
                                              (data['reactions'] as Map<String, dynamic>).entries.map((e) {
                                            final emoji = e.key;
                                            final users = List<String>.from(e.value ?? <String>[]);
                                            final hasMyReaction = users.contains(uid);
                                            return Container(
                                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                              decoration: BoxDecoration(
                                                color: hasMyReaction
                                                    ? const Color(0xFF2563EB).withValues(alpha: 0.15)
                                                    : (isDark ? const Color(0xFF334155) : Colors.grey.shade200),
                                                borderRadius: BorderRadius.circular(12),
                                                border: Border.all(
                                                  color: hasMyReaction
                                                      ? const Color(0xFF2563EB)
                                                      : Colors.transparent,
                                                  width: 1,
                                                ),
                                              ),
                                              child: Row(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  Text(emoji, style: const TextStyle(fontSize: 12)),
                                                  const SizedBox(width: 3),
                                                  Text(
                                                    '${users.length}',
                                                    style: TextStyle(
                                                      fontSize: 11,
                                                      fontWeight: FontWeight.bold,
                                                      color: hasMyReaction
                                                          ? const Color(0xFF2563EB)
                                                          : (isDark ? Colors.white70 : Colors.grey.shade800),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            );
                                          }).toList(),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        );
                      },
                    );
                  },
                );
              },
            ),
          ),

          // Bottom Floating Modern Input Bar
          Container(
            padding: const EdgeInsets.fromLTRB(10, 6, 10, 10),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF1E293B) : Colors.white,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.05),
                  blurRadius: 10,
                  offset: const Offset(0, -2),
                ),
              ],
            ),
            child: SafeArea(
              child: Row(
                children: [
                  IconButton(
                    tooltip: 'Attachments',
                    icon: Container(
                      padding: const EdgeInsets.all(7),
                      decoration: BoxDecoration(
                        color: isDark ? Colors.white10 : Colors.grey.shade100,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(Icons.add_rounded, size: 20, color: isDark ? Colors.white : Colors.black87),
                    ),
                    onPressed: _sending ? null : _showAttachmentOptions,
                  ),
                  IconButton(
                    tooltip: 'Send Photo',
                    icon: Container(
                      padding: const EdgeInsets.all(7),
                      decoration: BoxDecoration(
                        color: isDark ? Colors.white10 : Colors.grey.shade100,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(Icons.image_outlined, size: 20, color: isDark ? Colors.white : Colors.black87),
                    ),
                    onPressed: _sending ? null : _pickAndSendImage,
                  ),
                  IconButton(
                    tooltip: _isRecording ? 'Stop Recording' : 'Voice Note',
                    icon: Container(
                      padding: const EdgeInsets.all(7),
                      decoration: BoxDecoration(
                        color: _isRecording
                            ? const Color(0xFFEF4444)
                            : (isDark ? Colors.white10 : Colors.grey.shade100),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        _isRecording ? Icons.stop_rounded : Icons.mic_none_rounded,
                        size: 20,
                        color: _isRecording
                            ? Colors.white
                            : (isDark ? Colors.white : Colors.black87),
                      ),
                    ),
                    onPressed: _sending ? null : _toggleRecord,
                  ),
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      decoration: BoxDecoration(
                        color: isDark ? const Color(0xFF0F172A) : const Color(0xFFF1F5F9),
                        borderRadius: BorderRadius.circular(24),
                      ),
                      child: TextField(
                        controller: _controller,
                        minLines: 1,
                        maxLines: 4,
                        enabled: !_sending,
                        style: TextStyle(
                          fontSize: 14,
                          color: isDark ? Colors.white : Colors.black87,
                        ),
                        decoration: InputDecoration(
                          hintText: _isRecording ? 'Recording voice note...' : 'Type a message...',
                          hintStyle: TextStyle(
                            fontSize: 14,
                            color: _isRecording
                                ? const Color(0xFFEF4444)
                                : (isDark ? Colors.white38 : Colors.grey.shade500),
                          ),
                          border: InputBorder.none,
                          contentPadding: const EdgeInsets.symmetric(vertical: 10),
                        ),
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
                  ),
                  const SizedBox(width: 6),
                  GestureDetector(
                    onTap: (_sending || _controller.text.trim().isEmpty)
                        ? null
                        : () => _sendMessage(text: _controller.text.trim()),
                    child: Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        gradient: (_controller.text.trim().isNotEmpty && !_sending)
                            ? const LinearGradient(
                                colors: [Color(0xFF2563EB), Color(0xFF3B82F6)],
                              )
                            : null,
                        color: (_controller.text.trim().isEmpty || _sending)
                            ? (isDark ? Colors.white10 : Colors.grey.shade300)
                            : null,
                        shape: BoxShape.circle,
                      ),
                      child: _sending
                          ? const Padding(
                              padding: EdgeInsets.all(11.0),
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                            )
                          : Icon(
                              Icons.send_rounded,
                              size: 19,
                              color: (_controller.text.trim().isNotEmpty && !_sending)
                                  ? Colors.white
                                  : (isDark ? Colors.white38 : Colors.grey.shade500),
                            ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDateSeparator(int timestamp, bool isDark) {
    final date = DateTime.fromMillisecondsSinceEpoch(timestamp);
    final now = DateTime.now();
    String text;
    if (date.year == now.year && date.month == now.month && date.day == now.day) {
      text = 'Today';
    } else if (date.year == now.year && date.month == now.month && date.day == now.day - 1) {
      text = 'Yesterday';
    } else {
      text = '${date.month}/${date.day}/${date.year}';
    }

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 10),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E293B) : Colors.grey.shade200,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: isDark ? Colors.white54 : Colors.grey.shade600,
        ),
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
    final FirebaseFirestore firestore = FirebaseFirestore.instance;
    return Scaffold(
      appBar: AppBar(title: const Text('Conversation media')),
      body: StreamBuilder<QuerySnapshot>(
        stream: firestore
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
  final bool isGroupCall;
  final VoidCallback onFinished;
  const IncomingCallDialog({super.key, required this.conversationId, required this.fromUserId, required this.channelName, required this.video, this.isGroupCall = false, required this.onFinished});
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
              backgroundColor: widget.isGroupCall ? Colors.teal : Colors.blueGrey,
              backgroundImage: (avatarUrl is String && avatarUrl.isNotEmpty) ? NetworkImage(avatarUrl) : null,
              child: (avatarUrl is String && avatarUrl.isNotEmpty) ? null : (widget.isGroupCall ? const Icon(Icons.group, size: 48, color: Colors.white) : Text(name[0].toUpperCase(), style: const TextStyle(fontSize: 32, color: Colors.white))),
            ),
            const SizedBox(height: 16),
            Text('${widget.video ? 'Video' : 'Audio'} call ${widget.isGroupCall ? 'in group' : 'from'}', style: const TextStyle(color: Colors.white70)),
            const SizedBox(height: 8),
            Text(name, style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w600)),
            if (widget.isGroupCall)
              const Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text('Group Call', style: TextStyle(color: Colors.tealAccent, fontSize: 14)),
              ),
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
                  onPressed: () async {
                    // Find and update the call_session status to 'rejected'
                    try {
                      final callSessions = await _firestore
                          .collection('call_sessions')
                          .where('channel', isEqualTo: widget.channelName)
                          .where('status', isEqualTo: 'ringing')
                          .limit(1)
                          .get();
                      
                      if (callSessions.docs.isNotEmpty) {
                        final sessionDoc = callSessions.docs.first;
                        await sessionDoc.reference.update({
                          'status': 'rejected',
                          'ended_at': DateTime.now().millisecondsSinceEpoch,
                        });
                        debugPrint('Updated call session ${sessionDoc.id} to rejected');
                      }
                    } catch (e) {
                      debugPrint('Error updating call session status: $e');
                    }

                    if (!mounted) return;
                    Navigator.pop(context); 
                    widget.onFinished();
                  },
                  icon: const Icon(Icons.call_end),
                  label: const Text('Decline'),
                ),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
                  onPressed: () async {
                    // Find and update the call_session status to 'accepted'
                    String? sessionId;
                    try {
                      final callSessions = await _firestore
                          .collection('call_sessions')
                          .where('channel', isEqualTo: widget.channelName)
                          .where('status', isEqualTo: 'ringing')
                          .limit(1)
                          .get();
                      
                      if (callSessions.docs.isNotEmpty) {
                        final sessionDoc = callSessions.docs.first;
                        sessionId = sessionDoc.id;
                        await sessionDoc.reference.update({
                          'status': 'accepted',
                          'accepted_at': DateTime.now().millisecondsSinceEpoch,
                        });
                        debugPrint('Updated call session ${sessionDoc.id} to accepted');
                      }
                    } catch (e) {
                      debugPrint('Error updating call session status: $e');
                    }

                    if (!mounted) return;
                    Navigator.pop(context); 
                    widget.onFinished();
                    
                    Navigator.push(context, CallPage.route(
                      channelName: widget.channelName, 
                      video: widget.video, 
                      conversationId: widget.conversationId, 
                      remoteUserId: widget.fromUserId,
                      callSessionId: sessionId,
                      isGroupCall: widget.isGroupCall,
                    ));
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