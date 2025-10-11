import 'dart:async';
import 'dart:io';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:image_picker/image_picker.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;
import 'package:video_player/video_player.dart';
import 'package:chewie/chewie.dart';
import 'package:permission_handler/permission_handler.dart';
import 'supabase.dart' as sb;
import 'see_profile_from_newsfeed.dart';
import 'subnewsfeed1.dart';
import 'subnewsfeed2.dart';
import 'videos.dart';
import 'messages.dart';
import 'jobs.dart';

class NewsfeedPage extends StatefulWidget {
  const NewsfeedPage({super.key});

  @override
  State<NewsfeedPage> createState() => _NewsfeedPageState();
}

class _NewsfeedPageState extends State<NewsfeedPage> with TickerProviderStateMixin {
  final firebase_auth.FirebaseAuth _auth = firebase_auth.FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final ImagePicker _imagePicker = ImagePicker();
  final TextEditingController _postController = TextEditingController();
  final TextEditingController _commentController = TextEditingController();
  // per-post comment controllers to avoid sharing a single controller across posts
  Map<String, TextEditingController> perPostCommentControllers = {};
  final Connectivity _connectivity = Connectivity();

  File? _selectedImage;
  File? _selectedVideo;
  Map<String, dynamic>? userData;
  List<Map<String, dynamic>> posts = [];
  Map<String, List<Map<String, dynamic>>> postComments = {};
  Map<String, int> postLikes = {};
  Map<String, int> postCommentCounts = {};
  Map<String, String> userReactions = {};
  Map<String, bool> commentEditing = {};
  Map<String, TextEditingController> commentEditControllers = {};
  Map<String, bool> expandedComments = {};
  Map<String, Map<String, dynamic>?> userCache = {};
  // video player controllers are initialized lazily to avoid blocking initial load
  Map<String, VideoPlayerController?> videoPlayerControllers = {};
  Map<String, ChewieController?> videoControllers = {};
  Map<String, AnimationController?> likeAnimationControllers = {};
  StreamSubscription<QuerySnapshot>? _postsSubscription;
  Map<String, StreamSubscription<QuerySnapshot>?> commentSubscriptions = {};
  StreamSubscription<ConnectivityResult>? _connectivitySubscription;
  bool isLoading = true;
  bool hasConnection = true;

  @override
  void initState() {
    super.initState();
    _firestore.settings = const Settings(persistenceEnabled: true);
    _checkConnectivity();
    _fetchUserData();
    _fetchInitialPosts();
    _setupPostsListener();
  }

  void _checkConnectivity() {
    _connectivitySubscription = _connectivity.onConnectivityChanged.listen((ConnectivityResult result) {
      setState(() {
        hasConnection = result != ConnectivityResult.none;
      });
      if (!hasConnection) {
        Fluttertoast.showToast(msg: 'No internet connection. Showing cached data if available.');
      }
    });
  }

  @override
  void dispose() {
    _postController.dispose();
    _commentController.dispose();
    perPostCommentControllers.forEach((_, c) => c.dispose());
    commentEditControllers.forEach((_, controller) => controller.dispose());
    videoControllers.forEach((_, controller) => controller?.dispose());
    videoPlayerControllers.forEach((_, controller) => controller?.dispose());
    likeAnimationControllers.forEach((_, controller) => controller?.dispose());
    _postsSubscription?.cancel();
    commentSubscriptions.forEach((_, sub) => sub?.cancel());
    _connectivitySubscription?.cancel();
    super.dispose();
  }

  Future<void> _requestPermissions(Permission permission) async {
    try {
      final status = await permission.request();
      if (status.isDenied) {
        Fluttertoast.showToast(
          msg: 'Permission denied. Please enable ${permission.toString().split('.').last} access in settings.',
          toastLength: Toast.LENGTH_LONG,
        );
        await openAppSettings();
      } else if (status.isPermanentlyDenied) {
        Fluttertoast.showToast(
          msg: 'Permission permanently denied. Please enable in settings.',
          toastLength: Toast.LENGTH_LONG,
        );
        await openAppSettings();
      }
    } catch (e) {
      print('Error requesting permission: $e');
      // Avoid showing random error messages
    }
  }

