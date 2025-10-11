import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'supabase.dart' as sb;

class JobsPage extends StatefulWidget {
  const JobsPage({super.key});

  @override
  State<JobsPage> createState() => _JobsPageState();
}

class _JobsPageState extends State<JobsPage> {
  final TextEditingController _descriptionController = TextEditingController();
  File? _pickedImage;
  bool _posting = false;

  @override
  void dispose() {
    _descriptionController.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    final picker = ImagePicker();
    final XFile? file = await picker.pickImage(source: ImageSource.gallery, maxWidth: 1600);
    if (file != null) {
      setState(() => _pickedImage = File(file.path));
    }
  }

  Future<void> _postJob() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('You must be signed in to post a job')));
      return;
    }

    final description = _descriptionController.text.trim();
    if (description.isEmpty && _pickedImage == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Enter a description or pick an image')));
      return;
    }

    setState(() => _posting = true);

    try {
      String? imageUrl;
      if (_pickedImage != null) {
        imageUrl = await sb.uploadPostImage(_pickedImage!);
      }

      // Create a post in the shared `posts` collection, marked as a job post
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final doc = {
        'user_id': user.uid,
        'text': description,
        'image_url': imageUrl ?? '',
        'video_url': '',
        'timestamp': timestamp,
        'is_private': false,
        'likes_count': 0,
        'comments_count': 0,
        'post_type': 'job', // marker so we can query only job posts
      };

      await FirebaseFirestore.instance.collection('posts').add(doc);

      // clear composer
      _descriptionController.clear();
      setState(() {
        _pickedImage = null;
      });

      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Job posted')));
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to post job: $e')));
    } finally {
      setState(() => _posting = false);
    }
  }

  Widget _composer() {
    return Card(
      margin: const EdgeInsets.all(12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _descriptionController,
              maxLines: null,
              decoration: const InputDecoration(hintText: 'Describe the job (title, location, details)') ,
            ),
            const SizedBox(height: 8),
            if (_pickedImage != null)
              Stack(
                children: [
                  Image.file(_pickedImage!, height: 160, width: double.infinity, fit: BoxFit.cover),
                  Positioned(
                    right: 4,
                    top: 4,
                    child: CircleAvatar(
                      backgroundColor: Colors.black54,
                      child: IconButton(
                        icon: const Icon(Icons.close, color: Colors.white, size: 18),
                        onPressed: () => setState(() => _pickedImage = null),
                      ),
                    ),
                  ),
                ],
              ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                TextButton.icon(
                  onPressed: _pickImage,
                  icon: const Icon(Icons.photo),
                  label: const Text('Add Image'),
                ),
                ElevatedButton(
                  onPressed: _posting ? null : _postJob,
                  child: _posting 
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) 
                    : const Text('Post Job'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _jobTile(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    
    // Extract data with null safety
    final description = data['text']?.toString() ?? 'No description';
    final imageUrl = data['image_url']?.toString() ?? '';
    
    // Handle timestamp - it could be int, Timestamp, or null
    DateTime dateTime;
    final timestamp = data['timestamp'];
    
    if (timestamp is int) {
      dateTime = DateTime.fromMillisecondsSinceEpoch(timestamp);
    } else if (timestamp is Timestamp) {
      dateTime = timestamp.toDate();
    } else {
      dateTime = DateTime.now(); // fallback
    }

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Description
            Text(
              description,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
            ),
            
            // Image if available
            if (imageUrl.isNotEmpty) ...[
              const SizedBox(height: 12),
              Container(
                height: 200,
                width: double.infinity,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Image.network(
                  imageUrl,
                  fit: BoxFit.cover,
                  errorBuilder: (context, error, stackTrace) {
                    return Container(
                      color: Colors.grey[200],
                      child: const Icon(Icons.error, color: Colors.red),
                    );
                  },
                  loadingBuilder: (context, child, loadingProgress) {
                    if (loadingProgress == null) return child;
                    return Container(
                      color: Colors.grey[200],
                      child: const Center(child: CircularProgressIndicator()),
                    );
                  },
                ),
              ),
            ],
            
            // Timestamp
            const SizedBox(height: 12),
            Text(
              'Posted on: ${dateTime.toLocal().toString().split('.').first}',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Jobs')),
      body: Column(
        children: [
          _composer(),
          const SizedBox(height: 8),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Recent Job Posts',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('posts')
                  .where('post_type', isEqualTo: 'job')
                  .orderBy('timestamp', descending: true)
                  .snapshots(),
              builder: (context, snapshot) {
                // Debug: Print snapshot state
                print('Snapshot connection state: ${snapshot.connectionState}');
                print('Snapshot has data: ${snapshot.hasData}');
                print('Snapshot error: ${snapshot.error}');
                
                if (snapshot.hasError) {
                  print('Stream error: ${snapshot.error}');
                  return Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.error, color: Colors.red, size: 48),
                        const SizedBox(height: 16),
                        Text('Error: ${snapshot.error}'),
                      ],
                    ),
                  );
                }
                
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                
                final docs = snapshot.data?.docs ?? [];
                print('Number of job posts found: ${docs.length}');
                
                if (docs.isEmpty) {
                  return const Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.work_outline, size: 64, color: Colors.grey),
                        SizedBox(height: 16),
                        Text('No job posts yet'),
                        Text('Be the first to post a job!', style: TextStyle(color: Colors.grey)),
                      ],
                    ),
                  );
                }
                
                return ListView.builder(
                  itemCount: docs.length,
                  itemBuilder: (context, index) {
                    final doc = docs[index];
                    print('Post ${index + 1}: ${doc.data()}');
                    return _jobTile(doc);
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