import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'see_profile_from_newsfeed.dart';

class AllUsersListPage extends StatefulWidget {
  const AllUsersListPage({super.key});

  @override
  State<AllUsersListPage> createState() => _AllUsersListPageState();
}

class _AllUsersListPageState extends State<AllUsersListPage> {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  List<Map<String, dynamic>> _groupedUsers = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadUsers();
  }

  Future<void> _loadUsers() async {
    setState(() => _isLoading = true);
    
    try {
      final snapshot = await _firestore.collection('users').get();
      final users = snapshot.docs.map((doc) {
        final data = doc.data();
        return {
          'id': doc.id,
          'name': data['name'] ?? 'Unknown',
          'session': data['session'] ?? '',
          'profile_image': data['profile_image'],
          'email': data['email'] ?? '',
        };
      }).toList();

      // Normalize and group by session
      final sessionGroups = <String, List<Map<String, dynamic>>>{};
      
      for (final user in users) {
        String session = _normalizeSession(user['session'] as String);
        if (session.isEmpty) session = 'No Session';
        
        sessionGroups.putIfAbsent(session, () => []);
        sessionGroups[session]!.add(user);
      }

      // Sort sessions in descending order
      final sortedSessions = sessionGroups.keys.toList()..sort((a, b) {
        if (a == 'No Session') return 1;
        if (b == 'No Session') return -1;
        return b.compareTo(a);
      });

      // Sort users within each session by name
      final grouped = <Map<String, dynamic>>[];
      for (final session in sortedSessions) {
        final sessionUsers = sessionGroups[session]!;
        sessionUsers.sort((a, b) => (a['name'] as String).toLowerCase().compareTo((b['name'] as String).toLowerCase()));
        
        grouped.add({
          'type': 'session_header',
          'session': session,
          'count': sessionUsers.length,
        });
        
        for (final user in sessionUsers) {
          grouped.add({
            'type': 'user',
            ...user,
          });
        }
      }

      setState(() {
        _groupedUsers = grouped;
        _isLoading = false;
      });
    } catch (e) {
      debugPrint('Error loading users: $e');
      setState(() => _isLoading = false);
    }
  }

  String _normalizeSession(String session) {
    if (session.trim().isEmpty) return '';
    
    // Match patterns like "21-22", "2021-22", "21-2022", "2021-2022"
    final regex = RegExp(r'^(\d{2,4})\s*-\s*(\d{2,4})$');
    final match = regex.firstMatch(session.trim());
    
    if (match != null) {
      String year1 = match.group(1)!;
      String year2 = match.group(2)!;
      
      // Convert to 4-digit years
      if (year1.length == 2) {
        int y1 = int.parse(year1);
        year1 = y1 >= 0 && y1 <= 50 ? '20$year1' : '19$year1';
      }
      if (year2.length == 2) {
        int y2 = int.parse(year2);
        year2 = y2 >= 0 && y2 <= 50 ? '20$year2' : '19$year2';
      }
      
      return '$year1-$year2';
    }
    
    return session;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('All Users'),
        backgroundColor: Colors.blue,
        foregroundColor: Colors.white,
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _groupedUsers.isEmpty
              ? const Center(child: Text('No users found'))
              : RefreshIndicator(
                  onRefresh: _loadUsers,
                  child: ListView.builder(
                    itemCount: _groupedUsers.length,
                    itemBuilder: (context, index) {
                      final item = _groupedUsers[index];
                      
                      if (item['type'] == 'session_header') {
                        return Container(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                          color: Colors.blue.shade50,
                          child: Row(
                            children: [
                              Icon(Icons.school, color: Colors.blue.shade700, size: 20),
                              const SizedBox(width: 8),
                              Text(
                                item['session'] as String,
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.blue.shade700,
                                ),
                              ),
                              const Spacer(),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                decoration: BoxDecoration(
                                  color: Colors.blue.shade700,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Text(
                                  '${item['count']} users',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        );
                      } else {
                        // User item
                        final user = item;
                        final profileImage = user['profile_image'] as String?;
                        final name = user['name'] as String;
                        final email = user['email'] as String;
                        
                        return ListTile(
                          leading: CircleAvatar(
                            radius: 24,
                            backgroundColor: Colors.blue.shade100,
                            backgroundImage: (profileImage != null && profileImage.isNotEmpty)
                                ? CachedNetworkImageProvider(profileImage)
                                : null,
                            child: (profileImage == null || profileImage.isEmpty)
                                ? Text(
                                    name.isNotEmpty ? name[0].toUpperCase() : '?',
                                    style: TextStyle(
                                      fontSize: 20,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.blue.shade700,
                                    ),
                                  )
                                : null,
                          ),
                          title: Text(
                            name,
                            style: const TextStyle(
                              fontWeight: FontWeight.w500,
                              fontSize: 15,
                            ),
                          ),
                          subtitle: email.isNotEmpty
                              ? Text(
                                  email,
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: Colors.grey.shade600,
                                  ),
                                )
                              : null,
                          trailing: const Icon(Icons.arrow_forward_ios, size: 16, color: Colors.grey),
                          onTap: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => SeeProfileFromNewsfeed(userId: user['id'] as String),
                              ),
                            );
                          },
                        );
                      }
                    },
                  ),
                ),
    );
  }
}
