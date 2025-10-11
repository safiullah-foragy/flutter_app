import 'package:flutter/material.dart';

/// Small reusable post composer used in the newsfeed and jobs pages.
class PostComposer extends StatelessWidget {
  final TextEditingController controller;
  final VoidCallback onPickImage;
  final VoidCallback onPickVideo;
  final VoidCallback onPost;
  final Map<String, dynamic>? userData;

  const PostComposer({
    super.key,
    required this.controller,
    required this.onPickImage,
    required this.onPickVideo,
    required this.onPost,
    this.userData,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.all(8.0),
      child: Padding(
        padding: const EdgeInsets.all(8.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            GestureDetector(
              onTap: () {},
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 20,
                    backgroundColor: Colors.grey[300],
                    backgroundImage: userData?['profile_image'] != null
                        ? NetworkImage(userData!['profile_image'])
                        : null,
                    child: userData?['profile_image'] == null
                        ? const Icon(Icons.person, size: 20, color: Colors.grey)
                        : null,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: controller,
                      maxLines: null,
                      minLines: 1,
                      decoration: InputDecoration(
                        hintText: "What's on your mind?",
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(20)),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                IconButton(icon: const Icon(Icons.photo_library), onPressed: onPickImage),
                IconButton(icon: const Icon(Icons.video_library), onPressed: onPickVideo),
                IconButton(icon: const Icon(Icons.send), onPressed: onPost),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
 
