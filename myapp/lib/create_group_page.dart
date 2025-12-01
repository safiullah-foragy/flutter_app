import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:image_picker/image_picker.dart';
import 'supabase.dart' as sb;

/// Page for creating a new group chat.
/// The user who creates the group automatically becomes the admin.
class CreateGroupPage extends StatefulWidget {
  const CreateGroupPage({super.key});

  @override
  State<CreateGroupPage> createState() => _CreateGroupPageState();
}

class _CreateGroupPageState extends State<CreateGroupPage> {
  final firebase_auth.FirebaseAuth _auth = firebase_auth.FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _descriptionController = TextEditingController();
  final TextEditingController _searchController = TextEditingController();
  final ImagePicker _imagePicker = ImagePicker();
  
  final Set<String> _selectedUsers = {}; // User IDs selected for the group
  List<QueryDocumentSnapshot> _searchResults = [];
  bool _isSearching = false;
  bool _isCreating = false;
  String? _groupPhotoUrl;

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
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
      setState(() => _searchResults = snapshot.docs);
    } catch (e) {
      debugPrint('User search error: $e');
    } finally {
      setState(() => _isSearching = false);
    }
  }

  Future<void> _pickGroupPhoto() async {
    try {
      final XFile? pickedFile = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 800,
        maxHeight: 800,
        imageQuality: 85,
      );

      if (pickedFile == null) return;

      setState(() => _isCreating = true);

      // Upload to Supabase
      final bytes = await pickedFile.readAsBytes();
      final fileName = 'group_photos/${DateTime.now().millisecondsSinceEpoch}.jpg';
      final photoUrl = await sb.uploadImageData(
        bytes, 
        fileName: fileName, 
        folder: 'message-images',
      );

      setState(() {
        _groupPhotoUrl = photoUrl;
        _isCreating = false;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Group photo selected'))
      );
    } catch (e) {
      debugPrint('Error picking group photo: $e');
      if (mounted) {
        setState(() => _isCreating = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to upload photo: ${e.toString()}'))
        );
      }
    }
  }

  Future<void> _createGroup() async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please sign in to create a group'))
      );
      return;
    }

    final groupName = _nameController.text.trim();
    if (groupName.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a group name'))
      );
      return;
    }

    if (_selectedUsers.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please add at least one member'))
      );
      return;
    }

    setState(() => _isCreating = true);

    try {
      // Create the group conversation document
      final participants = [uid, ..._selectedUsers]; // Admin + selected users
      final now = DateTime.now().millisecondsSinceEpoch;
      
      final groupData = {
        'is_group': true,
        'group_name': groupName,
        'group_description': _descriptionController.text.trim(),
        'group_admin': uid, // Creator is the admin
        'participants': participants,
        'last_message': 'Group created',
        'last_updated': now,
        'created_at': now,
        // Initialize last_read for all participants
        'last_read': {for (var userId in participants) userId: now},
        'archived': {for (var userId in participants) userId: false},
      };

      // Add group photo if selected
      if (_groupPhotoUrl != null && _groupPhotoUrl!.isNotEmpty) {
        groupData['group_photo'] = _groupPhotoUrl!;
      }

      final groupDoc = await _firestore.collection('conversations').add(groupData);

      // Send a system message about group creation
      await _firestore
          .collection('conversations')
          .doc(groupDoc.id)
          .collection('messages')
          .add({
        'sender_id': uid,
        'text': 'created the group',
        'timestamp': now,
        'file_url': '',
        'file_type': 'system',
        'reactions': <String, dynamic>{},
        'edited': false,
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Group created successfully'))
        );
        Navigator.pop(context, groupDoc.id); // Return group ID to navigate to it
      }
    } catch (e) {
      debugPrint('Error creating group: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to create group: ${e.toString()}'))
        );
      }
    } finally {
      if (mounted) setState(() => _isCreating = false);
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
    
    return Scaffold(
      appBar: AppBar(
        title: const Text('Create Group'),
        actions: [
          if (_isCreating)
            const Padding(
              padding: EdgeInsets.all(16.0),
              child: CircularProgressIndicator(),
            )
          else
            TextButton(
              onPressed: _createGroup,
              child: const Text('CREATE', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
        ],
      ),
      body: Column(
        children: [
          // Group photo selection
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              children: [
                GestureDetector(
                  onTap: _pickGroupPhoto,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      CircleAvatar(
                        radius: 50,
                        backgroundImage: _groupPhotoUrl != null && _groupPhotoUrl!.isNotEmpty
                            ? CachedNetworkImageProvider(_groupPhotoUrl!)
                            : null,
                        backgroundColor: Colors.teal.shade100,
                        child: _groupPhotoUrl == null || _groupPhotoUrl!.isEmpty
                            ? const Icon(Icons.group, size: 50, color: Colors.teal)
                            : null,
                      ),
                      Positioned(
                        bottom: 0,
                        right: 0,
                        child: Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: Colors.teal,
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.2),
                                blurRadius: 4,
                              ),
                            ],
                          ),
                          child: const Icon(Icons.camera_alt, size: 18, color: Colors.white),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Tap to set group photo',
                  style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                ),
              ],
            ),
          ),
          const Divider(),
          
          // Group name and description
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              children: [
                TextField(
                  controller: _nameController,
                  decoration: const InputDecoration(
                    labelText: 'Group Name',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.group),
                  ),
                  maxLength: 50,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _descriptionController,
                  decoration: const InputDecoration(
                    labelText: 'Description (optional)',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.description),
                  ),
                  maxLength: 200,
                  maxLines: 2,
                ),
              ],
            ),
          ),
          const Divider(),
          
          // Selected members count
          if (_selectedUsers.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
              child: Row(
                children: [
                  Text(
                    '${_selectedUsers.length} member${_selectedUsers.length == 1 ? '' : 's'} selected',
                    style: const TextStyle(fontWeight: FontWeight.w500),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: () => setState(() => _selectedUsers.clear()),
                    child: const Text('Clear all'),
                  ),
                ],
              ),
            ),
          
          // Search users
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: TextField(
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
          ),
          
          // Search results
          if (_isSearching)
            const Padding(
              padding: EdgeInsets.all(16.0),
              child: CircularProgressIndicator(),
            )
          else if (_searchResults.isEmpty && _searchController.text.isNotEmpty)
            const Padding(
              padding: EdgeInsets.all(16.0),
              child: Text('No users found'),
            )
          else if (_searchResults.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16.0),
              child: Text('Search for users by name to add to the group'),
            )
          else
            Expanded(
              child: ListView.builder(
                itemCount: _searchResults.length,
                itemBuilder: (context, i) {
                  final userData = _searchResults[i].data() as Map<String, dynamic>;
                  final userId = _searchResults[i].id;
                  final userName = userData['name'] ?? userId;
                  final userEmail = userData['email'] ?? '';
                  final avatarUrl = userData['profile_image'];
                  
                  // Don't show current user
                  if (userId == uid) return const SizedBox.shrink();
                  
                  final isSelected = _selectedUsers.contains(userId);
                  
                  return ListTile(
                    leading: _buildUserAvatar(avatarUrl, userId),
                    title: Text(userName),
                    subtitle: Text(userEmail),
                    trailing: Checkbox(
                      value: isSelected,
                      onChanged: (checked) {
                        setState(() {
                          if (checked == true) {
                            _selectedUsers.add(userId);
                          } else {
                            _selectedUsers.remove(userId);
                          }
                        });
                      },
                    ),
                    onTap: () {
                      setState(() {
                        if (isSelected) {
                          _selectedUsers.remove(userId);
                        } else {
                          _selectedUsers.add(userId);
                        }
                      });
                    },
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}
