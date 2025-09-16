import 'package:flutter/material.dart';
import 'homepage.dart'; // Import HomePage for navigation

class NewsfeedPage extends StatelessWidget {
  const NewsfeedPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('News Feed'),
        backgroundColor: Colors.blue,
        foregroundColor: Colors.white,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            Navigator.pushReplacement(
              context,
              MaterialPageRoute(builder: (_) => const HomePage()),
            );
          },
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16.0),
        children: [
          _buildNewsItem(
            context,
            title: 'Welcome to the News Feed!',
            description: 'This is your social news feed. Stay updated with the latest posts.',
            timestamp: '2 hours ago',
          ),
          _buildNewsItem(
            context,
            title: 'Community Update',
            description: 'Join our community event this weekend!',
            timestamp: '5 hours ago',
          ),
          _buildNewsItem(
            context,
            title: 'New Feature Released',
            description: 'Check out the latest app features in the update.',
            timestamp: '1 day ago',
          ),
        ],
      ),
    );
  }

  Widget _buildNewsItem(BuildContext context, {required String title, required String description, required String timestamp}) {
    return Card(
      elevation: 4,
      margin: const EdgeInsets.symmetric(vertical: 8.0),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: Colors.blue,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              description,
              style: const TextStyle(fontSize: 16, color: Colors.black87),
            ),
            const SizedBox(height: 8),
            Text(
              timestamp,
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }
}