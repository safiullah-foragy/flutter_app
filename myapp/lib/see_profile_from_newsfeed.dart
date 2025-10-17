import 'dart:async';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:fluttertoast/fluttertoast.dart';

class SeeProfileFromNewsfeed extends StatefulWidget {
  final String userId;

  const SeeProfileFromNewsfeed({super.key, required this.userId});

  @override
  State<SeeProfileFromNewsfeed> createState() => _SeeProfileFromNewsfeedState();
}

class _SeeProfileFromNewsfeedState extends State<SeeProfileFromNewsfeed> {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  Map<String, dynamic>? userData;
  bool isLoading = true;
  int postsCount = 0;
  int followersCount = 0;
  int followingCount = 0;
  StreamSubscription<DocumentSnapshot>? _userSub;
  StreamSubscription<QuerySnapshot>? _postsSub;

  @override
  void initState() {
    super.initState();
    _fetchUserData();
    _setupUserListener();
    _setupPostsCountListener();
  }

  @override
  void dispose() {
    _userSub?.cancel();
    _postsSub?.cancel();
    super.dispose();
  }

  Future<void> _fetchUserData() async {
    try {
      DocumentSnapshot userDoc = await _firestore.collection('users').doc(widget.userId).get();
      if (userDoc.exists) {
        final data = userDoc.data() as Map<String, dynamic>?;
        
        // Fetch posts count
        int posts = 0;
        int followers = 0;
        int following = 0;
        
        try {
          final postsSnapshot = await _firestore
              .collection('posts')
              .where('user_id', isEqualTo: widget.userId)
              .get();
          posts = postsSnapshot.docs.length;
        } catch (e) {
          print('Error fetching posts: $e');
        }

        // You can add followers/following counts here if you have those collections
        // For now, using placeholder values
        followers = data?['followers_count'] ?? 0;
        following = data?['following_count'] ?? 0;

        setState(() {
          userData = data;
          postsCount = posts;
          followersCount = followers;
          followingCount = following;
          isLoading = false;
        });
      } else {
        Fluttertoast.showToast(msg: 'User not found');
        setState(() {
          isLoading = false;
        });
      }
    } catch (e) {
      print('Error fetching user data: $e');
      Fluttertoast.showToast(msg: 'Failed to load user data');
      setState(() {
        isLoading = false;
      });
    }
  }

  void _setupUserListener() {
    _userSub?.cancel();
    _userSub = _firestore.collection('users').doc(widget.userId).snapshots().listen((doc) {
      if (!doc.exists) return;
  final data = doc.data();
      if (data == null) return;
      setState(() {
        userData = data;
        followersCount = data['followers_count'] ?? followersCount;
        followingCount = data['following_count'] ?? followingCount;
        isLoading = false;
      });
    }, onError: (e) {
      print('User realtime listener error: $e');
    });
  }