  Future<void> _fetchUserData() async {
    try {
      final firebase_auth.User? user = _auth.currentUser;
      if (user == null) {
        return;
      }
      DocumentSnapshot userDoc = await _firestore.collection('users').doc(user.uid).get();
      if (userDoc.exists) {
        setState(() {
          userData = userDoc.data() as Map<String, dynamic>?;
          userCache[user.uid] = userData;
        });
      }
    } catch (e) {
      print('Error fetching user data: $e');
      if (e is FirebaseException && e.code == 'permission-denied') {
        // Handle silently or log
      } else {
        // Avoid showing toast
      }
    }
  }

  Future<void> _fetchInitialPosts() async {
    if (!hasConnection) {
      setState(() {
        isLoading = false;
      });
      return;
    }
    try {
      QuerySnapshot postsSnapshot = await _firestore
          .collection('posts')
          .where('is_private', isEqualTo: false)
          .orderBy('timestamp', descending: true)
          .get();

      List<Map<String, dynamic>> postsList = [];
      for (var doc in postsSnapshot.docs) {
        try {
          final postData = doc.data() as Map<String, dynamic>?;
          if (postData == null) continue;
          String postId = doc.id;

          String userId = postData['user_id'] ?? '';
          Map<String, dynamic>? postUserData;
          if (userCache.containsKey(userId)) {
            postUserData = userCache[userId];
          } else {
            DocumentSnapshot userDoc = await _firestore.collection('users').doc(userId).get();
            if (userDoc.exists) {
              postUserData = userDoc.data() as Map<String, dynamic>;
              userCache[userId] = postUserData;
            }
          }

          DocumentSnapshot likesDoc = await _firestore
              .collection('posts')
              .doc(postId)
              .collection('likes')
              .doc(_auth.currentUser?.uid)
              .get();

          String userReaction = likesDoc.exists ? (likesDoc.get('reaction') ?? 'like') : '';

          postsList.add({
            'id': postId,
            ...postData,
            'user_data': postUserData,
          });

          postLikes[postId] = postData['likes_count'] ?? 0;
          postCommentCounts[postId] = postData['comments_count'] ?? 0;
          userReactions[postId] = userReaction;

          // Defer video initialization until the post is visible to improve load performance.
          if ((postData['video_url'] as String?)?.isNotEmpty ?? false) {
            videoPlayerControllers[postId] = null;
            videoControllers[postId] = null;
          }
        } catch (postError) {
          print('Error processing post ${doc.id}: $postError');
        }
      }

      setState(() {
        posts = postsList;
        isLoading = false;
      });
    } catch (e) {
      print('Error fetching initial posts: $e');
      if (e is FirebaseException && e.code == 'permission-denied') {
        // Handle silently
      } else {
        // Avoid toast
      }
      setState(() {
        isLoading = false;
      });
    }
  }

