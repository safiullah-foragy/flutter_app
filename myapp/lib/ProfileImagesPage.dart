import 'package:flutter/material.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import 'supabase.dart' as sb;

class ProfileImagesPage extends StatefulWidget {
  const ProfileImagesPage({super.key});

  @override
  State<ProfileImagesPage> createState() => _ProfileImagesPageState();
}

class _ProfileImagesPageState extends State<ProfileImagesPage> {
  List<Map<String, String>> images = [];
  bool isLoading = true;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  @override
  void initState() {
    super.initState();
    _fetchImages();
  }

  Future<void> _fetchImages() async {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        Fluttertoast.showToast(
          msg: 'Please log in to view images',
          toastLength: Toast.LENGTH_LONG,
          backgroundColor: Colors.red,
          textColor: Colors.white,
        );
        setState(() {
          isLoading = false;
        });
        return;
      }

      final response = await sb.supabase.storage
          .from('profile-images')
          .list();
      
      final imageList = response
          .where((file) => file.name.startsWith(user.uid)) // Filter by UID
          .map((file) => {
                'url': sb.supabase.storage.from('profile-images').getPublicUrl(file.name),
                'name': file.name,
              }).toList();

      setState(() {
        images = imageList;
        isLoading = false;
      });
    } catch (e) {
      print('Error fetching images: $e');
      Fluttertoast.showToast(
        msg: 'Error fetching images: $e',
        toastLength: Toast.LENGTH_LONG,
        backgroundColor: Colors.red,
        textColor: Colors.white,
      );
      setState(() {
        isLoading = false;
      });
    }
  }

  Future<void> _downloadImage(String imageUrl, String fileName) async {
    try {
      final directory = await getTemporaryDirectory();
      final filePath = '${directory.path}/$fileName';
      final response = await http.get(Uri.parse(imageUrl));
      
      if (response.statusCode == 200) {
        final file = File(filePath);
        await file.writeAsBytes(response.bodyBytes);
        
        Fluttertoast.showToast(
          msg: 'Image downloaded to temporary directory: $filePath',
          toastLength: Toast.LENGTH_LONG,
          backgroundColor: Colors.blue,
          textColor: Colors.white,
        );
      } else {
        Fluttertoast.showToast(
          msg: 'Failed to download image: HTTP ${response.statusCode}',
          toastLength: Toast.LENGTH_LONG,
          backgroundColor: Colors.red,
          textColor: Colors.white,
        );
      }
    } catch (e) {
      print('Error downloading image: $e');
      Fluttertoast.showToast(
        msg: 'Error downloading image: $e',
        toastLength: Toast.LENGTH_LONG,
        backgroundColor: Colors.red,
        textColor: Colors.white,
      );
    }
  }

  Future<void> _deleteImage(String fileName) async {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        Fluttertoast.showToast(
          msg: 'Please log in to delete images',
          toastLength: Toast.LENGTH_LONG,
          backgroundColor: Colors.red,
          textColor: Colors.white,
        );
        return;
      }

      await sb.supabase.storage
          .from('profile-images')
          .remove([fileName]);
      
      setState(() {
        images.removeWhere((image) => image['name'] == fileName);
      });
      
      Fluttertoast.showToast(
        msg: 'Image deleted successfully',
        toastLength: Toast.LENGTH_LONG,
        backgroundColor: Colors.blue,
        textColor: Colors.white,
      );
    } catch (e) {
      print('Error deleting image: $e');
      Fluttertoast.showToast(
        msg: 'Error deleting image: $e',
        toastLength: Toast.LENGTH_LONG,
        backgroundColor: Colors.red,
        textColor: Colors.white,
      );
    }
  }

  void _showDeleteConfirmation(String fileName) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Confirm Deletion'),
          content: const Text('Are you sure you want to delete this image?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () {
                Navigator.pop(context);
                _deleteImage(fileName);
              },
              child: const Text('Delete', style: TextStyle(color: Colors.red)),
            ),
          ],
        );
      },
    );
  }

  void _openFullScreenImage(String imageUrl, String fileName) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => Scaffold(
          appBar: AppBar(
            backgroundColor: Colors.black,
            leading: IconButton(
              icon: const Icon(Icons.arrow_back, color: Colors.white),
              onPressed: () => Navigator.pop(context),
            ),
            actions: [
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert, color: Colors.white),
                onSelected: (value) {
                  if (value == 'download') {
                    _downloadImage(imageUrl, fileName);
                  } else if (value == 'delete') {
                    _showDeleteConfirmation(fileName);
                  }
                },
                itemBuilder: (BuildContext context) => [
                  const PopupMenuItem<String>(
                    value: 'download',
                    child: Row(
                      children: [
                        Icon(Icons.download, color: Colors.black),
                        SizedBox(width: 8),
                        Text('Download Image'),
                      ],
                    ),
                  ),
                  const PopupMenuItem<String>(
                    value: 'delete',
                    child: Row(
                      children: [
                        Icon(Icons.delete, color: Colors.red),
                        SizedBox(width: 8),
                        Text('Delete Image', style: TextStyle(color: Colors.red)),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
          body: Center(
            child: CachedNetworkImage(
              imageUrl: imageUrl,
              fit: BoxFit.contain,
              placeholder: (context, url) => const CircularProgressIndicator(),
              errorWidget: (context, url, error) => const Icon(Icons.error, size: 50),
            ),
          ),
          backgroundColor: Colors.black,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('All Profile Images'),
        backgroundColor: Colors.blue,
        foregroundColor: Colors.white,
      ),
      body: isLoading
          ? const Center(child: CircularProgressIndicator())
          : images.isEmpty
              ? const Center(child: Text('No images found', style: TextStyle(fontSize: 18)))
              : GridView.builder(
                  padding: const EdgeInsets.all(16.0),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    crossAxisSpacing: 10,
                    mainAxisSpacing: 10,
                    childAspectRatio: 1,
                  ),
                  itemCount: images.length,
                  itemBuilder: (context, index) {
                    final image = images[index];
                    return GestureDetector(
                      onTap: () => _openFullScreenImage(image['url']!, image['name']!),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: CachedNetworkImage(
                          imageUrl: image['url']!,
                          fit: BoxFit.cover,
                          placeholder: (context, url) => const Center(child: CircularProgressIndicator()),
                          errorWidget: (context, url, error) => const Icon(Icons.error, size: 50),
                        ),
                      ),
                    );
                  },
                ),
    );
  }
}