import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:image_picker/image_picker.dart';
import 'supabase.dart' as sb;

/// Bottom sheet displaying group information and management options
class GroupInfoSheet extends StatefulWidget {
  final String conversationId;
  final Map<String, dynamic>? groupData;
  final List<String> participants;
  final String? adminId;
  final VoidCallback onMembersUpdated;

  const GroupInfoSheet({
    super.key,
    required this.conversationId,
    required this.groupData,
    required this.participants,
    required this.adminId,
    required this.onMembersUpdated,
  });

  @override
  State<GroupInfoSheet> createState() => _GroupInfoSheetState();
}

class _GroupInfoSheetState extends State<GroupInfoSheet> {
  final firebase_auth.FirebaseAuth _auth = firebase_auth.FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final TextEditingController _searchController = TextEditingController();
  final ImagePicker _imagePicker = ImagePicker();
  
  List<QueryDocumentSnapshot> _searchResults = [];
  bool _isSearching = false;
  bool _isUploadingPhoto = false;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _searchUsers() async {
    final query = _searchController.text.trim();
    if (query.isEmpty) {
      setState(() => _searchResults = []);
      return;
    }
    
    setState(() => _isSearching = true);
    try {
      final snapshot = await _firestore
          .collection('users')
          .where('name', isGreaterThanOrEqualTo: query)
          .where('name', isLessThanOrEqualTo: '$query\uf8ff')
          .limit(50)
          .get();
      
      // Filter out users already in the group
      final results = snapshot.docs.where((doc) => !widget.participants.contains(doc.id)).toList();
      setState(() => _searchResults = results);
    } catch (e) {
      debugPrint('User search error: $e');
    } finally {
      setState(() => _isSearching = false);
    }
  }