  void _setupPostsCountListener() {
    _postsSub?.cancel();
    _postsSub = _firestore
        .collection('posts')
        .where('user_id', isEqualTo: widget.userId)
        .snapshots()
        .listen((snap) {
      setState(() {
        postsCount = snap.docs.length;
      });
    }, onError: (e) {
      print('Posts count listener error: $e');
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Profile',
          style: TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 18,
          ),
        ),
        centerTitle: true,
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        elevation: 1,
        toolbarHeight: 56,
      ),
      body: isLoading
          ? const Center(
              child: CircularProgressIndicator(
                valueColor: AlwaysStoppedAnimation<Color>(Colors.blue),
              ),
            )
          : userData == null
              ? _buildErrorState()
              : _buildProfileContent(),
    );
  }

  Widget _buildErrorState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.error_outline,
            size: 64,
            color: Colors.grey[400],
          ),
          const SizedBox(height: 16),
          const Text(
            'User not found',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w500,
              color: Colors.grey,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'User ID: ${widget.userId}',
            style: const TextStyle(
              fontSize: 14,
              color: Colors.grey,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildProfileContent() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(0),
      child: Column(
        children: [
          // Header Section
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Colors.blue.shade50,
                  Colors.purple.shade50,
                ],
              ),
            ),
            child: Column(
              children: [
                // Profile Avatar
                Stack(
                  alignment: Alignment.bottomRight,
                  children: [
                    Container(
                      width: 120,
                      height: 120,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: Colors.white,
                          width: 4,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.1),
                            blurRadius: 8,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: CircleAvatar(
                        radius: 56,
                        backgroundColor: Colors.grey[300],
                        backgroundImage: (userData!['profile_image'] != null && 
                            (userData!['profile_image'] as String).isNotEmpty)
                            ? CachedNetworkImageProvider(userData!['profile_image'])
                            : null,
                        child: (userData!['profile_image'] == null || 
                            (userData!['profile_image'] as String).isEmpty)
                            ? Text(
                                _initialsFromName(userData!['name'] ?? ''),
                                style: const TextStyle(
                                  fontSize: 32,
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                ),
                              )
                            : null,
                      ),
                    ),
                    Container(
                      width: 24,
                      height: 24,
                      decoration: const BoxDecoration(
                        color: Colors.green,
                        shape: BoxShape.circle,
                        border: Border.fromBorderSide(
                          BorderSide(color: Colors.white, width: 2),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),

                // Name and Username
                Text(
                  userData!['name'] ?? 'Unknown User',
                  style: const TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: Colors.black87,
                  ),
                ),
                const SizedBox(height: 4),
                if (userData!['username'] != null)
                  Text(
                    '@${userData!['username']}',
                    style: TextStyle(
                      fontSize: 16,
                      color: Colors.grey[600],
                    ),
                  ),
                const SizedBox(height: 8),
                if (userData!['email'] != null)
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.email, size: 16, color: Colors.grey[600]),
                      const SizedBox(width: 4),
                      Text(
                        userData!['email'],
                        style: TextStyle(
                          fontSize: 14,
                          color: Colors.grey[600],
                        ),
                      ),
                    ],
                  ),

                const SizedBox(height: 16),

                // Stats Row
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.05),
                        blurRadius: 8,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      _buildStatItem(postsCount, 'Posts'),
                      _buildStatItem(followersCount, 'Followers'),
                      _buildStatItem(followingCount, 'Following'),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // Bio Section
          if ((userData!['bio'] ?? userData!['about']) != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'About',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Colors.black87,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    (userData!['bio'] ?? userData!['about']) ?? '',
                    style: TextStyle(
                      fontSize: 16,
                      color: Colors.grey[700],
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),

          // Details Section
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.all(16.0),
                  child: Text(
                    'Details',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Colors.black87,
                    ),
                  ),
                ),
                ..._buildDetailsCards(userData!),
              ],
            ),
          ),

          const SizedBox(height: 20),
        ],
      ),
    );
  }

  Widget _buildStatItem(int count, String label) {
    return Column(
      children: [
        Text(
          count.toString(),
          style: const TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: Colors.black87,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: 14,
            color: Colors.grey[600],
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }

  List<Widget> _buildDetailsCards(Map<String, dynamic> data) {
    final widgets = <Widget>[];
    final preferred = [
      'location', 
      'phone', 
      'joined_at', 
      'created_at', 
      'website', 
      'company',
      'profession',
      'education'
    ];

    for (var key in preferred) {
      if (data.containsKey(key) && data[key] != null && data[key].toString().isNotEmpty) {
        widgets.add(_buildDetailCard(key, _formatValue(data[key])));
      }
    }

    // Show other keys
    for (var entry in data.entries) {
      final key = entry.key;
      if (key == 'profile_image' || key == 'name' || key == 'email' || 
          key == 'bio' || key == 'about' || key == 'username' || 
          preferred.contains(key)) continue;
      
      final value = entry.value;
      if (value.toString().isNotEmpty) {
        widgets.add(_buildDetailCard(key, _formatValue(value)));
      }
    }

    return widgets;
  }

  Widget _buildDetailCard(String key, String value) {
    IconData icon = _getIconForKey(key);
    
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      elevation: 1,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
      child: ListTile(
        leading: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: Colors.blue.shade50,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(
            icon,
            color: Colors.blue.shade700,
            size: 20,
          ),
        ),
        title: Text(
          _humanKey(key),
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w500,
          ),
        ),
        subtitle: Text(
          value,
          style: TextStyle(
            fontSize: 14,
            color: Colors.grey[700],
          ),
        ),
        trailing: Icon(
          Icons.chevron_right,
          color: Colors.grey[400],
        ),
        onTap: () {
          // You can add specific actions for each detail type
          _handleDetailTap(key, value);
        },
      ),
    );
  }

  IconData _getIconForKey(String key) {
    switch (key) {
      case 'location':
        return Icons.location_on;
      case 'phone':
        return Icons.phone;
      case 'joined_at':
      case 'created_at':
        return Icons.calendar_today;
      case 'website':
        return Icons.language;
      case 'company':
      case 'profession':
        return Icons.work;
      case 'education':
        return Icons.school;
      default:
        return Icons.info;
    }
  }

  void _handleDetailTap(String key, String value) {
    // Handle taps on detail items
    switch (key) {
      case 'phone':
        // You can implement phone call functionality
        break;
      case 'website':
        // You can implement website opening functionality
        break;
      case 'location':
        // You can implement map opening functionality
        break;
    }
  }

  String _initialsFromName(String name) {
    if (name.trim().isEmpty) return '?';
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.length == 1) return parts[0][0].toUpperCase();
    return (parts[0][0] + parts[parts.length - 1][0]).toUpperCase();
  }

  String _humanKey(String key) {
    return key.replaceAll('_', ' ').splitMapJoin(
      RegExp(r'\b'),
      onMatch: (m) => m[0]!.toUpperCase(),
      onNonMatch: (n) => n,
    ).trim();
  }

  String _formatValue(dynamic v) {
    if (v == null) return '';
    if (v is int) {
      // Check if it's a timestamp (reasonable timestamp range)
      if (v > 1000000000 && v < 2000000000000) {
        try {
          final dt = DateTime.fromMillisecondsSinceEpoch(v);
          return '${_formatDate(dt)}';
        } catch (_) {
          return v.toString();
        }
      }
      return v.toString();
    }
    if (v is Timestamp) {
      return '${_formatDate(v.toDate())}';
    }
    return v.toString();
  }

  String _formatDate(DateTime date) {
    final now = DateTime.now();
    final difference = now.difference(date);
    
    if (difference.inDays == 0) {
      return 'Today';
    } else if (difference.inDays == 1) {
      return 'Yesterday';
    } else if (difference.inDays < 7) {
      return '${difference.inDays} days ago';
    } else if (difference.inDays < 30) {
      final weeks = (difference.inDays / 7).floor();
      return '$weeks ${weeks == 1 ? 'week' : 'weeks'} ago';
    } else {
      return '${date.day}/${date.month}/${date.year}';
    }
  }
}