  void _setupPostsListener() {
    _postsSubscription?.cancel();
    _postsSubscription = _firestore
        .collection('posts')
        .where('is_private', isEqualTo: false)
        .orderBy('timestamp', descending: true)
        .snapshots()
        .listen((snapshot) async {
      if (!hasConnection) return;
      List<Map<String, dynamic>> postsList = [];
      for (var doc in snapshot.docs) {
        try {
          final postData = doc.data() as Map<String, dynamic>?;
          if (postData == null) continue;
          String postId = doc.id;

          String userId = postData['user_id'] ?? '';
          Map<String, dynamic>? postUserData;
          if (userCache.containsKey(userId)) {
            postUserData = userCache[userId];
          } else {
            DocumentSnapshot userDoc = await _firestore.collection('users').doc(userId).get();
            if (userDoc.exists) {
              postUserData = userDoc.data() as Map<String, dynamic>;
              userCache[userId] = postUserData;
            }
          }

          DocumentSnapshot likesDoc = await _firestore
              .collection('posts')
              .doc(postId)
              .collection('likes')
              .doc(_auth.currentUser?.uid)
              .get();

          String userReaction = likesDoc.exists ? (likesDoc.get('reaction') ?? 'like') : '';

          postsList.add({
            'id': postId,
            ...postData,
            'user_data': postUserData,
          });

          postLikes[postId] = postData['likes_count'] ?? 0;
          postCommentCounts[postId] = postData['comments_count'] ?? 0;
          userReactions[postId] = userReaction;
          // videos are handled lazily when user opens a video player screen
        } catch (postError) {
          print('Error processing post ${doc.id}: $postError');
        }
      }

      setState(() {
        posts = postsList;
        isLoading = false;
      });
    }, onError: (e) {
      print('Error in posts listener: $e');
      if (e is FirebaseException && e.code == 'permission-denied') {
        // Handle silently
      } else {
        // Avoid toast
      }
    });
  }

  Future<void> _fetchComments(String postId) async {
    try {
      QuerySnapshot commentsSnapshot = await _firestore
          .collection('posts')
          .doc(postId)
          .collection('comments')
          .orderBy('timestamp', descending: false)
          .get();

      List<Map<String, dynamic>> comments = [];
      for (var commentDoc in commentsSnapshot.docs) {
        Map<String, dynamic> commentData = commentDoc.data() as Map<String, dynamic>;
        String commentUserId = commentData['user_id'] ?? '';
        Map<String, dynamic>? commentUserData;

        if (userCache.containsKey(commentUserId)) {
          commentUserData = userCache[commentUserId];
        } else {
          DocumentSnapshot commentUserDoc = await _firestore.collection('users').doc(commentUserId).get();
          if (commentUserDoc.exists) {
            commentUserData = commentUserDoc.data() as Map<String, dynamic>;
            userCache[commentUserId] = commentUserData;
          } else {
            commentUserData = {'name': 'Unknown User', 'profile_image': null};
          }
        }

        comments.add({
          'id': commentDoc.id,
          ...commentData,
          'user_data': commentUserData,
        });
      }

      setState(() {
        postComments[postId] = comments;
      });
    } catch (e) {
      print('Error fetching comments: $e');
      if (e is FirebaseException && e.code == 'permission-denied') {
        // Handle silently
      } else {
        // Avoid toast
      }
      setState(() {
        postComments[postId] = [];
      });
    }
  }

  Future<void> _createPost() async {
    try {
      final firebase_auth.User? user = _auth.currentUser;
      if (user == null) {
        return;
      }
      if (_postController.text.isEmpty && _selectedImage == null && _selectedVideo == null) {
        return;
      }

      String imageUrl = '';
      String videoUrl = '';

      if (_selectedImage != null) {
        final status = await Permission.photos.status;
        if (!status.isGranted) {
          await _requestPermissions(Permission.photos);
          if (!await Permission.photos.isGranted) return;
        }
        final String fileName = 'post_${user.uid}_${DateTime.now().millisecondsSinceEpoch}.jpg';
        imageUrl = await sb.uploadPostImage(_selectedImage!, fileName: fileName);
      }

      if (_selectedVideo != null) {
        final status = await Permission.videos.status;
        if (!status.isGranted) {
          await _requestPermissions(Permission.videos);
          if (!await Permission.videos.isGranted) return;
        }
        final String fileName = 'video_${user.uid}_${DateTime.now().millisecondsSinceEpoch}.mp4';
        videoUrl = await sb.uploadVideo(_selectedVideo!, fileName: fileName);
      }

      final int timestamp = DateTime.now().millisecondsSinceEpoch;
      DocumentReference ref = await _firestore.collection('posts').add({
        'user_id': user.uid,
        'text': _postController.text,
        'image_url': imageUrl,
        'video_url': videoUrl,
        'timestamp': timestamp,
        'is_private': false,
        'likes_count': 0,
        'comments_count': 0,
      });

      String postId = ref.id;
      setState(() {
        posts.insert(0, {
          'id': postId,
          'user_id': user.uid,
          'text': _postController.text,
          'image_url': imageUrl,
          'video_url': videoUrl,
          'timestamp': timestamp,
          'is_private': false,
          'likes_count': 0,
          'comments_count': 0,
          'user_data': userData,
        });
        postLikes[postId] = 0;
        postCommentCounts[postId] = 0;
        userReactions[postId] = '';
        _postController.clear();
        _selectedImage = null;
        _selectedVideo = null;
      });
    } catch (e) {
      print('Error creating post: $e');
      if (e is FirebaseException && e.code == 'permission-denied') {
        // Handle silently
      } else {
        // Avoid toast
      }
    }
  }

