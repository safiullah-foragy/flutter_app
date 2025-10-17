import 'package:flutter/material.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';
import 'package:chewie/chewie.dart';
import 'dart:io';
import 'supabase.dart' as sb;

class ProfileImagesPage extends StatefulWidget {
  const ProfileImagesPage({super.key});

  @override
  State<ProfileImagesPage> createState() => _ProfileImagesPageState();
}

class _ProfileImagesPageState extends State<ProfileImagesPage> {
  // Unified media list from profile images and user posts (photos/videos)
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  List<_MediaItem> _allMedia = [];
  bool _showPhotos = true;
  bool _showVideos = true;
  bool isLoading = true;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  @override
  void initState() {
    super.initState();
    _fetchMedia();
  }

  Future<void> _fetchMedia() async {
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

      // Fetch profile images (network-only as Supabase list requires connectivity)
      final response = await sb.supabase.storage.from('profile-images').list();
      final profileItems = response
          .where((file) => file.name.startsWith(user.uid))
          .map((file) => _MediaItem(
                type: MediaType.photo,
                url: sb.supabase.storage.from('profile-images').getPublicUrl(file.name),
                name: file.name,
                // profile images may not have a comparable timestamp; set to 0 to sort after posts
                timestamp: 0,
                isProfileAsset: true,
              ))
          .toList();

      // Fetch user's post media (cache-first, fallback to server)
      Query query = _firestore
          .collection('posts')
          .where('user_id', isEqualTo: user.uid)
          .orderBy('timestamp', descending: true);

      QuerySnapshot postsSnapshot;
      try {
        postsSnapshot = await query.get(const GetOptions(source: Source.cache));
        if (postsSnapshot.docs.isEmpty) {
          postsSnapshot = await query.get();
        }
      } catch (_) {
        try {
          postsSnapshot = await _firestore
              .collection('posts')
              .where('user_id', isEqualTo: user.uid)
              .get(const GetOptions(source: Source.cache));
          if (postsSnapshot.docs.isEmpty) {
            postsSnapshot = await _firestore
                .collection('posts')
                .where('user_id', isEqualTo: user.uid)
                .get();
          }
        } catch (e) {
          postsSnapshot = await _firestore
              .collection('posts')
              .where('user_id', isEqualTo: user.uid)
              .get();
        }
      }

      final postItems = <_MediaItem>[];
      for (final d in postsSnapshot.docs) {
        final data = d.data() as Map<String, dynamic>?;
        if (data == null) continue;
        final ts = (data['timestamp'] ?? 0) as int;
        final img = (data['image_url'] ?? '') as String;
        final vid = (data['video_url'] ?? '') as String;
        if (img.isNotEmpty) {
          postItems.add(_MediaItem(
            type: MediaType.photo,
            url: img,
            name: 'post_image_${d.id}',
            timestamp: ts,
            isProfileAsset: false,
          ));
        }
        if (vid.isNotEmpty) {
          postItems.add(_MediaItem(
            type: MediaType.video,
            url: vid,
            name: 'post_video_${d.id}',
            timestamp: ts,
            isProfileAsset: false,
          ));
        }
      }

      // Sort posts by timestamp desc; profile images will follow
      postItems.sort((a, b) => b.timestamp.compareTo(a.timestamp));
      final all = [...postItems, ...profileItems];

      setState(() {
        _allMedia = all;
        isLoading = false;
      });
    } catch (e) {
      print('Error fetching images: $e');
      Fluttertoast.showToast(
        msg: 'Error fetching media: $e',
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
        _allMedia.removeWhere((m) => m.isProfileAsset && m.name == fileName);
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

  Future<bool> _validateUrlExists(String url) async {
    try {
      final uri = Uri.parse(url);
      final client = HttpClient();
      client.userAgent = 'MyApp/1.0';
      final req = await client.openUrl('HEAD', uri);
      final resp = await req.close();
      final status = resp.statusCode;
      client.close(force: true);
      return status >= 200 && status < 300;
    } catch (_) {
      return false;
    }
  }

  Future<String?> _resolveVideoUrl(String url) async {
    if (await _validateUrlExists(url)) return url;
    try {
      const marker = '/storage/v1/object/public/';
      final idx = url.indexOf(marker);
      if (idx == -1) return null;
      final tail = url.substring(idx + marker.length);
      final parts = tail.split('/');
      if (parts.length < 2) return null;
      final bucket = parts[0];
      final objectPath = parts.sublist(1).join('/');
      final dynamic signed = await sb.supabase.storage.from(bucket).createSignedUrl(objectPath, 60 * 60);
      final String? signedUrl = signed?.toString();
      if (signedUrl == null) return null;
      if (await _validateUrlExists(signedUrl)) return signedUrl;
      return null;
    } catch (_) {
      return null;
    }
  }

  void _openVideoPlayer(String url) async {
    final resolved = await _resolveVideoUrl(url);
    if (resolved == null) {
      Fluttertoast.showToast(msg: 'Unable to open video');
      return;
    }
    if (!mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _VideoPlayerScreen(videoUrl: resolved),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _allMedia.where((m) => (m.type == MediaType.photo && _showPhotos) || (m.type == MediaType.video && _showVideos)).toList();
    return Scaffold(
      appBar: AppBar(
        title: const Text('All Media'),
        backgroundColor: Colors.blue,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: () async {
              setState(() => isLoading = true);
              await _fetchMedia();
            },
          )
        ],
      ),
      body: isLoading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      FilterChip(
                        label: const Text('Photos'),
                        selected: _showPhotos,
                        onSelected: (v) => setState(() => _showPhotos = v),
                      ),
                      const SizedBox(width: 12),
                      FilterChip(
                        label: const Text('Videos'),
                        selected: _showVideos,
                        onSelected: (v) => setState(() => _showVideos = v),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 4),
                Expanded(
                  child: filtered.isEmpty
                      ? const Center(child: Text('No media found', style: TextStyle(fontSize: 18)))
                      : GridView.builder(
                          padding: const EdgeInsets.all(16.0),
                          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 2,
                            crossAxisSpacing: 10,
                            mainAxisSpacing: 10,
                            childAspectRatio: 1,
                          ),
                          itemCount: filtered.length,
                          itemBuilder: (context, index) {
                            final item = filtered[index];
                            return GestureDetector(
                              onTap: () {
                                if (item.type == MediaType.photo) {
                                  _openFullScreenImage(item.url, item.name);
                                } else {
                                  _openVideoPlayer(item.url);
                                }
                              },
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(10),
                                child: Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    if (item.type == MediaType.photo)
                                      CachedNetworkImage(
                                        imageUrl: item.url,
                                        fit: BoxFit.cover,
                                        placeholder: (context, url) => const Center(child: CircularProgressIndicator()),
                                        errorWidget: (context, url, error) => const Icon(Icons.error, size: 50),
                                      )
                                    else
                                      Container(
                                        color: Colors.black12,
                                        child: const Center(
                                          child: Icon(Icons.play_circle_fill, size: 56, color: Colors.black54),
                                        ),
                                      ),
                                    if (item.isProfileAsset)
                                      Positioned(
                                        right: 6,
                                        top: 6,
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                          decoration: BoxDecoration(
                                            color: Colors.black54,
                                            borderRadius: BorderRadius.circular(6),
                                          ),
                                          child: const Text('Profile', style: TextStyle(color: Colors.white, fontSize: 10)),
                                        ),
                                      ),
                                    Positioned(
                                      left: 6,
                                      bottom: 6,
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                        decoration: BoxDecoration(
                                          color: Colors.black54,
                                          borderRadius: BorderRadius.circular(6),
                                        ),
                                        child: Text(
                                          item.type == MediaType.photo ? 'Photo' : 'Video',
                                          style: const TextStyle(color: Colors.white, fontSize: 10),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
    );
  }
}

enum MediaType { photo, video }

class _MediaItem {
  final MediaType type;
  final String url;
  final String name;
  final int timestamp; // for posts media sorting; 0 for profile images
  final bool isProfileAsset; // true if from profile-images bucket

  _MediaItem({
    required this.type,
    required this.url,
    required this.name,
    required this.timestamp,
    required this.isProfileAsset,
  });
}

class _VideoPlayerScreen extends StatefulWidget {
  final String videoUrl;
  const _VideoPlayerScreen({required this.videoUrl});

  @override
  State<_VideoPlayerScreen> createState() => _VideoPlayerScreenState();
}

class _VideoPlayerScreenState extends State<_VideoPlayerScreen> {
  VideoPlayerController? _vpc;
  ChewieController? _chewie;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final vpc = VideoPlayerController.networkUrl(Uri.parse(widget.videoUrl));
      await vpc.initialize();
      final chewie = ChewieController(
        videoPlayerController: vpc,
        autoInitialize: true,
        autoPlay: true,
        looping: false,
        allowMuting: true,
      );
      setState(() {
        _vpc = vpc;
        _chewie = chewie;
        _loading = false;
      });
    } catch (e) {
      Fluttertoast.showToast(msg: 'Video error: $e');
      setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    try {
      _chewie?.dispose();
    } catch (_) {}
    try {
      _vpc?.dispose();
    } catch (_) {}
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
      ),
      backgroundColor: Colors.black,
      body: Center(
        child: _loading
            ? const CircularProgressIndicator()
            : (_chewie != null
                ? AspectRatio(
                    aspectRatio: _vpc?.value.aspectRatio == 0 ? 16 / 9 : _vpc!.value.aspectRatio,
                    child: Chewie(controller: _chewie!),
                  )
                : const Text('Video unavailable', style: TextStyle(color: Colors.white))),
      ),
    );
  }
}