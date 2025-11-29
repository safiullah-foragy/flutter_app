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
          ? _buildLoadingSkeleton()
          : userData == null
              ? _buildErrorState()
              : _buildProfileContent(),
    );
  }

  Widget _buildLoadingSkeleton() {
    return SingleChildScrollView(
      child: Column(
        children: [
          // Header skeleton
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Colors.blue.shade50, Colors.purple.shade50],
              ),
            ),
            child: Column(
              children: [
                Container(
                  width: 120,
                  height: 120,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.grey[300],
                  ),
                ),
                const SizedBox(height: 16),
                Container(
                  width: 150,
                  height: 20,
                  decoration: BoxDecoration(
                    color: Colors.grey[300],
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                const SizedBox(height: 8),
                Container(
                  width: 100,
                  height: 16,
                  decoration: BoxDecoration(
                    color: Colors.grey[300],
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: List.generate(
                      1,
                      (index) => Column(
                        children: [
                          Container(
                            width: 40,
                            height: 20,
                            decoration: BoxDecoration(
                              color: Colors.grey[300],
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Container(
                            width: 60,
                            height: 16,
                            decoration: BoxDecoration(
                              color: Colors.grey[300],
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          // Content skeleton
          Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: List.generate(
                3,
                (index) => Container(
                  margin: const EdgeInsets.only(bottom: 12),
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.grey[200],
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 120,
                        height: 16,
                        decoration: BoxDecoration(
                          color: Colors.grey[300],
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Container(
                        width: double.infinity,
                        height: 14,
                        decoration: BoxDecoration(
                          color: Colors.grey[300],
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
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
    // Calculate online status
    bool isOnline = userData!['is_online'] == true;
    int lastActive = userData!['last_active'] ?? 0;
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
      }
    }
    
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
                // Profile Avatar with online status
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
                    if (isOnline)
                      Container(
                        width: 28,
                        height: 28,
                        decoration: BoxDecoration(
                          color: Colors.green,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 3),
                        ),
                        child: const Icon(
                          Icons.circle,
                          color: Colors.green,
                          size: 16,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 16),

                // Name
                Text(
                  userData!['name'] ?? 'Unknown User',
                  style: const TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: Colors.black87,
                  ),
                ),
                const SizedBox(height: 8),
                
                // Online Status
                if (statusText.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: isOnline ? Colors.green.withOpacity(0.1) : Colors.grey.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: isOnline ? Colors.green : Colors.grey,
                        width: 1,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: isOnline ? Colors.green : Colors.grey,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          statusText,
                          style: TextStyle(
                            fontSize: 14,
                            color: isOnline ? Colors.green.shade700 : Colors.grey.shade700,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),

                const SizedBox(height: 16),

                // Posts Count
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
                  child: Column(
                    children: [
                      Text(
                        postsCount.toString(),
                        style: const TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.bold,
                          color: Colors.black87,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Posts',
                        style: TextStyle(
                          fontSize: 14,
                          color: Colors.grey[600],
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // Personal Details Section
          _buildSectionTitle('Personal Details', Icons.person),
          _buildPersonalDetailsSection(),

          // Professional Profile Section
          if (_hasWorkExperience(userData!)) ...[
            _buildSectionTitle('Professional Profile', Icons.work),
            _buildProfessionalSection(),
          ],

          // Educational Profile Section
          if (_hasEducation(userData!)) ...[
            _buildSectionTitle('Educational Profile', Icons.school),
            _buildEducationalSection(),
          ],

          // Bio Section
          if ((userData!['bio'] ?? userData!['about']) != null &&
              (userData!['bio'] ?? userData!['about']).toString().isNotEmpty) ...[
            _buildSectionTitle('About', Icons.info_outline),
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 20),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.05),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Text(
                (userData!['bio'] ?? userData!['about']) ?? '',
                style: TextStyle(
                  fontSize: 15,
                  color: Colors.grey[700],
                  height: 1.5,
                ),
              ),
            ),
            const SizedBox(height: 16),
          ],

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
          key == 'fcmTokens' || key == 'fcm_token' || 
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

  Widget _buildSectionTitle(String title, IconData icon) {
    return Container(
      margin: const EdgeInsets.only(left: 20, right: 20, top: 16, bottom: 12),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: Colors.blue.shade50,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: Colors.blue.shade700, size: 22),
          ),
          const SizedBox(width: 12),
          Text(
            title,
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: Colors.black87,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPersonalDetailsSection() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        children: [
          if (userData!['name'] != null && (userData!['name'] as String).isNotEmpty)
            _buildInfoTile('Full Name', userData!['name'], Icons.person),
          if (userData!['username'] != null && (userData!['username'] as String).isNotEmpty)
            _buildInfoTile('Username', '@${userData!['username']}', Icons.alternate_email),
          if (userData!['email'] != null && (userData!['email'] as String).isNotEmpty)
            _buildInfoTile('Email', userData!['email'], Icons.email),
          if (userData!['dob'] != null && (userData!['dob'] as String).isNotEmpty)
            _buildInfoTile('Date of Birth', _formatDate(userData!['dob']), Icons.cake),
          if (userData!['phone'] != null && (userData!['phone'] as String).isNotEmpty)
            _buildInfoTile('Phone', userData!['phone'], Icons.phone),
          if (userData!['location'] != null && (userData!['location'] as String).isNotEmpty)
            _buildInfoTile('Location', userData!['location'], Icons.location_on),
          if (userData!['website'] != null && (userData!['website'] as String).isNotEmpty)
            _buildInfoTile('Website', userData!['website'], Icons.language),
        ],
      ),
    );
  }

  Widget _buildProfessionalSection() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        children: [
          if (userData!['current_job'] != null && (userData!['current_job'] as String).isNotEmpty)
            _buildInfoTile('Current Position', userData!['current_job'], Icons.work),
          if (userData!['current_company'] != null && (userData!['current_company'] as String).isNotEmpty)
            _buildInfoTile('Current Company', userData!['current_company'], Icons.business),
          if (userData!['previous_job'] != null && (userData!['previous_job'] as String).isNotEmpty)
            _buildInfoTile('Previous Position', userData!['previous_job'], Icons.work_history),
          if (userData!['previous_company'] != null && (userData!['previous_company'] as String).isNotEmpty)
            _buildInfoTile('Previous Company', userData!['previous_company'], Icons.business_center),
          if (userData!['experience'] != null && (userData!['experience'] as String).isNotEmpty)
            _buildInfoTile('Experience', userData!['experience'], Icons.timeline),
          if (userData!['profession'] != null && (userData!['profession'] as String).isNotEmpty)
            _buildInfoTile('Profession', userData!['profession'], Icons.badge),
        ],
      ),
    );
  }

  Widget _buildEducationalSection() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        children: [
          if (userData!['school'] != null && (userData!['school'] as String).isNotEmpty)
            _buildInfoTile(
              'School',
              userData!['school'] + 
                (userData!['school_year'] != null && (userData!['school_year'] as String).isNotEmpty
                  ? ' (${userData!['school_year']})'
                  : ''),
              Icons.school,
            ),
          if (userData!['college'] != null && (userData!['college'] as String).isNotEmpty)
            _buildInfoTile(
              'College',
              userData!['college'] + 
                (userData!['college_year'] != null && (userData!['college_year'] as String).isNotEmpty
                  ? ' (${userData!['college_year']})'
                  : ''),
              Icons.business,
            ),
          if (userData!['university'] != null && (userData!['university'] as String).isNotEmpty)
            _buildInfoTile(
              'University',
              userData!['university'] + 
                (userData!['university_year'] != null && (userData!['university_year'] as String).isNotEmpty
                  ? ' (${userData!['university_year']})'
                  : ''),
              Icons.school_outlined,
            ),
          if (userData!['field_of_study'] != null && (userData!['field_of_study'] as String).isNotEmpty)
            _buildInfoTile('Field of Study', userData!['field_of_study'], Icons.menu_book),
          if (userData!['studying_currently'] != null)
            _buildInfoTile(
              'Current Status',
              userData!['studying_currently'] == true ? 'Currently Studying' : 'Completed',
              Icons.access_time,
            ),
        ],
      ),
    );
  }

  Widget _buildInfoTile(String label, String value, IconData icon) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: Colors.grey.shade200,
            width: 1,
          ),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: Colors.blue.shade50,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, color: Colors.blue.shade700, size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    color: Colors.grey[600],
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  value,
                  style: const TextStyle(
                    fontSize: 15,
                    color: Colors.black87,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _formatDate(dynamic dateValue) {
    if (dateValue == null) return '';
    
    try {
      DateTime date;
      if (dateValue is String) {
        date = DateTime.parse(dateValue);
      } else if (dateValue is DateTime) {
        date = dateValue;
      } else {
        return dateValue.toString();
      }
      
      final months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
      return '${months[date.month - 1]} ${date.day}, ${date.year}';
    } catch (e) {
      return dateValue.toString();
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
      final date = v.toDate();
      final months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
      return '${months[date.month - 1]} ${date.day}, ${date.year}';
    }
    return v.toString();
  }

  bool _hasEducation(Map<String, dynamic> data) {
    return (data['school']?.toString().isNotEmpty ?? false) ||
        (data['college']?.toString().isNotEmpty ?? false) ||
        (data['university']?.toString().isNotEmpty ?? false) ||
        (data['field_of_study']?.toString().isNotEmpty ?? false);
  }

  bool _hasWorkExperience(Map<String, dynamic> data) {
    return (data['current_job']?.toString().isNotEmpty ?? false) ||
        (data['current_company']?.toString().isNotEmpty ?? false) ||
        (data['previous_job']?.toString().isNotEmpty ?? false) ||
        (data['previous_company']?.toString().isNotEmpty ?? false) ||
        (data['experience']?.toString().isNotEmpty ?? false);
  }

  List<Widget> _buildEducationCards(Map<String, dynamic> data) {
    final cards = <Widget>[];

    // University
    if (data['university']?.toString().isNotEmpty ?? false) {
      cards.add(_buildInfoCard(
        icon: Icons.school,
        title: data['university'],
        subtitle: data['university_year'] ?? 
                  (data['studying_currently'] == true ? 'Currently Studying' : null),
        detail: data['field_of_study'],
      ));
    }

    // College
    if (data['college']?.toString().isNotEmpty ?? false) {
      cards.add(_buildInfoCard(
        icon: Icons.school,
        title: data['college'],
        subtitle: data['college_year'],
        detail: null,
      ));
    }

    // School
    if (data['school']?.toString().isNotEmpty ?? false) {
      cards.add(_buildInfoCard(
        icon: Icons.school,
        title: data['school'],
        subtitle: data['school_year'],
        detail: null,
      ));
    }

    return cards;
  }

  List<Widget> _buildWorkCards(Map<String, dynamic> data) {
    final cards = <Widget>[];

    // Current Job
    if (data['current_job']?.toString().isNotEmpty ?? false) {
      cards.add(_buildInfoCard(
        icon: Icons.work,
        title: data['current_job'],
        subtitle: data['current_company'],
        detail: data['current_job_start'] != null
            ? 'Since ${data['current_job_start']}'
            : (data['working_currently'] == true ? 'Currently Working' : null),
      ));
    }

    // Previous Job
    if (data['previous_job']?.toString().isNotEmpty ?? false) {
      cards.add(_buildInfoCard(
        icon: Icons.work_history,
        title: data['previous_job'],
        subtitle: data['previous_company'],
        detail: data['previous_job_year'],
      ));
    }

    // Experience
    if (data['experience']?.toString().isNotEmpty ?? false) {
      cards.add(_buildInfoCard(
        icon: Icons.timeline,
        title: 'Total Experience',
        subtitle: data['experience'],
        detail: null,
      ));
    }

    return cards;
  }

  Widget _buildInfoCard({
    required IconData icon,
    required String? title,
    String? subtitle,
    String? detail,
  }) {
    if (title == null || title.isEmpty) return const SizedBox.shrink();

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
          title,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w500,
          ),
        ),
        subtitle: subtitle != null && subtitle.isNotEmpty
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 14,
                      color: Colors.grey[700],
                    ),
                  ),
                  if (detail != null && detail.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      detail,
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey[600],
                      ),
                    ),
                  ],
                ],
              )
            : null,
      ),
    );
  }
}