  Future<void> _pickImage() async {
    try {
      final status = await Permission.photos.status;
      if (!status.isGranted) {
        await _requestPermissions(Permission.photos);
        if (!await Permission.photos.isGranted) return;
      }

      final XFile? pickedFile = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 85,
      );
      if (pickedFile != null) {
        setState(() {
          _selectedImage = File(pickedFile.path);
          _selectedVideo = null;
        });
      }
    } catch (e) {
      print('Error picking image: $e');
      // Avoid toast
    }
  }

  Future<void> _pickVideo() async {
    try {
      final status = await Permission.videos.status;
      if (!status.isGranted) {
        await _requestPermissions(Permission.videos);
        if (!await Permission.videos.isGranted) return;
      }

      final XFile? pickedFile = await _imagePicker.pickVideo(
        source: ImageSource.gallery,
      );
      if (pickedFile != null) {
        setState(() {
          _selectedVideo = File(pickedFile.path);
          _selectedImage = null;
        });
      }
    } catch (e) {
      print('Error picking video: $e');
      // Avoid toast
    }
  }

  Future<void> _addComment(String postId, TextEditingController controller) async {
    try {
      final firebase_auth.User? user = _auth.currentUser;
      if (user == null) {
        return;
      }
      if (controller.text.isEmpty) {
        return;
      }

      final int timestamp = DateTime.now().millisecondsSinceEpoch;
      DocumentReference ref = await _firestore
          .collection('posts')
          .doc(postId)
          .collection('comments')
          .add({
        'user_id': user.uid,
  'text': controller.text,
        'timestamp': timestamp,
      });

      await _firestore.collection('posts').doc(postId).update({
        'comments_count': FieldValue.increment(1),
      });

      setState(() {
        postComments[postId] = postComments[postId] ?? [];
        postComments[postId]!.add({
          'id': ref.id,
          'user_id': user.uid,
          'text': controller.text,
          'timestamp': timestamp,
          'user_data': userData,
        });
        postCommentCounts[postId] = (postCommentCounts[postId] ?? 0) + 1;
        controller.clear();
      });
    } catch (e) {
      print('Error adding comment: $e');
      if (e is FirebaseException && e.code == 'permission-denied') {
        // Handle silently
      } else {
        // Avoid toast
      }
    }
  }

  Future<void> _editComment(String postId, String commentId, String newText) async {
    try {
      if (newText.isEmpty) {
        return;
      }
      await _firestore
          .collection('posts')
          .doc(postId)
          .collection('comments')
          .doc(commentId)
          .update({
        'text': newText,
        'edited': true,
      });

      setState(() {
        commentEditing[commentId] = false;
        if (postComments.containsKey(postId)) {
          final comment = postComments[postId]!.firstWhere((c) => c['id'] == commentId);
          comment['text'] = newText;
          comment['edited'] = true;
        }
      });
    } catch (e) {
      print('Error updating comment: $e');
      if (e is FirebaseException && e.code == 'permission-denied') {
        // Handle silently
      } else {
        // Avoid toast
      }
    }
  }

  Future<void> _deleteComment(String postId, String commentId) async {
    try {
      await _firestore
          .collection('posts')
          .doc(postId)
          .collection('comments')
          .doc(commentId)
          .delete();

      await _firestore.collection('posts').doc(postId).update({
        'comments_count': FieldValue.increment(-1),
      });

      setState(() {
        if (postComments.containsKey(postId)) {
          postComments[postId]!.removeWhere((c) => c['id'] == commentId);
          postCommentCounts[postId] = (postCommentCounts[postId] ?? 1) - 1;
        }
      });
    } catch (e) {
      print('Error deleting comment: $e');
      if (e is FirebaseException && e.code == 'permission-denied') {
        // Handle silently
      } else {
        // Avoid toast
      }
    }
  }

  Future<void> _toggleLike(String postId, String reaction) async {
    try {
      final firebase_auth.User? user = _auth.currentUser;
      if (user == null) {
        return;
      }

      final docRef = _firestore
          .collection('posts')
          .doc(postId)
          .collection('likes')
          .doc(user.uid);

      DocumentSnapshot likeDoc = await docRef.get();
      bool wasLiked = likeDoc.exists;
      String oldReaction = wasLiked ? (likeDoc.get('reaction') ?? 'like') : '';

      if (wasLiked && oldReaction == reaction) {
        // Unlike
        await docRef.delete();
        setState(() {
          userReactions[postId] = '';
          postLikes[postId] = (postLikes[postId] ?? 1) - 1;
        });
        await _firestore.collection('posts').doc(postId).update({
          'likes_count': FieldValue.increment(-1),
        });
      } else {
        // Like or change reaction
        await docRef.set({
          'user_id': user.uid,
          'reaction': reaction,
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        });
        setState(() {
          userReactions[postId] = reaction;
          if (!wasLiked) {
            postLikes[postId] = (postLikes[postId] ?? 0) + 1;
          }
          likeAnimationControllers[postId]?.forward(from: 0);
        });
        if (!wasLiked) {
          await _firestore.collection('posts').doc(postId).update({
            'likes_count': FieldValue.increment(1),
          });
        }
      }
    } catch (e) {
      print('Error toggling like: $e');
      if (e is FirebaseException && e.code == 'permission-denied') {
        // Handle silently
      } else {
        // Avoid toast
      }
    }
  }

  void _showReactionOptions(String postId) {
    showModalBottomSheet(
      context: context,
      builder: (BuildContext context) {
        return Container(
          padding: const EdgeInsets.all(16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _buildReactionButton('❤️', 'love', postId),
              _buildReactionButton('😊', 'like', postId),
              _buildReactionButton('😢', 'sad', postId),
              _buildReactionButton('😠', 'angry', postId),
            ],
          ),
        );
      },
    );
  }

  Future<void> _initVideoControllers(String postId, String url) async {
    if (url.isEmpty) return;
    try {
      // If a controller already exists, don't re-create
      if (videoPlayerControllers[postId] != null || videoControllers[postId] != null) return;

  final vpc = VideoPlayerController.networkUrl(Uri.parse(url));
      videoPlayerControllers[postId] = vpc;
      // start initialize and wait
      await vpc.initialize();

      final chewie = ChewieController(
        videoPlayerController: vpc,
        autoInitialize: true,
        autoPlay: false,
        looping: false,
        allowMuting: true,
      );

      videoControllers[postId] = chewie;
      if (mounted) setState(() {});
    } catch (e) {
      print('Error initializing video for $postId: $e');
      // Clean up any partially created controllers
      try {
        await videoPlayerControllers[postId]?.dispose();
      } catch (_) {}
      videoPlayerControllers[postId] = null;
      videoControllers[postId] = null;
      if (mounted) setState(() {});
    }
  }

  Widget _buildReactionButton(String emoji, String reaction, String postId) {
    return GestureDetector(
      onTap: () {
        Navigator.pop(context);
        _toggleLike(postId, reaction);
      },
      child: Text(
        emoji,
        style: const TextStyle(fontSize: 30),
      ),
    );
  }

  String _getReactionEmoji(String reaction) {
    switch (reaction) {
      case 'love':
        return '❤️';
      case 'like':
        return '😊';
      case 'sad':
        return '😢';
      case 'angry':
        return '😠';
      default:
        return '👍';
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: true,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Newsfeed'),
          backgroundColor: Colors.blue,
          foregroundColor: Colors.white,
          toolbarHeight: 48,
          actions: [
            IconButton(
              tooltip: 'Messages',
              icon: const Icon(Icons.message),
              onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const MessagesPage())),
            ),
            IconButton(
              tooltip: 'Videos',
              icon: const Icon(Icons.videocam),
              onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const VideosPage())),
            ),
            IconButton(
              tooltip: 'Jobs',
              icon: const Icon(Icons.work),
              onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const JobsPage())),
            ),
          ],
        ),
        body: Column(
          children: [
            Card(
              margin: const EdgeInsets.all(8.0),
              child: Padding(
                padding: const EdgeInsets.all(8.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    GestureDetector(
                      onTap: () {
                        if (userData != null && _auth.currentUser != null) {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (context) => SeeProfileFromNewsfeed(userId: _auth.currentUser!.uid),
                            ),
                          );
                        }
                      },
                      child: Row(
                        children: [
                          CircleAvatar(
                            radius: 20,
                            backgroundColor: Colors.grey[300],
                            backgroundImage: userData?['profile_image'] != null
                                ? CachedNetworkImageProvider(userData!['profile_image'])
                                : null,
                            child: userData?['profile_image'] == null
                                ? const Icon(Icons.person, size: 20, color: Colors.grey)
                                : null,
                          ),
                          const SizedBox(width: 10),
                          Text(
                            userData?['name'] ?? 'User',
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: _postController,
                      maxLines: null,
                      minLines: 1,
                      decoration: InputDecoration(
                        hintText: "What's on your mind?",
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(20),
                        ),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.photo_library, size: 24),
                          onPressed: _pickImage,
                          tooltip: 'Add Photo',
                        ),
                        IconButton(
                          icon: const Icon(Icons.video_library, size: 24),
                          onPressed: _pickVideo,
                          tooltip: 'Add Video',
                        ),
                        IconButton(
                          icon: const Icon(Icons.send, size: 24),
                          onPressed: _createPost,
                          tooltip: 'Post',
                        ),
                      ],
                    ),
                    if (_selectedImage != null || _selectedVideo != null)
                      Container(
                        height: 150,
                        margin: const EdgeInsets.only(top: 10),
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.grey),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          children: [
                            if (_selectedImage != null)
                              Expanded(
                                child: Image.file(
                                  _selectedImage!,
                                  fit: BoxFit.cover,
                                ),
                              ),
                            if (_selectedVideo != null)
                              Expanded(
                                child: Chewie(
                                  controller: ChewieController(
                                    videoPlayerController: VideoPlayerController.file(_selectedVideo!),
                                    autoInitialize: true,
                                    autoPlay: false,
                                    looping: false,
                                    allowMuting: true,
                                    errorBuilder: (context, errorMessage) => Center(child: Text('Video error: $errorMessage')),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
            if (!hasConnection)
              const Padding(
                padding: EdgeInsets.all(8.0),
                child: Text('No internet connection. Showing cached data.'),
              ),
            Expanded(
              child: isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : posts.isEmpty
                      ? const Center(child: Text('No posts available'))
                      : ListView.builder(
                          itemCount: posts.length,
                          itemBuilder: (context, index) {
                            final post = posts[index];
                            return _buildPostItem(post);
                          },
                        ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPostItem(Map<String, dynamic> post) {
    final String postId = post['id'];
    final int likesCount = postLikes[postId] ?? 0;
    final int commentsCount = postCommentCounts[postId] ?? 0;
    final String userReaction = userReactions[postId] ?? '';

    if (!likeAnimationControllers.containsKey(postId)) {
      likeAnimationControllers[postId] = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 300),
      );
    }

    return Card(
      margin: const EdgeInsets.all(8.0),
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            GestureDetector(
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => SeeProfileFromNewsfeed(userId: post['user_id']),
                  ),
                );
              },
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 20,
                    backgroundColor: Colors.grey[300],
                    backgroundImage: post['user_data']?['profile_image'] != null
                        ? CachedNetworkImageProvider(post['user_data']['profile_image'])
                        : null,
                    child: post['user_data']?['profile_image'] == null
                        ? const Icon(Icons.person, size: 20, color: Colors.grey)
                        : null,
                  ),
                  const SizedBox(width: 10),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        post['user_data']?['name'] ?? 'Unknown User',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      Text(
                        DateFormat('MMM dd, yyyy - HH:mm').format(
                          DateTime.fromMillisecondsSinceEpoch(post['timestamp'] ?? 0),
                        ),
                        style: const TextStyle(color: Colors.grey, fontSize: 12),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            if (post['text']?.isNotEmpty ?? false) Text(post['text']),
            const SizedBox(height: 10),
            if (post['image_url']?.isNotEmpty ?? false)
              CachedNetworkImage(
                imageUrl: post['image_url'],
                placeholder: (context, url) => const SizedBox(
                  height: 200,
                  child: Center(child: CircularProgressIndicator()),
                ),
                errorWidget: (context, url, error) => const Icon(Icons.error),
                fit: BoxFit.cover,
              ),
            if (post['video_url']?.isNotEmpty ?? false)
              SizedBox(
                height: 200,
                child: Builder(builder: (context) {
                  final url = post['video_url'] as String? ?? '';
                  // kick off lazy initialization if not yet created
                  if ((videoControllers[postId] == null) && (videoPlayerControllers[postId] == null)) {
                    // initialize in background; don't await here
                    _initVideoControllers(postId, url);
                    return const Center(child: CircularProgressIndicator());
                  }

                  if (videoControllers[postId] != null) {
                    return Chewie(controller: videoControllers[postId]!);
                  }

                  // If player exists but chewie not ready, show loading
                  if (videoPlayerControllers[postId] != null && !(videoPlayerControllers[postId]!.value.isInitialized)) {
                    return const Center(child: CircularProgressIndicator());
                  }

                  return const Center(child: Text('Video unavailable'));
                }),
              ),
            const SizedBox(height: 10),
            Row(
              children: [
                if (likesCount > 0)
                  Row(
                    children: [
                      if (userReaction.isNotEmpty) Text(_getReactionEmoji(userReaction)),
                      Text('$likesCount'),
                      const SizedBox(width: 16),
                    ],
                  ),
                if (commentsCount > 0) Text('$commentsCount comments'),
              ],
            ),
            const Divider(),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                GestureDetector(
                  onTap: () => _toggleLike(postId, 'like'),
                  onLongPress: () => _showReactionOptions(postId),
                  child: ScaleTransition(
                    scale: Tween<double>(begin: 1.0, end: 1.2).animate(
                      CurvedAnimation(
                        parent: likeAnimationControllers[postId]!,
                        curve: Curves.easeInOut,
                      ),
                    ),
                    child: Row(
                      children: [
                        if (userReaction.isEmpty)
                          Icon(
                            Icons.thumb_up,
                            color: Colors.grey,
                          )
                        else
                          Text(
                            _getReactionEmoji(userReaction),
                            style: const TextStyle(fontSize: 24, color: Colors.blue),
                          ),
                        const SizedBox(width: 5),
                        Text(
                          userReaction.isEmpty ? 'Like' : 'Liked',
                          style: TextStyle(
                            color: userReaction.isNotEmpty ? Colors.blue : Colors.grey,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                GestureDetector(
                  onTap: () {
                    setState(() {
                      expandedComments[postId] = !(expandedComments[postId] ?? false);
                    });
                    if (expandedComments[postId] ?? false) {
                      _fetchComments(postId);
                      commentSubscriptions[postId]?.cancel();
                      commentSubscriptions[postId] = _firestore
                          .collection('posts')
                          .doc(postId)
                          .collection('comments')
                          .orderBy('timestamp', descending: false)
                          .snapshots()
                          .listen((_) => _fetchComments(postId), onError: (e) {
                        print('Error in comments listener: $e');
                        setState(() {
                          postComments[postId] = [];
                        });
                      });
                    } else {
                      commentSubscriptions[postId]?.cancel();
                      commentSubscriptions.remove(postId);
                      postComments.remove(postId);
                    }
                  },
                  child: Row(
                    children: [
                      const Icon(Icons.comment, color: Colors.grey),
                      const SizedBox(width: 5),
                      const Text('Comment', style: TextStyle(color: Colors.grey)),
                    ],
                  ),
                ),
              ],
            ),
            if (expandedComments[postId] ?? false) ...[
              const Divider(),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8.0),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: perPostCommentControllers.putIfAbsent(postId, () => TextEditingController()),
                        decoration: const InputDecoration(
                          hintText: 'Write a comment...',
                          border: OutlineInputBorder(),
                          contentPadding: EdgeInsets.symmetric(horizontal: 10),
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.send),
                      onPressed: () => _addComment(postId, perPostCommentControllers[postId]!),
                    ),
                  ],
                ),
              ),
              if (postComments[postId] == null)
                const Center(child: CircularProgressIndicator())
              else if (postComments[postId]!.isEmpty)
                const Text('No comments yet')
              else
                Column(
                  children: postComments[postId]!
                      .map((comment) => _buildCommentItem(postId, comment))
                      .toList(),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildCommentItem(String postId, Map<String, dynamic> comment) {
    final String commentId = comment['id'];
    final bool isEditing = commentEditing[commentId] ?? false;

    if (!commentEditControllers.containsKey(commentId)) {
      commentEditControllers[commentId] = TextEditingController(text: comment['text']);
    }

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 5.0),
      padding: const EdgeInsets.all(8.0),
      decoration: BoxDecoration(
        color: Colors.grey[100],
        borderRadius: BorderRadius.circular(8.0),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 15,
                backgroundColor: Colors.grey[300],
                backgroundImage: comment['user_data']?['profile_image'] != null
                    ? CachedNetworkImageProvider(comment['user_data']['profile_image'])
                    : null,
                child: comment['user_data']?['profile_image'] == null
                    ? const Icon(Icons.person, size: 15, color: Colors.grey)
                    : null,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  comment['user_data']?['name'] ?? 'Unknown User',
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                ),
              ),
              if (comment['user_id'] == _auth.currentUser?.uid) ...[
                IconButton(
                  icon: const Icon(Icons.edit, size: 16),
                  onPressed: () {
                    setState(() {
                      commentEditing[commentId] = true;
                    });
                  },
                  tooltip: 'Edit Comment',
                ),
                IconButton(
                  icon: const Icon(Icons.delete, size: 16),
                  onPressed: () => _deleteComment(postId, commentId),
                  tooltip: 'Delete Comment',
                ),
              ],
            ],
          ),
          const SizedBox(height: 5),
          if (isEditing)
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: commentEditControllers[commentId],
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(horizontal: 8),
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.check, size: 16),
                  onPressed: () => _editComment(postId, commentId, commentEditControllers[commentId]!.text),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 16),
                  onPressed: () {
                    setState(() {
                      commentEditing[commentId] = false;
                    });
                  },
                ),
              ],
            )
          else
            Text(comment['text'] ?? ''),
          if (comment['edited'] ?? false)
            const Text(
              'edited',
              style: TextStyle(fontSize: 10, color: Colors.grey),
            ),
        ],
      ),
    );
  }
}