  Future<void> _addMember(String userId, String userName) async {
    final uid = _auth.currentUser?.uid;
    if (uid == null || uid != widget.adminId) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Only the group admin can add members'))
      );
      return;
    }

    try {
      // Add user to participants
      await _firestore.collection('conversations').doc(widget.conversationId).update({
        'participants': FieldValue.arrayUnion([userId]),
        'last_read.$userId': DateTime.now().millisecondsSinceEpoch,
        'archived.$userId': false,
      });

      // Send system message
      await _firestore
          .collection('conversations')
          .doc(widget.conversationId)
          .collection('messages')
          .add({
        'sender_id': uid,
        'text': 'added $userName to the group',
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'file_url': '',
        'file_type': 'system',
        'reactions': <String, dynamic>{},
        'edited': false,
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$userName added to group'))
        );
        _searchController.clear();
        setState(() => _searchResults = []);
        widget.onMembersUpdated();
      }
    } catch (e) {
      debugPrint('Error adding member: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to add member: ${e.toString()}'))
        );
      }
    }
  }

  Future<void> _removeMember(String userId, String userName) async {
    final uid = _auth.currentUser?.uid;
    if (uid == null || uid != widget.adminId) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Only the group admin can remove members'))
      );
      return;
    }

    if (userId == widget.adminId) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Cannot remove the group admin'))
      );
      return;
    }

    final confirm = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Remove Member'),
        content: Text('Remove $userName from this group?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Remove', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    try {
      // Remove user from participants
      await _firestore.collection('conversations').doc(widget.conversationId).update({
        'participants': FieldValue.arrayRemove([userId]),
      });

      // Send system message
      await _firestore
          .collection('conversations')
          .doc(widget.conversationId)
          .collection('messages')
          .add({
        'sender_id': uid,
        'text': 'removed $userName from the group',
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'file_url': '',
        'file_type': 'system',
        'reactions': <String, dynamic>{},
        'edited': false,
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$userName removed from group'))
        );
        widget.onMembersUpdated();
      }
    } catch (e) {
      debugPrint('Error removing member: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to remove member: ${e.toString()}'))
        );
      }
    }
  }

  Future<void> _leaveGroup() async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return;

    if (uid == widget.adminId) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Admin cannot leave the group. Transfer admin first or delete the group.'))
      );
      return;
    }

    final confirm = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Leave Group'),
        content: const Text('Are you sure you want to leave this group?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Leave', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    try {
      // Remove self from participants
      await _firestore.collection('conversations').doc(widget.conversationId).update({
        'participants': FieldValue.arrayRemove([uid]),
      });

      // Send system message
      final currentUserDoc = await _firestore.collection('users').doc(uid).get();
      final currentUserName = currentUserDoc.data()?['name'] ?? 'User';
      
      await _firestore
          .collection('conversations')
          .doc(widget.conversationId)
          .collection('messages')
          .add({
        'sender_id': uid,
        'text': '$currentUserName left the group',
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'file_url': '',
        'file_type': 'system',
        'reactions': <String, dynamic>{},
        'edited': false,
      });

      if (mounted) {
        Navigator.pop(context); // Close bottom sheet
        Navigator.pop(context); // Go back to messages list
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Left the group'))
        );
      }
    } catch (e) {
      debugPrint('Error leaving group: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to leave group: ${e.toString()}'))
        );
      }
    }
  }

  Future<void> _updateGroupPhoto() async {
    final uid = _auth.currentUser?.uid;
    if (uid == null || uid != widget.adminId) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Only the group admin can change the group photo'))
      );
      return;
    }

    try {
      final XFile? pickedFile = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 800,
        maxHeight: 800,
        imageQuality: 85,
      );

      if (pickedFile == null) return;

      setState(() => _isUploadingPhoto = true);

      // Upload to Supabase
      final bytes = await pickedFile.readAsBytes();
      final fileName = 'group_photos/${widget.conversationId}_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final photoUrl = await sb.uploadImageData(
        bytes, 
        fileName: fileName, 
        folder: 'message-images',
      );

      // Update Firestore
      await _firestore.collection('conversations').doc(widget.conversationId).update({
        'group_photo': photoUrl,
      });

      // Send system message
      await _firestore
          .collection('conversations')
          .doc(widget.conversationId)
          .collection('messages')
          .add({
        'sender_id': uid,
        'text': 'updated the group photo',
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'file_url': '',
        'file_type': 'system',
        'reactions': <String, dynamic>{},
        'edited': false,
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Group photo updated'))
        );
        widget.onMembersUpdated();
      }
    } catch (e) {
      debugPrint('Error updating group photo: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to update photo: ${e.toString()}'))
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isUploadingPhoto = false);
      }
    }
  }

  Widget _buildUserAvatar(String? avatarUrl, String userId) {
    if (avatarUrl != null && avatarUrl.isNotEmpty) {
      return CircleAvatar(
        backgroundImage: CachedNetworkImageProvider(avatarUrl),
        radius: 20,
      );
    } else {
      final colors = [
        Colors.blue, Colors.red, Colors.green, Colors.orange, 
        Colors.purple, Colors.teal, Colors.pink, Colors.indigo
      ];
      final colorIndex = userId.hashCode % colors.length;
      final firstChar = userId.isNotEmpty ? userId[0].toUpperCase() : '?';
      
      return CircleAvatar(
        backgroundColor: colors[colorIndex],
        radius: 20,
        child: Text(
          firstChar,
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final uid = _auth.currentUser?.uid;
    final isAdmin = uid == widget.adminId;
    final groupName = widget.groupData?['group_name'] ?? 'Group';
    final groupDescription = widget.groupData?['group_description'] ?? '';
    final groupPhotoUrl = widget.groupData?['group_photo'];

    return DraggableScrollableSheet(
      initialChildSize: 0.9,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) {
        return Column(
          children: [
            // Header
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.teal,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
              ),
              child: Column(
                children: [
                  Stack(
                    alignment: Alignment.center,
                    children: [
                      GestureDetector(
                        onTap: isAdmin ? _updateGroupPhoto : null,
                        child: CircleAvatar(
                          backgroundColor: Colors.white,
                          radius: 40,
                          backgroundImage: groupPhotoUrl != null && groupPhotoUrl.isNotEmpty
                              ? CachedNetworkImageProvider(groupPhotoUrl)
                              : null,
                          child: groupPhotoUrl == null || groupPhotoUrl.isEmpty
                              ? const Icon(Icons.group, size: 40, color: Colors.teal)
                              : null,
                        ),
                      ),
                      if (isAdmin && !_isUploadingPhoto)
                        Positioned(
                          bottom: 0,
                          right: 0,
                          child: GestureDetector(
                            onTap: _updateGroupPhoto,
                            child: Container(
                              padding: const EdgeInsets.all(6),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                shape: BoxShape.circle,
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withOpacity(0.2),
                                    blurRadius: 4,
                                  ),
                                ],
                              ),
                              child: const Icon(Icons.camera_alt, size: 16, color: Colors.teal),
                            ),
                          ),
                        ),
                      if (_isUploadingPhoto)
                        const CircularProgressIndicator(color: Colors.white),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    groupName,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  if (groupDescription.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      groupDescription,
                      style: const TextStyle(color: Colors.white70),
                      textAlign: TextAlign.center,
                    ),
                  ],
                  const SizedBox(height: 8),
                  Text(
                    '${widget.participants.length} members',
                    style: const TextStyle(color: Colors.white70),
                  ),
                ],
              ),
            ),
            
            // Members list
            Expanded(
              child: ListView(
                controller: scrollController,
                padding: const EdgeInsets.all(16),
                children: [
                  const Text(
                    'Members',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  
                  // Display current members
                  ...widget.participants.map((participantId) {
                    return StreamBuilder<DocumentSnapshot>(
                      stream: _firestore.collection('users').doc(participantId).snapshots(),
                      builder: (context, snapshot) {
                        String userName = participantId;
                        String? avatarUrl;
                        
                        if (snapshot.hasData && snapshot.data!.exists) {
                          final userData = snapshot.data!.data() as Map<String, dynamic>?;
                          userName = userData?['name'] ?? participantId;
                          avatarUrl = userData?['profile_image'];
                        }
                        
                        final isThisAdmin = participantId == widget.adminId;
                        
                        return ListTile(
                          leading: _buildUserAvatar(avatarUrl, participantId),
                          title: Text(userName),
                          subtitle: isThisAdmin ? const Text('Admin', style: TextStyle(color: Colors.teal)) : null,
                          trailing: isAdmin && !isThisAdmin
                              ? IconButton(
                                  icon: const Icon(Icons.remove_circle, color: Colors.red),
                                  onPressed: () => _removeMember(participantId, userName),
                                  tooltip: 'Remove member',
                                )
                              : isThisAdmin
                                  ? const Icon(Icons.admin_panel_settings, color: Colors.teal)
                                  : null,
                        );
                      },
                    );
                  }).toList(),
                  
                  // Add member section (admin only)
                  if (isAdmin) ...[
                    const Divider(height: 32),
                    const Text(
                      'Add Members',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _searchController,
                      decoration: InputDecoration(
                        hintText: 'Search users to add...',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        prefixIcon: const Icon(Icons.search),
                        suffixIcon: _searchController.text.isNotEmpty
                            ? IconButton(
                                icon: const Icon(Icons.clear),
                                onPressed: () {
                                  _searchController.clear();
                                  setState(() => _searchResults = []);
                                },
                              )
                            : null,
                      ),
                      onChanged: (_) => _searchUsers(),
                    ),
                    const SizedBox(height: 8),
                    
                    if (_isSearching)
                      const Center(child: CircularProgressIndicator())
                    else if (_searchResults.isEmpty && _searchController.text.isNotEmpty)
                      const Padding(
                        padding: EdgeInsets.all(16.0),
                        child: Text('No users found', textAlign: TextAlign.center),
                      )
                    else if (_searchResults.isNotEmpty)
                      ..._searchResults.map((doc) {
                        final userData = doc.data() as Map<String, dynamic>;
                        final userId = doc.id;
                        final userName = userData['name'] ?? userId;
                        final avatarUrl = userData['profile_image'];
                        
                        return ListTile(
                          leading: _buildUserAvatar(avatarUrl, userId),
                          title: Text(userName),
                          trailing: IconButton(
                            icon: const Icon(Icons.add_circle, color: Colors.green),
                            onPressed: () => _addMember(userId, userName),
                          ),
                        );
                      }).toList(),
                  ],
                  
                  const Divider(height: 32),
                  
                  // Leave group button (non-admin users)
                  if (!isAdmin)
                    ListTile(
                      leading: const Icon(Icons.exit_to_app, color: Colors.red),
                      title: const Text('Leave Group', style: TextStyle(color: Colors.red)),
                      onTap: _leaveGroup,
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}
